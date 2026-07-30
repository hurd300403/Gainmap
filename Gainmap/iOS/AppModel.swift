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

struct SessionExportResult {
    let urls: [URL]
    let failedCount: Int
}

enum SessionExportError: LocalizedError {
    case busy
    case missingSession
    case noExports

    var errorDescription: String? {
        switch self {
        case .busy:
            return "Another session is already exporting."
        case .missingSession:
            return "That session is no longer available."
        case .noExports:
            return "None of the photos could be exported. Make sure their originals have finished syncing and try again."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var cards: [SessionCard] = []
    @Published private(set) var syncing = false
    @Published private(set) var initialSyncComplete = false
    @Published private(set) var syncPassInFlight = false
    @Published private(set) var pendingWorkCount = 0
    @Published private(set) var hasSyncIssue = false
    @Published private(set) var exportingSessionID: UUID?
    @Published private(set) var exportCompletedCount = 0
    @Published private(set) var exportTotalCount = 0
    /// Resolved sources for every cell in the currently open editor. Remote
    /// sessions use the small synced thumbnail tier; full originals remain
    /// on-demand for the selected preview and export.
    @Published private(set) var editorThumbnailURLs: [UUID: URL] = [:]
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
    private var editorThumbnailSessionID: UUID?

    /// Thumb hashes whose download failed this session — skipped until the
    /// user explicitly refreshes or the app foregrounds (no infinite retry).
    private var failedThumbs: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var refreshQueued = false
    private var progressRefreshTask: Task<Void, Never>?
    private var lastSyncStatusSnapshot: SyncStatusSnapshot?

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
        let root = await store.root
            .appendingPathComponent("users/\(uid)", isDirectory: true)
        lastSyncStatusSnapshot =
            SyncEngine.persistedStatusSnapshot(root: root)
        if wantSync {
            let engine = SyncEngine(uid: uid, deviceID: Self.deviceID,
                                    backend: FirebaseSyncBackend(),
                                    store: store, root: root)
            self.engine = engine
            await engine.setOnRemoteChange { [weak self] id in
                Task { @MainActor in await self?.remoteChanged(id, expectedUID: uid) }
            }
            await engine.setOnTransferProgress { [weak self] in
                Task { @MainActor in
                    self?.transferProgressChanged(expectedUID: uid)
                }
            }
            await engine.start()
            lastSyncStatusSnapshot = await engine.statusSnapshot
            syncing = true
            syncPassInFlight = true
            Task { [weak self] in
                await engine.drainOnce()
                await engine.pumpTransfers()
                guard let self, self.activeUID == uid else { return }
                self.syncPassInFlight = false
                self.initialSyncComplete = true
                self.scheduleRefresh()
            }
        }
        scheduleRefresh()
    }

    private func deactivate(clearCards: Bool = true) async {
        refreshTask?.cancel()
        refreshTask = nil
        progressRefreshTask?.cancel()
        progressRefreshTask = nil
        refreshQueued = false
        if let engine {
            await engine.setOnRemoteChange(nil)
            await engine.setOnTransferProgress(nil)
            await engine.stop()
        }
        engine = nil
        store = nil
        activeUID = nil
        syncing = false
        initialSyncComplete = false
        syncPassInFlight = false
        pendingWorkCount = 0
        hasSyncIssue = false
        lastSyncStatusSnapshot = nil
        failedThumbs = []
        editorThumbnailSessionID = nil
        editorThumbnailURLs = [:]
        activeEditorModel = nil
        if clearCards {
            cards = []
            initialLoadDone = false
        }
    }

    func appBecameActive() async {
        failedThumbs = []   // give failed thumb downloads another chance
        guard let engine else { return }
        syncPassInFlight = true
        await engine.retryTransfers()
        await engine.drainOnce()
        syncPassInFlight = false
        scheduleRefresh()
        if let sessionID = editorThumbnailSessionID {
            await prepareEditorThumbnails(sessionID: sessionID)
        }
    }

    /// The editor's persist hook: journal + drain local edits.
    func sessionPersisted(_ session: Session, before: Session?) {
        // Publish the local mutation immediately. Waiting for a full upload
        // made the editor ring and covers look stale; without an engine
        // (local/waitlisted use), they otherwise never refreshed at all.
        scheduleRefresh()
        if editorThumbnailSessionID == session.id {
            Task { [weak self] in
                await self?.prepareEditorThumbnails(sessionID: session.id)
            }
        }
        guard let engine else { return }
        let expectedUID = activeUID
        syncPassInFlight = true
        Task { [weak self] in
            await engine.noteLocalSession(session, before: before)
            await engine.drainOnce()
            await engine.pumpTransfers()
            guard let self, self.activeUID == expectedUID else { return }
            self.syncPassInFlight = false
            self.scheduleRefresh()
        }
    }

    /// Inbound change: fold into the open editor (if it's this session),
    /// then rebuild the grid.
    private func remoteChanged(_ sessionID: UUID, expectedUID: String) async {
        guard activeUID == expectedUID else { return }
        if let editorModel = activeEditorModel, editorModel.session.id == sessionID,
           let fresh = await store?.load(id: sessionID) {
            editorModel.reloadFromRemote(fresh)
            Task { [weak self] in
                await self?.prepareEditorThumbnails(sessionID: sessionID)
            }
        }
        scheduleRefresh()
    }

    private func transferProgressChanged(expectedUID: String) {
        guard activeUID == expectedUID, progressRefreshTask == nil else { return }
        progressRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled,
                  self.activeUID == expectedUID else { return }
            self.progressRefreshTask = nil
            self.scheduleRefresh()
        }
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
        let status: SyncStatusSnapshot?
        if let engine {
            let live = await engine.statusSnapshot
            lastSyncStatusSnapshot = live
            status = live
        } else {
            status = lastSyncStatusSnapshot
        }
        let knownSynced = status?.knownSyncedSessionIDs(for: sessions) ?? []
        let metrics = SessionSyncMetrics.calculate(
            sessions: sessions,
            journal: status?.journal,
            transfers: status?.transfers,
            persistedSyncedSessionIDs: knownSynced)
        if let status {
            pendingWorkCount = status.journal.entries.count
                + status.transfers.transfers.filter { $0.status != .done }.count
            hasSyncIssue = status.transfers.hasParked
                || status.transfers.isQuotaExceeded
                || !status.journal.conflicts.isEmpty
        } else {
            pendingWorkCount = 0
            hasSyncIssue = false
        }
        var missing: [String] = []   // thumb hashes to hydrate in phase 2
        cards = buildCards(
            sessions: sessions,
            metrics: metrics,
            collectMissing: &missing)
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
        let refreshedStatus = await engine.statusSnapshot
        lastSyncStatusSnapshot = refreshedStatus
        let refreshedKnown =
            refreshedStatus.knownSyncedSessionIDs(for: fresh)
        let refreshedMetrics = SessionSyncMetrics.calculate(
            sessions: fresh,
            journal: refreshedStatus.journal,
            transfers: refreshedStatus.transfers,
            persistedSyncedSessionIDs: refreshedKnown)
        var ignored: [String] = []
        cards = buildCards(
            sessions: fresh,
            metrics: refreshedMetrics,
            collectMissing: &ignored)
    }

    /// Cover URL preference: local thumb file if present; else the photo's
    /// own local source file (imports on this device); else nil (placeholder)
    /// with the hash queued for hydration.
    private func buildCards(sessions: [Session], metrics: SessionSyncMetrics,
                            collectMissing: inout [String]) -> [SessionCard] {
        let fm = FileManager.default
        guard let store else { return [] }
        let managedRoot = store.managedFilesDir
        return sessions.map { session in
            var covers: [URL?] = []
            for photo in session.photos.prefix(4) {
                if let hash = photo.contentHash {
                    let thumb = store.thumbnailURL(forContentHash: hash)
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
                pendingSync: metrics.pendingSessionIDs.contains(session.id),
                syncIssue: metrics.issueSessionIDs.contains(session.id),
                syncProgress: metrics.progressBySessionID[session.id],
                knownSynced: metrics.knownSyncedSessionIDs.contains(session.id))
        }
    }

    // ------------------------------------------------------------- editor thumbs

    func beginEditing(_ model: MergeModel) {
        if activeEditorModel === model,
           editorThumbnailSessionID == model.session.id {
            return
        }
        activeEditorModel = model
        editorThumbnailSessionID = model.session.id
        editorThumbnailURLs = [:]
    }

    func endEditing(_ model: MergeModel) {
        guard activeEditorModel === model else { return }
        activeEditorModel = nil
        editorThumbnailSessionID = nil
        editorThumbnailURLs = [:]
    }

    /// Resolve local sources immediately, then download missing 1024px thumbs
    /// four at a time. A 20–30 photo session therefore fills its filmstrip
    /// without bulk-downloading 20–30 originals.
    func prepareEditorThumbnails(sessionID: UUID) async {
        guard editorThumbnailSessionID == sessionID,
              let store,
              let session = await store.load(id: sessionID)
        else { return }

        let plan = store.thumbnailPlan(for: session)
        guard editorThumbnailSessionID == sessionID,
              !Task.isCancelled else { return }
        editorThumbnailURLs = plan.localURLsByPhotoID

        guard let engine, !plan.missing.isEmpty else { return }
        let requestsByHash = Dictionary(
            grouping: plan.missing,
            by: \.contentHash)
        let hashes = Array(requestsByHash.keys)

        await withTaskGroup(of: (String, URL?).self) { group in
            var next = min(4, hashes.count)
            for hash in hashes.prefix(next) {
                group.addTask {
                    (hash, await engine.hydrateThumb(hash: hash))
                }
            }
            while let (hash, url) = await group.next() {
                guard !Task.isCancelled,
                      editorThumbnailSessionID == sessionID else {
                    group.cancelAll()
                    return
                }
                if let url,
                   FileManager.default.fileExists(atPath: url.path) {
                    var updated = editorThumbnailURLs
                    for request in requestsByHash[hash] ?? [] {
                        updated[request.photoID] = url
                    }
                    editorThumbnailURLs = updated
                }
                if next < hashes.count {
                    let nextHash = hashes[next]
                    next += 1
                    group.addTask {
                        (nextHash, await engine.hydrateThumb(hash: nextHash))
                    }
                }
            }
        }
    }

    func editorOriginalBecameAvailable(
        sessionID: UUID,
        photoID: UUID,
        url: URL
    ) {
        guard editorThumbnailSessionID == sessionID,
              FileManager.default.fileExists(atPath: url.path) else { return }
        var updated = editorThumbnailURLs
        updated[photoID] = url
        editorThumbnailURLs = updated
    }

    // ------------------------------------------------------------- actions

    func renameSession(id: UUID, to title: String) async {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let store,
              var session = await store.load(id: id),
              session.title != clean else { return }
        let before = session
        session.title = clean
        session.updatedAt = Date()
        try? await store.save(session)
        if let engine {
            syncPassInFlight = true
            await engine.noteLocalSession(session, before: before)
            await engine.drainOnce()
            await engine.pumpTransfers()
            syncPassInFlight = false
        }
        scheduleRefresh()
    }

    func deleteSession(id: UUID) async {
        guard exportingSessionID != id, let store else { return }
        if let engine {
            syncPassInFlight = true
            await engine.deleteSessionLocally(id)
            await engine.drainOnce()
            syncPassInFlight = false
        } else {
            await store.delete(id: id)
        }
        scheduleRefresh()
    }

    func exportSession(id: UUID) async throws -> SessionExportResult {
        guard exportingSessionID == nil else { throw SessionExportError.busy }
        guard let store, let session = await store.load(id: id) else {
            throw SessionExportError.missingSession
        }

        exportingSessionID = id
        exportCompletedCount = 0
        exportTotalCount = session.photos.count
        defer {
            exportingSessionID = nil
            exportCompletedCount = 0
            exportTotalCount = 0
        }

        let exportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-exports/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: exportDir, withIntermediateDirectories: true)
        let merge = MergeModel(
            session: session,
            store: store,
            output: .managedDirectory(exportDir))
        merge.onSessionPersisted = { [weak self] updated, before in
            Task { @MainActor in self?.sessionPersisted(updated, before: before) }
        }

        var outputs: [URL] = []
        var failed = 0
        for item in merge.items {
            if !FileManager.default.fileExists(atPath: item.sdrURL.path) {
                let hash = session.photos.first(where: { $0.id == item.id })?.contentHash
                guard let hash, await engine?.hydrateOriginal(hash: hash) != nil else {
                    failed += 1
                    exportCompletedCount += 1
                    continue
                }
            }
            let itemExportDir = exportDir
                .appendingPathComponent(item.id.uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: itemExportDir, withIntermediateDirectories: true)
            merge.outputPolicy = .managedDirectory(itemExportDir)
            await merge.mergeItem(item.id)
            if let output = merge.items.first(where: { $0.id == item.id })?.outputURL {
                outputs.append(output)
            } else {
                failed += 1
            }
            exportCompletedCount += 1
        }
        await merge.flushSession()
        scheduleRefresh()
        guard !outputs.isEmpty else { throw SessionExportError.noExports }
        return SessionExportResult(urls: outputs, failedCount: failed)
    }

    func session(id: UUID) async -> Session? {
        await store?.load(id: id)
    }
}
