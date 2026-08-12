//
//  AppModel.swift
//  Gainmap for iPhone (P5)
//
//  Per-namespace app state: the session store, the sync engine's lifecycle,
//  and the grid's card list. The local namespace is always available without
//  authentication. Only `.ready` attaches the cloud engine.
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

    private struct LifecycleConfiguration: Equatable {
        let uid: String
        let syncing: Bool
    }

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
    /// Entitled engine: may listen, upload, download, and drain.
    private(set) var engine: SyncEngine?
    /// Unentitled, previously activated namespace: records local mutations in
    /// the durable journal but is never connected to Firebase.
    private var journalEngine: SyncEngine?
    private var activeUID: String?

    private var mutationEngine: SyncEngine? { engine ?? journalEngine }

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
    /// Every observed auth state invalidates all older transition continuations
    /// before they can resume from an actor/network await.
    private var lifecycleGeneration: UInt = 0
    private var lifecycleTask: Task<Void, Never>?
    private var completedConfiguration: LifecycleConfiguration?
    private var refreshGeneration: UInt = 0
    private var refreshRunID: UUID?

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
        let target: (uid: String, syncing: Bool)
        switch state {
        case .ready(let uid):
            target = (uid, true)
        case .checking(let uid), .localOnly(let uid):
            // Before first Cloud Sync activation, checking Patreon must not
            // move the user's existing local library. After activation, keep
            // using the uid namespace during grace/lapse so sessions never
            // appear to vanish merely because sync stopped.
            let namespace = AuthController.hasCloudNamespace(for: uid) ? uid : "local"
            target = (namespace, false)
        case .signedOut, .failed:
            target = ("local", false)
        }

        if hasCompletedConfiguration(uid: target.uid, syncing: target.syncing) {
            scheduleRefresh()
            return
        }

        lifecycleGeneration &+= 1
        refreshGeneration &+= 1
        completedConfiguration = nil
        let generation = lifecycleGeneration

        // SwiftUI launch can deliver the same state through both `.task` and
        // `.onChange`. Serialize transitions, cancel the superseded intent,
        // and let only the newest generation publish resources.
        let previous = lifecycleTask
        previous?.cancel()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self,
                  self.isCurrentLifecycle(generation) else { return }
            await self.activate(
                uid: target.uid,
                syncing: target.syncing,
                generation: generation)
        }
        lifecycleTask = task
        await task.value
    }

    private func activate(
        uid: String,
        syncing wantSync: Bool,
        generation: UInt
    ) async {
        guard isCurrentLifecycle(generation) else { return }
        let switchingNamespace = activeUID != uid
        await deactivate(
            clearCards: switchingNamespace,
            preserveEditor: !switchingNamespace)
        guard isCurrentLifecycle(generation) else { return }

        let nextStore = FileSessionStore(uid: uid)
        if uid != "local" {
            await nextStore.adoptLocalSessions()
        }
        guard isCurrentLifecycle(generation) else { return }
        activeUID = uid
        store = nextStore
        let root = await nextStore.root
            .appendingPathComponent("users/\(uid)", isDirectory: true)
        guard isCurrentLifecycle(generation),
              store === nextStore,
              activeUID == uid else { return }
        lastSyncStatusSnapshot =
            SyncEngine.persistedStatusSnapshot(root: root)
        if wantSync {
            let nextEngine = SyncEngine(uid: uid, deviceID: Self.deviceID,
                                        backend: FirebaseSyncBackend(),
                                        store: nextStore, root: root)
            engine = nextEngine
            await nextEngine.setOnRemoteChange { [weak self] id in
                Task { @MainActor in
                    await self?.remoteChanged(
                        id,
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
                uid: uid, syncing: true)
            Task { [weak self] in
                await nextEngine.drainOnce()
                await nextEngine.pumpTransfers()
                guard let self,
                      self.isCurrentLifecycle(generation),
                      self.activeUID == uid,
                      self.engine === nextEngine else { return }
                self.syncPassInFlight = false
                self.initialSyncComplete = true
                self.scheduleRefresh()
            }
        } else if uid != "local" {
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
                uid: uid, syncing: false)
        } else {
            completedConfiguration = LifecycleConfiguration(
                uid: uid, syncing: false)
        }
        guard isCurrentLifecycle(generation) else { return }
        scheduleRefresh()
    }

    private func deactivate(
        clearCards: Bool = true,
        preserveEditor: Bool = false
    ) async {
        refreshTask?.cancel()
        refreshTask = nil
        refreshRunID = nil
        refreshGeneration &+= 1
        progressRefreshTask?.cancel()
        progressRefreshTask = nil
        refreshQueued = false
        completedConfiguration = nil
        let outgoingEngine = engine
        let outgoingJournal = journalEngine
        engine = nil
        journalEngine = nil
        store = nil
        activeUID = nil
        if let outgoingEngine {
            await outgoingEngine.setOnRemoteChange(nil)
            await outgoingEngine.setOnTransferProgress(nil)
            await outgoingEngine.stop()
        }
        if let outgoingJournal {
            await outgoingJournal.stop()
        }
        syncing = false
        initialSyncComplete = false
        syncPassInFlight = false
        pendingWorkCount = 0
        hasSyncIssue = false
        lastSyncStatusSnapshot = nil
        failedThumbs = []
        if !preserveEditor {
            editorThumbnailSessionID = nil
            editorThumbnailURLs = [:]
            activeEditorModel = nil
        }
        if clearCards {
            cards = []
            initialLoadDone = false
        }
    }

    /// Stop every reader/writer before removing the deleted account's local
    /// namespace. Exports already saved to Photos or Files live outside this
    /// container and intentionally remain under the user's control.
    func purgeLocalAccountData(uid: String) async throws {
        lifecycleGeneration &+= 1
        refreshGeneration &+= 1
        lifecycleTask?.cancel()
        await lifecycleTask?.value
        lifecycleTask = nil
        await deactivate()
        try await Self.removeAccountNamespace(uid: uid)
    }

    private func isCurrentLifecycle(_ generation: UInt) -> Bool {
        generation == lifecycleGeneration && !Task.isCancelled
    }

    private func hasCompletedConfiguration(uid: String, syncing: Bool) -> Bool {
        guard completedConfiguration == LifecycleConfiguration(
            uid: uid, syncing: syncing),
              activeUID == uid,
              store != nil else { return false }
        if syncing {
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
        for uid in AuthController.pendingLocalCleanupUIDs where uid != activeUID {
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

    func appBecameActive() async {
        failedThumbs = []   // give failed thumb downloads another chance
        let generation = lifecycleGeneration
        guard let engine,
              let activeUID,
              isCurrentLifecycle(generation),
              hasCompletedConfiguration(
                uid: activeUID, syncing: true) else { return }
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

    /// The editor's persist hook: journal + drain local edits.
    func sessionPersisted(
        _ session: Session,
        before: Session?,
        sourceModel: MergeModel? = nil,
        expectedGeneration: UInt? = nil,
        expectedStore: FileSessionStore? = nil
    ) {
        let generation = expectedGeneration ?? lifecycleGeneration
        let contextStore = expectedStore ?? store
        guard isCurrentLifecycle(generation),
              let contextStore,
              store === contextStore else { return }
        if let sourceModel, activeEditorModel !== sourceModel { return }
        // Publish the local mutation immediately. Waiting for a full upload
        // made the editor ring and covers look stale; without an engine
        // (local/waitlisted use), they otherwise never refreshed at all.
        scheduleRefresh()
        if editorThumbnailSessionID == session.id {
            Task { [weak self] in
                await self?.prepareEditorThumbnails(sessionID: session.id)
            }
        }
        guard let recorder = mutationEngine else { return }
        let expectedUID = activeUID
        syncPassInFlight = engine != nil
        Task { [weak self] in
            await recorder.noteLocalSession(session, before: before)
            guard let self,
                  self.isCurrentLifecycle(generation),
                  self.activeUID == expectedUID,
                  self.mutationEngine === recorder else { return }
            guard self.engine === recorder else {
                self.scheduleRefresh()
                return
            }
            await recorder.drainOnce()
            await recorder.pumpTransfers()
            guard self.isCurrentLifecycle(generation),
                  self.activeUID == expectedUID,
                  self.engine === recorder else { return }
            self.syncPassInFlight = false
            self.scheduleRefresh()
        }
    }

    /// Inbound change: fold into the open editor (if it's this session),
    /// then rebuild the grid.
    private func remoteChanged(
        _ sessionID: UUID,
        expectedUID: String,
        generation: UInt,
        expectedEngine: SyncEngine
    ) async {
        guard isCurrentLifecycle(generation),
              activeUID == expectedUID,
              engine === expectedEngine,
              hasCompletedConfiguration(
                uid: expectedUID, syncing: true),
              let expectedStore = store else { return }
        if let editorModel = activeEditorModel, editorModel.session.id == sessionID,
           let fresh = await expectedStore.load(id: sessionID) {
            guard isCurrentLifecycle(generation),
                  activeUID == expectedUID,
                  engine === expectedEngine,
                  store === expectedStore else { return }
            editorModel.reloadFromRemote(fresh)
            Task { [weak self] in
                await self?.prepareEditorThumbnails(sessionID: sessionID)
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
              activeUID == expectedUID,
              engine === expectedEngine,
              hasCompletedConfiguration(
                uid: expectedUID, syncing: true),
              progressRefreshTask == nil else { return }
        progressRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self,
                  self.isCurrentLifecycle(generation),
                  self.activeUID == expectedUID,
                  self.engine === expectedEngine,
                  self.hasCompletedConfiguration(
                    uid: expectedUID, syncing: true) else { return }
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

    /// Async entry for view modifiers (.task / .refreshable / onDismiss).
    func refresh() async {
        failedThumbs = []
        scheduleRefresh()
    }

    private func performRefresh(generation: UInt) async {
        guard generation == refreshGeneration,
              let expectedStore = store else {
            guard generation == refreshGeneration else { return }
            cards = []
            initialLoadDone = true
            return
        }
        // Phase 1 — LOCAL ONLY, no network: publish immediately so the grid
        // never sits on "No sessions yet" behind downloads.
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
        var missing: [String] = []   // thumb hashes to hydrate in phase 2
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
        cards = localCards
        initialLoadDone = true

        // Phase 2 — hydrate missing thumbs (bounded, deduped, no eternal
        // retries), then publish once more.
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

    /// Cover URL preference: local thumb file if present; else the photo's
    /// own local source file (imports on this device); else nil (placeholder)
    /// with the hash queued for hydration.
    private func buildCards(sessions: [Session], metrics: SessionSyncMetrics,
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
        let generation = lifecycleGeneration
        guard editorThumbnailSessionID == sessionID,
              completedConfiguration != nil,
              let expectedStore = store,
              let session = await expectedStore.load(id: sessionID),
              isCurrentLifecycle(generation),
              store === expectedStore
        else { return }

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
        let generation = lifecycleGeneration
        guard !clean.isEmpty,
              let expectedStore = store,
              var session = await expectedStore.load(id: id),
              isCurrentLifecycle(generation),
              store === expectedStore,
              session.title != clean else { return }
        let before = session
        session.title = clean
        session.updatedAt = Date()
        try? await expectedStore.save(session)
        guard isCurrentLifecycle(generation),
              store === expectedStore else { return }
        if let recorder = mutationEngine {
            await recorder.noteLocalSession(session, before: before)
            guard isCurrentLifecycle(generation),
                  store === expectedStore,
                  mutationEngine === recorder else { return }
            if engine === recorder {
                syncPassInFlight = true
                await recorder.drainOnce()
                await recorder.pumpTransfers()
                guard isCurrentLifecycle(generation),
                      store === expectedStore,
                      engine === recorder else { return }
                syncPassInFlight = false
            }
        }
        scheduleRefresh()
    }

    func deleteSession(id: UUID) async {
        let generation = lifecycleGeneration
        guard exportingSessionID != id,
              let expectedStore = store else { return }
        let recorder = mutationEngine
        if let recorder {
            await recorder.deleteSessionLocally(id)
            guard isCurrentLifecycle(generation),
                  store === expectedStore,
                  mutationEngine === recorder else { return }
            if engine === recorder {
                syncPassInFlight = true
                await recorder.drainOnce()
                guard isCurrentLifecycle(generation),
                      store === expectedStore,
                      engine === recorder else { return }
                syncPassInFlight = false
            }
        } else {
            await expectedStore.delete(id: id)
            guard isCurrentLifecycle(generation),
                  store === expectedStore else { return }
        }
        scheduleRefresh()
    }

    func exportSession(id: UUID) async throws -> SessionExportResult {
        let generation = lifecycleGeneration
        guard exportingSessionID == nil else { throw SessionExportError.busy }
        guard let expectedStore = store,
              let session = await expectedStore.load(id: id),
              isCurrentLifecycle(generation),
              store === expectedStore else {
            throw SessionExportError.missingSession
        }
        let exportEngine = engine

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
            store: expectedStore,
            output: .managedDirectory(exportDir))
        merge.onSessionPersisted = { [weak self] updated, before in
            Task { @MainActor in
                self?.sessionPersisted(
                    updated,
                    before: before,
                    expectedGeneration: generation,
                    expectedStore: expectedStore)
            }
        }

        var outputs: [URL] = []
        var failed = 0
        for item in merge.items {
            if !FileManager.default.fileExists(atPath: item.sdrURL.path) {
                let hash = session.photos.first(where: { $0.id == item.id })?.contentHash
                guard let hash,
                      await exportEngine?.hydrateOriginal(hash: hash) != nil else {
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
        let generation = lifecycleGeneration
        guard let expectedStore = store else { return nil }
        let session = await expectedStore.load(id: id)
        guard isCurrentLifecycle(generation),
              store === expectedStore else { return nil }
        return session
    }
}
