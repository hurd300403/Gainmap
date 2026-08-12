//
//  SyncCoordinator.swift
//  Gainmap (Mac) — P5
//
//  Owns the Mac's local/per-uid store + sync engine lifecycle. Authentication
//  and Patreon are optional; signed out or unentitled uses a local store and
//  no engine. Once Cloud Sync has activated, entitlement changes retain the
//  uid namespace locally while detaching the engine. On first activation,
//  pre-auth sessions are adopted and MergeModel's persist
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

    private struct LifecycleConfiguration: Equatable {
        let uid: String
        let withEngine: Bool
    }

    @Published private(set) var syncing = false
    @Published private(set) var cards: [SessionCard] = []
    @Published private(set) var initialLoadDone = false
    @Published private(set) var pendingWorkCount = 0
    @Published private(set) var hasSyncIssue = false
    @Published private(set) var initialSyncComplete = false
    @Published private(set) var syncPassInFlight = false
    @Published private(set) var namespaceID = "local"
    @Published private(set) var recentlyDeleted: DeletedSessionNotice?
    /// Lightweight sources for every cell in the open editor. Originals are
    /// still hydrated only when selected; the filmstrip uses synced thumbs.
    @Published private(set) var editorThumbnailURLs: [UUID: URL] = [:]
    /// The open editor was tombstoned by another device and should return to
    /// the library. Nil is restored after the root consumes the event.
    @Published private(set) var externallyClosedSession: UUID?

    private var engine: SyncEngine?
    /// Keeps the durable mutation journal current while Cloud Sync is gated,
    /// without starting any remote listener or transfer.
    private var journalEngine: SyncEngine?
    private var model: MergeModel?
    private var currentUID: String?
    private(set) var store: FileSessionStore?
    private var failedThumbs: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var refreshQueued = false
    private var progressRefreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var refreshRunID: UUID?
    private var lifecycleGeneration: UInt = 0
    private var lifecycleTask: Task<Void, Never>?
    private var completedConfiguration: LifecycleConfiguration?
    private var lastSyncStatusSnapshot: SyncStatusSnapshot?
    private var editorThumbnailSessionID: UUID?

    private var mutationEngine: SyncEngine? { engine ?? journalEngine }

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
        let target: (uid: String, withEngine: Bool)
        switch authState {
        case .ready(let uid):
            target = (uid, true)
        case .checking(let uid), .localOnly(let uid):
            let namespace = AuthController.hasCloudNamespace(for: uid) ? uid : "local"
            target = (namespace, false)
        case .signedOut, .failed:
            target = ("local", false)
        }

        if hasCompletedConfiguration(
            uid: target.uid,
            withEngine: target.withEngine) {
            scheduleRefresh()
            return
        }

        lifecycleGeneration &+= 1
        refreshGeneration &+= 1
        completedConfiguration = nil
        let generation = lifecycleGeneration

        let previous = lifecycleTask
        previous?.cancel()
        let task = Task { @MainActor [weak self, weak model] in
            await previous?.value
            guard let self, let model,
                  self.isCurrentLifecycle(generation) else { return }
            await self.activate(
                uid: target.uid,
                withEngine: target.withEngine,
                model: model,
                generation: generation)
        }
        lifecycleTask = task
        await task.value
    }

    private func activate(
        uid: String,
        withEngine: Bool,
        model: MergeModel,
        generation: UInt
    ) async {
        guard isCurrentLifecycle(generation) else { return }
        let switchingUID = currentUID != uid

        // Order matters (P5 review, critical):
        // 1. FLUSH FIRST — into the OLD namespace, while the outgoing
        //    engine's persist hook is still armed (so the edit journals).
        //    Flushing after adoption re-created the just-swept users/local
        //    file and stranded the newest edits in a dead namespace.
        await model.flushSession()
        guard isCurrentLifecycle(generation) else { return }
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshRunID = nil
        refreshQueued = false
        completedConfiguration = nil
        progressRefreshTask?.cancel()
        progressRefreshTask = nil
        let outgoingEngine = engine
        let outgoingJournal = journalEngine
        engine = nil
        journalEngine = nil
        store = nil
        currentUID = nil
        model.onSessionPersisted = nil
        editorThumbnailSessionID = nil
        editorThumbnailURLs = [:]
        syncing = false
        initialSyncComplete = false
        syncPassInFlight = false
        lastSyncStatusSnapshot = nil
        if let outgoingEngine {
            await outgoingEngine.setOnRemoteChange(nil)
            await outgoingEngine.setOnTransferProgress(nil)
            await outgoingEngine.stop()
        }
        if let outgoingJournal {
            await outgoingJournal.stop()
        }
        guard isCurrentLifecycle(generation) else { return }

        // 2. ADOPT — users/local moves under the real uid (newest copy wins).
        let nextStore = FileSessionStore(uid: uid)
        if uid != "local" {
            await nextStore.adoptLocalSessions()
        }
        guard isCurrentLifecycle(generation) else { return }
        let root = await nextStore.root
            .appendingPathComponent("users/\(uid)", isDirectory: true)
        guard isCurrentLifecycle(generation) else { return }
        store = nextStore
        currentUID = uid
        lastSyncStatusSnapshot =
            SyncEngine.persistedStatusSnapshot(root: root)
        // 3. ATTACH — resetting the model whenever the namespace changed:
        //    keeping the old account's session live over the new store wrote
        //    A's photos into whatever namespace came next (sign-out leak).
        await model.attachStoreAndRestore(nextStore, reset: switchingUID)
        guard isCurrentLifecycle(generation),
              store === nextStore,
              currentUID == uid else { return }
        if switchingUID {
            namespaceID = uid
            recentlyDeleted = nil
        }
        // Keep the library current even while signed out/waitlisted; the
        // engine is optional, local session persistence is not.
        model.onSessionPersisted = { [weak self] session, before in
            Task { @MainActor in
                await self?.localPersisted(
                    session,
                    before: before,
                    expectedUID: uid,
                    generation: generation)
            }
        }
        guard withEngine else {
            if uid != "local" {
                let nextJournal = SyncEngine(
                    uid: uid,
                    deviceID: Self.deviceID,
                    backend: FirebaseSyncBackend(),
                    store: nextStore,
                    root: root)
                journalEngine = nextJournal
                await nextJournal.start(connectToBackend: false)
                guard isCurrentLifecycle(generation),
                      journalEngine === nextJournal else {
                    await abandonEngine(nextJournal)
                    return
                }
                let snapshot = await nextJournal.statusSnapshot
                guard isCurrentLifecycle(generation),
                      journalEngine === nextJournal else {
                    await abandonEngine(nextJournal)
                    return
                }
                lastSyncStatusSnapshot = snapshot
                completedConfiguration = LifecycleConfiguration(
                    uid: uid, withEngine: false)
            } else {
                completedConfiguration = LifecycleConfiguration(
                    uid: uid, withEngine: false)
            }
            scheduleRefresh()
            return
        }
        let nextEngine = SyncEngine(uid: uid, deviceID: Self.deviceID,
                                    backend: FirebaseSyncBackend(),
                                    store: nextStore, root: root)
        engine = nextEngine
        await nextEngine.setOnRemoteChange { [weak self] sessionID in
            Task { @MainActor in
                await self?.remoteChanged(
                    sessionID,
                    expectedUID: uid,
                    generation: generation,
                    expectedEngine: nextEngine)
            }
        }
        guard isCurrentLifecycle(generation), engine === nextEngine else {
            await abandonEngine(nextEngine)
            return
        }
        await nextEngine.setOnTransferProgress { [weak self] in
            Task { @MainActor in
                self?.transferProgressChanged(
                    expectedUID: uid,
                    generation: generation,
                    expectedEngine: nextEngine)
            }
        }
        guard isCurrentLifecycle(generation), engine === nextEngine else {
            await abandonEngine(nextEngine)
            return
        }
        await nextEngine.start()
        guard isCurrentLifecycle(generation), engine === nextEngine else {
            await abandonEngine(nextEngine)
            return
        }
        let snapshot = await nextEngine.statusSnapshot
        guard isCurrentLifecycle(generation), engine === nextEngine else {
            await abandonEngine(nextEngine)
            return
        }
        lastSyncStatusSnapshot = snapshot
        syncing = true
        syncPassInFlight = true
        completedConfiguration = LifecycleConfiguration(
            uid: uid, withEngine: true)
        // Re-project the persisted acknowledgement ledger immediately. The
        // pre-engine local refresh cannot know which clean cards were already
        // synced on the previous launch.
        scheduleRefresh()
        Task { [weak self] in
            await nextEngine.drainOnce()
            await nextEngine.pumpTransfers()
            guard let self,
                  self.isCurrentLifecycle(generation),
                  self.currentUID == uid,
                  self.engine === nextEngine else { return }
            self.syncPassInFlight = false
            self.initialSyncComplete = true
            self.scheduleRefresh()
        }
    }

    private func localPersisted(
        _ session: Session,
        before: Session?,
        expectedUID: String? = nil,
        generation: UInt? = nil
    ) async {
        if let generation, !isCurrentLifecycle(generation) { return }
        if let expectedUID, currentUID != expectedUID { return }
        scheduleRefresh()
        guard let recorder = mutationEngine else { return }
        let expectedGeneration = generation ?? lifecycleGeneration
        let uid = expectedUID ?? currentUID
        await recorder.noteLocalSession(session, before: before)
        guard isCurrentLifecycle(expectedGeneration),
              currentUID == uid,
              mutationEngine === recorder else { return }
        guard engine === recorder else {
            scheduleRefresh()
            return
        }
        syncPassInFlight = true
        await recorder.drainOnce()
        await recorder.pumpTransfers()
        guard isCurrentLifecycle(expectedGeneration),
              currentUID == uid,
              engine === recorder else { return }
        syncPassInFlight = false
        scheduleRefresh()
    }

    private func remoteChanged(
        _ sessionID: UUID,
        expectedUID: String,
        generation: UInt,
        expectedEngine: SyncEngine
    ) async {
        // A listener callback can already be queued when sign-out stops its
        // engine. Never let that old account's event touch the newly attached
        // namespace.
        guard isCurrentLifecycle(generation),
              currentUID == expectedUID,
              engine === expectedEngine,
              hasCompletedConfiguration(
                uid: expectedUID, withEngine: true),
              let model,
              let expectedStore = store else { return }
        if model.session.id == sessionID {
            if let fresh = await expectedStore.load(id: sessionID) {
                guard isCurrentLifecycle(generation),
                      currentUID == expectedUID,
                      engine === expectedEngine,
                      store === expectedStore else { return }
                model.reloadFromRemote(fresh)
                Task { [weak self] in
                    await self?.prepareEditorThumbnails(sessionID: sessionID)
                }
            } else {
                // Flush a pending local look into the conflict machinery
                // before adopting delete-wins, then ensure no later navigation
                // can recreate the tombstoned file.
                await model.flushSession()
                guard isCurrentLifecycle(generation),
                      currentUID == expectedUID,
                      engine === expectedEngine,
                      store === expectedStore else { return }
                await Task.yield()
                guard isCurrentLifecycle(generation) else { return }
                await expectedStore.delete(id: sessionID)
                guard isCurrentLifecycle(generation),
                      currentUID == expectedUID,
                      engine === expectedEngine,
                      store === expectedStore else { return }
                if model.discardSessionIfCurrent(sessionID) {
                    externallyClosedSession = sessionID
                }
            }
        }
        scheduleRefresh()
    }

    private func transferProgressChanged(
        expectedUID: String,
        generation: UInt,
        expectedEngine: SyncEngine
    ) {
        guard isCurrentLifecycle(generation),
              currentUID == expectedUID,
              engine === expectedEngine,
              hasCompletedConfiguration(
                uid: expectedUID, withEngine: true),
              progressRefreshTask == nil else { return }
        progressRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self,
                  self.isCurrentLifecycle(generation),
                  self.currentUID == expectedUID,
                  self.engine === expectedEngine,
                  self.hasCompletedConfiguration(
                    uid: expectedUID, withEngine: true) else { return }
            self.progressRefreshTask = nil
            self.scheduleRefresh()
        }
    }

    /// Foreground hook: retry parked transfers + drain anything pending.
    func appBecameActive() async {
        failedThumbs = []
        scheduleRefresh()
        let generation = lifecycleGeneration
        guard let engine,
              let currentUID,
              isCurrentLifecycle(generation),
              hasCompletedConfiguration(
                uid: currentUID, withEngine: true) else { return }
        syncPassInFlight = true
        await engine.retryTransfers()
        guard isCurrentLifecycle(generation), self.engine === engine else { return }
        await engine.drainOnce()
        guard isCurrentLifecycle(generation), self.engine === engine else { return }
        syncPassInFlight = false
        scheduleRefresh()
        if let sessionID = editorThumbnailSessionID {
            await prepareEditorThumbnails(sessionID: sessionID)
        }
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
        let runID = UUID()
        refreshRunID = runID
        refreshTask = Task { [weak self] in
            await self?.performRefresh(generation: generation)
            guard let self,
                  self.refreshRunID == runID else { return }
            self.refreshTask = nil
            self.refreshRunID = nil
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
        guard generation == refreshGeneration,
              let expectedStore = store else {
            guard generation == refreshGeneration else { return }
            cards = []
            initialLoadDone = true
            return
        }

        let sessions = await expectedStore.loadAll()
        guard generation == refreshGeneration,
              store === expectedStore,
              !Task.isCancelled else { return }
        let status: SyncStatusSnapshot?
        let expectedStatusEngine = mutationEngine
        if let statusEngine = expectedStatusEngine {
            let live = await statusEngine.statusSnapshot
            guard generation == refreshGeneration,
                  store === expectedStore,
                  mutationEngine === statusEngine,
                  !Task.isCancelled else { return }
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
        var missing: [String] = []
        let localCards = buildCards(
            sessions: sessions,
            metrics: metrics,
            collectMissing: &missing,
            store: expectedStore)

        guard generation == refreshGeneration,
              store === expectedStore,
              mutationEngine === expectedStatusEngine,
              !Task.isCancelled else { return }
        lastSyncStatusSnapshot = status
        cards = localCards
        initialLoadDone = true
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

        guard let expectedEngine = engine, !missing.isEmpty else { return }
        let wanted = Array(Set(missing)).filter { !failedThumbs.contains($0) }
        guard !wanted.isEmpty else { return }
        var anyLanded = false
        await withTaskGroup(of: (String, Bool).self) { group in
            var next = min(4, wanted.count)
            for hash in wanted.prefix(next) {
                group.addTask {
                    let url = await expectedEngine.hydrateThumb(hash: hash)
                    return (hash, url != nil)
                }
            }
            while let (hash, ok) = await group.next() {
                guard generation == refreshGeneration,
                      store === expectedStore,
                      engine === expectedEngine,
                      !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if ok { anyLanded = true } else { failedThumbs.insert(hash) }
                if next < wanted.count {
                    let upNext = wanted[next]
                    next += 1
                    group.addTask {
                        let url = await expectedEngine.hydrateThumb(hash: upNext)
                        return (upNext, url != nil)
                    }
                }
            }
        }
        guard anyLanded,
              generation == refreshGeneration,
              store === expectedStore,
              engine === expectedEngine,
              !Task.isCancelled else { return }
        let fresh = await expectedStore.loadAll()
        guard generation == refreshGeneration,
              store === expectedStore,
              engine === expectedEngine,
              !Task.isCancelled else { return }
        let refreshedStatus = await expectedEngine.statusSnapshot
        guard generation == refreshGeneration,
              store === expectedStore,
              engine === expectedEngine,
              !Task.isCancelled else { return }
        let refreshedKnown =
            refreshedStatus.knownSyncedSessionIDs(for: fresh)
        let refreshedMetrics = SessionSyncMetrics.calculate(
            sessions: fresh,
            journal: refreshedStatus.journal,
            transfers: refreshedStatus.transfers,
            persistedSyncedSessionIDs: refreshedKnown)
        var ignored: [String] = []
        let refreshedCards = buildCards(
            sessions: fresh,
            metrics: refreshedMetrics,
            collectMissing: &ignored,
            store: expectedStore)
        guard generation == refreshGeneration,
              store === expectedStore,
              engine === expectedEngine else { return }
        lastSyncStatusSnapshot = refreshedStatus
        cards = refreshedCards
    }

    private func buildCards(sessions: [Session],
                            metrics: SessionSyncMetrics,
                            collectMissing: inout [String],
                            store: FileSessionStore) -> [SessionCard] {
        let fm = FileManager.default
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
                syncProgress: metrics.progressBySessionID[session.id],
                knownSynced: metrics.knownSyncedSessionIDs.contains(session.id))
        }
    }

    @discardableResult
    func openSession(id: UUID) async -> Bool {
        let generation = lifecycleGeneration
        guard let expectedModel = model else { return false }
        let expectedEngine = engine
        if let expectedEngine {
            await expectedEngine.listenPhotos(session: id)
            guard isCurrentLifecycle(generation),
                  engine === expectedEngine,
                  model === expectedModel else { return false }
        }
        let opened = await expectedModel.openSession(id: id)
        guard isCurrentLifecycle(generation),
              model === expectedModel else { return false }
        if opened {
            editorThumbnailSessionID = id
            editorThumbnailURLs = [:]
        }
        return opened
    }

    @discardableResult
    func startSession(with urls: [URL]) async -> Bool {
        let hasJPEG = urls.contains { FileRole.role(for: $0) == .sdr }
        let generation = lifecycleGeneration
        guard hasJPEG,
              let expectedModel = model,
              await expectedModel.startNewSession(),
              isCurrentLifecycle(generation),
              model === expectedModel else { return false }
        expectedModel.addFiles(urls)
        return !expectedModel.items.isEmpty
    }

    func renameSession(id: UUID, to title: String) async {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = lifecycleGeneration
        guard !clean.isEmpty, let expectedStore = store else { return }
        if let expectedModel = model, expectedModel.session.id == id {
            expectedModel.setSessionTitle(clean)
            await expectedModel.flushSession()
            guard isCurrentLifecycle(generation),
                  store === expectedStore,
                  model === expectedModel else { return }
            scheduleRefresh()
            return
        }
        guard var session = await expectedStore.load(id: id),
              isCurrentLifecycle(generation),
              store === expectedStore,
              session.title != clean else { return }
        let before = session
        session.title = clean
        session.updatedAt = Date()
        try? await expectedStore.save(session)
        guard isCurrentLifecycle(generation),
              store === expectedStore else { return }
        await localPersisted(
            session,
            before: before,
            expectedUID: currentUID,
            generation: generation)
    }

    func deleteSession(id: UUID) async {
        let generation = lifecycleGeneration
        guard let expectedStore = store,
              let session = await expectedStore.load(id: id),
              isCurrentLifecycle(generation),
              store === expectedStore else { return }
        if let expectedModel = model, expectedModel.session.id == id {
            guard await expectedModel.startNewSession(),
                  isCurrentLifecycle(generation),
                  store === expectedStore,
                  model === expectedModel else { return }
        }
        let recorder = mutationEngine
        let needsRemoteUndo = await recorder?.everAcked(.session(id)) ?? false
        guard isCurrentLifecycle(generation),
              store === expectedStore,
              mutationEngine === recorder else { return }
        if let recorder {
            await recorder.deleteSessionLocally(id)
            guard isCurrentLifecycle(generation),
                  store === expectedStore,
                  mutationEngine === recorder else { return }
            if engine === recorder {
                await recorder.drainOnce()
                guard isCurrentLifecycle(generation),
                      store === expectedStore,
                      engine === recorder else { return }
            }
        } else {
            await expectedStore.delete(id: id)
            guard isCurrentLifecycle(generation),
                  store === expectedStore else { return }
        }
        recentlyDeleted = DeletedSessionNotice(
            session: session,
            needsRemoteUndo: needsRemoteUndo,
            namespace: namespaceID)
        scheduleRefresh()
    }

    func undoLastDelete() async {
        let generation = lifecycleGeneration
        guard let deletion = recentlyDeleted,
              deletion.namespace == namespaceID,
              let expectedStore = store else { return }
        // Seed the local copy first so remote materialization can preserve Mac
        // linked paths and export state instead of replacing them with caches.
        try? await expectedStore.save(deletion.session)
        guard isCurrentLifecycle(generation),
              store === expectedStore,
              recentlyDeleted == deletion else { return }
        if let recorder = mutationEngine {
            if deletion.needsRemoteUndo {
                await recorder.undoDeleteSessionLocally(deletion.session.id)
            } else {
                await recorder.noteLocalSession(deletion.session)
            }
            guard isCurrentLifecycle(generation),
                  store === expectedStore,
                  mutationEngine === recorder else { return }
            if engine === recorder {
                await recorder.drainOnce()
                await recorder.pumpTransfers()
                guard isCurrentLifecycle(generation),
                      store === expectedStore,
                      engine === recorder else { return }
            }
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

    /// Removes only the Firebase account namespace. The always-free local
    /// namespace is intentionally preserved and becomes active after auth
    /// transitions to signed out.
    func purgeLocalAccountData(uid: String) async throws {
        guard uid != "local" else { return }
        lifecycleGeneration &+= 1
        refreshGeneration &+= 1
        completedConfiguration = nil
        lifecycleTask?.cancel()
        await lifecycleTask?.value
        lifecycleTask = nil
        if currentUID == uid {
            if let model { await model.flushSession() }
            let outgoingEngine = engine
            let outgoingJournal = journalEngine
            engine = nil
            journalEngine = nil
            store = nil
            currentUID = nil
            model?.onSessionPersisted = nil
            syncing = false
            if let outgoingEngine {
                await outgoingEngine.setOnRemoteChange(nil)
                await outgoingEngine.setOnTransferProgress(nil)
                await outgoingEngine.stop()
            }
            if let outgoingJournal {
                await outgoingJournal.stop()
            }
        }
        try await Self.removeAccountNamespace(uid: uid)
    }

    private func isCurrentLifecycle(_ generation: UInt) -> Bool {
        generation == lifecycleGeneration && !Task.isCancelled
    }

    private func hasCompletedConfiguration(
        uid: String,
        withEngine: Bool
    ) -> Bool {
        guard completedConfiguration == LifecycleConfiguration(
            uid: uid, withEngine: withEngine),
              currentUID == uid,
              store != nil else { return false }
        if withEngine {
            return engine != nil && journalEngine == nil
        }
        return engine == nil && (uid == "local" || journalEngine != nil)
    }

    private func abandonEngine(_ candidate: SyncEngine) async {
        await candidate.setOnRemoteChange(nil)
        await candidate.setOnTransferProgress(nil)
        await candidate.stop()
        if engine === candidate { engine = nil }
        if journalEngine === candidate { journalEngine = nil }
    }

    func retryPendingLocalAccountCleanup() async {
        for uid in AuthController.pendingLocalCleanupUIDs where uid != currentUID {
            do {
                try await Self.removeAccountNamespace(uid: uid)
                AuthController.completePendingLocalCleanup(uid: uid)
            } catch {
                // Keep the durable marker for the next foreground/launch.
            }
        }
    }

    private static func removeAccountNamespace(uid: String) async throws {
        guard uid != "local" else { return }
        guard let accountRoot = FileSessionStore.namespaceRoot(for: uid) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard FileManager.default.fileExists(atPath: accountRoot.path) else { return }
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.removeItem(at: accountRoot)
        }.value
    }

    // ------------------------------------------------------------- editor thumbs

    func prepareEditorThumbnails(sessionID: UUID) async {
        let generation = lifecycleGeneration
        guard completedConfiguration != nil,
              let expectedStore = store,
              let session = await expectedStore.load(id: sessionID),
              isCurrentLifecycle(generation),
              store === expectedStore
        else { return }
        if editorThumbnailSessionID != sessionID {
            editorThumbnailSessionID = sessionID
            editorThumbnailURLs = [:]
        }

        let plan = expectedStore.thumbnailPlan(for: session)
        guard editorThumbnailSessionID == sessionID,
              !Task.isCancelled else { return }
        editorThumbnailURLs = plan.localURLsByPhotoID

        guard let expectedEngine = engine, !plan.missing.isEmpty else { return }
        let requestsByHash = Dictionary(
            grouping: plan.missing,
            by: \.contentHash)
        let hashes = Array(requestsByHash.keys)

        await withTaskGroup(of: (String, URL?).self) { group in
            var next = min(4, hashes.count)
            for hash in hashes.prefix(next) {
                group.addTask {
                    (hash, await expectedEngine.hydrateThumb(hash: hash))
                }
            }
            while let (hash, url) = await group.next() {
                guard isCurrentLifecycle(generation),
                      store === expectedStore,
                      engine === expectedEngine,
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
                        (nextHash, await expectedEngine.hydrateThumb(hash: nextHash))
                    }
                }
            }
        }
    }

    /// Download a phone-originated original when its editor item becomes
    /// selected, then rewrite the local-only origin so MergeModel can render it.
    func hydratePhotoIfNeeded(sessionID: UUID, photoID: UUID) async {
        let generation = lifecycleGeneration
        guard let expectedEngine = engine,
              let expectedStore = store,
              hasCompletedConfiguration(
                uid: currentUID ?? "", withEngine: true),
              var session = await expectedStore.load(id: sessionID),
              isCurrentLifecycle(generation),
              engine === expectedEngine,
              store === expectedStore,
              let index = session.photos.firstIndex(where: { $0.id == photoID }) else { return }
        let fm = FileManager.default
        let managedRoot = expectedStore.managedFilesDir
        let currentURL = session.photos[index].sourceURL(managedRoot: managedRoot)
        if fm.fileExists(atPath: currentURL.path) {
            if let model, model.session.id == sessionID {
                if model.items.first(where: { $0.id == photoID })?.sdrURL != currentURL {
                    model.reloadFromRemote(session)
                }
            }
            return
        }
        guard let hash = session.photos[index].contentHash,
              let hydrated = await expectedEngine.hydrateOriginal(hash: hash),
              isCurrentLifecycle(generation),
              engine === expectedEngine,
              store === expectedStore else { return }
        // Hydration can take seconds. Re-read before writing so a look edit,
        // photo deletion, or inbound peer change that landed meanwhile is
        // never replaced with the stale pre-download snapshot above.
        guard var latest = await expectedStore.load(id: sessionID),
              isCurrentLifecycle(generation),
              engine === expectedEngine,
              store === expectedStore,
              let latestIndex = latest.photos.firstIndex(
                where: { $0.id == photoID }),
              latest.photos[latestIndex].contentHash == hash else { return }
        let managedPrefix = managedRoot.path + "/"
        if hydrated.path.hasPrefix(managedPrefix) {
            latest.photos[latestIndex].origin = .managed(
                relativePath: String(hydrated.path.dropFirst(managedPrefix.count)))
        } else {
            latest.photos[latestIndex].origin = .linked(path: hydrated.path)
        }
        do {
            try await expectedStore.save(latest)
        } catch {
            return
        }
        guard isCurrentLifecycle(generation),
              engine === expectedEngine,
              store === expectedStore else { return }
        if let model, model.session.id == sessionID {
            model.reloadFromRemote(latest)
            // The portable origin normally already points at this exact cache
            // URL. Its metadata therefore compares equal even though the file
            // changed from missing to present; explicitly wake image loaders.
            model.markSourceAvailable(photoID)
        }
        if editorThumbnailSessionID == sessionID {
            var updated = editorThumbnailURLs
            updated[photoID] = hydrated
            editorThumbnailURLs = updated
        }
        scheduleRefresh()
    }
}
