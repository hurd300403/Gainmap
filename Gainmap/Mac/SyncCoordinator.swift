//
//  SyncCoordinator.swift
//  Gainmap (Mac) — P5
//
//  Owns the Mac's per-uid store + sync engine lifecycle, driven by auth
//  state. Signed out: the classic local store (uid "local"), no engine.
//  Signed in + admitted: one-time adoption of pre-auth sessions, the store
//  switches to the real uid, the engine starts, and MergeModel's persist
//  hook feeds local edits into the journal while inbound changes fold back
//  into the live model.
//

import Foundation
import SwiftUI
import GainmapCore

struct DeletedSessionNotice: Identifiable, Equatable {
    var id: UUID { session.id }
    let session: Session
    let needsRemoteUndo: Bool
    let namespace: String
}

@MainActor
final class SyncCoordinator: ObservableObject {

    @Published private(set) var syncing = false
    @Published private(set) var cards: [SessionCard] = []
    @Published private(set) var initialLoadDone = false
    @Published private(set) var pendingWorkCount = 0
    @Published private(set) var hasSyncIssue = false
    @Published private(set) var initialSyncComplete = false
    @Published private(set) var syncPassInFlight = false
    @Published private(set) var namespaceID = "local"
    @Published private(set) var recentlyDeleted: DeletedSessionNotice?
    /// The open editor was tombstoned by another device and should return to
    /// the library. Nil is restored after the root consumes the event.
    @Published private(set) var externallyClosedSession: UUID?

    private var engine: SyncEngine?
    private var model: MergeModel?
    private var currentUID: String?
    private(set) var store: FileSessionStore?
    private var failedThumbs: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var refreshQueued = false
    private var progressRefreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    var hasOutstandingCloudWork: Bool {
        syncing && (pendingWorkCount > 0 || syncPassInFlight)
    }

    /// Stable per-install device identity (the `by` in rev metadata).
    static var deviceID: String {
        let key = "gm-device-id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = "mac-\(UUID().uuidString.prefix(8))"
        UserDefaults.standard.set(fresh, forKey: key)
        return String(fresh)
    }

    /// True in dev/test launches that must not touch stores or Firebase.
    static var isEphemeralLaunch: Bool {
        UserDefaults.standard.string(forKey: "gm-seed") != nil
            || UserDefaults.standard.bool(forKey: "gm-no-store")
    }

    /// The UI can still exercise full session management in isolated
    /// screenshot/QA launches. Give those runs a process-scoped temporary
    /// store: they skip the real library and Firebase, not autosave.
    func bind(model: MergeModel) async {
        self.model = model
        guard Self.isEphemeralLaunch, store == nil else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Gainmap-QA-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        let store = FileSessionStore(root: root)
        self.store = store
        currentUID = "local"
        await model.attachStoreAndRestore(store)
        model.onSessionPersisted = { [weak self] session, before in
            Task { @MainActor in await self?.localPersisted(session, before: before) }
        }
        scheduleRefresh()
    }

    /// Called once at launch and again on every auth-state change.
    func apply(authState: AuthState, model: MergeModel) async {
        guard !Self.isEphemeralLaunch else { return }
        self.model = model
        switch authState {
        case .ready(let uid):
            await activate(uid: uid, withEngine: true, model: model)
        case .waitlisted(let uid):
            await activate(uid: uid, withEngine: false, model: model)
        case .signedOut, .failed:
            await activate(uid: "local", withEngine: false, model: model)
        case .admitting:
            break   // keep whatever is attached; .ready/.waitlisted follows
        }
    }

    private func activate(uid: String, withEngine: Bool, model: MergeModel) async {
        if currentUID == uid, (engine != nil) == withEngine { return }
        let switchingUID = currentUID != uid
        if switchingUID {
            refreshGeneration += 1
            namespaceID = uid
            recentlyDeleted = nil
        }

        // Order matters (P5 review, critical):
        // 1. FLUSH FIRST — into the OLD namespace, while the outgoing
        //    engine's persist hook is still armed (so the edit journals).
        //    Flushing after adoption re-created the just-swept users/local
        //    file and stranded the newest edits in a dead namespace.
        await model.flushSession()
        if let engine {
            await engine.setOnRemoteChange(nil)
            await engine.setOnTransferProgress(nil)
            await engine.stop()
            self.engine = nil
        }
        progressRefreshTask?.cancel()
        progressRefreshTask = nil
        model.onSessionPersisted = nil
        syncing = false
        initialSyncComplete = false
        syncPassInFlight = false
        currentUID = uid

        // 2. ADOPT — users/local moves under the real uid (newest copy wins).
        let store = FileSessionStore(uid: uid)
        self.store = store
        if uid != "local" {
            await store.adoptLocalSessions()
        }
        // 3. ATTACH — resetting the model whenever the namespace changed:
        //    keeping the old account's session live over the new store wrote
        //    A's photos into whatever namespace came next (sign-out leak).
        await model.attachStoreAndRestore(store, reset: switchingUID)
        // Keep the library current even while signed out/waitlisted; the
        // engine is optional, local session persistence is not.
        model.onSessionPersisted = { [weak self] session, before in
            Task { @MainActor in await self?.localPersisted(session, before: before) }
        }
        scheduleRefresh()

        guard withEngine else { return }
        let root = await store.root.appendingPathComponent("users/\(uid)", isDirectory: true)
        let engine = SyncEngine(uid: uid, deviceID: Self.deviceID,
                                backend: FirebaseSyncBackend(),
                                store: store, root: root)
        self.engine = engine
        await engine.setOnRemoteChange { [weak self] sessionID in
            Task { @MainActor in
                await self?.remoteChanged(sessionID, expectedUID: uid)
            }
        }
        await engine.setOnTransferProgress { [weak self] in
            Task { @MainActor in
                self?.transferProgressChanged(expectedUID: uid)
            }
        }
        await engine.start()
        syncing = true
        syncPassInFlight = true
        Task { [weak self] in
            await engine.drainOnce()
            await engine.pumpTransfers()
            guard let self, self.currentUID == uid else { return }
            self.syncPassInFlight = false
            self.initialSyncComplete = true
            self.scheduleRefresh()
        }
    }

    private func localPersisted(_ session: Session, before: Session?) async {
        scheduleRefresh()
        guard let engine else { return }
        syncPassInFlight = true
        await engine.noteLocalSession(session, before: before)
        await engine.drainOnce()
        await engine.pumpTransfers()
        syncPassInFlight = false
        scheduleRefresh()
    }

    private func remoteChanged(_ sessionID: UUID, expectedUID: String) async {
        // A listener callback can already be queued when sign-out stops its
        // engine. Never let that old account's event touch the newly attached
        // namespace.
        guard currentUID == expectedUID, let model, let store else { return }
        if model.session.id == sessionID {
            if let fresh = await store.load(id: sessionID) {
                model.reloadFromRemote(fresh)
            } else {
                // Flush a pending local look into the conflict machinery
                // before adopting delete-wins, then ensure no later navigation
                // can recreate the tombstoned file.
                await model.flushSession()
                await Task.yield()
                await store.delete(id: sessionID)
                if model.discardSessionIfCurrent(sessionID) {
                    externallyClosedSession = sessionID
                }
            }
        }
        scheduleRefresh()
    }

    private func transferProgressChanged(expectedUID: String) {
        guard currentUID == expectedUID, progressRefreshTask == nil else { return }
        progressRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled,
                  self.currentUID == expectedUID else { return }
            self.progressRefreshTask = nil
            self.scheduleRefresh()
        }
    }

    /// Foreground hook: retry parked transfers + drain anything pending.
    func appBecameActive() async {
        failedThumbs = []
        scheduleRefresh()
        guard let engine else { return }
        syncPassInFlight = true
        await engine.retryTransfers()
        await engine.drainOnce()
        syncPassInFlight = false
        scheduleRefresh()
    }

    // ------------------------------------------------------------- library

    /// Coalesced local-first library refresh. Large grids publish before any
    /// network thumb hydration, then update once when downloaded covers land.
    func scheduleRefresh() {
        if refreshTask != nil {
            refreshQueued = true
            return
        }
        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            await self?.performRefresh(generation: generation)
            guard let self else { return }
            self.refreshTask = nil
            if self.refreshQueued {
                self.refreshQueued = false
                self.scheduleRefresh()
            }
        }
    }

    func refresh() async {
        failedThumbs = []
        scheduleRefresh()
    }

    private func performRefresh(generation: Int) async {
        guard let store else {
            guard generation == refreshGeneration else { return }
            cards = []
            initialLoadDone = true
            return
        }

        let sessions = await store.loadAll()
        let journal = await engine?.journalSnapshot
        let transfers = await engine?.transferSnapshot
        let metrics = SessionSyncMetrics.calculate(
            sessions: sessions, journal: journal, transfers: transfers)
        var missing: [String] = []
        let localCards = buildCards(
            sessions: sessions,
            metrics: metrics,
            collectMissing: &missing)

        guard generation == refreshGeneration else { return }
        cards = localCards
        initialLoadDone = true
        if let journal, let transfers {
            pendingWorkCount = journal.entries.count
                + transfers.transfers.filter { $0.status != .done }.count
            hasSyncIssue = transfers.hasParked || transfers.isQuotaExceeded
                || !journal.conflicts.isEmpty
        } else {
            pendingWorkCount = 0
            hasSyncIssue = false
        }

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
        guard anyLanded, generation == refreshGeneration, !Task.isCancelled else { return }
        let fresh = await store.loadAll()
        var ignored: [String] = []
        cards = buildCards(
            sessions: fresh,
            metrics: metrics,
            collectMissing: &ignored)
    }

    private func buildCards(sessions: [Session],
                            metrics: SessionSyncMetrics,
                            collectMissing: inout [String]) -> [SessionCard] {
        guard let store else { return [] }
        let fm = FileManager.default
        let managedRoot = store.managedFilesDir
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
                let source = photo.sourceURL(managedRoot: managedRoot)
                covers.append(fm.fileExists(atPath: source.path) ? source : nil)
            }
            return SessionCard(
                id: session.id,
                title: session.title,
                photoCount: session.photos.count,
                updatedAt: session.updatedAt,
                covers: covers,
                pendingSync: metrics.pendingSessionIDs.contains(session.id),
                syncIssue: metrics.issueSessionIDs.contains(session.id),
                syncProgress: metrics.progressBySessionID[session.id])
        }
    }

    @discardableResult
    func openSession(id: UUID) async -> Bool {
        if let engine { await engine.listenPhotos(session: id) }
        return await model?.openSession(id: id) ?? false
    }

    @discardableResult
    func startSession(with urls: [URL]) async -> Bool {
        let hasJPEG = urls.contains { FileRole.role(for: $0) == .sdr }
        guard hasJPEG, let model, await model.startNewSession() else { return false }
        model.addFiles(urls)
        return !model.items.isEmpty
    }

    func renameSession(id: UUID, to title: String) async {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let store else { return }
        if let model, model.session.id == id {
            model.setSessionTitle(clean)
            await model.flushSession()
            scheduleRefresh()
            return
        }
        guard var session = await store.load(id: id), session.title != clean else { return }
        let before = session
        session.title = clean
        session.updatedAt = Date()
        try? await store.save(session)
        await localPersisted(session, before: before)
    }

    func deleteSession(id: UUID) async {
        guard let store, let session = await store.load(id: id) else { return }
        if let model, model.session.id == id {
            guard await model.startNewSession() else { return }
        }
        let needsRemoteUndo = await engine?.everAcked(.session(id)) ?? false
        if let engine {
            await engine.deleteSessionLocally(id)
            await engine.drainOnce()
        } else {
            await store.delete(id: id)
        }
        recentlyDeleted = DeletedSessionNotice(
            session: session,
            needsRemoteUndo: needsRemoteUndo,
            namespace: namespaceID)
        scheduleRefresh()
    }

    func undoLastDelete() async {
        guard let deletion = recentlyDeleted,
              deletion.namespace == namespaceID,
              let store else { return }
        // Seed the local copy first so remote materialization can preserve Mac
        // linked paths and export state instead of replacing them with caches.
        try? await store.save(deletion.session)
        if let engine {
            if deletion.needsRemoteUndo {
                await engine.undoDeleteSessionLocally(deletion.session.id)
            } else {
                await engine.noteLocalSession(deletion.session)
            }
            await engine.drainOnce()
            await engine.pumpTransfers()
        }
        recentlyDeleted = nil
        scheduleRefresh()
    }

    func dismissDeleteNotice() {
        recentlyDeleted = nil
    }

    func consumeExternalClose(_ id: UUID) {
        guard externallyClosedSession == id else { return }
        externallyClosedSession = nil
    }

    /// Download a phone-originated original when its editor item becomes
    /// selected, then rewrite the local-only origin so MergeModel can render it.
    func hydratePhotoIfNeeded(sessionID: UUID, photoID: UUID) async {
        guard let engine, let store,
              var session = await store.load(id: sessionID),
              let index = session.photos.firstIndex(where: { $0.id == photoID }) else { return }
        let fm = FileManager.default
        let managedRoot = store.managedFilesDir
        let currentURL = session.photos[index].sourceURL(managedRoot: managedRoot)
        if fm.fileExists(atPath: currentURL.path) {
            if let model, model.session.id == sessionID,
               model.items.first(where: { $0.id == photoID })?.sdrURL != currentURL {
                model.reloadFromRemote(session)
            }
            return
        }
        guard let hash = session.photos[index].contentHash,
              let hydrated = await engine.hydrateOriginal(hash: hash) else { return }
        let managedPrefix = managedRoot.path + "/"
        if hydrated.path.hasPrefix(managedPrefix) {
            session.photos[index].origin = .managed(
                relativePath: String(hydrated.path.dropFirst(managedPrefix.count)))
        } else {
            session.photos[index].origin = .linked(path: hydrated.path)
        }
        try? await store.save(session)
        if let model, model.session.id == sessionID {
            model.reloadFromRemote(session)
        }
        scheduleRefresh()
    }
}
