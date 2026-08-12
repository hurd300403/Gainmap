//
//  RemoteSchemaTests.swift
//  GainmapCoreTests
//
//  P4a: the frozen cloud schema. These tests pin the wire format — field
//  names, group key sets, null-vs-missing look semantics, rev arithmetic —
//  against what firestore.rules enforces. A failure here means a protocol
//  break, not a refactor.
//

import XCTest
@testable import GainmapCore

final class RemoteSchemaTests: XCTestCase {

    private func customLook() -> AutoHDR.BloomParams {
        var p = AutoHDR.BloomParams()
        p.glow = 1.23; p.threshold = 0.5; p.spread = 0.01; p.punch = 0.4
        p.peak = 4.5; p.falloff = 1.2; p.saturation = 0.8; p.tint = -0.3
        p.headroom = 1.7; p.bakeGlowIntoSDR = true
        return p
    }

    private let h64 = String(repeating: "ab", count: 32)   // 64 hex chars

    // MARK: field-group key sets — MUST mirror firestore.rules verbatim

    func testFieldGroupKeysMatchRules() {
        XCTAssertEqual(FieldGroup.photoLook.keys, ["look", "lookRev", "lookBy", "lookMut"])
        XCTAssertEqual(FieldGroup.photoOrder.keys, ["orderKey", "orderRev", "orderBy", "orderMut"])
        XCTAssertEqual(FieldGroup.sessionTitle.keys, ["title", "titleRev", "titleBy", "titleMut"])
        XCTAssertEqual(FieldGroup.sessionRunningLook.keys,
                       ["runningLook", "sameLookForAll", "rlRev", "rlBy", "rlMut"])
        XCTAssertEqual(FieldGroup.delete.keys, ["deletedAt", "delRev", "delBy", "delMut"])
        XCTAssertEqual(FieldGroup.tombstoneOnlyKeys,
                       ["deletedAt", "delRev", "delBy", "delMut", "updatedAt"])
    }

    func testGroupsPerTarget() {
        XCTAssertEqual(FieldGroup.groups(for: .user), [.userSignature])
        XCTAssertEqual(FieldGroup.groups(for: .session(UUID())),
                       [.sessionTitle, .sessionRunningLook, .delete])
        XCTAssertEqual(FieldGroup.groups(for: .photo(session: UUID(), photo: UUID())),
                       [.photoLook, .photoOrder, .delete])
    }

    // MARK: reservation/object naming — lockstep with functions/lib/constants.js

    func testReservationIdAndObjectNameScheme() {
        XCTAssertEqual(SyncSchema.reservationId(tier: "thumbs", contentHash: h64),
                       "thumbs_\(h64)")
        XCTAssertEqual(SyncSchema.objectName(uid: "u1", tier: "originals", contentHash: h64),
                       "users/u1/originals/\(h64).jpg")
    }

    func testContentHashValidation() {
        XCTAssertTrue(SyncSchema.isValidContentHash(h64))
        XCTAssertFalse(SyncSchema.isValidContentHash(String(h64.dropLast())))    // 63
        XCTAssertFalse(SyncSchema.isValidContentHash(h64.uppercased()))          // A-F
        XCTAssertFalse(SyncSchema.isValidContentHash(String(repeating: "g", count: 64)))
    }

    // MARK: BloomParams wire format

    func testBloomParamsRoundTripExact() {
        let p = customLook()
        let decoded = AutoHDR.BloomParams(fsValue: p.fsMap())
        XCTAssertEqual(decoded, p)
    }

    func testBloomParamsTolerantDecode() {
        // Unknown key ignored, missing keys keep defaults, int-where-double OK.
        let v = FSValue.map(["glow": .int(1), "futureKnob": .string("x")])
        let p = AutoHDR.BloomParams(fsValue: v)
        XCTAssertEqual(p?.glow, 1.0)
        XCTAssertEqual(p?.threshold, AutoHDR.BloomParams().threshold)
        XCTAssertNil(AutoHDR.BloomParams(fsValue: .string("not a map")))
    }

    // MARK: photo doc

    func testPhotoDocRoundTrip() {
        let id = UUID()
        let doc = RemotePhotoDoc(
            id: id, contentHash: h64, look: customLook(),
            lookMeta: RevMeta(rev: 3, by: "mac-1", mut: "M1"),
            orderKey: 2.5, orderMeta: RevMeta(rev: 1, by: "mac-1", mut: "M2"),
            gamut: "p3", pixelWidth: 6000, pixelHeight: 4000, looksMerged: true,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            deletedAt: Date(timeIntervalSince1970: 300),
            delMeta: RevMeta(rev: 2, by: "ios-2", mut: "M3"))
        let decoded = RemotePhotoDoc(id: id, fsMap: doc.fsMap())
        XCTAssertEqual(decoded, doc)
    }

    func testPhotoLookNilEncodesLiteralNull() {
        let doc = RemotePhotoDoc(id: UUID(), contentHash: h64, look: nil)
        XCTAssertEqual(doc.fsMap()["look"], FSValue.null)   // stated, not omitted
    }

    func testPhotoLookNullAndMissingBothDecodeAsInherit() {
        var m = RemotePhotoDoc(id: UUID(), contentHash: h64).fsMap()
        m["look"] = .null
        XCTAssertNil(RemotePhotoDoc(id: UUID(), fsMap: m)?.look)
        m.removeValue(forKey: "look")
        XCTAssertNil(RemotePhotoDoc(id: UUID(), fsMap: m)?.look)
    }

    func testPhotoDocFreshGroupsStayImplicit() {
        // A created doc carries no rev metadata: rules treat missing rev as 0,
        // so the first edit is rev 1.
        let m = RemotePhotoDoc(id: UUID(), contentHash: h64).fsMap()
        for key in ["lookRev", "lookBy", "lookMut", "orderRev", "delRev", "deletedAt"] {
            XCTAssertNil(m[key], "\(key) must be absent on a fresh doc")
        }
        // And decoding implicit groups yields rev 0.
        let doc = RemotePhotoDoc(id: UUID(), fsMap: m)
        XCTAssertEqual(doc?.lookMeta.rev, 0)
        XCTAssertEqual(doc?.delMeta.rev, 0)
    }

    func testPhotoDocRejectsFutureSchemaAndBadHash() {
        var m = RemotePhotoDoc(id: UUID(), contentHash: h64).fsMap()
        m["schemaVersion"] = .int(2)
        XCTAssertNil(RemotePhotoDoc(id: UUID(), fsMap: m))
        var bad = RemotePhotoDoc(id: UUID(), contentHash: h64).fsMap()
        bad["contentHash"] = .string("nope")
        XCTAssertNil(RemotePhotoDoc(id: UUID(), fsMap: bad))
    }

    func testPhotoDocToleratesUnknownKeysAndIntDoubles() {
        var m = RemotePhotoDoc(id: UUID(), contentHash: h64).fsMap()
        m["someFutureField"] = .map(["x": .int(1)])
        m["orderKey"] = .int(7)               // int where double expected
        let doc = RemotePhotoDoc(id: UUID(), fsMap: m)
        XCTAssertEqual(doc?.orderKey, 7.0)
    }

    func testPhotoOrderingTiebreak() {
        let early = Date(timeIntervalSince1970: 1)
        let late = Date(timeIntervalSince1970: 2)
        let idA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
        let idB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
        let a = RemotePhotoDoc(id: idB, contentHash: h64, orderKey: 1, createdAt: early)
        let b = RemotePhotoDoc(id: idA, contentHash: h64, orderKey: 1, createdAt: early)
        let c = RemotePhotoDoc(id: idA, contentHash: h64, orderKey: 1, createdAt: late)
        let d = RemotePhotoDoc(id: idA, contentHash: h64, orderKey: 0.5, createdAt: late)
        let sorted = RemotePhotoDoc.ordered([a, c, b, d])
        // orderKey first, then createdAt, then id.
        XCTAssertEqual(sorted.map(\.orderKey), [0.5, 1, 1, 1])
        XCTAssertEqual(sorted[1].id, idA)   // same key+date: id tiebreak
        XCTAssertEqual(sorted[2].id, idB)
        XCTAssertEqual(sorted[3].createdAt, late)
    }

    func testDeletionAloneIsNotAnExplicitReorder() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertFalse(SyncPhotoOrdering.didExplicitlyReorder(
            current: [a, c],
            baseline: [a, b, c],
            remoteIDs: [a, b, c]))
        XCTAssertTrue(SyncPhotoOrdering.didExplicitlyReorder(
            current: [c, a],
            baseline: [a, b, c],
            remoteIDs: [a, b, c]))
    }

    func testSparseInsertionUsesIntendedNeighbours() {
        let a = UUID(), x = UUID(), y = UUID(), b = UUID()
        let order = [a, x, y, b]
        var keys = [a: 1.0, b: 2.0]
        let xKey = SyncPhotoOrdering.insertionKey(
            for: x, localOrder: order, knownKeys: keys)
        XCTAssertEqual(xKey, 1.5)
        keys[x] = xKey
        let yKey = SyncPhotoOrdering.insertionKey(
            for: y, localOrder: order, knownKeys: keys)
        XCTAssertEqual(yKey, 1.75)
        XCTAssertLessThan(xKey!, yKey!)
        XCTAssertLessThan(yKey!, keys[b]!)
    }

    func testInboundRemoteOrderKeepsLocalOnlyPhotoInItsSlot() {
        let a = UUID(), localOnly = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(
            SyncPhotoOrdering.materializedIDs(
                existing: [a, localOnly, b],
                remotelyKnown: [a, b, c],
                orderedAliveRemote: [c, a, b]),
            [c, localOnly, a, b])
    }

    // MARK: session doc

    func testSessionDocRoundTrip() {
        let id = UUID()
        let doc = RemoteSessionDoc(
            id: id, title: "Smith Wedding", titleMeta: RevMeta(rev: 1, by: "mac", mut: "T1"),
            sameLookForAll: true, runningLook: customLook(),
            rlMeta: RevMeta(rev: 5, by: "ios", mut: "R1"),
            covers: [.init(photoId: UUID(), contentHash: h64)], photoCount: 12,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20))
        let decoded = RemoteSessionDoc(id: id, fsMap: doc.fsMap())
        XCTAssertEqual(decoded, doc)
    }

    func testSessionCoversCappedAtFour() {
        let covers = (0..<7).map {
            RemoteSessionDoc.Cover(photoId: UUID(), contentHash: h64 + String($0))
        }
        // init caps
        let doc = RemoteSessionDoc(id: UUID(), covers: covers)
        XCTAssertEqual(doc.covers.count, 4)
        // decode tolerates an overlong remote array (older-build bug etc.)
        var m = doc.fsMap()
        m["covers"] = .array((0..<6).map { _ in
            .map(["photoId": .string(UUID().uuidString), "contentHash": .string(h64)])
        })
        let decoded = RemoteSessionDoc(id: UUID(), fsMap: m)
        XCTAssertEqual(decoded?.covers.count, 6)   // read-side keeps data; write-side caps
    }

    func testSessionDocRejectsFutureSchema() {
        var m = RemoteSessionDoc(id: UUID()).fsMap()
        m["schemaVersion"] = .int(99)
        XCTAssertNil(RemoteSessionDoc(id: UUID(), fsMap: m))
    }

    // MARK: blob doc

    func testBlobShellNeverEmitsServerOwnedKeys() {
        let shell = RemoteBlobDoc(contentHash: h64, byteSize: 123).shellFSMap()
        XCTAssertEqual(Set(shell.keys),
                       ["schemaVersion", "contentHash", "byteSize", "createdAt"])
    }

    func testBlobDecodeWithHugeGeneration() {
        // GCS generations exceed 2^53; must survive as a string, never Double.
        let gen = "18446744073709551615"
        let m: [String: FSValue] = [
            "schemaVersion": .int(1),
            "byteSize": .int(999),
            "renditions": .map([
                "thumbs": .map([
                    "generation": .string(gen),
                    "byteSize": .int(999),
                    "counted": .bool(true),
                    "uploadedAt": .timestamp(Date(timeIntervalSince1970: 5)),
                ]),
            ]),
            "state": .string("gcCandidate"),
        ]
        let doc = RemoteBlobDoc(contentHash: h64, fsMap: m)
        XCTAssertEqual(doc?.renditions["thumbs"]?.generation, gen)
        XCTAssertTrue(doc?.isUploaded(tier: "thumbs") ?? false)
        XCTAssertFalse(doc?.isUploaded(tier: "originals") ?? true)
        XCTAssertEqual(doc?.state, .gcCandidate)
    }

    func testBlobUnknownStateDecodesAsActive() {
        let m: [String: FSValue] = ["state": .string("someFutureState")]
        XCTAssertEqual(RemoteBlobDoc(contentHash: h64, fsMap: m)?.state, .active)
    }

    // MARK: user / usage / reservation decode

    func testUserDocDecode() {
        let m: [String: FSValue] = [
            "schemaVersion": .int(1),
            "signatureLook": customLook().fsMap(),
            "hasCustomDefault": .bool(true),
            "quotaBytes": .int(5 * 1024 * 1024 * 1024),
            "syncAdmitted": .bool(true),
        ]
        let doc = RemoteUserDoc(fsMap: m)
        XCTAssertEqual(doc?.signatureLook, customLook())
        XCTAssertEqual(doc?.hasCustomDefault, true)
        XCTAssertEqual(doc?.quotaBytes, 5 * 1024 * 1024 * 1024)
        XCTAssertEqual(doc?.syncAdmitted, true)
    }

    func testReservationDecodeRequiresCoreFields() {
        let good: [String: FSValue] = [
            "contentHash": .string(h64), "tier": .string("thumbs"),
            "byteSize": .int(42), "expiresAt": .timestamp(Date(timeIntervalSince1970: 9)),
        ]
        XCTAssertNotNil(RemoteReservationDoc(fsMap: good))
        var missing = good
        missing.removeValue(forKey: "expiresAt")
        XCTAssertNil(RemoteReservationDoc(fsMap: missing))
    }

    // MARK: update payload builders — the rules-compliance contract

    func testUpdatePayloadTouchesExactlyGroupKeysPlusUpdatedAt() {
        let cases: [(GroupValue, FieldGroup)] = [
            (.look(customLook()), .photoLook),
            (.look(nil), .photoLook),
            (.order(3.5), .photoOrder),
            (.title("New title"), .sessionTitle),
            (.runningLook(customLook(), sameLookForAll: true), .sessionRunningLook),
            (.tombstone(Date()), .delete),
            (.tombstone(nil), .delete),
            (.signature(customLook(), hasCustomDefault: true), .userSignature),
        ]
        for (value, group) in cases {
            XCTAssertEqual(value.group, group)
            let payload = SyncMutationPayload.update(
                value: value, baseRev: 4, deviceID: "dev", mutationID: "mut",
                updatedAt: Date())
            XCTAssertEqual(Set(payload.keys), Set(group.keys + ["updatedAt"]),
                           "payload for \(group) must touch exactly its keys + updatedAt")
        }
    }

    func testUpdatePayloadRevIsBasePlusOne() {
        let payload = SyncMutationPayload.update(
            value: .look(nil), baseRev: 7, deviceID: "mac-1", mutationID: "M9",
            updatedAt: Date())
        XCTAssertEqual(payload["lookRev"], .int(8))
        XCTAssertEqual(payload["lookBy"], .string("mac-1"))
        XCTAssertEqual(payload["lookMut"], .string("M9"))
        XCTAssertEqual(payload["look"], .null)
    }

    func testTombstonePayloadPassesKillSwitchGate() {
        let set = SyncMutationPayload.update(
            value: .tombstone(Date()), baseRev: 0, deviceID: "d", mutationID: "m",
            updatedAt: Date())
        XCTAssertTrue(SyncMutationPayload.isTombstoneOnly(set))
        let undo = SyncMutationPayload.update(
            value: .tombstone(nil), baseRev: 1, deviceID: "d", mutationID: "m",
            updatedAt: Date())
        XCTAssertTrue(SyncMutationPayload.isTombstoneOnly(undo))
        let edit = SyncMutationPayload.update(
            value: .title("x"), baseRev: 0, deviceID: "d", mutationID: "m",
            updatedAt: Date())
        XCTAssertFalse(SyncMutationPayload.isTombstoneOnly(edit))
    }

    func testSignaturePayloadHasNoRevFields() {
        let payload = SyncMutationPayload.update(
            value: .signature(nil, hasCustomDefault: false), baseRev: 0,
            deviceID: "d", mutationID: "m", updatedAt: Date())
        XCTAssertEqual(Set(payload.keys), ["signatureLook", "hasCustomDefault", "updatedAt"])
        XCTAssertEqual(payload["signatureLook"], .null)
    }

    // MARK: target paths

    func testSyncTargetPaths() {
        let s = UUID(), p = UUID()
        XCTAssertEqual(SyncTarget.user.path(uid: "u1"), "users/u1")
        XCTAssertEqual(SyncTarget.session(s).path(uid: "u1"),
                       "users/u1/sessions/\(s.uuidString)")
        XCTAssertEqual(SyncTarget.photo(session: s, photo: p).path(uid: "u1"),
                       "users/u1/sessions/\(s.uuidString)/photos/\(p.uuidString)")
    }

    // MARK: Patreon entitlement callable contract

    func testPatreonEntitlementParsesBackendMilliseconds() throws {
        let payload: [String: Any] = [
            "state": "grace",
            "effective": NSNumber(value: true),
            "linkRequired": NSNumber(value: true),
            "graceExpiresAt": NSNumber(value: 1_800_000_123_000 as Int64),
            "lastVerifiedAt": NSNumber(value: 1_799_000_000_000 as Int64),
            "message": "Patreon is temporarily unavailable.",
        ]
        let value = try XCTUnwrap(PatreonEntitlement(payload: payload))
        XCTAssertEqual(value.status, .grace)
        XCTAssertTrue(value.effective)
        XCTAssertTrue(value.linkRequired)
        XCTAssertEqual(try XCTUnwrap(value.graceExpiresAt).timeIntervalSince1970,
                       1_800_000_123, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(value.lastVerifiedAt).timeIntervalSince1970,
                       1_799_000_000, accuracy: 0.001)
    }

    func testPatreonEntitlementRejectsUnknownOrIncompleteResponses() {
        XCTAssertNil(PatreonEntitlement(payload: [
            "state": "future-state", "effective": true, "message": "x",
        ]))
        XCTAssertNil(PatreonEntitlement(payload: [
            "state": "active", "message": "missing effective",
        ]))
    }

    func testPatreonLinkRequirementDistinguishesProvisionalFromLinkedGrace() throws {
        let provisional = try XCTUnwrap(PatreonEntitlement(payload: [
            "state": "grace",
            "effective": true,
            "linkRequired": true,
            "message": "Connect Patreon before temporary access expires.",
        ]))
        XCTAssertTrue(provisional.linkRequired)

        let linked = try XCTUnwrap(PatreonEntitlement(payload: [
            "state": "grace",
            "effective": true,
            "linkRequired": false,
            "message": "Membership verification is temporarily unavailable.",
        ]))
        XCTAssertFalse(linked.linkRequired)

        // Safe rollout compatibility: legacy responses offer linking only for
        // an explicitly unlinked account, without mislabeling linked grace.
        let legacyUnlinked = try XCTUnwrap(PatreonEntitlement(payload: [
            "state": "unlinked", "effective": false, "message": "Connect Patreon.",
        ]))
        XCTAssertTrue(legacyUnlinked.linkRequired)
        let legacyGrace = try XCTUnwrap(PatreonEntitlement(payload: [
            "state": "grace", "effective": true, "message": "Grace access.",
        ]))
        XCTAssertFalse(legacyGrace.linkRequired)
    }

    func testCloudSyncRequiresBothEffectiveEntitlementAndAdmission() {
        let entitled = PatreonEntitlement(
            status: .active, effective: true, message: "Active")
        XCTAssertTrue(CloudSyncAccess(entitlement: entitled, admitted: true).canSync)
        XCTAssertFalse(CloudSyncAccess(entitlement: entitled, admitted: false).canSync)
        let waitlisted = CloudSyncAccess(
            entitlement: entitled,
            admitted: false,
            admissionReason: "waitlist")
        XCTAssertTrue(waitlisted.isWaitlisted)
        XCTAssertFalse(waitlisted.canSync)
        XCTAssertNotNil(waitlisted.admissionBlockMessage)
        XCTAssertNotNil(CloudSyncAccess(
            entitlement: entitled,
            admitted: false).admissionBlockMessage)
        XCTAssertFalse(CloudSyncAccess(
            entitlement: PatreonEntitlement(
                status: .inactive, effective: false, message: "Inactive"),
            admitted: true).canSync)
    }
}
