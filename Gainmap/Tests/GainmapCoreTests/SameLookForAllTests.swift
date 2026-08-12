//
//  SameLookForAllTests.swift
//  GainmapTests
//
//  The SAME LOOK FOR ALL contract: while ON, one shared look drives every
//  photo (navigation neither loads nor commits per-photo looks; merges use the
//  shared look for every item; Export All re-targets done items so the promise
//  holds); enabling and disabling establish the visible shared look as every
//  photo's independent baseline. Plus the
//  atomic-replace guarantee: stopping a re-export never destroys the previous
//  good export.
//

import XCTest
@testable import GainmapCore

@MainActor
final class SameLookForAllTests: XCTestCase {

    private var workDir: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: MergeModel.sameLookKey)
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-sla-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: MergeModel.sameLookKey)
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        super.tearDown()
    }

    private func url(_ name: String) -> URL { workDir.appendingPathComponent("\(name).jpg") }

    private func stubbedModel(outcome: @escaping @Sendable (UHDRRunner.Job) -> RunOutcome
                                = { .success(output: $0.out, readout: nil) }) -> MergeModel {
        let m = MergeModel()
        m.synthesizeBuffer = { sdr, _, _ in
            AutoHDR.RawBuffer(data: Data(), width: 4, height: 4)
        }
        m.synthesizeBakeInputs = { sdr, _, _ in
            AutoHDR.UltraHDRInputs(hdr: AutoHDR.RawBuffer(data: Data(), width: 4, height: 4),
                                   sdrJPEG: sdr)
        }
        m.runTool = { job in
            let o = outcome(job)
            if case .success = o { try? Data("stub".utf8).write(to: job.out) }
            return o
        }
        return m
    }

    // MARK: Persistence

    func testDefaultsToOffAndPersists() {
        XCTAssertFalse(MergeModel().sameLookForAll, "unset key must mean per-photo mode")
        let m = MergeModel()
        m.setSameLookForAll(true)
        XCTAssertTrue(MergeModel().sameLookForAll, "a fresh model reads the persisted flag")
    }

    // MARK: Navigation while ON

    func testNavigationNeitherLoadsNorCommitsWhileOn() {
        let m = stubbedModel()
        m.addFiles([url("a"), url("b")])
        m.bloom.glow = 0.9          // A's would-be look (uncommitted, look == nil)
        m.setSameLookForAll(true)
        XCTAssertEqual(m.items[0].look?.glow, 0.9,
                       "enabling immediately makes the visible look durable")
        m.bloom.glow = 1.2          // the shared look
        m.setIntensity(0.5)
        let shared = m.bloom

        m.selectNext()
        XCTAssertEqual(m.selectedIndex, 1, "selection still moves")
        XCTAssertEqual(m.sdrURL?.lastPathComponent, "b.jpg", "preview mirror still updates")
        XCTAssertEqual(m.bloom, shared, "the shared look survives navigation")
        XCTAssertEqual(m.intensity, 0.5, accuracy: 1e-9, "intensity is not reset per photo")
        XCTAssertEqual(m.items[0].look?.glow, 0.9,
                       "navigation must not rewrite the shared baseline on every step")
    }

    // MARK: Merging while ON

    func testMergeUsesSharedLookAndPreservesStoredOnes() async {
        var seenLooks: [String: Double] = [:]
        let m = stubbedModel()
        m.synthesizeBuffer = { sdr, look, _ in
            seenLooks[sdr.lastPathComponent] = look.glow
            return AutoHDR.RawBuffer(data: Data(), width: 4, height: 4)
        }
        m.addFiles([url("a"), url("b")])
        m.bloom.glow = 0.3
        m.selectNext(); m.selectPrevious()        // commit 0.3 onto both on-leave
        XCTAssertEqual(m.items[1].look?.glow, 0.3)

        m.setSameLookForAll(true)
        m.bloom.glow = 1.4                        // shared look ≠ stored looks
        await m.exportAll()

        XCTAssertEqual(seenLooks["a.jpg"] ?? 0, 1.4, accuracy: 1e-9)
        XCTAssertEqual(seenLooks["b.jpg"] ?? 0, 1.4, accuracy: 1e-9)
        XCTAssertEqual(m.items[0].look?.glow, 0.3, "stored per-photo looks stay preserved")
        XCTAssertEqual(m.items[1].look?.glow, 0.3, "stored per-photo looks stay preserved")
    }

    func testExportAllTargetsDoneItemsAndSnapshotsLook() async {
        var runLooks: [Double] = []
        let m = stubbedModel()
        m.addFiles([url("a"), url("b")])
        await m.mergeItem(m.items[0].id)          // a is .done before the batch
        XCTAssertEqual(m.savedCount, 1)

        m.setSameLookForAll(true)
        m.bloom.glow = 1.0
        m.synthesizeBuffer = { [weak m] sdr, look, _ in
            runLooks.append(look.glow)
            // Sabotage: mutate the live look mid-batch — the snapshot must win.
            Task { @MainActor in m?.bloom.glow = 0.1 }
            return AutoHDR.RawBuffer(data: Data(), width: 4, height: 4)
        }
        await m.exportAll()

        XCTAssertEqual(runLooks.count, 2, "done items are re-exported while ON")
        XCTAssertEqual(runLooks, [1.0, 1.0], "every job sees the snapshotted look")
        XCTAssertTrue(m.canExportAll, "re-export stays available while ON")
    }

    // MARK: Shared-mode transitions

    func testDisableFreezesSharedLookOntoEveryPhoto() {
        let m = stubbedModel()
        m.addFiles([url("a"), url("b")])
        m.bloom.glow = 0.3
        m.selectNext()                            // commits 0.3 onto a; b owns nothing yet
        m.bloom.glow = 0.6
        m.selectPrevious()                        // commits 0.6 onto b; back on a (0.3)

        m.setSameLookForAll(true)
        m.bloom.glow = 1.5                        // shared look

        m.setSameLookForAll(false)
        XCTAssertEqual(m.bloom.glow, 1.5, accuracy: 1e-9,
                       "disable keeps exactly what was visible")
        XCTAssertEqual(m.items[0].look?.glow ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(m.items[1].look?.glow ?? 0, 1.5, accuracy: 1e-9,
                       "every photo starts from the shared look")
        m.selectNext()
        XCTAssertEqual(m.bloom.glow, 1.5, accuracy: 1e-9)
        m.bloom.glow = 0.8
        m.selectPrevious()
        XCTAssertEqual(m.bloom.glow, 1.5, accuracy: 1e-9,
                       "photos can diverge independently after disabling")
    }

    func testEnableAppliesCurrentLookToEveryPhotoImmediately() {
        let m = stubbedModel()
        m.addFiles([url("a"), url("b")])
        m.bloom.glow = 0.7                        // live edit, never committed (look == nil)
        m.setSameLookForAll(true)
        XCTAssertEqual(m.items[0].look?.glow, 0.7)
        XCTAssertEqual(m.items[1].look?.glow, 0.7,
                       "the selected/current look becomes the durable unified baseline")
        XCTAssertEqual(m.intensity, 1.0, accuracy: 1e-9, "the shared look re-anchors to 100%")
    }

    func testDifferentEffectiveLooksRequireConfirmation() {
        let m = stubbedModel()
        m.addFiles([url("a"), url("b")])
        XCTAssertFalse(m.needsSameLookForAllConfirmation)
        m.bloom.glow = 0.3
        m.selectNext()
        m.bloom.glow = 1.1
        m.selectPrevious()
        XCTAssertTrue(m.needsSameLookForAllConfirmation)
    }

    func testDifferentHiddenDialsStillRequireConfirmationWhileLookIsOff() {
        let m = stubbedModel()
        m.addFiles([url("a"), url("b")])
        m.setHDRLookEnabled(false)
        m.bloom.glow = 0.3
        m.selectNext()
        m.bloom.glow = 1.1
        m.selectPrevious()
        XCTAssertTrue(m.needsSameLookForAllConfirmation,
                      "enabling shared mode will replace those unique saved settings")
    }

    func testHDRLookTogglePreservesDialsIntensityAndBakeChoice() {
        let m = stubbedModel()
        m.addFiles([url("a")])
        m.setIntensity(0.42)
        m.bloom.bakeGlowIntoSDR = true
        let dialed = m.bloom

        m.setHDRLookEnabled(false)
        XCTAssertFalse(m.bloom.hdrLookEnabled)
        XCTAssertEqual(m.intensity, 0.42, accuracy: 1e-9)
        XCTAssertEqual(m.bloom.glow, dialed.glow, accuracy: 1e-9)
        XCTAssertTrue(m.bloom.bakeGlowIntoSDR, "OFF remembers the bake preference")

        m.setHDRLookEnabled(true)
        XCTAssertEqual(m.bloom, dialed, "ON restores the exact dialed look")
        XCTAssertEqual(m.intensity, 0.42, accuracy: 1e-9)
    }

    func testDisabledHDRLookSuppressesSDRBakeDuringExport() async {
        var plainCalls = 0
        var bakeCalls = 0
        var seen: AutoHDR.BloomParams?
        let m = stubbedModel()
        m.synthesizeBuffer = { _, look, _ in
            plainCalls += 1
            seen = look
            return AutoHDR.RawBuffer(data: Data(), width: 4, height: 4)
        }
        m.synthesizeBakeInputs = { sdr, _, _ in
            bakeCalls += 1
            return AutoHDR.UltraHDRInputs(
                hdr: AutoHDR.RawBuffer(data: Data(), width: 4, height: 4),
                sdrJPEG: sdr)
        }
        m.addFiles([url("a")])
        m.bloom.bakeGlowIntoSDR = true
        m.setHDRLookEnabled(false)
        await m.mergeItem(m.items[0].id)

        XCTAssertEqual(plainCalls, 1)
        XCTAssertEqual(bakeCalls, 0, "OFF must suppress Glow in SDR")
        XCTAssertFalse(seen?.hdrLookEnabled ?? true)
        XCTAssertTrue(seen?.bakeGlowIntoSDR ?? false,
                      "the export bypass must not discard the remembered preference")
    }

    // MARK: Stopping a re-export can't destroy the previous export (Codex High #2)

    func testCancelledReexportKeepsPriorFileAndStatus() async {
        let m = stubbedModel()
        m.addFiles([url("a")])
        await m.mergeItem(m.items[0].id)          // real (stub) file lands
        let out = try! XCTUnwrap(m.items[0].outputURL)
        let priorReadout = m.items[0].readout
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))

        m.setSameLookForAll(true)
        // Re-export inside a cancelled task: the tool reports failure ("Stopped.").
        m.runTool = { _ in .failure(message: "Stopped.") }
        let task = Task { await m.mergeItem(m.items[0].id) }
        task.cancel()
        await task.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path),
                      "the previous good export must survive a stopped re-export")
        XCTAssertEqual(m.items[0].status, .done, "prior status restored, not reset to pending")
        XCTAssertEqual(m.items[0].outputURL, out)
        XCTAssertEqual(m.items[0].readout, priorReadout)
    }

    // MARK: Guards & counters

    func testToggleIsNoOpWhileExporting() async {
        let m = stubbedModel()
        m.addFiles([url("a"), url("b")])
        m.setSameLookForAll(true)
        m.runTool = { job in
            try? await Task.sleep(nanoseconds: 40_000_000)
            try? Data("stub".utf8).write(to: job.out)
            return .success(output: job.out, readout: nil)
        }
        m.startExportAll()
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(m.isExportingAll)
        m.setSameLookForAll(false)
        XCTAssertTrue(m.sameLookForAll, "flipping mid-batch must be a model-level no-op")
        while m.isExportingAll { await Task.yield() }
        XCTAssertEqual(m.batchTotal, 0, "counters reset after the run")
    }

    func testDirectAwaitExportAllOwnsBusyStateAndBlocksInboundReload() async {
        let m = stubbedModel()
        m.addFiles([url("a"), url("b")])
        m.runTool = { job in
            try? await Task.sleep(nanoseconds: 60_000_000)
            try? Data("stub".utf8).write(to: job.out)
            return .success(output: job.out, readout: nil)
        }
        let originalTitle = m.session.title
        var remote = m.session
        remote.title = "Inbound during export"

        let task = Task { await m.exportAll() }
        while !m.isExportingAll { await Task.yield() }
        m.reloadFromRemote(remote)
        XCTAssertEqual(m.session.title, originalTitle,
                       "an inbound materialization cannot replace batch state")
        await task.value
        XCTAssertFalse(m.isExportingAll)

        m.reloadFromRemote(remote)
        XCTAssertEqual(m.session.title, "Inbound during export",
                       "the same inbound state applies once the batch is idle")
    }

    func testEnableWithEmptyQueueIsHarmless() {
        let m = MergeModel()
        m.setSameLookForAll(true)
        XCTAssertTrue(m.sameLookForAll)
        m.setSameLookForAll(false)
        XCTAssertFalse(m.sameLookForAll)
    }

    func testSharedBakeRoutesEveryItemThroughBakePath() async {
        var bakeCalls: [String] = []
        let m = stubbedModel()
        m.synthesizeBakeInputs = { sdr, _, _ in
            bakeCalls.append(sdr.lastPathComponent)
            return AutoHDR.UltraHDRInputs(hdr: AutoHDR.RawBuffer(data: Data(), width: 4, height: 4),
                                          sdrJPEG: sdr)
        }
        m.addFiles([url("a"), url("b")])
        m.setSameLookForAll(true)
        m.bloom.bakeGlowIntoSDR = true
        await m.exportAll()
        XCTAssertEqual(bakeCalls.sorted(), ["a.jpg", "b.jpg"],
                       "shared Glow-in-SDR must bake every photo in the batch")
    }
}
