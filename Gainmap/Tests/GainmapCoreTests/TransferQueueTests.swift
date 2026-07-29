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
