//
//  SyncEmulatorTests.swift
//  GainmapCoreTests
//
//  P4d: the emulator integration suite — the spec's P4 exit list, run against
//  the REAL rules + Cloud Functions in the Firebase Local Emulator Suite:
//
//    * two peers converge (title / looks / order / nil-inheritance)
//    * rev guard: conflict-record preservation + restore-as-new-mutation
//    * delete-wins over an interleaved edit; edit-vs-tombstone preserved
//    * session tombstone delete / undo round-trip
//    * upload pipeline end-to-end (reserve -> upload -> reconciler ledger ->
//      usage accounting), skip-if-exists, kill-mid-upload recovery
//    * quota-exceeded as a terminal transfer state
//    * ack-aware reconcile: offline-created push; acked-but-absent purge
//
//  SKIPPED unless the emulators are up: run via  scripts/test-sync.sh swift
//  (which boots auth/firestore/storage/functions on demo-gainmap and passes
//  GM_EMULATOR_* through). Each test signs in a FRESH anonymous uid, so tests
//  are isolated without emulator resets.
//

import XCTest
@testable import GainmapCore

final class SyncEmulatorTests: XCTestCase {

    private static var configuredHost: String?

    private var uid = ""
    private var host = ""
    private var firestorePort = 8080
    private var tempDirs: [URL] = []

    // ------------------------------------------------------------ scaffolding

    private func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    override func setUp() async throws {
        try await super.setUp()
        guard env("GM_EMULATOR") == "1" else {
            throw XCTSkip("Firebase emulators not running (scripts/test-sync.sh swift)")
        }
        host = env("GM_EMULATOR_HOST") ?? "127.0.0.1"
        firestorePort = env("GM_FIRESTORE_PORT").flatMap(Int.init) ?? 8080
        if Self.configuredHost == nil {
            FirebaseSetup.configureForEmulator(
                projectID: "demo-gainmap",
                host: host,
                authPort: env("GM_AUTH_PORT").flatMap(Int.init) ?? 9099,
                firestorePort: firestorePort,
                storagePort: env("GM_STORAGE_PORT").flatMap(Int.init) ?? 9199,
                functionsPort: env("GM_FUNCTIONS_PORT").flatMap(Int.init) ?? 5001)
            Self.configuredHost = host
        }
        uid = try await FirebaseSetup.signInAnonymouslyForTesting()
        try await seedFlags()
        try await seedUser(uid: uid, quotaBytes: 5 * 1024 * 1024 * 1024)
    }

    override func tearDown() async throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    // --- Firestore emulator REST (Bearer owner bypasses rules — seeding only)

    private func firestoreDocURL(_ path: String) -> URL {
        URL(string: "http://\(host):\(firestorePort)/v1/projects/demo-gainmap/databases/(default)/documents/\(path)")!
    }

    private func restPatch(_ path: String, fields: [String: Any]) async throws {
        var request = URLRequest(url: firestoreDocURL(path))
        request.httpMethod = "PATCH"
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])
        // The emulator 409s under transaction contention (a previous test's
        // listeners may still be draining); retry briefly.
        var lastCode = 0
        for attempt in 0..<5 {
            if attempt > 0 { try await Task.sleep(nanoseconds: 300_000_000) }
            let (_, response) = try await URLSession.shared.data(for: request)
            lastCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(lastCode) { return }
        }
        throw NSError(domain: "seed", code: lastCode,
                      userInfo: [NSLocalizedDescriptionKey: "REST PATCH \(path) -> \(lastCode)"])
    }

    private func restDelete(_ path: String) async throws {
        var request = URLRequest(url: firestoreDocURL(path))
        request.httpMethod = "DELETE"
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: request)
    }

    private func seedFlags() async throws {
        try await restPatch("config/flags", fields: [
            "syncEnabled": ["booleanValue": true],
            "signupsOpen": ["booleanValue": true],
            "maxUsers": ["integerValue": "200"],
        ])
    }

    private func seedUser(uid: String, quotaBytes: Int64) async throws {
        try await restPatch("users/\(uid)", fields: [
            "schemaVersion": ["integerValue": "1"],
            "syncAdmitted": ["booleanValue": true],
            "quotaBytes": ["integerValue": String(quotaBytes)],
        ])
    }

    // --- engines / fixtures

    private func tempDir(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-sync-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirs.append(url)
        return url
    }

    private func makeEngine(_ label: String) -> (SyncEngine, FileSessionStore) {
        let root = tempDir(label)
        let store = FileSessionStore(root: root, uid: uid)
        let engine = SyncEngine(
            uid: uid, deviceID: label, backend: FirebaseSyncBackend(),
            store: store,
            root: root.appendingPathComponent("users/\(uid)", isDirectory: true))
        return (engine, store)
    }

    /// A decodable JPEG with unique bytes (unique hash) per call.
    private func makeSourceJPEG(_ label: String) throws -> (url: URL, hash: String, size: Int64) {
        let bundle = Bundle(for: SyncEmulatorTests.self)
        guard let fixture = bundle.url(forResource: "golden-512-sdr", withExtension: "jpg",
                                       subdirectory: "Fixtures")
            ?? bundle.url(forResource: "golden-512-sdr", withExtension: "jpg") else {
            throw XCTSkip("fixture golden-512-sdr.jpg missing from test bundle")
        }
        var data = try Data(contentsOf: fixture)
        data.append(contentsOf: Array("gm-\(label)-\(UUID().uuidString)".utf8))  // post-EOI: still decodable
        let dir = tempDir("src-\(label)")
        let url = dir.appendingPathComponent("\(label).jpg")
        try data.write(to: url)
        guard let hash = ContentHash.sha256(of: url) else {
            throw NSError(domain: "fixture", code: 1)
        }
        return (url, hash, Int64(data.count))
    }

    private func makeSession(title: String, photos: [(url: URL, hash: String, size: Int64)],
                             look: AutoHDR.BloomParams? = nil) -> Session {
        var session = Session(title: title)
        session.photos = photos.map {
            PhotoRecord(origin: .linked(path: $0.url.path), contentHash: $0.hash,
                        byteSize: $0.size, look: look)
        }
        return session
    }

    private func look(_ glow: Double) -> AutoHDR.BloomParams {
        var p = AutoHDR.BloomParams()
        p.glow = glow
        return p
    }

    /// Poll until `condition` holds (listeners are asynchronous). THROWS on
    /// timeout so the test aborts — continuing into a force-unwrap would
    /// crash the HOST APP (it hosts the tests) and poison every later test
    /// with relaunch debris.
    private func waitUntil(_ label: String, timeout: TimeInterval = 25,
                           condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("timed out waiting for \(label)")
        throw NSError(domain: "waitUntil", code: 408,
                      userInfo: [NSLocalizedDescriptionKey: "timeout: \(label)"])
    }

    /// Force-unwrap-free session load: missing session fails the test
    /// cleanly instead of trapping the host process.
    private func loadOrFail(_ store: FileSessionStore, _ id: UUID,
                            file: StaticString = #filePath,
                            line: UInt = #line) async throws -> Session {
        let session = await store.load(id: id)
        return try XCTUnwrap(session, "session \(id) missing", file: file, line: line)
    }

    // ================================================================ tests

    // MARK: two peers converge

    func testTwoPeersConvergeTitleLooksOrderAndInheritance() async throws {
        let (engineA, storeA) = makeEngine("mac-A")
        let (engineB, storeB) = makeEngine("ios-B")

        let p1 = try makeSourceJPEG("p1")
        let p2 = try makeSourceJPEG("p2")
        var session = makeSession(title: "Smith Wedding", photos: [p1, p2])
        session.photos[0].look = look(1.2)           // explicit look
        session.photos[1].look = nil                 // inherit
        try await storeA.save(session)

        await engineA.start()
        await engineA.noteLocalSession(session)
        await engineA.drainOnce()

        await engineB.start()
        try await waitUntil("B materializes the session") {
            await storeB.load(id: session.id) != nil
        }
        var atB = try await loadOrFail(storeB, session.id)
        XCTAssertEqual(atB.title, "Smith Wedding")
        XCTAssertEqual(atB.photos.count, 2)
        XCTAssertEqual(atB.photos[0].contentHash, p1.hash)   // order preserved
        XCTAssertEqual(atB.photos[0].look, look(1.2))
        XCTAssertNil(atB.photos[1].look, "nil-inheritance must survive the wire")

        // B edits the look of photo 2 (was inheriting) + the running look.
        atB.photos[1].look = look(0.8)
        atB.runningLook = look(0.5)
        atB.sameLookForAll = true
        try await storeB.save(atB)
        await engineB.noteLocalSession(atB)
        await engineB.drainOnce()

        try await waitUntil("A sees B's edits") {
            guard let s = await storeA.load(id: session.id) else { return false }
            return s.photos[1].look == self.look(0.8) && s.sameLookForAll
        }
        let atA = try await loadOrFail(storeA, session.id)
        XCTAssertEqual(atA.runningLook, look(0.5))
        // A's original photo look survived untouched.
        XCTAssertEqual(atA.photos[0].look, look(1.2))
        await engineA.stop()
        await engineB.stop()
    }

    // MARK: stale flush must not tombstone peer-added photos (P5 review)

    func testStaleFlushDoesNotDeletePeerAddedPhotoAndHealsLocalFile() async throws {
        let (engineA, storeA) = makeEngine("mac-A")
        let (engineB, storeB) = makeEngine("ios-B")

        let p1 = try makeSourceJPEG("p1")
        let original = makeSession(title: "Stale", photos: [p1])
        try await storeA.save(original)
        await engineA.start()
        await engineA.noteLocalSession(original)
        await engineA.drainOnce()

        await engineB.start()
        try await waitUntil("B materializes the session") {
            await storeB.load(id: original.id) != nil
        }

        // B adds a second photo and it syncs.
        let p2 = try makeSourceJPEG("p2")
        var atB = try await loadOrFail(storeB, original.id)
        atB.photos.append(PhotoRecord(origin: .linked(path: p2.url.path),
                                      contentHash: p2.hash, byteSize: p2.size))
        try await storeB.save(atB)
        await engineB.noteLocalSession(atB)
        await engineB.drainOnce()
        try await waitUntil("A's file gains B's photo") {
            guard let s = await storeA.load(id: original.id) else { return false }
            return s.photos.count == 2
        }

        // A's MODEL never consumed that inbound change: it flushes a
        // 1-photo snapshot carrying only a runningLook edit. The `before`
        // baseline tells the engine the user never held p2 — so no
        // tombstone may be journaled, and the clobbered file must heal.
        var stale = original
        stale.runningLook = look(0.9)
        stale.updatedAt = Date()
        try await storeA.save(stale)                      // the clobbering flush
        await engineA.noteLocalSession(stale, before: original)
        await engineA.drainOnce()

        try await waitUntil("A's file heals back to 2 photos") {
            guard let s = await storeA.load(id: original.id) else { return false }
            return s.photos.count == 2
        }
        try await waitUntil("B keeps p2 and gets A's look edit") {
            guard let s = await storeB.load(id: original.id) else { return false }
            return s.photos.count == 2 && s.runningLook == self.look(0.9)
        }
        let finalB = try await loadOrFail(storeB, original.id)
        XCTAssertEqual(finalB.photos.map(\.contentHash).compactMap { $0 }.sorted(),
                       [p1.hash, p2.hash].sorted(),
                       "the peer-added photo must survive a stale flush")
        await engineA.stop()
        await engineB.stop()
    }

    // MARK: rev guard — conflict preservation + restore

    func testConcurrentLookEditPreservesLoserAndRestores() async throws {
        let (engineA, storeA) = makeEngine("mac-A")
        let (engineB, storeB) = makeEngine("ios-B")

        let p1 = try makeSourceJPEG("p1")
        let session = makeSession(title: "Conflict", photos: [p1])
        try await storeA.save(session)
        await engineA.start()
        await engineA.noteLocalSession(session)
        await engineA.drainOnce()
        await engineB.start()
        try await waitUntil("B has the session") {
            await storeB.load(id: session.id) != nil
        }

        // Both edit the SAME photo look while "offline" (no drains yet).
        var atA = try await loadOrFail(storeA, session.id)
        atA.photos[0].look = look(1.5)
        try await storeA.save(atA)
        await engineA.noteLocalSession(atA)

        var atB = try await loadOrFail(storeB, session.id)
        atB.photos[0].look = look(0.3)
        try await storeB.save(atB)
        await engineB.noteLocalSession(atB)

        // A drains first and wins; B's drain must hit the rev guard.
        await engineA.drainOnce()
        await engineB.drainOnce()

        let conflicts = await engineB.conflictRecords
        XCTAssertEqual(conflicts.count, 1, "B's losing edit must be preserved")
        XCTAssertEqual(conflicts.first?.localValue, .look(look(0.3)))
        XCTAssertEqual(conflicts.first?.supersededBy, "mac-A")

        // B adopted A's committed value.
        try await waitUntil("B adopts the winner") {
            guard let s = await storeB.load(id: session.id) else { return false }
            return s.photos[0].look == self.look(1.5)
        }

        // Restore: B re-applies its value as a NEW mutation on the current rev.
        await engineB.restoreConflict(id: conflicts[0].id)
        await engineB.drainOnce()
        try await waitUntil("A converges to the restored value") {
            guard let s = await storeA.load(id: session.id) else { return false }
            return s.photos[0].look == self.look(0.3)
        }
        let empty = await engineB.conflictRecords
        XCTAssertTrue(empty.isEmpty)
        await engineA.stop()
        await engineB.stop()
    }

    // MARK: delete-wins exceptions

    func testDeleteWinsOverInterleavedEdit() async throws {
        let (engineA, storeA) = makeEngine("mac-A")
        let (engineB, storeB) = makeEngine("ios-B")

        let p1 = try makeSourceJPEG("p1")
        let p2 = try makeSourceJPEG("p2")
        let session = makeSession(title: "DeleteWins", photos: [p1, p2])
        try await storeA.save(session)
        await engineA.start()
        await engineA.noteLocalSession(session)
        await engineA.drainOnce()
        await engineB.start()
        try await waitUntil("B has the session") {
            (await storeB.load(id: session.id))?.photos.count == 2
        }
        let photoID = session.photos[1].id

        // A removes photo 2 (pending tombstone), B edits its look (pending).
        var atA = try await loadOrFail(storeA, session.id)
        atA.photos.removeAll { $0.id == photoID }
        try await storeA.save(atA)
        await engineA.noteLocalSession(atA)

        var atB = try await loadOrFail(storeB, session.id)
        atB.photos[1].look = look(0.9)
        try await storeB.save(atB)
        await engineB.noteLocalSession(atB)

        // B's edit commits FIRST (bumps lookRev) — then A's tombstone must
        // still win via the rebase-retry path.
        await engineB.drainOnce()
        await engineA.drainOnce()

        try await waitUntil("photo disappears on B") {
            guard let s = await storeB.load(id: session.id) else { return false }
            return !s.photos.contains { $0.id == photoID }
        }
        await engineA.stop()
        await engineB.stop()
    }

    func testPendingEditAgainstRemoteTombstoneIsPreservedNotWritten() async throws {
        let (engineA, storeA) = makeEngine("mac-A")
        let (engineB, storeB) = makeEngine("ios-B")

        let p1 = try makeSourceJPEG("p1")
        let p2 = try makeSourceJPEG("p2")
        let session = makeSession(title: "TombstoneBeatsEdit", photos: [p1, p2])
        try await storeA.save(session)
        await engineA.start()
        await engineA.noteLocalSession(session)
        await engineA.drainOnce()
        await engineB.start()
        try await waitUntil("B has the session") {
            (await storeB.load(id: session.id))?.photos.count == 2
        }
        let photoID = session.photos[0].id

        // B edits the photo FIRST (pending, not drained) — deterministic:
        // the edit is journaled before any tombstone exists anywhere.
        var atB = try await loadOrFail(storeB, session.id)
        let i = atB.photos.firstIndex { $0.id == photoID }!
        atB.photos[i].look = look(0.7)
        try await storeB.save(atB)
        await engineB.noteLocalSession(atB)

        // A deletes photo 1 AND DRAINS (tombstone committed remotely).
        var atA = try await loadOrFail(storeA, session.id)
        atA.photos.removeAll { $0.id == photoID }
        try await storeA.save(atA)
        await engineA.noteLocalSession(atA)
        await engineA.drainOnce()

        // B's pending edit now drains against a committed remote tombstone.
        await engineB.drainOnce()

        // The tombstone wins; the edit is preserved as a conflict record.
        try await waitUntil("B hides the deleted photo") {
            guard let s = await storeB.load(id: session.id) else { return false }
            return !s.photos.contains { $0.id == photoID }
        }
        let conflicts = await engineB.conflictRecords
        XCTAssertTrue(conflicts.contains { $0.localValue == .look(look(0.7)) },
                      "the losing edit must be recoverable")
        await engineA.stop()
        await engineB.stop()
    }

    // MARK: session tombstone delete / undo

    func testSessionDeleteAndUndoRoundTrip() async throws {
        let (engineA, storeA) = makeEngine("mac-A")
        let (engineB, storeB) = makeEngine("ios-B")

        let p1 = try makeSourceJPEG("p1")
        let session = makeSession(title: "Ephemeral", photos: [p1])
        try await storeA.save(session)
        await engineA.start()
        await engineA.noteLocalSession(session)
        await engineA.drainOnce()
        await engineB.start()
        try await waitUntil("B has the session") {
            await storeB.load(id: session.id) != nil
        }

        await engineA.deleteSessionLocally(session.id)
        await engineA.drainOnce()
        try await waitUntil("B hides the deleted session") {
            await storeB.load(id: session.id) == nil
        }
        let goneAtA = await storeA.load(id: session.id)
        XCTAssertNil(goneAtA)

        await engineA.undoDeleteSessionLocally(session.id)
        await engineA.drainOnce()
        try await waitUntil("B restores the session after undo") {
            await storeB.load(id: session.id) != nil
        }
        let backAtA = await storeA.load(id: session.id)
        XCTAssertNotNil(backAtA)
        await engineA.stop()
        await engineB.stop()
    }

    // MARK: upload pipeline

    func testUploadPipelineEndToEndWithReconcilerLedger() async throws {
        let (engineA, storeA) = makeEngine("mac-A")
        let p1 = try makeSourceJPEG("p1")
        let session = makeSession(title: "Uploads", photos: [p1])
        try await storeA.save(session)
        await engineA.start()
        await engineA.noteLocalSession(session)
        await engineA.drainOnce()          // creates docs + enqueues transfers
        await engineA.pumpTransfers()      // reserve + upload thumb, then original

        let queue = await engineA.transferSnapshot
        let thumbID = SyncSchema.reservationId(tier: "thumbs", contentHash: p1.hash)
        let origID = SyncSchema.reservationId(tier: "originals", contentHash: p1.hash)
        XCTAssertEqual(queue.transfer(id: thumbID)?.status, .done)
        XCTAssertEqual(queue.transfer(id: origID)?.status, .done)

        // Objects really exist.
        let backend = FirebaseSyncBackend()
        let thumbExists = try await backend.objectExists(
            objectName: SyncSchema.objectName(uid: uid, tier: "thumbs", contentHash: p1.hash))
        let origExists = try await backend.objectExists(
            objectName: SyncSchema.objectName(uid: uid, tier: "originals", contentHash: p1.hash))
        XCTAssertTrue(thumbExists)
        XCTAssertTrue(origExists)

        // The reconciler (functions emulator) converts reserved -> used and
        // writes the server-owned rendition ledger.
        try await waitUntil("reconciler accounts usage", timeout: 30) {
            guard let usage = try? await backend.getDocument(
                path: "users/\(self.uid)/usage/storage"),
                  let used = usage["bytesUsed"]?.intValue else { return false }
            return used > 0
        }
        try await waitUntil("rendition ledger written", timeout: 30) {
            guard let blob = try? await backend.getDocument(
                path: "users/\(self.uid)/blobs/\(p1.hash)") else { return false }
            return RemoteBlobDoc(contentHash: p1.hash, fsMap: blob)?
                .isUploaded(tier: "originals") ?? false
        }
        await engineA.stop()
    }

    func testKillMidUploadRecoversOnRelaunch() async throws {
        let root = tempDir("kill")
        let store = FileSessionStore(root: root, uid: uid)
        let engineRoot = root.appendingPathComponent("users/\(uid)", isDirectory: true)

        let p1 = try makeSourceJPEG("p1")
        let session = makeSession(title: "Killed", photos: [p1])
        try await store.save(session)

        // First life: create docs + enqueue, then "die" before uploading.
        let engine1 = SyncEngine(uid: uid, deviceID: "mac-A",
                                 backend: FirebaseSyncBackend(), store: store,
                                 root: engineRoot)
        await engine1.start()
        await engine1.noteLocalSession(session)
        await engine1.drainOnce()
        await engine1.stop()   // persisted queue still has queued transfers

        // Simulate death MID-FLIGHT (#147): a REAL reservation was granted
        // and the process died while `uploading`. Rewrite the persisted state
        // so the original transfer is in-flight with the live server lease —
        // relaunch must requeue it and the pump must finish against that
        // same reservation (Storage rules check it at finalize).
        let backend = FirebaseSyncBackend()
        let grant = try await backend.reserveUpload(
            contentHash: p1.hash, tier: "originals", byteSize: p1.size)
        let stateURL = engineRoot.appendingPathComponent("sync-state.json")
        var syncState = try JSONDecoder().decode(
            SyncState.self, from: Data(contentsOf: stateURL))
        var transfers = syncState.transfers
        transfers.beganReserving(id: "originals_\(p1.hash)")
        transfers.reserved(id: "originals_\(p1.hash)", expiresAt: grant.expiresAt)
        syncState.transfers = transfers
        try JSONEncoder().encode(syncState).write(to: stateURL)
        XCTAssertEqual(transfers.transfer(id: "originals_\(p1.hash)")?.status, .uploading)

        // Second life: relaunch requeues the in-flight transfer (keeping the
        // unexpired lease) and completes it.
        let engine2 = SyncEngine(uid: uid, deviceID: "mac-A",
                                 backend: FirebaseSyncBackend(), store: store,
                                 root: engineRoot)
        await engine2.start()
        await engine2.pumpTransfers()
        let queue = await engine2.transferSnapshot
        XCTAssertEqual(queue.activeCount, 0, "everything finishes after relaunch")
        let origExists = try await backend.objectExists(
            objectName: SyncSchema.objectName(uid: uid, tier: "originals",
                                              contentHash: p1.hash))
        XCTAssertTrue(origExists)
        await engine2.stop()
    }

    func testSameBytesInTwoSessionsDedupNoOp() async throws {
        // Plan's "dedup no-op": the same file in a second session must reuse
        // the blob — no second upload, no rules-denied blob-shell rewrite.
        let (engineA, storeA) = makeEngine("mac-A")
        let p1 = try makeSourceJPEG("p1")
        let session1 = makeSession(title: "First", photos: [p1])
        try await storeA.save(session1)
        await engineA.start()
        await engineA.noteLocalSession(session1)
        await engineA.drainOnce()
        await engineA.pumpTransfers()
        let firstPass = await engineA.transferSnapshot
        XCTAssertEqual(firstPass.transfer(id: "originals_\(p1.hash)")?.status, .done)

        let session2 = makeSession(title: "Second", photos: [p1])   // same bytes
        try await storeA.save(session2)
        await engineA.noteLocalSession(session2)
        await engineA.drainOnce()
        await engineA.pumpTransfers()

        // Photo doc exists in BOTH sessions, one blob doc, nothing stuck.
        let backend = FirebaseSyncBackend()
        let photo2Path = SyncTarget.photo(session: session2.id,
                                          photo: session2.photos[0].id).path(uid: uid)
        let photo2 = try await backend.getDocument(path: photo2Path)
        XCTAssertEqual(photo2?["contentHash"]?.stringValue, p1.hash)
        let queue = await engineA.transferSnapshot
        XCTAssertEqual(queue.activeCount, 0)
        XCTAssertFalse(queue.hasParked, "no denied writes / stuck transfers")
        await engineA.stop()
    }

    func testQuotaExceededIsTerminal() async throws {
        try await seedUser(uid: uid, quotaBytes: 1000)   // ~1 KB: nothing fits
        let (engineA, storeA) = makeEngine("mac-A")
        let p1 = try makeSourceJPEG("p1")
        let session = makeSession(title: "OverQuota", photos: [p1])
        try await storeA.save(session)
        await engineA.start()
        await engineA.noteLocalSession(session)
        await engineA.drainOnce()
        await engineA.pumpTransfers()
        let queue = await engineA.transferSnapshot
        XCTAssertTrue(queue.isQuotaExceeded, "quota exhaustion must be a first-class terminal state")
        await engineA.stop()
    }

    // MARK: ack-aware reconcile

    func testOfflineCreatedSessionIsPreservedAndPushed() async throws {
        let (engineA, storeA) = makeEngine("mac-A")
        let p1 = try makeSourceJPEG("p1")
        let session = makeSession(title: "Offline Creation", photos: [p1])
        try await storeA.save(session)
        await engineA.start()
        await engineA.noteLocalSession(session)

        // Reconcile BEFORE any drain: never-acked local must NOT be purged.
        await engineA.reconcileSessions()
        let survived = await storeA.load(id: session.id)
        XCTAssertNotNil(survived, "never-acked local session must survive reconcile")

        await engineA.drainOnce()
        let acked = await engineA.everAcked(.session(session.id))
        XCTAssertTrue(acked)
        let doc = try await FirebaseSyncBackend().getDocument(
            path: "users/\(uid)/sessions/\(session.id.uuidString)")
        XCTAssertEqual(doc?["title"]?.stringValue, "Offline Creation")
        await engineA.stop()
    }

    func testAckedButAbsentRemotelyIsPurgedLocally() async throws {
        let (engineA, storeA) = makeEngine("mac-A")
        let p1 = try makeSourceJPEG("p1")
        let session = makeSession(title: "Purged Remotely", photos: [p1])
        try await storeA.save(session)
        await engineA.start()
        await engineA.noteLocalSession(session)
        await engineA.drainOnce()

        // Server-side purge (maintenance/deleteAccount analog): admin delete.
        try await restDelete("users/\(uid)/sessions/\(session.id.uuidString)/photos/\(session.photos[0].id.uuidString)")
        try await restDelete("users/\(uid)/sessions/\(session.id.uuidString)")

        try await waitUntil("local copy purged after remote deletion") {
            await storeA.load(id: session.id) == nil
        }
        await engineA.stop()
    }
}
