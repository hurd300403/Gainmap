//
//  SessionPersistenceTests.swift
//  GainmapCoreTests
//
//  P3 exit tests: session round-trip, crash-safety (corrupt files skipped,
//  atomic writes leave no debris), naming, contentHash dedup, live-look
//  flush, too-large-to-sync flagging, and relaunch restore.
//

import XCTest
@testable import GainmapCore

@MainActor
final class SessionPersistenceTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: MergeModel.sameLookKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-p3-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: MergeModel.sameLookKey)
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func jpg(_ name: String, bytes: Data = Data("jpegish-bytes".utf8)) -> URL {
        let url = root.appendingPathComponent("\(name).jpg")
        try? bytes.write(to: url)
        return url
    }

    // MARK: Round-trip

    func testSessionRoundTripsThroughStore() async throws {
        let store = FileSessionStore(root: root)
        var look = AutoHDR.BloomParams(); look.glow = 1.23; look.tint = -0.4
        let photo = PhotoRecord(origin: .linked(path: "/x/a.jpg"), contentHash: "abc123",
                                byteSize: 12345, pixelWidth: 640, pixelHeight: 480,
                                tooLargeToSync: false, looksMerged: true, look: look,
                                done: true, outputPath: "/x/a_UltraHDR.jpg",
                                readout: ClampReadout(peakBoost: 2.5, stops: 1.32,
                                                      maxBoost: 2.625, targetNits: 507))
        var session = Session(title: "Smith Wedding", sameLookForAll: true,
                              runningLook: look, photos: [photo])
        session.updatedAt = Date()
        try await store.save(session)

        let loaded = await store.load(id: session.id)
        let back = try XCTUnwrap(loaded)
        XCTAssertEqual(back.id, session.id)
        XCTAssertEqual(back.title, "Smith Wedding")
        XCTAssertTrue(back.sameLookForAll)
        XCTAssertEqual(back.runningLook, look)
        XCTAssertEqual(back.photos.count, 1)
        XCTAssertEqual(back.photos[0].id, photo.id)
        XCTAssertEqual(back.photos[0].contentHash, "abc123")
        XCTAssertEqual(back.photos[0].byteSize, 12345)
        XCTAssertEqual(back.photos[0].pixelWidth, 640)
        XCTAssertTrue(back.photos[0].looksMerged)
        XCTAssertEqual(back.photos[0].look, look)
        XCTAssertTrue(back.photos[0].done)
        XCTAssertEqual(back.photos[0].readout?.targetNits, 507)
    }

    func testLegacyWholeSecondSessionDatesStillLoad() async throws {
        let store = FileSessionStore(root: root)
        let legacy = Session(title: "Legacy Date")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(legacy)
        let dir = root.appendingPathComponent("users/local/sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("\(legacy.id.uuidString).json"))

        let loaded = await store.load(id: legacy.id)
        XCTAssertEqual(loaded?.title, "Legacy Date")
    }

    // MARK: Crash safety

    func testCorruptSessionFileIsSkippedNotFatal() async throws {
        let store = FileSessionStore(root: root)
        let good = Session(title: "Good", photos: [PhotoRecord(origin: .linked(path: "/a.jpg"))])
        try await store.save(good)
        // A torn/corrupt neighbor must not take the store down.
        let dir = root.appendingPathComponent("users/local/sessions")
        try Data("{not json at all".utf8)
            .write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))

        let all = await store.loadAll()
        XCTAssertEqual(all.map(\.id), [good.id], "corrupt file skipped, good one loads")
    }

    func testTooNewSchemaVersionIsSkipped() async throws {
        let store = FileSessionStore(root: root)
        let dir = root.appendingPathComponent("users/local/sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let futureID = UUID()
        let future = """
        {"id":"\(futureID.uuidString)","schemaVersion":2,"title":"from the future","photos":[]}
        """
        try Data(future.utf8).write(to: dir.appendingPathComponent("\(futureID.uuidString).json"))
        let loaded = await store.load(id: futureID)
        XCTAssertNil(loaded, "a newer schema must be skipped, never mis-read")
    }

    func testSaveLeavesNoTempDebris() async throws {
        let store = FileSessionStore(root: root)
        for i in 0..<5 {
            try await store.save(Session(title: "s\(i)"))
        }
        let dir = root.appendingPathComponent("users/local/sessions")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "atomic save must clean its temp files")
    }

    func testEditorThumbnailPlanUsesLocalOriginalThenSyncedThumb() throws {
        let store = FileSessionStore(root: root, uid: "thumb-user")
        let original = jpg("local-original")
        let localHash = String(repeating: "a", count: 64)
        let remoteHash = String(repeating: "b", count: 64)
        let missingHash = String(repeating: "c", count: 64)
        let localPhoto = PhotoRecord(
            origin: .linked(path: original.path),
            contentHash: localHash)
        let remotePhoto = PhotoRecord(
            origin: .managed(relativePath: "blobs/\(remoteHash).jpg"),
            contentHash: remoteHash)
        let missingPhoto = PhotoRecord(
            origin: .managed(relativePath: "blobs/\(missingHash).jpg"),
            contentHash: missingHash)

        let localThumb = store.thumbnailURL(forContentHash: localHash)
        let remoteThumb = store.thumbnailURL(forContentHash: remoteHash)
        try FileManager.default.createDirectory(
            at: remoteThumb.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("local thumb".utf8).write(to: localThumb)
        try Data("remote thumb".utf8).write(to: remoteThumb)

        let plan = store.thumbnailPlan(for: Session(
            photos: [localPhoto, remotePhoto, missingPhoto]))

        XCTAssertEqual(plan.localURLsByPhotoID[localPhoto.id], original)
        XCTAssertEqual(plan.localURLsByPhotoID[remotePhoto.id], remoteThumb)
        XCTAssertNil(plan.localURLsByPhotoID[missingPhoto.id])
        XCTAssertEqual(
            plan.missing,
            [SessionThumbnailRequest(
                photoID: missingPhoto.id,
                contentHash: missingHash)])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.managedFilesDir
                    .appendingPathComponent("blobs/\(remoteHash).jpg").path),
            "filmstrip hydration must not download an original")
    }

    // MARK: Naming

    func testNamingUsesShootFolderName() {
        let urls = [URL(fileURLWithPath: "/Users/x/Pictures/Smith Wedding/a.jpg"),
                    URL(fileURLWithPath: "/Users/x/Pictures/Smith Wedding/b.jpg")]
        XCTAssertEqual(SessionNaming.suggest(from: urls), "Smith Wedding")
    }

    func testNamingFallsBackToDateForGenericOrMixedFolders() {
        let date = DateComponents(calendar: .current, year: 2026, month: 7, day: 27).date!
        let generic = [URL(fileURLWithPath: "/Users/x/Downloads/a.jpg")]
        XCTAssertEqual(SessionNaming.suggest(from: generic, date: date), "July 27 Session")
        let mixed = [URL(fileURLWithPath: "/p/one/a.jpg"), URL(fileURLWithPath: "/p/two/b.jpg")]
        XCTAssertEqual(SessionNaming.suggest(from: mixed, date: date), "July 27 Session")
    }

    // MARK: Too large to sync

    func testTooLargeBoundary() {
        XCTAssertFalse(SyncLimits.tooLargeToSync(byteSize: SyncLimits.maxSyncableBytes - 1))
        XCTAssertTrue(SyncLimits.tooLargeToSync(byteSize: SyncLimits.maxSyncableBytes))
    }

    func testImportFlagsOversizedFileAndStillImportsIt() throws {
        // Sparse 64 MB file — instant to create, real according to stat.
        let url = root.appendingPathComponent("huge.jpg")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(SyncLimits.maxSyncableBytes))
        try h.close()

        let m = MergeModel()
        m.addFiles([url, jpg("normal")])
        XCTAssertEqual(m.items.count, 2, "oversized photos import and edit normally")
        XCTAssertTrue(m.items[0].tooLargeToSync)
        XCTAssertFalse(m.items[1].tooLargeToSync)
    }

    // MARK: contentHash dedup

    func testSameBytesTwiceInOneDropDeduplicate() async throws {
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let a = jpg("first", bytes: bytes)
        let b = jpg("second-copy", bytes: bytes)

        let m = MergeModel()
        m.addFiles([a, b])                        // ONE gesture, same bytes twice
        XCTAssertEqual(m.items.count, 2, "path dedup alone can't catch this")

        // Hashing runs off-main; poll until the dedup lands.
        for _ in 0..<100 where m.items.count > 1 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(m.items.count, 1, "identical bytes in one drop collapse to one photo")
        XCTAssertEqual(m.items[0].sdrURL, a, "the FIRST occurrence wins")
        XCTAssertTrue(m.dropNotice?.contains("Duplicate") ?? false)
    }

    /// Dedup is deliberately same-batch only: removals across batches were
    /// racy and could delete an edited/exported photo (P3 review). Re-adding
    /// a photo — or dropping the same bytes from another folder later — works.
    func testCrossBatchAndReAddAreAllowed() async throws {
        let bytes = Data((0..<4096).map { UInt8($0 % 199) })
        let a = jpg("orig", bytes: bytes)
        let b = jpg("other-folder-copy", bytes: bytes)

        let m = MergeModel()
        m.addFiles([a])
        try await waitForHashes(m, count: 1)
        m.addFiles([b])                           // separate gesture: allowed
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(m.items.count, 2, "cross-batch duplicates are the user's call")

        m.remove(m.items[1].id)
        m.addFiles([b])                           // re-add after remove: allowed
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(m.items.count, 2, "a removed photo must be re-addable")
    }

    private func waitForHashes(_ m: MergeModel, count: Int) async throws {
        for _ in 0..<100 {
            if m.session.photos.filter({ $0.contentHash != nil }).count >= count { return }
            m.syncToSession()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: Live-look flush + relaunch restore

    func testDialedLookSurvivesRelaunch() async throws {
        let store = FileSessionStore(root: root)
        let m = MergeModel(store: store)
        m.addFiles([jpg("a"), jpg("b")])
        m.bloom.glow = 1.31                       // dialed, NOT navigated away
        m.bloom.tint = 0.5
        await m.flushSession()                    // live-look flush commits it

        let m2 = MergeModel()
        await m2.attachStoreAndRestore(FileSessionStore(root: root))
        XCTAssertEqual(m2.items.count, 2)
        XCTAssertEqual(m2.items.map(\.sdrURL.lastPathComponent), ["a.jpg", "b.jpg"])
        XCTAssertEqual(m2.items[0].look?.glow ?? 0, 1.31, accuracy: 1e-9,
                       "the look dialed on the selected photo must survive relaunch")
        XCTAssertEqual(m2.runningLook.glow, 1.31, accuracy: 1e-9)
        XCTAssertEqual(m2.selectedID, m2.items[0].id, "restore selects the first photo")
    }

    func testOpeningAnotherSessionFlushesTheOneBeingLeft() async throws {
        let store = FileSessionStore(root: root)
        let first = Session(title: "First", photos: [
            PhotoRecord(origin: .linked(path: jpg("first").path))
        ])
        let second = Session(title: "Second", photos: [
            PhotoRecord(origin: .linked(path: jpg("second").path))
        ])
        try await store.save(first)
        try await store.save(second)

        let model = MergeModel(session: first, store: store)
        model.bloom.glow = 1.37
        let opened = await model.openSession(id: second.id)
        XCTAssertTrue(opened)

        XCTAssertEqual(model.session.id, second.id)
        XCTAssertEqual(model.items.map(\.sdrURL.lastPathComponent), ["second.jpg"])
        let loadedFirst = await store.load(id: first.id)
        let flushedFirst = try XCTUnwrap(loadedFirst)
        XCTAssertEqual(flushedFirst.photos[0].look?.glow ?? 0, 1.37, accuracy: 1e-9,
                       "switching sessions must flush the live look first")
    }

    func testStartingNewSessionKeepsPriorBatchAndUsesSignature() async throws {
        let store = FileSessionStore(root: root)
        let model = MergeModel(store: store)
        model.addFiles([jpg("prior")])
        let priorID = model.session.id
        var signature = AutoHDR.BloomParams()
        signature.glow = 0.82
        model.signature = signature

        let started = await model.startNewSession()
        XCTAssertTrue(started)
        XCTAssertNotEqual(model.session.id, priorID)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.runningLook.glow, 0.82, accuracy: 1e-9)
        let savedPrior = await store.load(id: priorID)
        XCTAssertEqual(savedPrior?.photos.count, 1,
                       "the previous batch remains a resumable session")
    }

    func testThreeBatchesRemainThreeSessionsAcrossRelaunch() async throws {
        let store = FileSessionStore(root: root)
        let model = MergeModel(store: store)

        model.addFiles([jpg("batch-one")])
        let startedSecond = await model.startNewSession()
        XCTAssertTrue(startedSecond)
        model.addFiles([jpg("batch-two")])
        let startedThird = await model.startNewSession()
        XCTAssertTrue(startedThird)
        model.addFiles([jpg("batch-three")])
        await model.flushSession()

        let saved = await store.loadAll()
        XCTAssertEqual(saved.count, 3)
        let storedNames = Set(saved.compactMap {
            $0.photos.first?.sourceURL(managedRoot: store.managedFilesDir).lastPathComponent
        })
        XCTAssertEqual(storedNames,
                       Set(["batch-one.jpg", "batch-two.jpg", "batch-three.jpg"]))

        let relaunched = MergeModel()
        await relaunched.attachStoreAndRestore(FileSessionStore(root: root))
        XCTAssertEqual(relaunched.items.map(\.sdrURL.lastPathComponent),
                       ["batch-three.jpg"])
    }

    func testFiveHundredSessionLibraryLoadsWithinOneSecond() async throws {
        let store = FileSessionStore(root: root)
        let base = Date()
        for index in 0..<500 {
            try await store.save(Session(
                title: "Session \(index)",
                updatedAt: base.addingTimeInterval(Double(index))))
        }

        let clock = ContinuousClock()
        let start = clock.now
        let saved = await store.loadAll()
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(saved.count, 500)
        XCTAssertEqual(saved.first?.title, "Session 499")
        XCTAssertLessThan(elapsed, .seconds(1),
                          "the lazy grid still needs its local library snapshot promptly")
    }

    func testRenamingLiveSessionPersists() async throws {
        let store = FileSessionStore(root: root)
        let model = MergeModel(store: store)
        model.addFiles([jpg("rename")])
        model.setSessionTitle("  July Campaign  ")
        await model.flushSession()

        XCTAssertEqual(model.session.title, "July Campaign")
        let renamed = await store.load(id: model.session.id)
        XCTAssertEqual(renamed?.title, "July Campaign")
    }

    func testTerminationFlushIsSynchronous() throws {
        let store = FileSessionStore(root: root)
        let m = MergeModel(store: store)
        m.addFiles([jpg("quit-test")])
        m.bloom.headroom = 2.5
        m.flushNowForTermination()                // no await — the quit path

        let dir = root.appendingPathComponent("users/local/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(files.filter { $0.hasSuffix(".json") }.count, 1)
        let data = try Data(contentsOf: dir.appendingPathComponent(files[0]))
        let session = try JSONDecoder.p3.decode(Session.self, from: data)
        XCTAssertEqual(session.photos.count, 1)
        XCTAssertEqual(session.photos[0].look?.headroom ?? 0, 2.5, accuracy: 1e-9)
    }

    func testRestoreMarksMissingSourceAsError() async throws {
        let store = FileSessionStore(root: root)
        let gone = PhotoRecord(origin: .linked(path: root.appendingPathComponent("vanished.jpg").path))
        let here = PhotoRecord(origin: .linked(path: jpg("still-here").path))
        try await store.save(Session(title: "T", photos: [gone, here]))

        let m = MergeModel()
        await m.attachStoreAndRestore(FileSessionStore(root: root))
        XCTAssertEqual(m.items.count, 2)
        XCTAssertEqual(m.items[0].status, .error, "a moved/deleted source is visible, not silent")
        XCTAssertEqual(m.items[1].status, .pending)
    }

    func testUnreachableExportShowsPendingButLedgerSurvives() async throws {
        let store = FileSessionStore(root: root)
        let src = jpg("exported")
        let out = jpg("exported_UltraHDR")
        let done = PhotoRecord(origin: .linked(path: src.path), done: true,
                               outputPath: out.path,
                               readout: ClampReadout(peakBoost: 2, stops: 1,
                                                     maxBoost: 2.1, targetNits: 406))
        let offline = PhotoRecord(origin: .linked(path: jpg("on-volume").path), done: true,
                                  outputPath: root.appendingPathComponent("unmounted.jpg").path,
                                  readout: ClampReadout(peakBoost: 3, stops: 1.58,
                                                        maxBoost: 3.15, targetNits: 609))
        try await store.save(Session(title: "T", photos: [done, offline]))

        let m = MergeModel()
        await m.attachStoreAndRestore(FileSessionStore(root: root))
        XCTAssertEqual(m.items[0].status, .done)
        XCTAssertEqual(m.items[0].readout?.targetNits, 406)
        XCTAssertEqual(m.items[1].status, .pending,
                       "an unreachable export shows as not-saved in the VIEW")

        // …but flushing must NOT erase the durable record: when the volume
        // comes back and the app relaunches, the export is 'saved' again.
        await m.flushSession()
        let reloaded = await FileSessionStore(root: root).load(id: m.session.id)
        let record = try XCTUnwrap(reloaded?.photos.first { $0.id == offline.id })
        XCTAssertTrue(record.done, "a temporarily offline export is never forgotten")
        XCTAssertEqual(record.outputPath, offline.outputPath)
        XCTAssertEqual(record.readout?.targetNits, 609)
    }

    /// P3 review regression: flush→commitLiveLook re-armed the debounce from
    /// inside the flush it triggered — a self-sustaining 2 Hz write loop. An
    /// idle app must write NOTHING after its state is flushed.
    func testIdleAppStopsWritingAfterFlush() async throws {
        let store = FileSessionStore(root: root)
        let m = MergeModel(store: store)
        m.addFiles([jpg("idle")])
        try await waitForHashes(m, count: 1)   // let the one metadata persist land
        await m.flushSession()

        let dir = root.appendingPathComponent("users/local/sessions")
        let file = dir.appendingPathComponent("\(m.session.id.uuidString).json")
        let mtime = { try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date }
        let before = try XCTUnwrap(mtime())
        try await Task.sleep(nanoseconds: 1_500_000_000)   // three debounce periods
        XCTAssertEqual(mtime(), before, "an idle app must not keep rewriting its session")
    }

    /// P3 review regression: removing a NON-selected photo returned before the
    /// persist was scheduled — the deletion held only until relaunch.
    func testRemovingNonSelectedPhotoIsDurable() async throws {
        let store = FileSessionStore(root: root)
        let m = MergeModel(store: store)
        m.addFiles([jpg("keep"), jpg("axe")])
        m.select(m.items[0].id)
        m.remove(m.items[1].id)                    // not the selected one
        await m.flushSession()

        let m2 = MergeModel()
        await m2.attachStoreAndRestore(FileSessionStore(root: root))
        XCTAssertEqual(m2.items.map(\.sdrURL.lastPathComponent), ["keep.jpg"],
                       "a removal must survive relaunch")
    }

    func testReorderedFilmstripIsDurableAndRestoresExactOrder() async throws {
        let store = FileSessionStore(root: root)
        let model = MergeModel(store: store)
        model.addFiles([jpg("a"), jpg("b"), jpg("c")])
        let ids = model.items.map(\.id)

        XCTAssertTrue(model.reorderItems(to: [ids[2], ids[0], ids[1]]))
        await model.flushSession()

        let loaded = await store.load(id: model.session.id)
        let persisted = try XCTUnwrap(loaded)
        XCTAssertEqual(persisted.photos.map(\.id),
                       [ids[2], ids[0], ids[1]])

        let reopened = MergeModel(session: persisted, store: store)
        XCTAssertEqual(reopened.items.map(\.id),
                       [ids[2], ids[0], ids[1]])
        XCTAssertEqual(
            reopened.items.map(\.sdrURL.lastPathComponent),
            ["c.jpg", "a.jpg", "b.jpg"])
    }

    func testFirstImportNamesTheSession() {
        let shoot = root.appendingPathComponent("Jones Portraits")
        try? FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let a = shoot.appendingPathComponent("a.jpg")
        try? Data("x".utf8).write(to: a)

        let m = MergeModel()
        m.addFiles([a])
        XCTAssertEqual(m.session.title, "Jones Portraits")
    }

    // MARK: Signature file store

    func testLegacyUserDefaultsSignatureMigratesToFileOnAttach() async {
        var p = AutoHDR.BloomParams(); p.glow = 0.77
        SignatureStore.save(p)
        defer { SignatureStore.clear() }

        let m = MergeModel()
        await m.attachStoreAndRestore(FileSessionStore(root: root))
        let migrated = await FileSessionStore(root: root).loadSignature()
        XCTAssertEqual(migrated?.glow ?? 0, 0.77, accuracy: 1e-9,
                       "the UserDefaults-era default look must migrate to signature.json")
    }

    func testSignatureRoundTripsAndNormalizesBakeOff() async {
        let store = FileSessionStore(root: root)
        var p = AutoHDR.BloomParams(); p.glow = 0.9; p.bakeGlowIntoSDR = true
        await store.saveSignature(p)
        let back = await store.loadSignature()
        XCTAssertEqual(back?.glow ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertFalse(back?.bakeGlowIntoSDR ?? true,
                       "the saved default never carries GLOW-IN-SDR")
    }

    // MARK: portable managed origins (P5 — iOS container UUIDs rotate)

    func testManagedImportsPersistRelativeAndHealStalePaths() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-managed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSessionStore(root: root, uid: "u1")
        let importsDir = store.managedFilesDir.appendingPathComponent("imports")
        try FileManager.default.createDirectory(at: importsDir,
                                                withIntermediateDirectories: true)
        let file = importsDir.appendingPathComponent("a.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]).write(to: file)

        // Import via the normal pipeline: the persisted record must be
        // RELATIVE (managed), never an absolute path into the container.
        let model = await MergeModel(session: Session(), store: store)
        await model.addFiles([file])
        await model.flushSession()
        let saved = await store.load(id: model.session.id)
        let record = try XCTUnwrap(saved?.photos.first)
        guard case .managed(let rel) = record.origin else {
            return XCTFail("import inside the store must persist as .managed, got \(record.origin)")
        }
        XCTAssertEqual(rel, "imports/a.jpg")

        // Reopening resolves against the CURRENT managed root.
        let reopened = await MergeModel(session: saved!, store: store)
        let reopenedItems = await reopened.items
        let item = try XCTUnwrap(reopenedItems.first)
        XCTAssertEqual(item.sdrURL.path, file.path)
        XCTAssertNotEqual(item.status, .error)

        // Legacy heal: a stale absolute path from a PREVIOUS container
        // (different UUID prefix, same /files/ suffix) re-roots to the
        // current container instead of erroring.
        var legacy = saved!
        legacy.photos[0].origin = .linked(
            path: "/var/mobile/Containers/Data/Application/OLD-UUID/Library/Application Support/Gainmap/users/u1/files/imports/a.jpg")
        legacy.photos[0].contentHash = try XCTUnwrap(ContentHash.sha256(of: file))
        legacy.photos[0].byteSize = 7
        try await store.save(legacy)
        let migrated = await store.loadAllRepairingManagedOrigins()
        let migratedSession = try XCTUnwrap(
            migrated.first(where: { $0.id == legacy.id }))
        guard case .managed(let migratedPath) = migratedSession.photos[0].origin else {
            return XCTFail("legacy store path should migrate durably to .managed")
        }
        XCTAssertEqual(migratedPath, "imports/a.jpg")
        let persistedMigration = await store.load(id: legacy.id)
        XCTAssertEqual(persistedMigration?.photos[0].origin, migratedSession.photos[0].origin)

        let healed = await MergeModel(session: migratedSession, store: store)
        let healedItems = await healed.items
        let healedItem = try XCTUnwrap(healedItems.first)
        XCTAssertEqual(healedItem.sdrURL.path, file.path)
        XCTAssertNotEqual(healedItem.status, .error)

        // Similar-looking external and unsafe paths are never rebound. The
        // migration is specifically for old iOS Gainmap containers and only
        // when the current bytes still match the persisted content address.
        var external = Session(photos: [legacy.photos[0]])
        external.photos[0].origin = .linked(
            path: "/Volumes/Archive/files/imports/a.jpg")
        var traversal = Session(photos: [legacy.photos[0]])
        traversal.photos[0].origin = .linked(
            path: "/var/mobile/Containers/Data/Application/OTHER/Library/Application Support/Gainmap/users/u1/files/imports/../imports/a.jpg")
        var hashMismatch = Session(photos: [legacy.photos[0]])
        hashMismatch.photos[0].origin = .linked(
            path: "/var/mobile/Containers/Data/Application/OTHER/Library/Application Support/Gainmap/users/u1/files/imports/a.jpg")
        hashMismatch.photos[0].contentHash = String(repeating: "ab", count: 32)
        try await store.save(external)
        try await store.save(traversal)
        try await store.save(hashMismatch)

        let guarded = await store.loadAllRepairingManagedOrigins()
        for id in [external.id, traversal.id, hashMismatch.id] {
            let session = try XCTUnwrap(guarded.first(where: { $0.id == id }))
            guard case .linked = session.photos[0].origin else {
                return XCTFail("unsafe or mismatched path must remain linked")
            }
        }
    }

    // MARK: inbound reload (P5 review — persistTask must reset after flush)

    func testInboundReloadAppliesAfterAFlushCycle() async throws {
        let store = FileSessionStore(root: root)
        let a = jpg("a")
        var photo = PhotoRecord(origin: .linked(path: a.path))
        photo.contentHash = "known-hash"
        let starting = Session(photos: [photo])
        let model = await MergeModel(session: starting, store: store)
        await model.select(photo.id)  // arm the same debounce a user action does
        await model.flushSession()   // debounce handle must reset to nil here

        var remote = await model.session
        remote.title = "Renamed on the phone"
        remote.updatedAt = Date().addingTimeInterval(60)
        await model.reloadFromRemote(remote)
        let title = await model.session.title
        XCTAssertEqual(title, "Renamed on the phone",
                       "an idle model (flushed, no pending debounce) must fold "
                       + "inbound changes in — a spent persistTask used to block "
                       + "this forever")
    }

    // MARK: adoption keeps the newer copy (P5 review — sign-out edits survived)

    func testAdoptLocalSessionsKeepsNewerCopyOnCollision() async throws {
        let uidStore = FileSessionStore(root: root, uid: "uA")
        let localStore = FileSessionStore(root: root, uid: "local")
        var session = Session(title: "synced copy",
                              photos: [PhotoRecord(origin: .linked(path: "/a.jpg"))])
        session.updatedAt = Date(timeIntervalSinceNow: -3600)
        try await uidStore.save(session)

        var newer = session
        newer.title = "edited while signed out"
        newer.updatedAt = Date()
        try await localStore.save(newer)

        await uidStore.adoptLocalSessions()
        let adopted = await uidStore.load(id: session.id)
        XCTAssertEqual(adopted?.title, "edited while signed out",
                       "the strictly newer local copy must win the collision")

        // Reverse: an OLDER local copy must not clobber newer synced state.
        var stale = session
        stale.title = "stale pre-auth copy"
        stale.updatedAt = Date(timeIntervalSinceNow: -7200)
        try await localStore.save(stale)
        await uidStore.adoptLocalSessions()
        let kept = await uidStore.load(id: session.id)
        XCTAssertEqual(kept?.title, "edited while signed out")
    }

    func testAdoptLocalSessionsReplacesCorruptDestinationWithoutLosingBytes() async throws {
        let uidStore = FileSessionStore(root: root, uid: "uA")
        let localStore = FileSessionStore(root: root, uid: "local")
        let local = Session(
            title: "valid local session",
            photos: [PhotoRecord(origin: .linked(path: "/valid.jpg"))])
        try await localStore.save(local)

        let destinationDir = root.appendingPathComponent("users/uA/sessions")
        try FileManager.default.createDirectory(
            at: destinationDir, withIntermediateDirectories: true)
        let destination = destinationDir
            .appendingPathComponent("\(local.id.uuidString).json")
        let corrupt = Data("{truncated-cloud-json".utf8)
        try corrupt.write(to: destination)

        await uidStore.adoptLocalSessions()

        let installed = await uidStore.load(id: local.id)
        let removedLocal = await localStore.load(id: local.id)
        XCTAssertEqual(installed?.title, "valid local session")
        XCTAssertNil(removedLocal)
        let recovery = root.appendingPathComponent(
            "users/uA/recovery/session-collisions")
        let recoveredFiles = try FileManager.default.contentsOfDirectory(
            at: recovery, includingPropertiesForKeys: nil)
        XCTAssertEqual(recoveredFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: recoveredFiles[0]), corrupt)

        await uidStore.adoptLocalSessions()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: recovery, includingPropertiesForKeys: nil).count, 1,
            "a retry must not create another recovery artifact")
    }

    func testAdoptLocalSessionsPreservesEqualTimestampDivergenceOnce() async throws {
        let uidStore = FileSessionStore(root: root, uid: "uA")
        let localStore = FileSessionStore(root: root, uid: "local")
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        var destination = Session(
            title: "cloud edit",
            photos: [PhotoRecord(origin: .linked(path: "/cloud.jpg"))])
        destination.updatedAt = timestamp
        try await uidStore.save(destination)

        var local = destination
        local.title = "local edit"
        local.photos = [PhotoRecord(origin: .linked(path: "/local.jpg"))]
        local.updatedAt = timestamp
        try await localStore.save(local)
        let localURL = root.appendingPathComponent(
            "users/local/sessions/\(local.id.uuidString).json")
        let sourceBytes = try Data(contentsOf: localURL)

        await uidStore.adoptLocalSessions()

        let firstPass = await uidStore.loadAll()
        XCTAssertEqual(firstPass.count, 2)
        XCTAssertTrue(firstPass.contains(where: { $0.title == "cloud edit" }))
        XCTAssertTrue(firstPass.contains(where: {
            $0.title == "local edit (Recovered local copy)"
                && $0.photos.first?.origin == .linked(path: "/local.jpg")
        }))
        let removedLocal = await localStore.load(id: local.id)
        XCTAssertNil(removedLocal)

        // Simulate a crash/retry boundary where the source removal did not
        // stick. The content-derived recovery identity must deduplicate it.
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try sourceBytes.write(to: localURL)
        await uidStore.adoptLocalSessions()
        let secondPass = await uidStore.loadAll()
        XCTAssertEqual(secondPass.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
        let recovery = root.appendingPathComponent(
            "users/uA/recovery/session-collisions")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: recovery, includingPropertiesForKeys: nil).count, 1)
    }

    func testStoredNamespaceDetectionRequiresSafeUIDAndActualData() throws {
        let empty = try XCTUnwrap(FileSessionStore.namespaceRoot(
            for: "legacy-user", root: root))
        try FileManager.default.createDirectory(
            at: empty.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true)
        XCTAssertFalse(FileSessionStore.hasStoredNamespaceData(
            for: "legacy-user", root: root))

        try Data("legacy session".utf8).write(
            to: empty.appendingPathComponent("sessions/old.json"))
        XCTAssertTrue(FileSessionStore.hasStoredNamespaceData(
            for: "legacy-user", root: root))
        for unsafe in ["", ".", "..", "../local", "nested/user", "nested\\user"] {
            XCTAssertNil(FileSessionStore.namespaceRoot(for: unsafe, root: root))
            XCTAssertFalse(FileSessionStore.hasStoredNamespaceData(
                for: unsafe, root: root))
        }
    }

    func testAdoptLocalSessionsCarriesManagedPhotoBytes() async throws {
        let localStore = FileSessionStore(root: root, uid: "local")
        let uidStore = FileSessionStore(root: root, uid: "uA")
        let relativePath = "imports/local-photo.jpg"
        let localPhoto = localStore.managedFilesDir
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: localPhoto.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let bytes = Data("managed-local-photo".utf8)
        try bytes.write(to: localPhoto)
        let session = Session(
            title: "Before Cloud Sync",
            photos: [PhotoRecord(origin: .managed(relativePath: relativePath))])
        try await localStore.save(session)

        await uidStore.adoptLocalSessions()

        let adopted = await uidStore.load(id: session.id)
        XCTAssertNotNil(adopted)
        let adoptedPhoto = uidStore.managedFilesDir
            .appendingPathComponent(relativePath)
        XCTAssertEqual(try Data(contentsOf: adoptedPhoto), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localPhoto.path),
                       "source bytes are removed only after every session is adopted")
    }

    func testAdoptLocalSessionsDoesNotOverwriteManagedFileCollision() async throws {
        let localStore = FileSessionStore(root: root, uid: "local")
        let uidStore = FileSessionStore(root: root, uid: "uA")
        let relativePath = "imports/collision.jpg"
        let localPhoto = localStore.managedFilesDir
            .appendingPathComponent(relativePath)
        let uidPhoto = uidStore.managedFilesDir
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: localPhoto.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: uidPhoto.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("local".utf8).write(to: localPhoto)
        try Data("cloud".utf8).write(to: uidPhoto)
        let session = Session(
            title: "Still Local",
            photos: [PhotoRecord(origin: .managed(relativePath: relativePath))])
        try await localStore.save(session)

        await uidStore.adoptLocalSessions()

        let uidSession = await uidStore.load(id: session.id)
        let localSession = await localStore.load(id: session.id)
        XCTAssertNil(uidSession)
        XCTAssertNotNil(localSession)
        XCTAssertEqual(try Data(contentsOf: uidPhoto), Data("cloud".utf8))
        XCTAssertEqual(try Data(contentsOf: localPhoto), Data("local".utf8))
    }

    // MARK: attach reset (P5 review — old account's session must not stay live)

    func testAttachWithResetSwapsToTheNewStoresContent() async throws {
        let storeA = FileSessionStore(root: root, uid: "uA")
        let a = jpg("mine")
        let model = await MergeModel(session: Session(), store: storeA)
        await model.addFiles([a])
        await model.flushSession()
        let oldID = await model.session.id

        let storeB = FileSessionStore(root: root, uid: "uB")
        await model.attachStoreAndRestore(storeB, reset: true)
        let newID = await model.session.id
        let items = await model.items
        XCTAssertNotEqual(newID, oldID,
                          "reset must drop the old namespace's session")
        XCTAssertTrue(items.isEmpty,
                      "no content may leak across a uid switch")
    }
}

private extension JSONDecoder {
    static var p3: JSONDecoder {
        SessionJSONCoding.decoder()
    }
}
