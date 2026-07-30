//
//  SyncEngine.swift
//  GainmapCore
//
//  P4: the actor that ties the sync protocol together. It owns, per uid:
//
//    * the ChangeJournal + AckLedger + TransferQueue (persisted atomically in
//      sync-state.json alongside the session files)
//    * shadow copies of the remote docs (last converged state) — local edits
//      are detected by diffing a Session against its shadow, so MergeModel
//      needs no knowledge of the protocol
//    * the listeners (sessions, photos of interesting sessions, user, blobs)
//    * the drain loop (creates first, then rev-gated group mutations through
//      ConflictPolicy transactions) and the transfer pump
//
//  Everything decision-shaped lives in the pure layer; this actor sequences
//  I/O. The Firebase adapter is injected (SyncBackend), so integration tests
//  run against the emulator and unit tests against a fake.
//

import Foundation
import CoreGraphics
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// MARK: - Persisted engine state

/// Everything the engine must remember across launches, in ONE atomic file.
/// Decoding is TOLERANT (missing keys get defaults): a version that adds a
/// field must never invalidate the whole state — a silently-dropped queue
/// permanently strands un-uploaded renditions (review P4-18).
struct SyncState: Codable, Equatable {
    var journal = ChangeJournal()
    var acks = AckLedger()
    var transfers = TransferQueue()
    /// Last converged remote session docs, keyed by session UUID string.
    var shadowSessions: [String: [String: FSValue]] = [:]
    /// Last converged remote photo docs, keyed by session then photo UUID.
    var shadowPhotos: [String: [String: [String: FSValue]]] = [:]
    /// Last observed server-owned blob ledgers, keyed by content hash. These
    /// persist rendition completion so a cold launch can restore the last
    /// truthful sync state before Firestore answers again.
    var shadowBlobs: [String: [String: FSValue]] = [:]
    /// contentHash -> absolute local path. Absolute sandbox paths are rebased
    /// from the session's portable origin every launch because iOS changes
    /// its app-container UUID when a development build is reinstalled.
    var hashIndex: [String: String] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case journal, acks, transfers, shadowSessions, shadowPhotos
        case shadowBlobs, hashIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        journal = (try? c.decodeIfPresent(ChangeJournal.self, forKey: .journal)) ?? ChangeJournal()
        acks = (try? c.decodeIfPresent(AckLedger.self, forKey: .acks)) ?? AckLedger()
        transfers = (try? c.decodeIfPresent(TransferQueue.self, forKey: .transfers)) ?? TransferQueue()
        shadowSessions = (try? c.decodeIfPresent([String: [String: FSValue]].self,
                                                 forKey: .shadowSessions)) ?? [:]
        shadowPhotos = (try? c.decodeIfPresent([String: [String: [String: FSValue]]].self,
                                               forKey: .shadowPhotos)) ?? [:]
        shadowBlobs = (try? c.decodeIfPresent([String: [String: FSValue]].self,
                                              forKey: .shadowBlobs)) ?? [:]
        hashIndex = (try? c.decodeIfPresent([String: String].self, forKey: .hashIndex)) ?? [:]
    }
}

/// Filesystem-backed status used by the session grid before the first network
/// response. It contains no credentials and is safe to derive from the
/// atomically persisted sync-state file during authentication/admission.
public struct SyncStatusSnapshot: Sendable {
    public let journal: ChangeJournal
    public let transfers: TransferQueue

    private let acks: AckLedger
    private let shadowSessions: [String: [String: FSValue]]
    private let shadowPhotos: [String: [String: [String: FSValue]]]
    private let shadowBlobs: [String: [String: FSValue]]

    init(state: SyncState) {
        journal = state.journal
        transfers = state.transfers
        acks = state.acks
        shadowSessions = state.shadowSessions
        shadowPhotos = state.shadowPhotos
        shadowBlobs = state.shadowBlobs
    }

    /// A green card requires proof that today's local session still matches
    /// the last converged metadata and that both peer-facing renditions were
    /// finalized by Storage. This catches the termination window where a
    /// session file lands just before its journal callback.
    public func knownSyncedSessionIDs(for sessions: [Session]) -> Set<UUID> {
        Set(sessions.compactMap { session -> UUID? in
            let target = SyncTarget.session(session.id)
            guard acks.everAcked(target),
                  let sessionMap = shadowSessions[session.id.uuidString],
                  let remoteSession = RemoteSessionDoc(
                    id: session.id, fsMap: sessionMap),
                  remoteSession.deletedAt == nil,
                  remoteSession.title == session.title,
                  remoteSession.sameLookForAll == session.sameLookForAll,
                  remoteSession.runningLook == session.runningLook
            else { return nil }

            let localPhotos = session.photos
            guard localPhotos.allSatisfy({
                !$0.tooLargeToSync
                    && $0.contentHash.map(SyncSchema.isValidContentHash) == true
            }) else { return nil }

            let remoteMaps = shadowPhotos[session.id.uuidString] ?? [:]
            let remotePhotos = remoteMaps.compactMap { key, map -> RemotePhotoDoc? in
                guard let id = UUID(uuidString: key),
                      let doc = RemotePhotoDoc(id: id, fsMap: map),
                      doc.deletedAt == nil else { return nil }
                return doc
            }
            guard remotePhotos.count == localPhotos.count,
                  Set(remotePhotos.map(\.id)) == Set(localPhotos.map(\.id)),
                  RemotePhotoDoc.ordered(remotePhotos).map(\.id)
                    == localPhotos.map(\.id)
            else { return nil }

            let remoteByID = Dictionary(
                remotePhotos.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
            for photo in localPhotos {
                guard let hash = photo.contentHash,
                      acks.everAcked(
                        .photo(session: session.id, photo: photo.id)),
                      let remote = remoteByID[photo.id],
                      remote.contentHash == hash,
                      remote.look == photo.look,
                      remote.looksMerged == photo.looksMerged,
                      remote.pixelWidth == photo.pixelWidth,
                      remote.pixelHeight == photo.pixelHeight
                else { return nil }

                let blob = shadowBlobs[hash].flatMap {
                    RemoteBlobDoc(contentHash: hash, fsMap: $0)
                }
                let originalID = SyncSchema.reservationId(
                    tier: "originals", contentHash: hash)
                let thumbID = SyncSchema.reservationId(
                    tier: "thumbs", contentHash: hash)
                let queueProvesCompletion =
                    transfers.transfer(id: originalID)?.status == .done
                    && transfers.transfer(id: thumbID)?.status == .done
                guard (blob?.isUploaded(tier: "originals") == true
                       && blob?.isUploaded(tier: "thumbs") == true)
                        || queueProvesCompletion
                else { return nil }
            }
            return session.id
        })
    }
}

// MARK: - Photo ordering

/// Pure ordering policy shared by outbound intent detection, sparse inserts,
/// inbound materialization, and focused tests.
enum SyncPhotoOrdering {

    /// A removal alone never counts as a reorder: compare only identities that
    /// existed in both snapshots and are represented by the remote collection.
    static func didExplicitlyReorder(
        current: [UUID],
        baseline: [UUID],
        remoteIDs: Set<UUID>
    ) -> Bool {
        let shared = Set(current)
            .intersection(baseline)
            .intersection(remoteIDs)
        return current.filter(shared.contains) != baseline.filter(shared.contains)
    }

    /// Choose a sparse key at the requested local position using the nearest
    /// already-keyed neighbours. Multiple pending creates can call this in
    /// local order, adding each returned key to `knownKeys` as they go.
    /// Nil means floating-point space was exhausted/corrupt and the caller
    /// should deterministically rebalance.
    static func insertionKey(
        for id: UUID,
        localOrder: [UUID],
        knownKeys: [UUID: Double]
    ) -> Double? {
        guard let index = localOrder.firstIndex(of: id) else { return nil }
        let left = localOrder[..<index].reversed()
            .compactMap { knownKeys[$0] }.first
        let right = localOrder[localOrder.index(after: index)...]
            .compactMap { knownKeys[$0] }.first

        switch (left, right) {
        case let (l?, r?):
            guard l.isFinite, r.isFinite, l < r else { return nil }
            let middle = l + ((r - l) / 2)
            return (middle > l && middle < r) ? middle : nil
        case let (l?, nil):
            guard l.isFinite else { return nil }
            let next = l + 1
            return next.isFinite && next > l ? next : nil
        case let (nil, r?):
            guard r.isFinite else { return nil }
            let previous = r - 1
            return previous.isFinite && previous < r ? previous : nil
        case (nil, nil):
            return 1
        }
    }

    /// Fill the slots previously occupied by remotely-known records with the
    /// authoritative remote order. Records the remote has never known stay in
    /// their exact slots; extra inbound photos append in remote order.
    static func materializedIDs(
        existing: [UUID],
        remotelyKnown: Set<UUID>,
        orderedAliveRemote: [UUID]
    ) -> [UUID] {
        var remoteIndex = 0
        var result: [UUID] = []
        result.reserveCapacity(
            existing.filter { !remotelyKnown.contains($0) }.count
                + orderedAliveRemote.count)

        for id in existing {
            if remotelyKnown.contains(id) {
                guard remoteIndex < orderedAliveRemote.count else { continue }
                result.append(orderedAliveRemote[remoteIndex])
                remoteIndex += 1
            } else {
                result.append(id)
            }
        }
        if remoteIndex < orderedAliveRemote.count {
            result.append(contentsOf: orderedAliveRemote[remoteIndex...])
        }
        return result
    }
}

// MARK: - Engine

public actor SyncEngine {

    public let uid: String
    public let deviceID: String
    private let backend: SyncBackend
    private let store: FileSessionStore
    /// users/<uid>/ directory for sync-state.json, thumbs/, blobs/.
    private let root: URL

    private var state = SyncState()
    private var listeners: [SyncListener] = []
    /// One consumer task per listener: events flow through an AsyncStream so
    /// they are applied IN DELIVERY ORDER. Wrapping each callback in its own
    /// unstructured Task gives no ordering guarantee on an actor — a stale
    /// snapshot applied after a newer one rolls the shadow (and the local
    /// file) backwards (review P4-9/20).
    private var eventPumps: [Task<Void, Never>] = []
    /// Sessions whose photo subcollections we listen to.
    private var photoListenerSessions: Set<UUID> = []
    /// Wi-Fi policy input (Mac: always true; iOS wires Settings later).
    public var allowLargeTransfers = true

    private var lastKnownQuotaBytes: Int64 = 0
    private var lifecycleGeneration: UInt = 0
    private var isRunning = false

    public init(uid: String, deviceID: String, backend: SyncBackend,
                store: FileSessionStore, root: URL) {
        self.uid = uid
        self.deviceID = deviceID
        self.backend = backend
        self.store = store
        self.root = root
    }

    // ------------------------------------------------------------- lifecycle

    private var stateURL: URL { root.appendingPathComponent("sync-state.json") }

    public func start() async {
        guard !isRunning else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        loadState()
        let localSessions = await store.loadAllRepairingManagedOrigins()
        // The store hop makes this actor re-entrant. A stop or newer start
        // while migration is running invalidates this activation; never leave
        // listeners alive after sign-out or install duplicate listener sets.
        guard generation == lifecycleGeneration else { return }
        state = Self.rebasingLocalFileReferences(
            state,
            sessions: localSessions,
            managedRoot: store.managedFilesDir,
            syncRoot: root)
        state.journal.requeueInFlightAfterRelaunch()
        state.transfers.relaunch()
        // A launch is a natural retry trigger: revive parked transfers and
        // give quota-terminal ones a fresh test. Completed entries are shed
        // only after their server-owned blob ledger is also persisted; until
        // then they are the cold-launch completion proof.
        state.transfers.retryTrigger()
        state.transfers.quotaChanged()
        let ledgerConfirmedTransferIDs = Set(
            state.transfers.transfers.compactMap { transfer -> String? in
                guard let map = state.shadowBlobs[transfer.contentHash],
                      let blob = RemoteBlobDoc(
                        contentHash: transfer.contentHash, fsMap: map),
                      blob.isUploaded(tier: transfer.tier)
                else { return nil }
                return transfer.id
            })
        state.transfers.pruneDone(
            confirmedIDs: ledgerConfirmedTransferIDs)
        persistState()
        isRunning = true
        startListeners()
    }

    /// Repairs persisted absolute paths after an app-container move. Session
    /// origins are portable (`managed` paths are relative to managedRoot), so
    /// they are the authority; sync-state paths are only a launch-local cache.
    ///
    /// Re-enqueueing an existing transfer refreshes its source URL and revives
    /// a parked entry. This turns an otherwise permanent reinstall failure
    /// into an automatic retry without asking the user to re-import anything.
    nonisolated static func rebasingLocalFileReferences(
        _ persisted: SyncState,
        sessions: [Session],
        managedRoot: URL,
        syncRoot: URL
    ) -> SyncState {
        let fm = FileManager.default
        var repaired = persisted
        var currentIndex = persisted.hashIndex.filter {
            fm.fileExists(atPath: $0.value)
        }
        var activeHashes = Set<String>()
        var tombstonedHashes = Set<String>()

        for session in sessions {
            for photo in session.photos {
                guard let hash = photo.contentHash else { continue }
                activeHashes.insert(hash)
                let source = photo.sourceURL(managedRoot: managedRoot)
                if fm.fileExists(atPath: source.path) {
                    currentIndex[hash] = source.path
                }
            }
        }

        // Tombstones are reversible. They are useful pruning evidence only
        // for a rendition whose source bytes are already unreachable; a live
        // path must survive so undo can restore the original without a
        // needless download (or permanent loss when it never uploaded).
        for (sessionID, photos) in persisted.shadowPhotos {
            guard let sessionUUID = UUID(uuidString: sessionID) else { continue }
            let sessionOverlay = persisted.journal.overlay(
                for: .session(sessionUUID))
            let parentDeleted: Bool
            if case .tombstone(let deletedAt)? = sessionOverlay[.delete] {
                parentDeleted = deletedAt != nil
            } else if let map = persisted.shadowSessions[sessionID],
                      let remote = RemoteSessionDoc(
                        id: sessionUUID, fsMap: map) {
                parentDeleted = remote.deletedAt != nil
            } else {
                parentDeleted = false
            }

            for (photoID, map) in photos {
                guard let photoUUID = UUID(uuidString: photoID),
                      let remote = RemotePhotoDoc(
                        id: photoUUID, fsMap: map) else { continue }
                let merged = InboundMerge.merged(
                    photo: remote,
                    overlay: persisted.journal.overlay(
                        for: .photo(session: sessionUUID, photo: photoUUID)))
                if parentDeleted || merged.deletedAt != nil {
                    tombstonedHashes.insert(merged.contentHash)
                }
            }
        }
        repaired.hashIndex = currentIndex

        // Iterate a value snapshot because enqueue mutates the queue.
        for transfer in repaired.transfers.transfers {
            let sourcePath: String?
            switch transfer.tier {
            case "thumbs":
                let thumb = syncRoot
                    .appendingPathComponent("thumbs/\(transfer.contentHash).jpg")
                sourcePath = fm.fileExists(atPath: thumb.path) ? thumb.path : nil
            case "originals":
                if let indexed = currentIndex[transfer.contentHash] {
                    sourcePath = indexed
                } else if fm.fileExists(atPath: transfer.sourcePath) {
                    sourcePath = transfer.sourcePath
                    currentIndex[transfer.contentHash] = transfer.sourcePath
                    repaired.hashIndex[transfer.contentHash] = transfer.sourcePath
                } else {
                    sourcePath = nil
                }
            default:
                // Future rendition tiers may already use a stable external
                // path. Preserve it only while it is actually reachable.
                sourcePath = fm.fileExists(atPath: transfer.sourcePath)
                    ? transfer.sourcePath
                    : nil
            }

            guard let sourcePath else {
                if tombstonedHashes.contains(transfer.contentHash),
                   !activeHashes.contains(transfer.contentHash) {
                    repaired.transfers.remove(id: transfer.id)
                }
                continue
            }
            repaired.transfers.enqueue(
                contentHash: transfer.contentHash,
                tier: transfer.tier,
                byteSize: transfer.byteSize,
                sourcePath: sourcePath)
        }
        return repaired
    }

    public func stop() {
        lifecycleGeneration &+= 1
        isRunning = false
        for l in listeners { l.cancel() }
        listeners.removeAll()
        for t in eventPumps { t.cancel() }
        eventPumps.removeAll()
        photoListenerSessions.removeAll()
        persistState()
    }

    /// Foreground / network-change / user-tapped-retry hook (P5/P7 wire this
    /// to app lifecycle): revives parked + quota-terminal transfers and pumps.
    public func retryTransfers(now: Date = Date()) async {
        state.transfers.retryTrigger()
        state.transfers.quotaChanged()
        await pumpTransfers(now: now)
    }

    /// Fired after inbound changes land in the local store (materialize,
    /// tombstone adoption, purge) — the app refreshes its grid/editor.
    private var onRemoteChange: (@Sendable (UUID) -> Void)?
    private var onTransferProgress: (@Sendable () -> Void)?

    public func setOnRemoteChange(_ handler: (@Sendable (UUID) -> Void)?) {
        onRemoteChange = handler
    }

    public func setOnTransferProgress(_ handler: (@Sendable () -> Void)?) {
        onTransferProgress = handler
    }

    private func noteRemoteChange(_ sessionID: UUID) {
        onRemoteChange?(sessionID)
    }

    // ------------------------------------------------------------- hydration

    /// Local path of a 1024px thumb for `hash` — downloads it from the thumbs
    /// tier if this device never generated one (the grid's mosaic source).
    public func hydrateThumb(hash: String) async -> URL? {
        let dir = root.appendingPathComponent("thumbs")
        let url = dir.appendingPathComponent("\(hash).jpg")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try await backend.downloadObject(
                objectName: SyncSchema.objectName(uid: uid, tier: "thumbs", contentHash: hash),
                to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Local URL of the ORIGINAL bytes for `hash`: the linked file when this
    /// device has it, else the blob cache (downloading on first request).
    /// The cache path matches the `.managed(relativePath: "blobs/<hash>.jpg")`
    /// origins materializeLocal writes, resolved against the store's managed
    /// files root — so PhotoRecord.sourceURL finds it too.
    public func hydrateOriginal(hash: String) async -> URL? {
        if let path = state.hashIndex[hash],
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let cacheURL = await store.managedFilesDir
            .appendingPathComponent("blobs/\(hash).jpg")
        if FileManager.default.fileExists(atPath: cacheURL.path) { return cacheURL }
        do {
            try await backend.downloadObject(
                objectName: SyncSchema.objectName(uid: uid, tier: "originals", contentHash: hash),
                to: cacheURL)
            return cacheURL
        } catch {
            return nil
        }
    }

    public nonisolated static func persistedStatusSnapshot(
        root: URL
    ) -> SyncStatusSnapshot? {
        decodedState(at: root.appendingPathComponent("sync-state.json"))
            .map(SyncStatusSnapshot.init(state:))
    }

    private nonisolated static func decodedState(at url: URL) -> SyncState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SyncState.self, from: data)
    }

    private func loadState() {
        guard let loaded = Self.decodedState(at: stateURL) else { return }
        state = loaded
    }

    private func persistState() {
        persistTask?.cancel()
        persistTask = nil
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let data = try enc.encode(state)
            let tmp = stateURL.appendingPathExtension("tmp-\(UUID().uuidString)")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(stateURL, withItemAt: tmp)
        } catch {
            // Never fatal: worst case the next launch re-derives from remote
            // + local files (reconcile handles both directions).
        }
    }

    private var persistTask: Task<Void, Never>?

    /// Debounced persist for high-frequency paths (listener events): the full
    /// state is re-encoded on every write, so coalescing bursts matters once
    /// libraries get large (review P4-6/13). Drains/stop persist immediately.
    private func persistSoon() {
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.persistNowFromDebounce()
        }
    }

    private func persistNowFromDebounce() {
        guard persistTask != nil else { return }
        persistState()
    }

    // Test/diagnostic visibility.
    public var journalSnapshot: ChangeJournal { state.journal }
    public var transferSnapshot: TransferQueue { state.transfers }
    public var statusSnapshot: SyncStatusSnapshot {
        SyncStatusSnapshot(state: state)
    }
    public var conflictRecords: [ConflictRecord] { state.journal.conflicts }
    public func everAcked(_ target: SyncTarget) -> Bool { state.acks.everAcked(target) }

    // ------------------------------------------------------------- shadows

    private func shadowSession(_ id: UUID) -> RemoteSessionDoc? {
        state.shadowSessions[id.uuidString].flatMap { RemoteSessionDoc(id: id, fsMap: $0) }
    }

    private func shadowPhoto(session: UUID, photo: UUID) -> RemotePhotoDoc? {
        state.shadowPhotos[session.uuidString]?[photo.uuidString]
            .flatMap { RemotePhotoDoc(id: photo, fsMap: $0) }
    }

    private func setShadow(_ doc: RemoteSessionDoc) {
        state.shadowSessions[doc.id.uuidString] = doc.fsMap()
    }

    private func setShadow(_ doc: RemotePhotoDoc, session: UUID) {
        state.shadowPhotos[session.uuidString, default: [:]][doc.id.uuidString] = doc.fsMap()
    }

    // ------------------------------------------------------------- local edits

    /// MergeModel's persist path calls this with every saved Session. Diffs
    /// against the shadow and journals exactly the changed field groups.
    /// Sessions with no shadow are handled at drain time (create push).
    ///
    /// `before` is the state the MODEL last knew (its previous persisted
    /// content) — the intent baseline. A group is journaled only when the
    /// flush differs from the shadow AND from `before`: a value that merely
    /// differs from the shadow but matches `before` means the model hasn't
    /// consumed an inbound change yet — journaling it would push the STALE
    /// value back out and revert the peer's edit. Same rule for deletions:
    /// a photo missing from the flush is a user delete only if the model
    /// ever HELD it (`before` contains it); a peer-added photo the model
    /// never saw must not be tombstoned (P5 review, critical — this is the
    /// epoch guard the P4 comment deferred to the UI wiring).
    /// `before: nil` keeps the raw shadow-diff semantics (tests; callers
    /// that have no baseline).
    public func noteLocalSession(_ session: Session, before: Session? = nil) async {
        // Rehydration index: remember where hashed originals live locally —
        // linked files AND store-managed imports (resolved to this launch's
        // container; start() prunes stale entries).
        let managedRoot = store.managedFilesDir
        for p in session.photos {
            guard let hash = p.contentHash else { continue }
            let url = p.sourceURL(managedRoot: managedRoot)
            if FileManager.default.fileExists(atPath: url.path) {
                state.hashIndex[hash] = url.path
            }
        }

        let target = SyncTarget.session(session.id)
        guard let shadow = shadowSession(session.id) else {
            persistState()
            return   // create is pushed by drainOnce (never-acked local)
        }

        // A `before` from a DIFFERENT session is no baseline at all.
        let baseline = (before?.id == session.id) ? before : nil
        let baselinePhotos: [UUID: PhotoRecord] = Dictionary(
            (baseline?.photos ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        /// True when this flush is allowed to journal the group: no baseline
        /// (raw semantics), or the user actually changed it since the model's
        /// last known persisted state.
        func userChanged(_ changed: Bool) -> Bool { baseline == nil || changed }
        // Tracks "the flushed file is stale vs the shadow" — groups or photos
        // the model hadn't consumed. The flush overwrote the session file
        // with that stale state, so re-materialize + notify at the end.
        var staleVsShadow = false

        if session.title != shadow.title {
            if userChanged(session.title != baseline?.title) {
                state.journal.record(target: target, value: .title(session.title),
                                     baseRev: shadow.titleMeta.rev, deviceID: deviceID)
            } else {
                staleVsShadow = true
            }
        }
        if session.runningLook != shadow.runningLook
            || session.sameLookForAll != shadow.sameLookForAll {
            if userChanged(session.runningLook != baseline?.runningLook
                           || session.sameLookForAll != baseline?.sameLookForAll) {
                state.journal.record(
                    target: target,
                    value: .runningLook(session.runningLook,
                                        sameLookForAll: session.sameLookForAll),
                    baseRev: shadow.rlMeta.rev, deviceID: deviceID)
            } else {
                staleVsShadow = true
            }
        }

        let shadowPhotoMaps = state.shadowPhotos[session.id.uuidString] ?? [:]
        var seen = Set<String>()
        for photo in session.photos {
            seen.insert(photo.id.uuidString)
            guard let remote = shadowPhoto(session: session.id, photo: photo.id) else {
                continue   // create is pushed by drainOnce
            }
            // A photo the shadow says is deleted is on its way out locally
            // too (the next materialize drops it). NEVER infer an undo from
            // its mere presence in a possibly-stale Session snapshot — undo
            // is an explicit user action only (review P4-2).
            guard remote.deletedAt == nil else { continue }
            let pTarget = SyncTarget.photo(session: session.id, photo: photo.id)
            if photo.look != remote.look {
                let base = baselinePhotos[photo.id]
                if userChanged(base == nil || photo.look != base?.look) {
                    state.journal.record(target: pTarget, value: .look(photo.look),
                                         baseRev: remote.lookMeta.rev, deviceID: deviceID)
                } else {
                    staleVsShadow = true
                }
            }
        }

        // Array position becomes order intent only when the relative order of
        // identities held by BOTH snapshots changed. A deletion by itself
        // therefore emits only a tombstone; it never densely renumbers every
        // survivor. Pending creates are excluded here and receive sparse keys
        // from their intended neighbours in pushCreates.
        let rawRemoteDocs = shadowPhotoMaps.compactMap {
            key, map -> RemotePhotoDoc? in
            guard let id = UUID(uuidString: key),
                  let doc = RemotePhotoDoc(id: id, fsMap: map),
                  doc.deletedAt == nil else { return nil }
            return doc
        }
        let rawRemoteByID = Dictionary(
            rawRemoteDocs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let remoteIDs = Set(rawRemoteByID.keys)
        let currentIDs = session.photos.map(\.id)
        let currentRemoteOrder = currentIDs.filter(remoteIDs.contains)
        let effectiveRemoteDocs = rawRemoteDocs.compactMap { doc -> RemotePhotoDoc? in
            let overlay = state.journal.overlay(
                for: .photo(session: session.id, photo: doc.id))
            let merged = InboundMerge.merged(photo: doc, overlay: overlay)
            return merged.deletedAt == nil ? merged : nil
        }
        let effectiveRemoteOrder = RemotePhotoDoc
            .ordered(effectiveRemoteDocs)
            .map(\.id)
            .filter(Set(currentRemoteOrder).contains)

        let userReordered: Bool
        if let baseline {
            userReordered = SyncPhotoOrdering.didExplicitlyReorder(
                current: currentIDs,
                baseline: baseline.photos.map(\.id),
                remoteIDs: remoteIDs)
        } else {
            userReordered = currentRemoteOrder != effectiveRemoteOrder
        }

        if userReordered {
            let rawRemoteOrder = RemotePhotoDoc
                .ordered(rawRemoteDocs)
                .map(\.id)
                .filter(Set(currentRemoteOrder).contains)
            let returnedToRemoteOrder = currentRemoteOrder == rawRemoteOrder
            for (index, photo) in session.photos.enumerated() {
                guard let remote = rawRemoteByID[photo.id] else { continue }
                let pTarget = SyncTarget.photo(
                    session: session.id, photo: photo.id)
                // A reorder reverted before its first drain must enqueue the
                // raw key over the existing dirty mutation. Otherwise use
                // deterministic dense keys; future inserts stay sparse.
                let desired = returnedToRemoteOrder
                    ? remote.orderKey
                    : Double(index + 1)
                if desired != remote.orderKey
                    || state.journal.isDirty(
                        target: pTarget, group: .photoOrder) {
                    state.journal.record(
                        target: pTarget, value: .order(desired),
                        baseRev: remote.orderMeta.rev, deviceID: deviceID)
                }
            }
        } else if currentRemoteOrder != effectiveRemoteOrder {
            // The model did not rearrange anything since its baseline; this
            // mismatch is an inbound peer reorder it has not consumed yet.
            staleVsShadow = true
        }

        // Photos in the shadow that vanished locally were removed here —
        // but ONLY if the model ever held them (see doc comment above).
        for (photoIdString, map) in shadowPhotoMaps where !seen.contains(photoIdString) {
            guard let photoId = UUID(uuidString: photoIdString),
                  let remote = RemotePhotoDoc(id: photoId, fsMap: map),
                  remote.deletedAt == nil else { continue }
            if baseline != nil, baselinePhotos[photoId] == nil {
                staleVsShadow = true   // peer-added photo the model never saw
                continue
            }
            state.journal.record(
                target: .photo(session: session.id, photo: photoId),
                value: .tombstone(Date()),
                baseRev: remote.delMeta.rev, deviceID: deviceID)
        }
        persistState()

        if staleVsShadow {
            // The flush clobbered the session file with pre-inbound state:
            // rebuild it from shadow + dirty overlay (which now includes any
            // groups journaled just above) and tell the UI to reload.
            await materializeLocal(session: session.id)
            noteRemoteChange(session.id)
        }
    }

    /// Session-level delete (P7 grid; emulator tests now). Removes the local
    /// file and journals the tombstone; a never-synced session just dies
    /// locally (there is nothing remote to tombstone).
    public func deleteSessionLocally(_ id: UUID, now: Date = Date()) async {
        await store.delete(id: id)
        let target = SyncTarget.session(id)
        if state.acks.everAcked(target) {
            let baseRev = shadowSession(id)?.delMeta.rev ?? 0
            state.journal.record(target: target, value: .tombstone(now),
                                 baseRev: baseRev, deviceID: deviceID)
        } else {
            state.journal.dropAll(for: target)
        }
        persistState()
    }

    /// Undo a session delete: clear the tombstone (rev-guarded — a deletion
    /// state that moved again surfaces a conflict instead) and bring the
    /// local copy back from the shadow.
    public func undoDeleteSessionLocally(_ id: UUID) async {
        let target = SyncTarget.session(id)
        let baseRev = shadowSession(id)?.delMeta.rev ?? 0
        state.journal.record(target: target, value: .tombstone(nil),
                             baseRev: baseRev, deviceID: deviceID)
        await materializeLocal(session: id)
        persistState()
    }

    /// Restore a preserved conflict loser as a NEW mutation on the current rev.
    public func restoreConflict(id: UUID) {
        guard let record = state.journal.popConflict(id: id) else { return }
        let baseRev: Int
        switch (record.target, record.group) {
        case (.session(let s), let g):
            baseRev = rev(of: g, in: shadowSession(s))
        case (.photo(let s, let p), let g):
            baseRev = rev(of: g, in: shadowPhoto(session: s, photo: p))
        case (.user, _):
            baseRev = 0
        }
        state.journal.record(target: record.target, value: record.localValue,
                             baseRev: baseRev, deviceID: deviceID)
        persistState()
    }

    public func dismissConflict(id: UUID) {
        state.journal.dismissConflict(id: id)
        persistState()
    }

    private func rev(of group: FieldGroup, in session: RemoteSessionDoc?) -> Int {
        guard let s = session else { return 0 }
        switch group {
        case .sessionTitle: return s.titleMeta.rev
        case .sessionRunningLook: return s.rlMeta.rev
        case .delete: return s.delMeta.rev
        default: return 0
        }
    }

    private func rev(of group: FieldGroup, in photo: RemotePhotoDoc?) -> Int {
        guard let p = photo else { return 0 }
        switch group {
        case .photoLook: return p.lookMeta.rev
        case .photoOrder: return p.orderMeta.rev
        case .delete: return p.delMeta.rev
        default: return 0
        }
    }

    // ------------------------------------------------------------- drain

    /// One full outbound pass: push never-acked creates, then drain the
    /// journal. Call when online; failures mark entries for retry.
    public func drainOnce(now: Date = Date()) async {
        await pushCreates(now: now)
        await drainJournal(now: now)
        persistState()
    }

    /// Create a document remotely — but ONLY if it does not already exist.
    /// A merge:false set over an existing doc is an UPDATE to the rules, and
    /// a create payload strips rev metadata, so it would be denied (or worse,
    /// on a rules gap, clobber history). If the doc exists (ack ledger was
    /// lost or another device created it), adopt it instead (review P4-4/10).
    private func createOrAdopt(path: String, data: [String: FSValue],
                               target: SyncTarget) async -> [String: FSValue]? {
        do {
            if let existing = try await backend.getDocument(path: path) {
                state.acks.markAcked(target)
                return existing
            }
            try await backend.setDocument(path: path, data: data, merge: false)
            state.acks.markAcked(target)
            return data
        } catch {
            return nil   // offline etc. — retried next drain
        }
    }

    private func pushCreates(now: Date) async {
        let sessions = await store.loadAll()
        for session in sessions {
            let target = SyncTarget.session(session.id)
            if !state.acks.everAcked(target) {
                let remote = remoteSessionDoc(from: session)
                guard let landed = await createOrAdopt(
                    path: target.path(uid: uid), data: remote.fsMap(),
                    target: target) else { continue }
                if let doc = RemoteSessionDoc(id: session.id, fsMap: landed) {
                    setShadow(doc)
                }
            }
            // Photo creates (hashed, syncable, not yet acked). Place each new
            // photo between its nearest current neighbours instead of always
            // appending it. This preserves an offline import that the user
            // already moved before its first acknowledgement.
            let syncable = syncablePhotos(session)
            let localOrder = syncable.map(\.id)
            var orderingDocs: [UUID: RemotePhotoDoc] = [:]
            for (pid, map) in state.shadowPhotos[session.id.uuidString] ?? [:] {
                guard let id = UUID(uuidString: pid),
                      let raw = RemotePhotoDoc(id: id, fsMap: map) else { continue }
                let merged = InboundMerge.merged(
                    photo: raw,
                    overlay: state.journal.overlay(
                        for: .photo(session: session.id, photo: id)))
                if merged.deletedAt == nil { orderingDocs[id] = merged }
            }

            for photo in syncable {
                guard let hash = photo.contentHash, !photo.tooLargeToSync,
                      SyncSchema.isValidContentHash(hash) else { continue }
                let pTarget = SyncTarget.photo(session: session.id, photo: photo.id)
                guard !state.acks.everAcked(pTarget) else { continue }
                await ensureBlobShell(hash: hash, byteSize: photo.byteSize, now: now)
                var knownKeys = orderingDocs.mapValues(\.orderKey)
                var orderKey = SyncPhotoOrdering.insertionKey(
                    for: photo.id,
                    localOrder: localOrder,
                    knownKeys: knownKeys)

                if orderKey == nil {
                    // Pathological equal/non-finite/exhausted neighbour keys:
                    // rebalance acknowledged peers to deterministic dense
                    // positions, then create this photo at its dense position.
                    let positions = Dictionary(
                        uniqueKeysWithValues: localOrder.enumerated().map {
                            ($0.element, Double($0.offset + 1))
                        })
                    for (knownID, var doc) in orderingDocs {
                        guard let desired = positions[knownID],
                              desired != doc.orderKey,
                              let raw = shadowPhoto(
                                session: session.id, photo: knownID)
                        else { continue }
                        state.journal.record(
                            target: .photo(
                                session: session.id, photo: knownID),
                            value: .order(desired),
                            baseRev: raw.orderMeta.rev,
                            deviceID: deviceID)
                        doc.orderKey = desired
                        orderingDocs[knownID] = doc
                    }
                    knownKeys = orderingDocs.mapValues(\.orderKey)
                    orderKey = SyncPhotoOrdering.insertionKey(
                        for: photo.id,
                        localOrder: localOrder,
                        knownKeys: knownKeys)
                        ?? positions[photo.id]
                        ?? Double(localOrder.count + 1)
                }
                let resolvedOrderKey = orderKey
                    ?? Double(localOrder.firstIndex(of: photo.id).map { $0 + 1 }
                        ?? (localOrder.count + 1))
                let doc = RemotePhotoDoc(
                    id: photo.id, contentHash: hash, look: photo.look,
                    orderKey: resolvedOrderKey,
                    gamut: nil,
                    pixelWidth: photo.pixelWidth, pixelHeight: photo.pixelHeight,
                    looksMerged: photo.looksMerged,
                    createdAt: now, updatedAt: now)
                guard let landed = await createOrAdopt(
                    path: pTarget.path(uid: uid), data: doc.fsMap(),
                    target: pTarget) else { continue }
                if let adopted = RemotePhotoDoc(id: photo.id, fsMap: landed) {
                    setShadow(adopted, session: session.id)
                    if adopted.deletedAt == nil {
                        orderingDocs[photo.id] = adopted
                    }
                }
                enqueueUploads(photo: photo, hash: hash)
            }
            // Derived, LWW: covers + photoCount (only when acked).
            if state.acks.everAcked(target) {
                await refreshDerivedFields(for: session)
            }
        }
    }

    private func remoteSessionDoc(from session: Session) -> RemoteSessionDoc {
        RemoteSessionDoc(
            id: session.id, title: session.title,
            sameLookForAll: session.sameLookForAll,
            runningLook: session.runningLook,
            covers: coverList(session),
            photoCount: syncablePhotos(session).count,
            createdAt: session.createdAt, updatedAt: session.updatedAt)
    }

    private func syncablePhotos(_ session: Session) -> [PhotoRecord] {
        session.photos.filter {
            !$0.tooLargeToSync && ($0.contentHash.map(SyncSchema.isValidContentHash) ?? false)
        }
    }

    private func coverList(_ session: Session) -> [RemoteSessionDoc.Cover] {
        syncablePhotos(session).prefix(SyncSchema.maxCovers).map {
            RemoteSessionDoc.Cover(photoId: $0.id, contentHash: $0.contentHash!)
        }
    }

    private func refreshDerivedFields(for session: Session) async {
        let covers = coverList(session)
        let count = syncablePhotos(session).count
        let shadow = shadowSession(session.id)
        if let shadow, shadow.covers == covers, shadow.photoCount == count { return }
        let payload: [String: FSValue] = [
            "covers": .array(covers.map {
                .map(["photoId": .string($0.photoId.uuidString),
                      "contentHash": .string($0.contentHash)])
            }),
            "photoCount": .int(Int64(count)),
            "updatedAt": .timestamp(Date()),
        ]
        do {
            try await backend.setDocument(
                path: SyncTarget.session(session.id).path(uid: uid),
                data: payload, merge: true)
            if var s = shadow {
                s.covers = covers
                s.photoCount = count
                setShadow(s)
            }
        } catch { /* retried on a later drain */ }
    }

    /// Blob docs we know exist remotely — avoids re-sending shells, whose
    /// fresh `createdAt` the rules reject as an immutable-field change on an
    /// existing doc (review P4-7/24). Rebuilt from the blobs listener.
    private var knownBlobDocs: Set<String> = []

    private func ensureBlobShell(hash: String, byteSize: Int64, now: Date) async {
        guard !knownBlobDocs.contains(hash) else { return }
        let path = "users/\(uid)/blobs/\(hash)"
        if (try? await backend.getDocument(path: path)) != nil {
            knownBlobDocs.insert(hash)
            return
        }
        let shell = RemoteBlobDoc(contentHash: hash, byteSize: byteSize, createdAt: now)
        do {
            try await backend.setDocument(path: path, data: shell.shellFSMap(), merge: false)
            knownBlobDocs.insert(hash)
        } catch { /* offline etc. — the next create attempt retries */ }
    }

    private func drainJournal(now: Date) async {
        var conflictedSessions: Set<UUID> = []
        // Mark EVERYTHING in-flight BEFORE the first suspension. Actors are
        // reentrant: while one entry's transaction is awaiting, a local edit
        // can run record() — and record() coalesces destructively into
        // `.pending` entries (value overwritten, `next` cleared). With every
        // entry already `.inFlight`, that edit parks in `next` and re-arms
        // after the commit instead of being silently lost (review P4-1/8).
        func drainable(_ target: SyncTarget) -> Bool {
            // The user doc always exists (admitSyncUser provisions it);
            // session/photo mutations wait until their create is pushed.
            if case .user = target { return true }
            return state.acks.everAcked(target)
        }
        let keys = state.journal.pendingEntries
            .filter { drainable($0.target) }
            .map { ($0.target, $0.group) }
        for (target, group) in keys {
            state.journal.markInFlight(target: target, group: group)
        }
        for (target, group) in keys {
            // Re-read the LIVE entry — never a pre-await snapshot.
            guard let entry = state.journal.entry(target: target, group: group),
                  entry.state == .inFlight else { continue }
            do {
                let result = try await backend.drainMutation(
                    docPath: entry.target.path(uid: uid),
                    pending: entry, deviceID: deviceID, updatedAt: now)
                apply(result: result, to: entry, now: now)
                if case .conflict = result.decision {
                    switch entry.target {
                    case .session(let s), .photo(let s, _): conflictedSessions.insert(s)
                    case .user: break
                    }
                }
            } catch {
                state.journal.completeFailure(target: entry.target, group: entry.group)
            }
        }
        // A lost conflict adopts the remote value — but the listener already
        // delivered that value while the group was still dirty, so nothing
        // will re-fire. Re-materialize now that the dirty flag is gone,
        // refreshing the shadow from the server first (the conflict's winner).
        for sessionID in conflictedSessions {
            await refreshShadowFromServer(session: sessionID)
            await materializeLocal(session: sessionID)
        }
    }

    /// Pull the current remote truth for one session (+ its photo docs we
    /// already track) into the shadow. Used after lost conflicts.
    private func refreshShadowFromServer(session id: UUID) async {
        let sessionPath = SyncTarget.session(id).path(uid: uid)
        if let data = try? await backend.getDocument(path: sessionPath),
           let doc = RemoteSessionDoc(id: id, fsMap: data) {
            setShadow(doc)
        }
        for pidString in (state.shadowPhotos[id.uuidString] ?? [:]).keys {
            guard let pid = UUID(uuidString: pidString) else { continue }
            let path = SyncTarget.photo(session: id, photo: pid).path(uid: uid)
            if let data = try? await backend.getDocument(path: path),
               let doc = RemotePhotoDoc(id: pid, fsMap: data) {
                setShadow(doc, session: id)
            }
        }
    }

    private func apply(result: DrainResult, to entry: PendingMutation, now: Date) {
        switch result.decision {
        case .write, .alreadyApplied:
            state.journal.completeCommit(target: entry.target, group: entry.group,
                                         committedRev: result.rev, now: now)
            bumpShadow(after: entry, committedRev: result.rev)
        case .satisfied:
            state.journal.completeCommit(target: entry.target, group: entry.group,
                                         committedRev: result.rev, now: now)
        case .conflict:
            state.journal.resolveConflict(target: entry.target, group: entry.group,
                                          supersededBy: result.supersededBy, now: now)
            // The listener delivers the winning remote value; with the dirty
            // flag gone it now applies cleanly.
        case .retry:
            // Only reachable through a fake backend that surfaces the pure
            // decision (Firebase rebases inside the transaction).
            state.journal.rebase(target: entry.target, group: entry.group,
                                 to: result.rev)
        case .targetGone:
            if state.acks.everAcked(entry.target) {
                state.journal.drop(target: entry.target, group: entry.group)
            } else {
                state.journal.completeFailure(target: entry.target, group: entry.group)
            }
        }
    }

    /// After our own commit, move the shadow's group to the committed value
    /// so the next local diff doesn't re-journal it.
    private func bumpShadow(after entry: PendingMutation, committedRev: Int) {
        let meta = RevMeta(rev: committedRev, by: deviceID, mut: entry.mutationID)
        switch entry.target {
        case .session(let sid):
            guard var doc = shadowSession(sid) else { return }
            switch entry.value {
            case .title(let t): doc.title = t; doc.titleMeta = meta
            case .runningLook(let look, let same):
                doc.runningLook = look; doc.sameLookForAll = same; doc.rlMeta = meta
            case .tombstone(let d): doc.deletedAt = d; doc.delMeta = meta
            default: break
            }
            setShadow(doc)
        case .photo(let sid, let pid):
            guard var doc = shadowPhoto(session: sid, photo: pid) else { return }
            switch entry.value {
            case .look(let params): doc.look = params; doc.lookMeta = meta
            case .order(let key): doc.orderKey = key; doc.orderMeta = meta
            case .tombstone(let d): doc.deletedAt = d; doc.delMeta = meta
            default: break
            }
            setShadow(doc, session: sid)
        case .user:
            break
        }
    }

    // ------------------------------------------------------------- transfers

    private func enqueueUploads(photo: PhotoRecord, hash: String) {
        let resolved = photo.sourceURL(managedRoot: store.managedFilesDir).path
        let candidate = state.hashIndex[hash]
            ?? (FileManager.default.fileExists(atPath: resolved) ? resolved : nil)
            ?? linkedPath(photo)
        guard let sourcePath = candidate else { return }
        // Thumb first (generated beside the state), then the original.
        if let thumb = ensureThumb(hash: hash, sourcePath: sourcePath) {
            state.transfers.enqueue(contentHash: hash, tier: "thumbs",
                                    byteSize: thumb.size, sourcePath: thumb.path)
        }
        // Reservation byteSize must equal the UPLOADED size exactly (rules).
        // If the file on disk no longer matches the record's size, the
        // CONTENT changed too — the recorded hash is stale, and uploading new
        // bytes under it would poison the content addressing. Skip; import
        // re-hashing mints a new photo record for replaced files (spec).
        let statSize = (try? FileManager.default.attributesOfItem(atPath: sourcePath))?[
            .size] as? Int64
        guard let onDisk = statSize, onDisk == photo.byteSize || photo.byteSize == 0 else {
            return
        }
        state.transfers.enqueue(contentHash: hash, tier: "originals",
                                byteSize: onDisk, sourcePath: sourcePath)
    }

    private func linkedPath(_ photo: PhotoRecord) -> String? {
        if case .linked(let path) = photo.origin { return path }
        return nil
    }

    private func ensureThumb(hash: String, sourcePath: String) -> (path: String, size: Int64)? {
        let dir = root.appendingPathComponent("thumbs")
        let url = dir.appendingPathComponent("\(hash).jpg")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64, size > 0 {
            return (url.path, size)
        }
        guard let data = ThumbnailMaker.jpegThumbnail(
            forFileAt: URL(fileURLWithPath: sourcePath)) else { return nil }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return (url.path, Int64(data.count))
        } catch {
            return nil
        }
    }

    private var pumpRunning = false

    /// One transfer-pump pass: execute what the queue plans, feed results
    /// back. Loops until the queue has nothing eligible (bounded).
    /// Re-entrancy-safe: listeners (config flips, usage changes) also pump,
    /// and two interleaved pumps would double-plan the same transfer (the
    /// duplicate reserve aborts the first transaction and knocks the
    /// transfer into backoff). The running pump's loop picks up anything
    /// new, so a second entry can simply bail.
    public func pumpTransfers(now: Date = Date()) async {
        guard !pumpRunning else { return }
        pumpRunning = true
        defer { pumpRunning = false }
        var guardRail = 0
        while guardRail < 64 {
            guardRail += 1
            let actions = state.transfers.nextActions(
                now: now, allowLargeTransfers: allowLargeTransfers)
            guard !actions.isEmpty else { break }
            for action in actions {
                switch action {
                case .reserve(let t):
                    state.transfers.beganReserving(id: t.id)
                    do {
                        let grant = try await backend.reserveUpload(
                            contentHash: t.contentHash, tier: t.tier, byteSize: t.byteSize)
                        state.transfers.reserved(id: t.id, expiresAt: grant.expiresAt)
                        // Chain straight into the upload: a reservation is a
                        // completion deadline (r7) — sitting on it is waste,
                        // and the planner (correctly) never re-plans a
                        // transfer that is already `uploading`.
                        await performUpload(state.transfers.transfer(id: t.id) ?? t, now: now)
                    } catch SyncBackendError.quotaExceeded {
                        state.transfers.failed(id: t.id, failure: .quotaExceeded, now: now)
                    } catch SyncBackendError.syncUnavailable(let why) {
                        state.transfers.failed(id: t.id, failure: .syncUnavailable(why), now: now)
                    } catch {
                        state.transfers.failed(
                            id: t.id, failure: .transient(String(describing: error)), now: now)
                    }
                case .upload(let t):
                    await performUpload(t, now: now)
                }
            }
        }
        persistState()
    }

    private func performUpload(_ t: Transfer, now: Date) async {
        let objectName = SyncSchema.objectName(
            uid: uid, tier: t.tier, contentHash: t.contentHash)
        do {
            // Skip-if-exists (plan: ledger + getMetadata): objects are
            // content-addressed and immutable — re-uploading an existing one
            // would be an update, which rules deny. Another device (or an
            // earlier launch) already finalized it: done.
            if try await backend.objectExists(objectName: objectName) {
                state.transfers.markAlreadyUploaded(id: t.id)
                onTransferProgress?()
                return
            }
            try await backend.uploadObject(
                objectName: objectName,
                fileURL: URL(fileURLWithPath: t.sourcePath),
                onProgress: { [weak self] completedBytes in
                    Task {
                        await self?.recordTransferProgress(
                            id: t.id, completedBytes: completedBytes)
                    }
                })
            state.transfers.uploadSucceeded(id: t.id)
            onTransferProgress?()
        } catch SyncBackendError.storageDenied {
            state.transfers.failed(id: t.id, failure: .leaseExpired, now: now)
            onTransferProgress?()
        } catch {
            state.transfers.failed(
                id: t.id, failure: .transient(String(describing: error)), now: now)
            onTransferProgress?()
        }
    }

    private func recordTransferProgress(id: String, completedBytes: Int64) {
        state.transfers.updateProgress(id: id, completedBytes: completedBytes)
        onTransferProgress?()
    }

    // ------------------------------------------------------------- listeners

    /// Attach a collection listener whose events are consumed strictly in
    /// order by a single task (see `eventPumps`).
    private func listenOrdered(path: String,
                               handler: @escaping (SyncEngine) -> ([DocEvent]) async -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: [DocEvent].self)
        listeners.append(backend.listenCollection(path: path) { events in
            continuation.yield(events)
        })
        eventPumps.append(Task { [weak self] in
            for await events in stream {
                guard let self else { break }
                await handler(self)(events)
            }
        })
    }

    private func startListeners() {
        listenOrdered(path: "users/\(uid)/sessions") { engine in
            { await engine.handleSessionEvents($0) }
        }
        listenOrdered(path: "users/\(uid)/blobs") { engine in
            { await engine.handleBlobEvents($0) }
        }
        // config/flags flips (kill switch off -> on) revive parked transfers
        // without waiting for a relaunch (review P4-5).
        listenOrdered(path: "config") { engine in
            { _ in await engine.retryTransfers() }
        }
        // usage changes (reconciler frees/converts bytes, quota raises land
        // here indirectly) re-test quota-terminal transfers (review P4-16).
        listenOrdered(path: "users/\(uid)/usage") { engine in
            { _ in
                await engine.noteUsageChanged()
            }
        }
    }

    private func noteUsageChanged() async {
        state.transfers.quotaChanged()
        await pumpTransfers()
    }

    /// Photos listeners: the open session + the N most recent (spec: 5).
    public func listenPhotos(session id: UUID) {
        guard !photoListenerSessions.contains(id) else { return }
        photoListenerSessions.insert(id)
        listenOrdered(path: "users/\(uid)/sessions/\(id.uuidString)/photos") { engine in
            { await engine.handlePhotoEvents(session: id, events: $0) }
        }
    }

    private func handleSessionEvents(_ events: [DocEvent]) async {
        for event in events {
            guard let id = UUID(uuidString: event.id) else { continue }
            let target = SyncTarget.session(id)
            guard let data = event.data else {
                // Physically purged remotely (maintenance/deleteAccount).
                if state.acks.everAcked(target) {
                    await adoptRemotePurge(session: id)
                }
                continue
            }
            guard let doc = RemoteSessionDoc(id: id, fsMap: data) else { continue }
            state.acks.markAcked(target)
            setShadow(doc)
            listenPhotos(session: id)
            if doc.deletedAt != nil,
               !state.journal.isDirty(target: target, group: .delete) {
                // Tombstone adopted: hide locally (undo lives remotely).
                await store.delete(id: id)
            } else {
                await materializeLocal(session: id)
            }
            noteRemoteChange(id)
        }
        persistSoon()
    }

    private func handlePhotoEvents(session sid: UUID, events: [DocEvent]) async {
        for event in events {
            guard let pid = UUID(uuidString: event.id) else { continue }
            let target = SyncTarget.photo(session: sid, photo: pid)
            guard let data = event.data else {
                // Physical purge (maintenance after tombstone retention).
                // Adopt it fully: drop the LOCAL record too, don't just
                // un-ack — an un-acked-but-present record reads as an
                // offline-created photo and gets resurrected by the next
                // pushCreates (review P4-10). Only records we know the
                // server once had are purged; a rollback of a never-acked
                // create no-ops here.
                guard state.acks.everAcked(target) else { continue }
                state.shadowPhotos[sid.uuidString]?.removeValue(forKey: pid.uuidString)
                state.acks.remove(target)
                state.journal.dropAll(for: target)
                if var session = await store.load(id: sid) {
                    session.photos.removeAll { $0.id == pid }
                    try? await store.save(session)
                }
                continue
            }
            guard let doc = RemotePhotoDoc(id: pid, fsMap: data) else { continue }
            state.acks.markAcked(target)
            setShadow(doc, session: sid)
        }
        await materializeLocal(session: sid)
        noteRemoteChange(sid)
        persistSoon()
    }

    private func handleBlobEvents(_ events: [DocEvent]) async {
        for event in events {
            guard let data = event.data else {
                // Blob doc physically deleted (GC): whatever "done" claims we
                // hold about its renditions are void — a future re-add of the
                // same bytes must re-upload (review P4-17).
                knownBlobDocs.remove(event.id)
                state.shadowBlobs.removeValue(forKey: event.id)
                state.transfers.remove(contentHash: event.id)
                continue
            }
            guard let doc = RemoteBlobDoc(contentHash: event.id, fsMap: data) else { continue }
            knownBlobDocs.insert(doc.contentHash)
            state.shadowBlobs[doc.contentHash] = data
            for tier in ["thumbs", "originals"] {
                if doc.isUploaded(tier: tier) {
                    // Server finalize — the completion signal we trust.
                    state.transfers.markAlreadyUploaded(
                        id: SyncSchema.reservationId(tier: tier, contentHash: doc.contentHash))
                } else if let path = state.hashIndex[doc.contentHash],
                          FileManager.default.fileExists(atPath: path) {
                    // The server's own ledger says this rendition is missing
                    // and we hold the bytes: (re-)enqueue. This is what makes
                    // uploads self-healing after a lost sync-state.json —
                    // the queue is re-derived from the blob docs, not only
                    // from photo-create time (review P4-18).
                    let record = PhotoRecord(origin: .linked(path: path),
                                             contentHash: doc.contentHash,
                                             byteSize: doc.byteSize)
                    enqueueUploads(photo: record, hash: doc.contentHash)
                }
            }
        }
        // Blob ledgers are the durable completion proof used by cold-launch
        // card status, so their arrival must re-project the grid even when no
        // byte-progress callback fires in this process.
        onTransferProgress?()
        persistSoon()
    }

    private func adoptRemotePurge(session id: UUID) async {
        state.journal.dropAll(for: .session(id))
        state.shadowSessions.removeValue(forKey: id.uuidString)
        state.shadowPhotos.removeValue(forKey: id.uuidString)
        await store.delete(id: id)
        noteRemoteChange(id)
    }

    /// Rebuild the local Session from shadow + dirty overlay and save it.
    /// Local-only fields (origin paths, export state, byte sizes) are carried
    /// over from the existing local copy; unknown originals point into the
    /// blob cache (hydrated on demand, P5/P6).
    private func materializeLocal(session id: UUID) async {
        guard let remote = shadowSession(id) else { return }
        let overlay = state.journal.overlay(for: .session(id))
        let merged = InboundMerge.merged(session: remote, overlay: overlay)
        guard merged.deletedAt == nil else {
            // A tombstoned winner must actually disappear locally — this is
            // the path a LOST undo takes (undo conflicted, remote deletion
            // stands); returning without deleting left a ghost session that
            // never went away (review P4-3).
            await store.delete(id: id)
            return
        }

        let photoMaps = state.shadowPhotos[id.uuidString] ?? [:]
        var aliveByID: [UUID: RemotePhotoDoc] = [:]
        for (pidString, map) in photoMaps {
            guard let pid = UUID(uuidString: pidString),
                  let doc = RemotePhotoDoc(id: pid, fsMap: map) else { continue }
            let pOverlay = state.journal.overlay(for: .photo(session: id, photo: pid))
            let m = InboundMerge.merged(photo: doc, overlay: pOverlay)
            if m.deletedAt == nil { aliveByID[pid] = m }
        }

        let existing = await store.load(id: id)
        var local = existing ?? Session(id: id, createdAt: merged.createdAt)
        local.title = merged.title
        local.sameLookForAll = merged.sameLookForAll
        local.runningLook = merged.runningLook
        local.updatedAt = merged.updatedAt

        // Remote order is authoritative for every remotely-known photo.
        // Local-only records (tooLargeToSync, unhashed, pending create) keep
        // occupying their existing slots while the remote records flow
        // through the remaining slots in order.
        let priorRecords = existing?.photos ?? []
        let priorByID = Dictionary(
            priorRecords.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let remotelyKnown = Set(photoMaps.keys.compactMap {
            UUID(uuidString: $0)
        })
        let orderedAlive = RemotePhotoDoc.ordered(Array(aliveByID.values))
        let orderedIDs = SyncPhotoOrdering.materializedIDs(
            existing: priorRecords.map(\.id),
            remotelyKnown: remotelyKnown,
            orderedAliveRemote: orderedAlive.map(\.id))

        let records = orderedIDs.compactMap { photoID -> PhotoRecord? in
            guard let doc = aliveByID[photoID] else {
                // Only identities the remote has never known can reach here.
                return priorByID[photoID]
            }
            if var prior = priorByID[photoID] {
                prior.look = doc.look
                prior.looksMerged = doc.looksMerged
                return prior
            }
            let origin: PhotoRecord.Origin
            if let path = state.hashIndex[doc.contentHash] {
                origin = .linked(path: path)
            } else {
                origin = .managed(
                    relativePath: "blobs/\(doc.contentHash).jpg")
            }
            return PhotoRecord(
                id: doc.id, origin: origin, contentHash: doc.contentHash,
                byteSize: 0, pixelWidth: doc.pixelWidth,
                pixelHeight: doc.pixelHeight,
                tooLargeToSync: false, looksMerged: doc.looksMerged,
                look: doc.look)
        }
        local.photos = records
        try? await store.save(local)
    }

    // ------------------------------------------------------------- reconcile

    /// Ack-aware full reconcile over sessions (spec r4/r5). Runs after
    /// listeners settle; also the recovery path for >30-days-offline.
    public func reconcileSessions() async {
        let localSessions = await store.loadAll()
        let local = Set(localSessions.map { SyncTarget.session($0.id) })
        var remote = Set<SyncTarget>()
        for key in state.shadowSessions.keys {
            if let id = UUID(uuidString: key) { remote.insert(.session(id)) }
        }
        for action in SyncReconcile.actions(local: local, remote: remote,
                                            acks: state.acks) {
            switch action {
            case .adoptRemote(let target):
                if case .session(let id) = target { await materializeLocal(session: id) }
            case .purgeLocal(let target):
                if case .session(let id) = target { await adoptRemotePurge(session: id) }
            case .pushLocalCreate:
                break   // drainOnce pushes never-acked creates
            }
        }
        persistState()
    }
}

// MARK: - Thumbnails

/// 1024px JPEG thumbs (q0.72, sRGB via ImageIO's thumbnail path) — the tier
/// peers render mosaics and previews from before originals hydrate.
public enum ThumbnailMaker {
    public static let maxPixel = 1024
    public static let quality = 0.72

    public static func jpegThumbnail(forFileAt url: URL) -> Data? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else {
            return nil
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake EXIF rotation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
            return nil
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, "public.jpeg" as CFString, 1, nil) else { return nil }
        let destOpts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, destOpts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
