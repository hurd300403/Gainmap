//
//  ConflictPolicyTests.swift
//  GainmapCoreTests
//
//  P4b: the full conflict decision table (r5/r6) + the journal's coalescing,
//  in-flight, and conflict-preservation semantics. These are the spec's
//  "ConflictPolicy table" tests: rev match/mismatch, self-ack via mutationID,
//  delete-wins both ways, both-tombstoned, undo-vs-changed-deletion,
//  conflict-record preservation + restore-as-new-mutation, dirty overlay.
//

import XCTest
@testable import GainmapCore

final class ConflictPolicyTests: XCTestCase {

    private let session = UUID()
    private let photo = UUID()
    private var target: SyncTarget { .photo(session: session, photo: photo) }

    private func look(_ glow: Double) -> AutoHDR.BloomParams {
        var p = AutoHDR.BloomParams()
        p.glow = glow
        return p
    }

    private func pending(_ value: GroupValue, baseRev: Int,
                         mutationID: String = "MUT-1") -> PendingMutation {
        PendingMutation(target: target, group: value.group, baseRev: baseRev,
                        mutationID: mutationID, deviceID: "mac-1", value: value,
                        next: nil, state: .pending, createdAt: Date())
    }

    // MARK: ordinary edits

    func testEditRevMatchWrites() {
        let d = ConflictPolicy.decide(
            pending: pending(.look(look(1.0)), baseRev: 3),
            remote: RemoteGroupState(rev: 3, mut: "OTHER"))
        XCTAssertEqual(d, .write)
    }

    func testEditRevMismatchConflicts() {
        let d = ConflictPolicy.decide(
            pending: pending(.look(look(1.0)), baseRev: 3),
            remote: RemoteGroupState(rev: 4, mut: "OTHER"))
        XCTAssertEqual(d, .conflict)
    }

    func testStaleDrainSelfAcksViaMutationID() {
        // Crash between commit and journal update: relaunch retries the same
        // mutation; the remote group already carries our mutationID.
        let d = ConflictPolicy.decide(
            pending: pending(.look(look(1.0)), baseRev: 3, mutationID: "MUT-1"),
            remote: RemoteGroupState(rev: 4, mut: "MUT-1"))
        XCTAssertEqual(d, .alreadyApplied(committedRev: 4))
    }

    func testEmptyMutationIDNeverSelfAcks() {
        let d = ConflictPolicy.decide(
            pending: pending(.look(look(1.0)), baseRev: 0, mutationID: ""),
            remote: RemoteGroupState(rev: 0, mut: ""))
        XCTAssertEqual(d, .write)
    }

    // MARK: delete-wins exceptions (r6)

    func testPendingTombstoneRevMismatchRetriesDeleteStillWins() {
        // An edit committed first — the delete does NOT lose; it rebases.
        let d = ConflictPolicy.decide(
            pending: pending(.tombstone(Date()), baseRev: 2),
            remote: RemoteGroupState(rev: 5, mut: "OTHER"))
        XCTAssertEqual(d, .retry(newBaseRev: 5))
    }

    func testPendingTombstoneRevMatchWrites() {
        let d = ConflictPolicy.decide(
            pending: pending(.tombstone(Date()), baseRev: 2),
            remote: RemoteGroupState(rev: 2, mut: "OTHER"))
        XCTAssertEqual(d, .write)
    }

    func testBothTombstonedIsSatisfied() {
        let d = ConflictPolicy.decide(
            pending: pending(.tombstone(Date()), baseRev: 1),
            remote: RemoteGroupState(rev: 3, mut: "OTHER",
                                     deletedAt: Date(timeIntervalSince1970: 50)))
        XCTAssertEqual(d, .satisfied)
    }

    func testPendingEditVsRemoteTombstoneLosesEvenOnMatchingRev() {
        // The tombstone wins; the edit is preserved as a conflict record.
        let d = ConflictPolicy.decide(
            pending: pending(.look(look(1.2)), baseRev: 3),
            remote: RemoteGroupState(rev: 3, mut: "OTHER",
                                     deletedAt: Date(timeIntervalSince1970: 9)))
        XCTAssertEqual(d, .conflict)
    }

    func testUndoOnObservedRevisionWrites() {
        let d = ConflictPolicy.decide(
            pending: pending(.tombstone(nil), baseRev: 4),
            remote: RemoteGroupState(rev: 4, mut: "OTHER",
                                     deletedAt: Date(timeIntervalSince1970: 7)))
        XCTAssertEqual(d, .write)
    }

    func testUndoVsChangedDeletionStateConflicts() {
        // Deletion state moved again since the undo was recorded.
        let d = ConflictPolicy.decide(
            pending: pending(.tombstone(nil), baseRev: 4),
            remote: RemoteGroupState(rev: 6, mut: "OTHER",
                                     deletedAt: Date(timeIntervalSince1970: 7)))
        XCTAssertEqual(d, .conflict)
    }

    func testUndoAlreadyUndoneIsSatisfied() {
        let d = ConflictPolicy.decide(
            pending: pending(.tombstone(nil), baseRev: 4),
            remote: RemoteGroupState(rev: 5, mut: "OTHER", deletedAt: nil))
        XCTAssertEqual(d, .satisfied)
    }

    // MARK: doc-level states

    func testMissingDocIsTargetGone() {
        let d = ConflictPolicy.decide(
            pending: pending(.look(look(1.0)), baseRev: 0),
            remote: RemoteGroupState(docExists: false))
        XCTAssertEqual(d, .targetGone)
    }

    func testSignatureGroupIsAlwaysLWWWrite() {
        let d = ConflictPolicy.decide(
            pending: PendingMutation(target: .user, group: .userSignature, baseRev: 0,
                                     mutationID: "M", deviceID: "d",
                                     value: .signature(look(2), hasCustomDefault: true),
                                     next: nil, state: .pending, createdAt: Date()),
            remote: RemoteGroupState(rev: 99, mut: "OTHER"))
        XCTAssertEqual(d, .write)
    }

    // MARK: journal — coalescing + flight semantics

    func testJournalCoalescesPendingValueKeepsBranchPoint() {
        var j = ChangeJournal()
        j.record(target: target, value: .look(look(0.5)), baseRev: 3, deviceID: "mac-1")
        let first = j.entry(target: target, group: .photoLook)!
        j.record(target: target, value: .look(look(0.9)), baseRev: 99, deviceID: "mac-1")
        let coalesced = j.entry(target: target, group: .photoLook)!
        XCTAssertEqual(coalesced.value, .look(look(0.9)))     // latest value wins
        XCTAssertEqual(coalesced.baseRev, 3)                  // branch point kept
        XCTAssertEqual(coalesced.mutationID, first.mutationID) // not yet written: ID kept
        XCTAssertEqual(j.entries.count, 1)
    }

    func testJournalEditDuringFlightQueuesAsNext() {
        var j = ChangeJournal()
        j.record(target: target, value: .look(look(0.5)), baseRev: 3, deviceID: "mac-1")
        j.markInFlight(target: target, group: .photoLook)
        j.record(target: target, value: .look(look(1.4)), baseRev: 3, deviceID: "mac-1")
        let e = j.entry(target: target, group: .photoLook)!
        XCTAssertEqual(e.state, .inFlight)
        XCTAssertEqual(e.value, .look(look(0.5)))   // the in-flight snapshot is untouched
        XCTAssertEqual(e.next, .look(look(1.4)))
        XCTAssertEqual(e.latestValue, .look(look(1.4)))
    }

    func testJournalCommitReArmsQueuedNextOnCommittedRev() {
        var j = ChangeJournal()
        j.record(target: target, value: .look(look(0.5)), baseRev: 3, deviceID: "mac-1")
        let firstID = j.entry(target: target, group: .photoLook)!.mutationID
        j.markInFlight(target: target, group: .photoLook)
        j.record(target: target, value: .look(look(1.4)), baseRev: 3, deviceID: "mac-1")
        j.completeCommit(target: target, group: .photoLook, committedRev: 4)
        let e = j.entry(target: target, group: .photoLook)!
        XCTAssertEqual(e.state, .pending)
        XCTAssertEqual(e.value, .look(look(1.4)))
        XCTAssertEqual(e.baseRev, 4)                   // branched from OUR commit
        XCTAssertNil(e.next)
        XCTAssertNotEqual(e.mutationID, firstID)       // old ID is on the server now
    }

    func testJournalCommitWithoutNextRemovesEntry() {
        var j = ChangeJournal()
        j.record(target: .session(session), value: .title("A"), baseRev: 0, deviceID: "d")
        j.markInFlight(target: .session(session), group: .sessionTitle)
        j.completeCommit(target: .session(session), group: .sessionTitle, committedRev: 1)
        XCTAssertFalse(j.isDirty(target: .session(session), group: .sessionTitle))
    }

    func testJournalFailureReturnsToPending() {
        var j = ChangeJournal()
        j.record(target: target, value: .order(2), baseRev: 1, deviceID: "d")
        j.markInFlight(target: target, group: .photoOrder)
        j.completeFailure(target: target, group: .photoOrder)
        XCTAssertEqual(j.entry(target: target, group: .photoOrder)?.state, .pending)
        XCTAssertEqual(j.pendingEntries.count, 1)
    }

    func testJournalRelaunchRequeuesInFlight() {
        var j = ChangeJournal()
        j.record(target: target, value: .order(2), baseRev: 1, deviceID: "d")
        j.markInFlight(target: target, group: .photoOrder)
        // simulate persistence round-trip mid-flight
        let data = try! JSONEncoder().encode(j)
        var restored = try! JSONDecoder().decode(ChangeJournal.self, from: data)
        restored.requeueInFlightAfterRelaunch()
        XCTAssertEqual(restored.entry(target: target, group: .photoOrder)?.state, .pending)
    }

    func testJournalRebaseForDeleteWinsRetry() {
        var j = ChangeJournal()
        j.record(target: target, value: .tombstone(Date()), baseRev: 2, deviceID: "d")
        j.markInFlight(target: target, group: .delete)
        j.rebase(target: target, group: .delete, to: 5)
        let e = j.entry(target: target, group: .delete)!
        XCTAssertEqual(e.baseRev, 5)
        XCTAssertEqual(e.state, .pending)
        XCTAssertEqual(e.value.group, .delete)   // the tombstone itself is intact
    }

    // MARK: conflict records — preserve the loser, restore as new mutation

    func testConflictPreservesLatestLocalValue() {
        var j = ChangeJournal()
        j.record(target: target, value: .look(look(0.5)), baseRev: 3, deviceID: "mac-1")
        j.markInFlight(target: target, group: .photoLook)
        j.record(target: target, value: .look(look(1.4)), baseRev: 3, deviceID: "mac-1")
        let record = j.resolveConflict(target: target, group: .photoLook,
                                       supersededBy: "ios-2")
        XCTAssertEqual(record?.localValue, .look(look(1.4)))   // the LATEST local value
        XCTAssertEqual(record?.supersededBy, "ios-2")
        XCTAssertFalse(j.isDirty(target: target, group: .photoLook))
        XCTAssertEqual(j.conflicts.count, 1)
    }

    func testConflictPreservesDisabledLookAndItsHiddenSettings() throws {
        var off = look(1.35)
        off.headroom = 2.1
        off.bakeGlowIntoSDR = true
        off.hdrLookEnabled = false
        var journal = ChangeJournal()
        journal.record(target: target, value: .look(off), baseRev: 3,
                       deviceID: "mac-1")

        let restored = try JSONDecoder().decode(
            ChangeJournal.self,
            from: JSONEncoder().encode(journal))
        let pending = try XCTUnwrap(restored.entry(target: target, group: .photoLook))
        XCTAssertEqual(pending.value, .look(off))

        var mutable = restored
        let record = try XCTUnwrap(mutable.resolveConflict(
            target: target, group: .photoLook, supersededBy: "ios-2"))
        XCTAssertEqual(record.localValue, .look(off),
                       "conflict recovery must not lose disabled look settings")
    }

    func testRestoreAsNewMutationOnCurrentRev() {
        var j = ChangeJournal()
        j.record(target: target, value: .look(look(0.7)), baseRev: 3, deviceID: "mac-1")
        let record = j.resolveConflict(target: target, group: .photoLook,
                                       supersededBy: "ios-2")!
        // Restore: pop the record, re-apply its value as a brand-new mutation
        // on the CURRENT rev (say remote moved to 6).
        let popped = j.popConflict(id: record.id)
        XCTAssertEqual(popped, record)
        XCTAssertTrue(j.conflicts.isEmpty)
        j.record(target: target, value: popped!.localValue, baseRev: 6, deviceID: "mac-1")
        let e = j.entry(target: target, group: .photoLook)!
        XCTAssertEqual(e.baseRev, 6)
        XCTAssertEqual(e.value, .look(look(0.7)))
        XCTAssertNotEqual(e.mutationID, "")   // fresh identity
    }

    func testDismissConflictDropsRecord() {
        var j2 = ChangeJournal()
        j2.record(target: .session(session), value: .title("x"), baseRev: 0, deviceID: "d")
        let r = j2.resolveConflict(target: .session(session), group: .sessionTitle,
                                   supersededBy: "other")!
        j2.dismissConflict(id: r.id)
        XCTAssertTrue(j2.conflicts.isEmpty)
    }

    // MARK: dirty overlay — inbound never overwrites dirty groups

    func testOverlayShowsLatestDirtyValues() {
        var j = ChangeJournal()
        j.record(target: target, value: .look(look(0.5)), baseRev: 3, deviceID: "d")
        j.record(target: target, value: .order(7), baseRev: 1, deviceID: "d")
        let o = j.overlay(for: target)
        XCTAssertEqual(o[.photoLook], .look(look(0.5)))
        XCTAssertEqual(o[.photoOrder], .order(7))
        XCTAssertNil(o[.delete])
    }

    func testInboundMergeKeepsDirtyGroupsAdoptsCleanOnes() {
        let remote = RemotePhotoDoc(
            id: photo, contentHash: String(repeating: "ab", count: 32),
            look: look(9.9), lookMeta: RevMeta(rev: 8, by: "ios-2", mut: "Z"),
            orderKey: 42)
        var j = ChangeJournal()
        j.record(target: target, value: .look(look(0.5)), baseRev: 3, deviceID: "d")
        let merged = InboundMerge.merged(photo: remote, overlay: j.overlay(for: target))
        XCTAssertEqual(merged.look, look(0.5))       // dirty group: local wins
        XCTAssertEqual(merged.orderKey, 42)          // clean group: snapshot adopted
        XCTAssertEqual(merged.lookMeta.rev, 8)       // metadata still remote (drain uses it)
    }

    func testInboundMergeSessionOverlay() {
        let remote = RemoteSessionDoc(id: session, title: "Remote title",
                                      sameLookForAll: false, runningLook: look(1.0))
        var j = ChangeJournal()
        j.record(target: .session(session),
                 value: .runningLook(look(2.0), sameLookForAll: true),
                 baseRev: 0, deviceID: "d")
        let merged = InboundMerge.merged(session: remote,
                                         overlay: j.overlay(for: .session(session)))
        XCTAssertEqual(merged.runningLook, look(2.0))
        XCTAssertTrue(merged.sameLookForAll)
        XCTAssertEqual(merged.title, "Remote title")
    }

    func testInboundMergeDirtyTombstoneOverlay() {
        // Local pending delete keeps the record hidden even if a snapshot
        // arrives without the tombstone yet.
        let remote = RemotePhotoDoc(id: photo,
                                    contentHash: String(repeating: "cd", count: 32))
        var j = ChangeJournal()
        let when = Date(timeIntervalSince1970: 123)
        j.record(target: target, value: .tombstone(when), baseRev: 0, deviceID: "d")
        let merged = InboundMerge.merged(photo: remote, overlay: j.overlay(for: target))
        XCTAssertEqual(merged.deletedAt, when)
    }

    // MARK: ack ledger

    func testAckLedgerRoundTrip() {
        var a = AckLedger()
        XCTAssertFalse(a.everAcked(target))
        a.markAcked(target)
        XCTAssertTrue(a.everAcked(target))
        let data = try! JSONEncoder().encode(a)
        let restored = try! JSONDecoder().decode(AckLedger.self, from: data)
        XCTAssertTrue(restored.everAcked(target))
        var mutable = restored
        mutable.remove(target)
        XCTAssertFalse(mutable.everAcked(target))
    }

    func testJournalDropAllForTarget() {
        var j = ChangeJournal()
        j.record(target: target, value: .look(nil), baseRev: 0, deviceID: "d")
        j.record(target: target, value: .order(1), baseRev: 0, deviceID: "d")
        j.record(target: .session(session), value: .title("keep"), baseRev: 0, deviceID: "d")
        j.dropAll(for: target)
        XCTAssertTrue(j.overlay(for: target).isEmpty)
        XCTAssertTrue(j.isDirty(target: .session(session), group: .sessionTitle))
    }

    func testJournalRejectsWrongGroupForTarget() {
        // A photo can't carry a session-title mutation — programmer error.
        // (Precondition; verified via the valid-groups table instead of a crash test.)
        XCTAssertFalse(FieldGroup.groups(for: target).contains(.sessionTitle))
        XCTAssertFalse(FieldGroup.groups(for: .user).contains(.delete))
    }
}
