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

    func testSameBytesFromTwoPathsDeduplicate() async throws {
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let a = jpg("first", bytes: bytes)
        let b = jpg("second-copy", bytes: bytes)

        let m = MergeModel()
        m.addFiles([a])
        m.addFiles([b])
        XCTAssertEqual(m.items.count, 2, "path dedup alone can't catch this")

        // Hashing runs off-main; poll until the dedup lands.
        for _ in 0..<100 where m.items.count > 1 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(m.items.count, 1, "identical bytes must collapse to one photo")
        XCTAssertEqual(m.items[0].sdrURL, a, "the FIRST import wins")
        XCTAssertNotNil(m.dropNotice)
        XCTAssertTrue(m.dropNotice?.contains("Duplicate") ?? false)
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

    func testDoneSurvivesOnlyWhileExportExists() async throws {
        let store = FileSessionStore(root: root)
        let src = jpg("exported")
        let out = jpg("exported_UltraHDR")
        let done = PhotoRecord(origin: .linked(path: src.path), done: true,
                               outputPath: out.path,
                               readout: ClampReadout(peakBoost: 2, stops: 1,
                                                     maxBoost: 2.1, targetNits: 406))
        let stale = PhotoRecord(origin: .linked(path: jpg("stale").path), done: true,
                                outputPath: root.appendingPathComponent("deleted.jpg").path)
        try await store.save(Session(title: "T", photos: [done, stale]))

        let m = MergeModel()
        await m.attachStoreAndRestore(FileSessionStore(root: root))
        XCTAssertEqual(m.items[0].status, .done)
        XCTAssertEqual(m.items[0].readout?.targetNits, 406)
        XCTAssertEqual(m.items[1].status, .pending,
                       "a deleted export means the photo is no longer 'saved'")
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

    func testSignatureRoundTripsAndNormalizesBakeOff() async {
        let store = FileSessionStore(root: root)
        var p = AutoHDR.BloomParams(); p.glow = 0.9; p.bakeGlowIntoSDR = true
        await store.saveSignature(p)
        let back = await store.loadSignature()
        XCTAssertEqual(back?.glow ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertFalse(back?.bakeGlowIntoSDR ?? true,
                       "the saved default never carries GLOW-IN-SDR")
    }
}

private extension JSONDecoder {
    static var p3: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
