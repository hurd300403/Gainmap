//
//  AppModel.swift
//  Gainmap for iPhone (P5)
//
//  Per-uid app state: the session store, the sync engine's lifecycle, and
//  the grid's card list. Auth drives it: `.ready` runs the engine; `.admitting`
//  and `.waitlisted` keep the app fully local (store, no engine); sign-out
//  tears everything down.
//

import Foundation
import SwiftUI
import GainmapCore

@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var cards: [SessionCard] = []
    @Published private(set) var syncing = false
    /// False until the first card build lands — the grid shows a spinner,
    /// not "No sessions yet", while the truth is still unknown.
    @Published private(set) var initialLoadDone = false

    private(set) var store: FileSessionStore?
    private(set) var engine: SyncEngine?
    private var activeUID: String?

    /// The MergeModel of the currently open editor (if any) — inbound sync
    /// folds into it via reloadFromRemote, exactly like the Mac coordinator.
    /// Without this the open editor kept a stale snapshot forever.
    weak var activeEditorModel: MergeModel?

    /// Thumb hashes whose download failed this session — skipped until the
    /// user explicitly refreshes or the app foregrounds (no infinite retry).
    private var failedThumbs: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var refreshQueued = false

    /// Stable per-install device identity (the `by` in rev metadata).
    static var deviceID: String {
        let key = "gm-device-id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = "ios-\(UUID().uuidString.prefix(8))"
        UserDefaults.standard.set(fresh, forKey: key)
        return String(fresh)
    }

    // ------------------------------------------------------------- lifecycle

    func authStateChanged(_ state: AuthState) async {
        switch state {
        case .ready(let uid):
            await activate(uid: uid, syncing: true)
        case .admitting(let uid), .waitlisted(let uid):
            // The grid is interactive in both states — a nil store here made
            // every import during the admission round-trip a silent no-op
            // (P5 review). Store now; the engine attaches when .ready lands.
            await activate(uid: uid, syncing: false)
        case .signedOut, .failed:
            await deactivate()
        }
    }

    private func activate(uid: String, syncing wantSync: Bool) async {
        if activeUID == uid, (engine != nil) == wantSync { return }
        await deactivate(clearCards: activeUID != uid)
        activeUID = uid
        let store = FileSessionStore(uid: uid)
        self.store = store
        if wantSync {
            let root = await store.root.appendingPathComponent("users/\(uid)", isDirectory: true)
            let engine = SyncEngine(uid: uid, deviceID: Self.deviceID,
                                    backend: FirebaseSyncBackend(),
                                    store: store, root: root)
            self.engine = engine
            await engine.setOnRemoteChange { [weak self] id in
                Task { @MainActor in await self?.remoteChanged(id) }
            }
            await engine.start()
            syncing = true
            Task {
                await engine.drainOnce()
                await engine.pumpTransfers()
                self.scheduleRefresh()
            }
        }
        scheduleRefresh()
    }

    private func deactivate(clearCards: Bool = true) async {
        refreshTask?.cancel()
        refreshTask = nil
        refreshQueued = false
        if let engine {
            await engine.setOnRemoteChange(nil)
            await engine.stop()
        }
        engine = nil
        store = nil
        activeUID = nil
        syncing = false
        failedThumbs = []
        if clearCards {
            cards = []
            initialLoadDone = false
        }
    }

    func appBecameActive() async {
        failedThumbs = []   // give failed thumb downloads another chance
        guard let engine else { return }
        await engine.retryTransfers()
        await engine.drainOnce()
        scheduleRefresh()
    }

    /// The editor's persist hook: journal + drain local edits.
    func sessionPersisted(_ session: Session, before: Session?) {
        guard let engine else { return }
        Task {
            await engine.noteLocalSession(session, before: before)
            await engine.drainOnce()
            await engine.pumpTransfers()
        }
    }

    /// Inbound change: fold into the open editor (if it's this session),
    /// then rebuild the grid.
    private func remoteChanged(_ sessionID: UUID) async {
        if let editorModel = activeEditorModel, editorModel.session.id == sessionID,
           let fresh = await store?.load(id: sessionID) {
            editorModel.reloadFromRemote(fresh)
        }
        scheduleRefresh()
    }

    // ------------------------------------------------------------- grid data

    /// Coalesced refresh: at most one in flight; calls that land mid-run
    /// queue exactly one follow-up. Prevents the per-remote-change stampede
    /// that raced Storage downloads and published stale card arrays.
    func scheduleRefresh() {
        if refreshTask != nil {
            refreshQueued = true
            return
        }
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
            guard let self else { return }
            self.refreshTask = nil
            if self.refreshQueued {
                self.refreshQueued = false
                self.scheduleRefresh()
            }
        }
    }

    /// Async entry for view modifiers (.task / .refreshable / onDismiss).
    func refresh() async {
        failedThumbs = []
        scheduleRefresh()
    }

    private func performRefresh() async {
        guard let store else {
            cards = []
            return
        }
        // Phase 1 — LOCAL ONLY, no network: publish immediately so the grid
        // never sits on "No sessions yet" behind downloads.
        let sessions = await store.loadAll()
        var pending = false
        if let engine {
            let transfers = await engine.transferSnapshot
            let journal = await engine.journalSnapshot
            pending = transfers.activeCount > 0 || !journal.pendingEntries.isEmpty
        }
        var missing: [String] = []   // thumb hashes to hydrate in phase 2
        cards = buildCards(sessions: sessions, pending: pending, collectMissing: &missing)
        initialLoadDone = true

        // Phase 2 — hydrate missing thumbs (bounded, deduped, no eternal
        // retries), then publish once more.
        guard let engine, !missing.isEmpty else { return }
        let wanted = Array(Set(missing)).filter { !failedThumbs.contains($0) }
        guard !wanted.isEmpty else { return }
        var anyLanded = false
        await withTaskGroup(of: (String, Bool).self) { group in
            var next = min(4, wanted.count)
            for hash in wanted.prefix(next) {
                group.addTask {
                    let url = await engine.hydrateThumb(hash: hash)
                    return (hash, url != nil)
                }
            }
            while let (hash, ok) = await group.next() {
                if ok { anyLanded = true } else { failedThumbs.insert(hash) }
                if next < wanted.count {
                    let upNext = wanted[next]
                    next += 1
                    group.addTask {
                        let url = await engine.hydrateThumb(hash: upNext)
                        return (upNext, url != nil)
                    }
                }
            }
        }
        guard anyLanded, !Task.isCancelled else { return }
        let fresh = await store.loadAll()
        var ignored: [String] = []
        cards = buildCards(sessions: fresh, pending: pending, collectMissing: &ignored)
    }

    /// Cover URL preference: local thumb file if present; else the photo's
    /// own local source file (imports on this device); else nil (placeholder)
    /// with the hash queued for hydration.
    private func buildCards(sessions: [Session], pending: Bool,
                            collectMissing: inout [String]) -> [SessionCard] {
        let fm = FileManager.default
        guard let store else { return [] }
        let managedRoot = store.managedFilesDir
        // Same layout hydrateThumb writes: <root>/users/<uid>/thumbs/<hash>.jpg
        // (managedFilesDir is <root>/users/<uid>/files — sibling directory).
        let thumbsDir = managedRoot.deletingLastPathComponent()
            .appendingPathComponent("thumbs", isDirectory: true)
        return sessions.map { session in
            var covers: [URL?] = []
            for photo in session.photos.prefix(4) {
                if let hash = photo.contentHash {
                    let thumb = thumbsDir.appendingPathComponent("\(hash).jpg")
                    if fm.fileExists(atPath: thumb.path) {
                        covers.append(thumb)
                        continue
                    }
                    collectMissing.append(hash)
                }
                let src = photo.sourceURL(managedRoot: managedRoot)
                covers.append(fm.fileExists(atPath: src.path) ? src : nil)
            }
            return SessionCard(
                id: session.id,
                title: session.title,
                photoCount: session.photos.count,
                updatedAt: session.updatedAt,
                covers: covers,
                pendingSync: pending)
        }
    }

    func session(id: UUID) async -> Session? {
        await store?.load(id: id)
    }
}
