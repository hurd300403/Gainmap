//
//  MergeStateMachineTests.swift
//  GainmapTests
//
//  Tests for MergeModel's merge state machine (mergeItem / exportAll), using
//  the injected runTool / synthesizeBuffer seams so no Core Image rendering or
//  uhdrtool process is involved.
//

import XCTest
@testable import GainmapCore

@MainActor
final class MergeStateMachineTests: XCTestCase {

    // Isolated working dir: successful merges now MOVE a real temp file into
    // `<base>_UltraHDR.jpg` beside the source, so tests need a disposable home.
    private var workDir: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: MergeModel.sameLookKey)
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-msm-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: MergeModel.sameLookKey)
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        super.tearDown()
    }

    private func url(_ name: String) -> URL { workDir.appendingPathComponent("\(name).jpg") }

    /// A model whose synthesis is a no-op and whose tool "writes" the output
    /// (an empty file at job.out — the atomic-place step requires it to exist)
    /// and returns `outcome`.
    private func stubbedModel(outcome: @escaping @Sendable (UHDRRunner.Job) -> RunOutcome) -> MergeModel {
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

    func testSuccessfulMergeMarksDoneAndMirrorsToBench() async {
        let readout = ClampReadout(peakBoost: 2.0, stops: 1.0, maxBoost: 2.1, targetNits: 406)
        let m = stubbedModel { job in .success(output: job.out, readout: readout) }
        m.addFiles([url("a"), url("b")])

        await m.mergeItem(m.items[0].id)

        XCTAssertEqual(m.items[0].status, .done)
        XCTAssertEqual(m.items[0].outputURL?.lastPathComponent, "a_UltraHDR.jpg")
        XCTAssertEqual(m.items[0].readout, readout)
        XCTAssertNil(m.items[0].error)
        // The selected photo mirrors onto the live bench.
        XCTAssertEqual(m.outputURL?.lastPathComponent, "a_UltraHDR.jpg")
        XCTAssertEqual(m.readout, readout)
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.savedCount, 1)
        XCTAssertEqual(m.pendingCount, 1)
    }

    func testFailedMergeMarksErrorWithToolMessage() async {
        let m = stubbedModel { _ in .failure(message: "cannot open SDR JPEG") }
        m.addFiles([url("a")])

        await m.mergeItem(m.items[0].id)

        XCTAssertEqual(m.items[0].status, .error)
        XCTAssertEqual(m.items[0].error, "cannot open SDR JPEG")
        XCTAssertNil(m.items[0].outputURL)
        XCTAssertEqual(m.errorMessage, "cannot open SDR JPEG")
    }

    func testExportAllMergesOnlyPending() async {
        let m = stubbedModel { job in .success(output: job.out, readout: nil) }
        m.addFiles([url("a"), url("b"), url("c")])
        await m.mergeItem(m.items[1].id)          // b already saved
        XCTAssertEqual(m.savedCount, 1)

        var merged: [String] = []
        m.runTool = { job in
            merged.append(job.sdr.lastPathComponent)   // job.out is now a temp URL
            try? Data("stub".utf8).write(to: job.out)
            return .success(output: job.out, readout: nil)
        }
        await m.exportAll()

        XCTAssertEqual(merged, ["a.jpg", "c.jpg"], "done items are not re-merged")
        XCTAssertEqual(m.savedCount, 3)
        XCTAssertEqual(m.pendingCount, 0)
    }

    func testMergeUsesLiveLookForSelectedPhoto() async {
        var seenLook: AutoHDR.BloomParams?
        let m = stubbedModel { job in .success(output: job.out, readout: nil) }
        m.synthesizeBuffer = { sdr, look, _ in
            seenLook = look
            return AutoHDR.RawBuffer(data: Data(), width: 4, height: 4)
        }
        m.addFiles([url("a")])
        m.bloom.glow = 1.11   // dialed but not yet committed (commit is on-leave)

        await m.mergeItem(m.items[0].id)

        XCTAssertEqual(seenLook?.glow ?? 0, 1.11, accuracy: 1e-9,
                       "merging the on-screen photo must use exactly what's on screen")
        XCTAssertEqual(m.items[0].look?.glow ?? 0, 1.11, accuracy: 1e-9,
                       "the merge commits the live look onto the item")
    }
}
