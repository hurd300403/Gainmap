//
//  TransferQueueTests.swift
//  GainmapCoreTests
//
//  P4c: the upload state machine — reservation lifecycle (r7 single-deadline
//  semantics), thumbs-first ordering, Wi-Fi gating, backoff/park, terminal
//  quota state, relaunch restart — plus the ack-aware reconcile table.
//

import XCTest
@testable import GainmapCore

final class TransferQueueTests: XCTestCase {

    private let hashA = String(repeating: "aa", count: 32)
    private let hashB = String(repeating: "bb", count: 32)
    private let hashC = String(repeating: "cc", count: 32)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func queue(_ entries: [(String, String, Int64)]) -> TransferQueue {
        var q = TransferQueue()
        for (hash, tier, size) in entries {
            q.enqueue(contentHash: hash, tier: tier, byteSize: size,
                      sourcePath: "/tmp/\(tier)-\(hash.prefix(4)).jpg")
        }
        return q
    }

    // MARK: intake

    func testEnqueueDedupesAndRejectsOversizedOrInvalid() {
        var q = queue([(hashA, "originals", 100), (hashA, "originals", 100)])
        XCTAssertEqual(q.transfers.count, 1)
        q.enqueue(contentHash: hashA, tier: "thumbs", byteSize: 100, sourcePath: "/t")
        XCTAssertEqual(q.transfers.count, 2)   // same hash, different tier = distinct
        q.enqueue(contentHash: hashB, tier: "originals",
                  byteSize: SyncSchema.maxObjectBytes, sourcePath: "/big")
        q.enqueue(contentHash: "bad-hash", tier: "originals", byteSize: 5, sourcePath: "/x")
        q.enqueue(contentHash: hashB, tier: "originals", byteSize: 0, sourcePath: "/zero")
        XCTAssertEqual(q.transfers.count, 2)   // none of those got in
    }

    func testReEnqueueRevivesParkedWithCleanSlate() {
        var q = queue([(hashA, "originals", 100)])
        for _ in 0..<TransferQueue.maxAttempts {
            q.failed(id: q.transfers[0].id, failure: .transient("net"), now: t0)
        }
        XCTAssertEqual(q.transfers[0].status, .parked)
        q.enqueue(contentHash: hashA, tier: "originals", byteSize: 100, sourcePath: "/new")
        XCTAssertEqual(q.transfers[0].status, .queued)
        XCTAssertEqual(q.transfers[0].attempts, 0)
        XCTAssertEqual(q.transfers[0].sourcePath, "/new")
    }

    // MARK: planning

    func testThumbsPlanBeforeOriginals() {
        let q = queue([(hashA, "originals", 100), (hashA, "thumbs", 10),
                       (hashB, "thumbs", 12)])
        let actions = q.nextActions(now: t0, allowLargeTransfers: true, maxConcurrent: 3)
        guard case .reserve(let first) = actions[0],
              case .reserve(let second) = actions[1] else {
            return XCTFail("expected reserve actions")
        }
        XCTAssertEqual(first.tier, "thumbs")
        XCTAssertEqual(second.tier, "thumbs")
        XCTAssertEqual(actions.count, 3)
    }

    func testWiFiGateHoldsOriginalsButNotThumbs() {
        let q = queue([(hashA, "originals", 100), (hashA, "thumbs", 10)])
        let actions = q.nextActions(now: t0, allowLargeTransfers: false, maxConcurrent: 4)
        XCTAssertEqual(actions.count, 1)
        guard case .reserve(let t) = actions[0] else { return XCTFail() }
        XCTAssertEqual(t.tier, "thumbs")
    }

    func testConcurrencyBudgetCountsInFlight() {
        var q = queue([(hashA, "thumbs", 1), (hashB, "thumbs", 2),
                       (hashA, "originals", 3)])
        q.beganReserving(id: "thumbs_\(hashA)")
        q.reserved(id: "thumbs_\(hashA)", expiresAt: t0.addingTimeInterval(600))
        let actions = q.nextActions(now: t0, allowLargeTransfers: true, maxConcurrent: 2)
        XCTAssertEqual(actions.count, 1)   // one slot left
    }

    func testPlanReusesLiveReservationSkipsExpired() {
        var q = queue([(hashA, "thumbs", 1)])
        let id = "thumbs_\(hashA)"
        q.beganReserving(id: id)
        q.reserved(id: id, expiresAt: t0.addingTimeInterval(600))
        // Simulate relaunch: goes back to queued but keeps the lease.
        q.relaunch()
        var actions = q.nextActions(now: t0, allowLargeTransfers: true)
        XCTAssertEqual(actions, [.upload(q.transfers[0])])   // live lease reused
        // After expiry it must re-reserve.
        actions = q.nextActions(now: t0.addingTimeInterval(601), allowLargeTransfers: true)
        XCTAssertEqual(actions, [.reserve(q.transfers[0])])
    }

    // MARK: reservation + upload lifecycle

    func testHappyPathLifecycle() {
        var q = queue([(hashA, "thumbs", 1)])
        let id = "thumbs_\(hashA)"
        q.beganReserving(id: id)
        XCTAssertEqual(q.transfer(id: id)?.status, .reserving)
        q.reserved(id: id, expiresAt: t0.addingTimeInterval(600))
        XCTAssertEqual(q.transfer(id: id)?.status, .uploading)
        q.uploadSucceeded(id: id)
        XCTAssertEqual(q.transfer(id: id)?.status, .done)
        XCTAssertEqual(q.activeCount, 0)
        q.pruneDone()
        XCTAssertTrue(q.transfers.isEmpty)
    }

    func testUploadProgressIsMonotonicClampedAndCompletes() {
        var q = queue([(hashA, "originals", 100)])
        let id = "originals_\(hashA)"
        q.beganReserving(id: id)
        q.reserved(id: id, expiresAt: t0.addingTimeInterval(600))
        q.updateProgress(id: id, completedBytes: 40)
        q.updateProgress(id: id, completedBytes: 20)
        XCTAssertEqual(q.transfer(id: id)?.bytesTransferred, 40)
        q.updateProgress(id: id, completedBytes: 140)
        XCTAssertEqual(q.transfer(id: id)?.bytesTransferred, 100)
        q.uploadSucceeded(id: id)
        XCTAssertEqual(q.transfer(id: id)?.bytesTransferred, 100)
    }

    func testSessionMetricsUseRealTransferredBytes() {
        var photo = PhotoRecord(origin: .linked(path: "/photo.jpg"))
        photo.contentHash = hashA
        let session = Session(photos: [photo])
        var q = queue([(hashA, "originals", 100)])
        let id = "originals_\(hashA)"
        q.beganReserving(id: id)
        q.reserved(id: id, expiresAt: t0.addingTimeInterval(600))
        q.updateProgress(id: id, completedBytes: 35)

        let metrics = SessionSyncMetrics.calculate(
            sessions: [session], journal: nil, transfers: q)
        XCTAssertTrue(metrics.pendingSessionIDs.contains(session.id))
        XCTAssertEqual(
            metrics.progressBySessionID[session.id] ?? -1, 0.35, accuracy: 0.001)
    }

    func testSessionMetricsAttributeIssuesToOwningSession() {
        var firstPhoto = PhotoRecord(origin: .linked(path: "/first.jpg"))
        firstPhoto.contentHash = hashA
        let first = Session(photos: [firstPhoto])
        var secondPhoto = PhotoRecord(origin: .linked(path: "/second.jpg"))
        secondPhoto.contentHash = hashB
        let second = Session(photos: [secondPhoto])

        var q = queue([(hashA, "originals", 100), (hashB, "originals", 100)])
        for _ in 0..<TransferQueue.maxAttempts {
            q.failed(
                id: "originals_\(hashA)",
                failure: .transient("network"),
                now: t0)
        }

        let metrics = SessionSyncMetrics.calculate(
            sessions: [first, second], journal: nil, transfers: q)
        XCTAssertTrue(metrics.issueSessionIDs.contains(first.id))
        XCTAssertFalse(metrics.issueSessionIDs.contains(second.id))
        XCTAssertTrue(metrics.pendingSessionIDs.contains(second.id))
    }

    func testSessionMetricsMapConflictToOwningSession() {
        let first = Session()
        let second = Session()
        var journal = ChangeJournal()
        journal.record(
            target: .session(first.id),
            value: .title("Local title"),
            baseRev: 0,
            deviceID: "iphone")
        journal.resolveConflict(
            target: .session(first.id),
            group: .sessionTitle,
            supersededBy: "mac")

        let metrics = SessionSyncMetrics.calculate(
            sessions: [first, second], journal: journal, transfers: nil)
        XCTAssertEqual(metrics.issueSessionIDs, Set([first.id]))
        XCTAssertEqual(metrics.pendingSessionIDs, Set([first.id]))
        XCTAssertEqual(metrics.progressBySessionID[first.id], 0)
        XCTAssertEqual(metrics.progressBySessionID[second.id], 1)
    }

    func testPersistedStatusRestoresOnlyExactCloudCompleteSession() throws {
        let photo = PhotoRecord(
            origin: .linked(path: "/photo.jpg"),
            contentHash: hashA,
            byteSize: 4,
            pixelWidth: 12,
            pixelHeight: 8)
        let session = Session(
            title: "Synced session",
            sameLookForAll: true,
            photos: [photo])
        var state = SyncState()
        state.acks.markAcked(.session(session.id))
        state.acks.markAcked(
            .photo(session: session.id, photo: photo.id))
        state.shadowSessions[session.id.uuidString] = RemoteSessionDoc(
            id: session.id,
            title: session.title,
            sameLookForAll: session.sameLookForAll,
            runningLook: session.runningLook,
            photoCount: 1).fsMap()
        state.shadowPhotos[session.id.uuidString] = [
            photo.id.uuidString: RemotePhotoDoc(
                id: photo.id,
                contentHash: hashA,
                pixelWidth: photo.pixelWidth,
                pixelHeight: photo.pixelHeight).fsMap(),
        ]
        let rendition: [String: FSValue] = [
            "generation": .string("1"),
            "byteSize": .int(4),
            "counted": .bool(true),
            "uploadedAt": .timestamp(t0),
        ]
        var blob = RemoteBlobDoc(
            contentHash: hashA, byteSize: 4).shellFSMap()
        blob["renditions"] = .map([
            "originals": .map(rendition),
            "thumbs": .map(rendition),
        ])
        state.shadowBlobs[hashA] = blob

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(
            to: root.appendingPathComponent("sync-state.json"),
            options: .atomic)

        let restored = try XCTUnwrap(
            SyncEngine.persistedStatusSnapshot(root: root))
        let known = restored.knownSyncedSessionIDs(for: [session])
        XCTAssertEqual(known, Set([session.id]))

        var changed = session
        changed.title = "Changed while terminating"
        XCTAssertTrue(
            restored.knownSyncedSessionIDs(for: [changed]).isEmpty)

        var localOnly = session
        localOnly.photos.append(PhotoRecord(
            origin: .linked(path: "/new.jpg"),
            contentHash: hashB,
            byteSize: 4))
        XCTAssertTrue(
            restored.knownSyncedSessionIDs(for: [localOnly]).isEmpty)

        var tooLarge = session
        tooLarge.photos[0].tooLargeToSync = true
        XCTAssertTrue(
            restored.knownSyncedSessionIDs(for: [tooLarge]).isEmpty)

        var pendingJournal = restored.journal
        pendingJournal.record(
            target: .session(session.id),
            value: .title("Pending"),
            baseRev: 0,
            deviceID: "iphone")
        let pendingMetrics = SessionSyncMetrics.calculate(
            sessions: [session],
            journal: pendingJournal,
            transfers: restored.transfers,
            persistedSyncedSessionIDs: known)
        XCTAssertTrue(
            pendingMetrics.knownSyncedSessionIDs.isEmpty)
        XCTAssertTrue(
            pendingMetrics.pendingSessionIDs.contains(session.id))
    }

    func testLaunchRebasesPersistedIOSContainerPathsAndRevivesUploads() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-rebase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let syncRoot = tempRoot.appendingPathComponent("users/test-user")
        let managedRoot = syncRoot.appendingPathComponent("files")
        let importURL = managedRoot.appendingPathComponent("imports/photo.jpg")
        let untrackedURL = managedRoot.appendingPathComponent("imports/untracked.jpg")
        let thumbURL = syncRoot.appendingPathComponent("thumbs/\(hashA).jpg")
        try FileManager.default.createDirectory(
            at: importURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: thumbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: importURL)
        try Data(repeating: 9, count: 9).write(to: untrackedURL)
        try Data([5, 6, 7]).write(to: thumbURL)

        let photo = PhotoRecord(
            origin: .managed(relativePath: "imports/photo.jpg"),
            contentHash: hashA,
            byteSize: 4)
        let session = Session(photos: [photo])
        let oldRoot = "/var/mobile/Containers/Data/Application/OLD/Library/Application Support/Gainmap"
        var state = SyncState()
        state.hashIndex[hashA] = "\(oldRoot)/users/test-user/files/imports/photo.jpg"
        state.hashIndex[hashB] = untrackedURL.path
        state.transfers.enqueue(
            contentHash: hashA,
            tier: "originals",
            byteSize: 4,
            sourcePath: "\(oldRoot)/users/test-user/files/imports/photo.jpg")
        state.transfers.enqueue(
            contentHash: hashA,
            tier: "thumbs",
            byteSize: 3,
            sourcePath: "\(oldRoot)/users/test-user/thumbs/\(hashA).jpg")
        state.transfers.enqueue(
            contentHash: hashB,
            tier: "originals",
            byteSize: 9,
            sourcePath: untrackedURL.path)
        state.transfers.enqueue(
            contentHash: hashC,
            tier: "originals",
            byteSize: 9,
            sourcePath: "\(oldRoot)/users/test-user/files/imports/deleted.jpg")
        let deletedSessionID = UUID()
        let deletedPhotoID = UUID()
        state.shadowPhotos[deletedSessionID.uuidString] = [
            deletedPhotoID.uuidString: RemotePhotoDoc(
                id: deletedPhotoID,
                contentHash: hashC,
                deletedAt: t0).fsMap(),
        ]
        for _ in 0..<TransferQueue.maxAttempts {
            state.transfers.failed(
                id: "originals_\(hashA)",
                failure: .transient("File is not reachable"),
                now: t0)
        }

        let repaired = SyncEngine.rebasingLocalFileReferences(
            state,
            sessions: [session],
            managedRoot: managedRoot,
            syncRoot: syncRoot)

        XCTAssertEqual(repaired.hashIndex[hashA], importURL.path)
        XCTAssertEqual(
            repaired.transfers.transfer(id: "originals_\(hashA)")?.sourcePath,
            importURL.path)
        XCTAssertEqual(
            repaired.transfers.transfer(id: "thumbs_\(hashA)")?.sourcePath,
            thumbURL.path)
        XCTAssertEqual(
            repaired.transfers.transfer(id: "originals_\(hashA)")?.status,
            .queued)
        XCTAssertEqual(
            repaired.transfers.transfer(id: "originals_\(hashA)")?.attempts,
            0)
        XCTAssertNotNil(
            repaired.transfers.transfer(id: "originals_\(hashB)"),
            "absence from partial local/shadow caches is not deletion evidence")
        XCTAssertEqual(repaired.hashIndex[hashB], untrackedURL.path)
        XCTAssertNil(
            repaired.transfers.transfer(id: "originals_\(hashC)"),
            "an unreachable tombstoned rendition must not become a permanent issue")
    }

    func testLaunchPreservesBytesUnderReversibleParentTombstone() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-tombstone-rebase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let original = tempRoot.appendingPathComponent("imports/photo.jpg")
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: original)

        let sessionID = UUID()
        let photoID = UUID()
        var state = SyncState()
        state.hashIndex[hashA] = original.path
        state.transfers.enqueue(
            contentHash: hashA, tier: "originals",
            byteSize: 4, sourcePath: original.path)
        state.shadowSessions[sessionID.uuidString] = RemoteSessionDoc(
            id: sessionID, deletedAt: t0).fsMap()
        state.shadowPhotos[sessionID.uuidString] = [
            photoID.uuidString: RemotePhotoDoc(
                id: photoID, contentHash: hashA).fsMap(),
        ]

        let repaired = SyncEngine.rebasingLocalFileReferences(
            state,
            sessions: [],
            managedRoot: URL(fileURLWithPath: "/managed"),
            syncRoot: URL(fileURLWithPath: "/sync"))

        XCTAssertEqual(repaired.hashIndex[hashA], original.path)
        XCTAssertEqual(
            repaired.transfers.transfer(id: "originals_\(hashA)")?.sourcePath,
            original.path)
    }

    func testRepeatedLeaseDenialsParkInsteadOfHotLooping() {
        // A finalize 403 is indistinguishable from a permanent rules denial;
        // a REAL expiry heals after one fresh lease, so consecutive denials
        // must park rather than re-upload the full file forever.
        var q = queue([(hashA, "originals", 100)])
        let id = "originals_\(hashA)"
        for n in 1..<TransferQueue.maxLeaseDenials {
            q.failed(id: id, failure: .leaseExpired, now: t0)
            XCTAssertEqual(q.transfer(id: id)?.status, .queued, "denial \(n) still retries")
        }
        q.failed(id: id, failure: .leaseExpired, now: t0)
        XCTAssertEqual(q.transfer(id: id)?.status, .parked)
        // Success resets the counter…
        q.retryTrigger()
        q.beganReserving(id: id)
        q.reserved(id: id, expiresAt: t0.addingTimeInterval(60))
        q.uploadSucceeded(id: id)
        XCTAssertEqual(q.transfer(id: id)?.leaseDenials, 0)
    }

    func testRemoveByContentHashForgetsDoneEntries() {
        // Blob GC deleted the objects server-side: stale .done entries must
        // not block a future re-upload of the same bytes.
        var q = queue([(hashA, "originals", 100), (hashA, "thumbs", 10),
                       (hashB, "thumbs", 5)])
        q.markAlreadyUploaded(id: "originals_\(hashA)")
        q.remove(contentHash: hashA)
        XCTAssertNil(q.transfer(id: "originals_\(hashA)"))
        XCTAssertNil(q.transfer(id: "thumbs_\(hashA)"))
        XCTAssertNotNil(q.transfer(id: "thumbs_\(hashB)"))
        q.enqueue(contentHash: hashA, tier: "originals", byteSize: 100, sourcePath: "/re")
        XCTAssertEqual(q.transfer(id: "originals_\(hashA)")?.status, .queued)
    }

    func testTransferDecodeToleratesMissingNewFields() {
        // Adding a field must never invalidate persisted state (a dropped
        // queue strands uploads). Decode a JSON without leaseDenials.
        let json = """
        {"transfers":[{"contentHash":"\(hashA)","tier":"thumbs","byteSize":5,
        "sourcePath":"/t","status":"queued","attempts":1}]}
        """
        let q = try! JSONDecoder().decode(TransferQueue.self, from: Data(json.utf8))
        XCTAssertEqual(q.transfers.first?.leaseDenials, 0)
        XCTAssertEqual(q.transfers.first?.bytesTransferred, 0)
        XCTAssertEqual(q.transfers.first?.attempts, 1)
    }

    func testLeaseExpiredAtFinalizeIsNotAStrike() {
        // r7: 403 at finalize -> re-reserve + NEW upload session; attempts
        // unchanged so a slow connection is never punished into parking.
        var q = queue([(hashA, "originals", 100)])
        let id = "originals_\(hashA)"
        q.beganReserving(id: id)
        q.reserved(id: id, expiresAt: t0.addingTimeInterval(1))
        q.failed(id: id, failure: .leaseExpired, now: t0.addingTimeInterval(2))
        let t = q.transfer(id: id)!
        XCTAssertEqual(t.status, .queued)
        XCTAssertEqual(t.attempts, 0)
        XCTAssertNil(t.expiresAt)   // dead lease dropped
        // Next plan starts with a fresh reservation.
        let actions = q.nextActions(now: t0.addingTimeInterval(3), allowLargeTransfers: true)
        XCTAssertEqual(actions, [.reserve(t)])
    }

    func testTransientFailuresBackOffThenPark() {
        var q = queue([(hashA, "thumbs", 1)])
        let id = "thumbs_\(hashA)"
        for attempt in 1...(TransferQueue.maxAttempts - 1) {
            q.failed(id: id, failure: .transient("offline"), now: t0)
            let t = q.transfer(id: id)!
            XCTAssertEqual(t.status, .queued)
            XCTAssertEqual(t.attempts, attempt)
            let expected = TransferQueue.backoff[min(attempt - 1,
                                                     TransferQueue.backoff.count - 1)]
            XCTAssertEqual(t.nextRetryAt, t0.addingTimeInterval(expected))
            // Backoff respected: not eligible before nextRetryAt.
            XCTAssertTrue(q.nextActions(now: t0, allowLargeTransfers: true).isEmpty)
            XCTAssertFalse(q.nextActions(now: t0.addingTimeInterval(expected),
                                         allowLargeTransfers: true).isEmpty)
        }
        q.failed(id: id, failure: .transient("offline"), now: t0)
        XCTAssertEqual(q.transfer(id: id)?.status, .parked)
        XCTAssertTrue(q.hasParked)
        XCTAssertTrue(q.nextActions(now: .distantFuture, allowLargeTransfers: true).isEmpty)
    }

    func testQuotaExceededIsTerminalUntilQuotaChanges() {
        var q = queue([(hashA, "originals", 100), (hashA, "thumbs", 1)])
        q.failed(id: "originals_\(hashA)", failure: .quotaExceeded, now: t0)
        XCTAssertTrue(q.isQuotaExceeded)
        // retryTrigger deliberately does NOT revive it (retrying won't help).
        q.retryTrigger()
        XCTAssertEqual(q.transfer(id: "originals_\(hashA)")?.status, .quotaExceeded)
        // quotaChanged does.
        q.quotaChanged()
        XCTAssertEqual(q.transfer(id: "originals_\(hashA)")?.status, .queued)
        XCTAssertFalse(q.isQuotaExceeded)
    }

    func testSyncUnavailableParksImmediately() {
        var q = queue([(hashA, "thumbs", 1)])
        q.failed(id: "thumbs_\(hashA)", failure: .syncUnavailable("Sync is disabled."), now: t0)
        XCTAssertEqual(q.transfer(id: "thumbs_\(hashA)")?.status, .parked)
        q.retryTrigger()
        XCTAssertEqual(q.transfer(id: "thumbs_\(hashA)")?.status, .queued)
    }

    func testRetryTriggerCutsBackoffShort() {
        var q = queue([(hashA, "thumbs", 1)])
        q.failed(id: "thumbs_\(hashA)", failure: .transient("x"), now: t0)
        XCTAssertNotNil(q.transfer(id: "thumbs_\(hashA)")?.nextRetryAt)
        q.retryTrigger()
        XCTAssertNil(q.transfer(id: "thumbs_\(hashA)")?.nextRetryAt)
        XCTAssertFalse(q.nextActions(now: t0, allowLargeTransfers: true).isEmpty)
    }

    func testRelaunchRestartsMidFlight() {
        var q = queue([(hashA, "thumbs", 1), (hashB, "thumbs", 2)])
        q.beganReserving(id: "thumbs_\(hashA)")
        q.reserved(id: "thumbs_\(hashB)", expiresAt: t0.addingTimeInterval(600))
        // persistence round-trip
        let data = try! JSONEncoder().encode(q)
        var restored = try! JSONDecoder().decode(TransferQueue.self, from: data)
        restored.relaunch()
        XCTAssertEqual(restored.transfer(id: "thumbs_\(hashA)")?.status, .queued)
        XCTAssertEqual(restored.transfer(id: "thumbs_\(hashB)")?.status, .queued)
    }

    func testMarkAlreadyUploadedSkips() {
        var q = queue([(hashA, "originals", 100)])
        q.markAlreadyUploaded(id: "originals_\(hashA)")
        XCTAssertEqual(q.transfer(id: "originals_\(hashA)")?.status, .done)
        XCTAssertTrue(q.nextActions(now: t0, allowLargeTransfers: true).isEmpty)
    }

    // MARK: ack-aware reconcile

    private func session(_ n: UInt8) -> SyncTarget {
        .session(UUID(uuidString: String(format: "%08X-0000-0000-0000-000000000000", n))!)
    }

    func testReconcileAdoptsRemoteOnlyRecords() {
        let actions = SyncReconcile.actions(
            local: [session(1)], remote: [session(1), session(2)], acks: AckLedger())
        XCTAssertEqual(actions, [.adoptRemote(session(2))])
    }

    func testReconcileAckedButAbsentPurges() {
        var acks = AckLedger()
        acks.markAcked(session(3))
        let actions = SyncReconcile.actions(
            local: [session(3)], remote: [], acks: acks)
        XCTAssertEqual(actions, [.purgeLocal(session(3))])
    }

    func testReconcileNeverAckedCreatePushes() {
        // The offline-created-session case: preserved and uploaded, never purged.
        let actions = SyncReconcile.actions(
            local: [session(4)], remote: [], acks: AckLedger())
        XCTAssertEqual(actions, [.pushLocalCreate(session(4))])
    }

    func testReconcileMixedDeterministicOrder() {
        var acks = AckLedger()
        acks.markAcked(session(1))
        let actions = SyncReconcile.actions(
            local: [session(1), session(2)],
            remote: [session(9)],
            acks: acks)
        XCTAssertEqual(actions, [.adoptRemote(session(9)),
                                 .pushLocalCreate(session(2)),
                                 .purgeLocal(session(1))])
    }

    func testReconcileConvergedSetsNoOp() {
        var acks = AckLedger()
        acks.markAcked(session(1))
        XCTAssertTrue(SyncReconcile.actions(
            local: [session(1)], remote: [session(1)], acks: acks).isEmpty)
    }
}
