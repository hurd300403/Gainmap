//
//  MergeStateMachineTests.swift
//  GainmapTests
//
//  Tests for MergeModel's merge state machine (mergeItem / exportAll), using
//  the injected runTool / synthesizeBuffer seams so no Core Image rendering or
//  uhdrtool process is involved.
//

import XCTest
@testable import Gainmap

@MainActor
final class MergeStateMachineTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).jpg") }

    /// A model whose synthesis is a no-op and whose tool returns `outcome`.
    private func stubbedModel(outcome: @escaping @Sendable (UHDRRunner.Job) -> RunOutcome) -> MergeModel {
        let m = MergeModel()
        m.synthesizeBuffer = { sdr, _, _ in
            AutoHDR.RawBuffer(url: sdr.appendingPathExtension("raw"), width: 4, height: 4)
        }
        m.synthesizeBakeInputs = { sdr, _, _ in
            AutoHDR.UltraHDRInputs(hdr: AutoHDR.RawBuffer(url: sdr.appendingPathExtension("raw"),
                                                          width: 4, height: 4),
                                   sdrJPEG: sdr)
        }
        m.runTool = { job in outcome(job) }
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
            merged.append(job.out.lastPathComponent)
            return .success(output: job.out, readout: nil)
        }
        await m.exportAll()

        XCTAssertEqual(merged, ["a_UltraHDR.jpg", "c_UltraHDR.jpg"], "done items are not re-merged")
        XCTAssertEqual(m.savedCount, 3)
        XCTAssertEqual(m.pendingCount, 0)
    }

    func testMergeUsesLiveLookForSelectedPhoto() async {
        var seenLook: AutoHDR.BloomParams?
        let m = stubbedModel { job in .success(output: job.out, readout: nil) }
        m.synthesizeBuffer = { sdr, look, _ in
            seenLook = look
            return AutoHDR.RawBuffer(url: sdr.appendingPathExtension("raw"), width: 4, height: 4)
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
