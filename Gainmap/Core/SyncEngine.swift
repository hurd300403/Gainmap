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
struct SyncState: Codable, Equatable {
    var journal = ChangeJournal()
    var acks = AckLedger()
    var transfers = TransferQueue()
    /// Last converged remote session docs, keyed by session UUID string.
    var shadowSessions: [String: [String: FSValue]] = [:]
    /// Last converged remote photo docs, keyed by session then photo UUID.
    var shadowPhotos: [String: [String: [String: FSValue]]] = [:]
    /// contentHash -> absolute local path (Mac rehydration index).
    var hashIndex: [String: String] = [:]
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
    /// Sessions whose photo subcollections we listen to.
    private var photoListenerSessions: Set<UUID> = []
    /// Wi-Fi policy input (Mac: always true; iOS wires Settings later).
    public var allowLargeTransfers = true

    private var lastKnownQuotaBytes: Int64 = 0

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
        loadState()
        state.journal.requeueInFlightAfterRelaunch()
        state.transfers.relaunch()
        persistState()
        startListeners()
    }

    public func stop() {
        for l in listeners { l.cancel() }
        listeners.removeAll()
        photoListenerSessions.removeAll()
        persistState()
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let loaded = try? JSONDecoder().decode(SyncState.self, from: data) else {
            return
        }
        state = loaded
    }

    private func persistState() {
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

    // Test/diagnostic visibility.
    public var journalSnapshot: ChangeJournal { state.journal }
    public var transferSnapshot: TransferQueue { state.transfers }
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
    public func noteLocalSession(_ session: Session) {
        // Rehydration index: remember where hashed originals live locally.
        for p in session.photos {
            if let hash = p.contentHash, case .linked(let path) = p.origin {
                state.hashIndex[hash] = path
            }
        }

        let target = SyncTarget.session(session.id)
        guard let shadow = shadowSession(session.id) else {
            persistState()
            return   // create is pushed by drainOnce (never-acked local)
        }

        if session.title != shadow.title {
            state.journal.record(target: target, value: .title(session.title),
                                 baseRev: shadow.titleMeta.rev, deviceID: deviceID)
        }
        if session.runningLook != shadow.runningLook
            || session.sameLookForAll != shadow.sameLookForAll {
            state.journal.record(
                target: target,
                value: .runningLook(session.runningLook,
                                    sameLookForAll: session.sameLookForAll),
                baseRev: shadow.rlMeta.rev, deviceID: deviceID)
        }

        let shadowPhotoMaps = state.shadowPhotos[session.id.uuidString] ?? [:]
        var seen = Set<String>()
        for (index, photo) in session.photos.enumerated() {
            seen.insert(photo.id.uuidString)
            guard let remote = shadowPhoto(session: session.id, photo: photo.id) else {
                continue   // create is pushed by drainOnce
            }
            let pTarget = SyncTarget.photo(session: session.id, photo: photo.id)
            if photo.look != remote.look {
                state.journal.record(target: pTarget, value: .look(photo.look),
                                     baseRev: remote.lookMeta.rev, deviceID: deviceID)
            }
            let localOrder = Double(index + 1)
            if remote.orderKey != localOrder {
                state.journal.record(target: pTarget, value: .order(localOrder),
                                     baseRev: remote.orderMeta.rev, deviceID: deviceID)
            }
            if remote.deletedAt != nil {
                // Present locally but tombstoned in shadow: local undo.
                state.journal.record(target: pTarget, value: .tombstone(nil),
                                     baseRev: remote.delMeta.rev, deviceID: deviceID)
            }
        }
        // Photos in the shadow that vanished locally were removed here.
        for (photoIdString, map) in shadowPhotoMaps where !seen.contains(photoIdString) {
            guard let photoId = UUID(uuidString: photoIdString),
                  let remote = RemotePhotoDoc(id: photoId, fsMap: map),
                  remote.deletedAt == nil else { continue }
            state.journal.record(
                target: .photo(session: session.id, photo: photoId),
                value: .tombstone(Date()),
                baseRev: remote.delMeta.rev, deviceID: deviceID)
        }
        persistState()
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

    private func pushCreates(now: Date) async {
        let sessions = await store.loadAll()
        for session in sessions {
            let target = SyncTarget.session(session.id)
            if !state.acks.everAcked(target) {
                let remote = remoteSessionDoc(from: session)
                do {
                    try await backend.setDocument(
                        path: target.path(uid: uid), data: remote.fsMap(), merge: false)
                    state.acks.markAcked(target)
                    setShadow(remote)
                } catch {
                    continue   // offline etc. — retried next drain
                }
            }
            // Photo creates (hashed, syncable, not yet acked).
            for (index, photo) in session.photos.enumerated() {
                guard let hash = photo.contentHash, !photo.tooLargeToSync,
                      SyncSchema.isValidContentHash(hash) else { continue }
                let pTarget = SyncTarget.photo(session: session.id, photo: photo.id)
                guard !state.acks.everAcked(pTarget) else { continue }
                await ensureBlobShell(hash: hash, byteSize: photo.byteSize, now: now)
                let doc = RemotePhotoDoc(
                    id: photo.id, contentHash: hash, look: photo.look,
                    orderKey: Double(index + 1),
                    gamut: nil,
                    pixelWidth: photo.pixelWidth, pixelHeight: photo.pixelHeight,
                    looksMerged: photo.looksMerged,
                    createdAt: now, updatedAt: now)
                do {
                    try await backend.setDocument(
                        path: pTarget.path(uid: uid), data: doc.fsMap(), merge: false)
                    state.acks.markAcked(pTarget)
                    setShadow(doc, session: session.id)
                    enqueueUploads(photo: photo, hash: hash)
                } catch {
                    continue
                }
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

    private func ensureBlobShell(hash: String, byteSize: Int64, now: Date) async {
        let path = "users/\(uid)/blobs/\(hash)"
        let shell = RemoteBlobDoc(contentHash: hash, byteSize: byteSize, createdAt: now)
        // merge:true — creating over an existing blob doc must not clobber
        // server-owned renditions/state (and same-value fields diff to nothing).
        try? await backend.setDocument(path: path, data: shell.shellFSMap(), merge: true)
    }

    private func drainJournal(now: Date) async {
        var conflictedSessions: Set<UUID> = []
        for entry in state.journal.pendingEntries {
            // Skip mutations whose target was never created remotely yet.
            if case .photo = entry.target,
               !state.acks.everAcked(entry.target) { continue }
            if case .session = entry.target,
               !state.acks.everAcked(entry.target) { continue }

            state.journal.markInFlight(target: entry.target, group: entry.group)
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
        guard let sourcePath = state.hashIndex[hash] ?? linkedPath(photo) else { return }
        // Thumb first (generated beside the state), then the original.
        if let thumb = ensureThumb(hash: hash, sourcePath: sourcePath) {
            state.transfers.enqueue(contentHash: hash, tier: "thumbs",
                                    byteSize: thumb.size, sourcePath: thumb.path)
        }
        state.transfers.enqueue(contentHash: hash, tier: "originals",
                                byteSize: photo.byteSize, sourcePath: sourcePath)
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

    /// One transfer-pump pass: execute what the queue plans, feed results
    /// back. Loops until the queue has nothing eligible (bounded).
    public func pumpTransfers(now: Date = Date()) async {
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
                return
            }
            try await backend.uploadObject(
                objectName: objectName,
                fileURL: URL(fileURLWithPath: t.sourcePath))
            state.transfers.uploadSucceeded(id: t.id)
        } catch SyncBackendError.storageDenied {
            state.transfers.failed(id: t.id, failure: .leaseExpired, now: now)
        } catch {
            state.transfers.failed(
                id: t.id, failure: .transient(String(describing: error)), now: now)
        }
    }

    // ------------------------------------------------------------- listeners

    private func startListeners() {
        let sessionsPath = "users/\(uid)/sessions"
        listeners.append(backend.listenCollection(path: sessionsPath) { [weak self] events in
            Task { await self?.handleSessionEvents(events) }
        })
        listeners.append(backend.listenCollection(path: "users/\(uid)/blobs") { [weak self] events in
            Task { await self?.handleBlobEvents(events) }
        })
    }

    /// Photos listeners: the open session + the N most recent (spec: 5).
    public func listenPhotos(session id: UUID) {
        guard !photoListenerSessions.contains(id) else { return }
        photoListenerSessions.insert(id)
        let path = "users/\(uid)/sessions/\(id.uuidString)/photos"
        listeners.append(backend.listenCollection(path: path) { [weak self] events in
            Task { await self?.handlePhotoEvents(session: id, events: events) }
        })
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
        }
        persistState()
    }

    private func handlePhotoEvents(session sid: UUID, events: [DocEvent]) async {
        for event in events {
            guard let pid = UUID(uuidString: event.id) else { continue }
            guard let data = event.data else {
                state.shadowPhotos[sid.uuidString]?.removeValue(forKey: pid.uuidString)
                state.acks.remove(.photo(session: sid, photo: pid))
                continue
            }
            guard let doc = RemotePhotoDoc(id: pid, fsMap: data) else { continue }
            state.acks.markAcked(.photo(session: sid, photo: pid))
            setShadow(doc, session: sid)
        }
        await materializeLocal(session: sid)
        persistState()
    }

    private func handleBlobEvents(_ events: [DocEvent]) async {
        for event in events {
            guard let doc = RemoteBlobDoc(contentHash: event.id,
                                          fsMap: event.data ?? [:]) else { continue }
            // Server finalize is the completion signal we trust but never write.
            for tier in SyncSchema.tiers where doc.isUploaded(tier: tier) {
                state.transfers.markAlreadyUploaded(
                    id: SyncSchema.reservationId(tier: tier, contentHash: doc.contentHash))
            }
        }
        persistState()
    }

    private func adoptRemotePurge(session id: UUID) async {
        state.journal.dropAll(for: .session(id))
        state.shadowSessions.removeValue(forKey: id.uuidString)
        state.shadowPhotos.removeValue(forKey: id.uuidString)
        await store.delete(id: id)
    }

    /// Rebuild the local Session from shadow + dirty overlay and save it.
    /// Local-only fields (origin paths, export state, byte sizes) are carried
    /// over from the existing local copy; unknown originals point into the
    /// blob cache (hydrated on demand, P5/P6).
    private func materializeLocal(session id: UUID) async {
        guard let remote = shadowSession(id) else { return }
        let overlay = state.journal.overlay(for: .session(id))
        let merged = InboundMerge.merged(session: remote, overlay: overlay)
        guard merged.deletedAt == nil else { return }

        let photoMaps = state.shadowPhotos[id.uuidString] ?? [:]
        var photos: [RemotePhotoDoc] = []
        for (pidString, map) in photoMaps {
            guard let pid = UUID(uuidString: pidString),
                  let doc = RemotePhotoDoc(id: pid, fsMap: map) else { continue }
            let pOverlay = state.journal.overlay(for: .photo(session: id, photo: pid))
            let m = InboundMerge.merged(photo: doc, overlay: pOverlay)
            if m.deletedAt == nil { photos.append(m) }
        }

        let existing = await store.load(id: id)
        let existingByID = Dictionary(uniqueKeysWithValues:
            (existing?.photos ?? []).map { ($0.id, $0) })

        var local = existing ?? Session(id: id, createdAt: merged.createdAt)
        local.title = merged.title
        local.sameLookForAll = merged.sameLookForAll
        local.runningLook = merged.runningLook
        local.updatedAt = merged.updatedAt

        var records: [PhotoRecord] = []
        for doc in RemotePhotoDoc.ordered(photos) {
            if var prior = existingByID[doc.id] {
                prior.look = doc.look
                prior.looksMerged = doc.looksMerged
                records.append(prior)
            } else {
                let origin: PhotoRecord.Origin
                if let path = state.hashIndex[doc.contentHash] {
                    origin = .linked(path: path)
                } else {
                    origin = .managed(relativePath: "blobs/\(doc.contentHash).jpg")
                }
                records.append(PhotoRecord(
                    id: doc.id, origin: origin, contentHash: doc.contentHash,
                    byteSize: 0, pixelWidth: doc.pixelWidth, pixelHeight: doc.pixelHeight,
                    tooLargeToSync: false, looksMerged: doc.looksMerged,
                    look: doc.look))
            }
        }
        // Local-only photos (unhashed yet, too large, or pending create) stay.
        let remoteIDs = Set(records.map(\.id))
        for p in existing?.photos ?? [] where !remoteIDs.contains(p.id) {
            let isKnownRemotely = photoMaps[p.id.uuidString] != nil
            if !isKnownRemotely { records.append(p) }
            // Known remotely but filtered out => tombstoned: drop it locally.
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
