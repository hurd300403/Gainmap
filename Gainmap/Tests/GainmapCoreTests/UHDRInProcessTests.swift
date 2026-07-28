//
//  UHDRInProcessTests.swift
//  GainmapCoreTests
//
//  P2 golden parity: the in-process encoder (GMUltraHDR -> encoder.cpp ->
//  vendored libultrahdr) must produce EXACTLY the bytes the bundled uhdrtool
//  CLI produced for the same inputs — the committed golden fixture IS the
//  CLI's output for the committed input pair, so equality here proves the
//  in-process path is a drop-in replacement. Runs identically on macOS and
//  the iOS simulator (S1 proved the engine is byte-identical across all
//  three platforms).
//

import XCTest
@testable import GainmapCore

final class UHDRInProcessTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let bundle = Bundle(for: UHDRInProcessTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "missing fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }

    // MARK: Golden bytes (the P2 exit criterion)

    func testInProcessEncodeMatchesCLIGoldenBytes() throws {
        let hdr = try fixture("golden-512", "rawf16")
        let sdr = try fixture("golden-512-sdr", "jpg")
        let golden = try fixture("golden-512-out", "jpg")

        var clamps: GMUHDRClamps?
        let out = try GMUltraHDR.encode(hdr, width: 512, height: 512,
                                           sdrJPEG: sdr, cgamut: 0, sgamut: 0,
                                           clamps: &clamps)
        XCTAssertEqual(out, golden,
                       "in-process encode must be byte-identical to the CLI's output")

        // The S1/P2-recorded clamps for this fixture.
        let c = try XCTUnwrap(clamps)
        XCTAssertEqual(c.peakBoost, 4.52734375, accuracy: 1e-12)
        XCTAssertEqual(c.maxBoost, 4.754, accuracy: 1e-12)
        XCTAssertEqual(c.targetNits, 919)
    }

    // MARK: Clamp edge cases (histogram semantics)

    /// Build an interleaved RGBA f16 buffer from per-pixel RGB float triples.
    private func buffer(_ rgb: [(Float, Float, Float)]) -> Data {
        var halfs: [UInt16] = []
        halfs.reserveCapacity(rgb.count * 4)
        for (r, g, b) in rgb {
            halfs.append(Float16(r).bitPattern)
            halfs.append(Float16(g).bitPattern)
            halfs.append(Float16(b).bitPattern)
            halfs.append(Float16(1.0).bitPattern)
        }
        return halfs.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func testClampsFloorAtSDRWhite() {
        // Every sample below 1.0 → peak floors at 1.0, L at 203.
        let data = buffer(Array(repeating: (Float(0.5), Float(0.3), Float(0.7)), count: 16))
        let c = GMUltraHDR.clamps(forHDR: data, width: 4, height: 4)
        XCTAssertEqual(c.peakBoost, 1.0)
        XCTAssertEqual(c.stops, 0.0)
        XCTAssertEqual(c.maxBoost, 1.05, accuracy: 1e-12)
        XCTAssertEqual(c.targetNits, 203)
    }

    func testClampsNegativesParticipateWithoutClipping(){
        // The raw-buffer path never clips: negatives sit at the bottom of the
        // ordered population and only shift WHICH sample the 99.9th percentile
        // lands on — uniform 2.0 with a few negatives must still read 2.0.
        var px = Array(repeating: (Float(2.0), Float(2.0), Float(2.0)), count: 99)
        px.append((Float(-1.0), Float(-0.5), Float(-2.0)))
        let data = buffer(px)
        let c = GMUltraHDR.clamps(forHDR: data, width: 10, height: 10)
        XCTAssertEqual(c.peakBoost, 2.0)
        XCTAssertEqual(c.targetNits, 406)
    }

    func testClampsSubnormalsAndUniformPeak() {
        // Subnormal halfs decode as tiny positives — present, floored away.
        var px = Array(repeating: (Float(3.25), Float(3.25), Float(3.25)), count: 64)
        px[0] = (Float(6e-8), Float(1e-7), Float(3.25))   // subnormal territory
        let data = buffer(px)
        let c = GMUltraHDR.clamps(forHDR: data, width: 8, height: 8)
        XCTAssertEqual(c.peakBoost, 3.25)
        XCTAssertEqual(c.maxBoost, 3.412, accuracy: 1e-12)
        XCTAssertEqual(c.targetNits, 660)
    }

    func testClampsNaNSamplesAreExcluded() {
        // NaN carries no ordering — the histogram excludes it from the
        // population (defined P2 behavior; the old sort path was UB on NaN).
        var halfs: [UInt16] = []
        for _ in 0..<32 {
            halfs.append(contentsOf: [Float16(1.5).bitPattern, 0x7E00, // qNaN
                                      Float16(1.5).bitPattern, Float16(1.0).bitPattern])
        }
        let data = halfs.withUnsafeBufferPointer { Data(buffer: $0) }
        let c = GMUltraHDR.clamps(forHDR: data, width: 8, height: 4)
        XCTAssertEqual(c.peakBoost, 1.5)
        // L = 203 * 1.5 = 304.5 → round-half-to-EVEN (the Python oracle) = 304.
        XCTAssertEqual(c.targetNits, 304)
    }

    // MARK: Verbatim errors

    func testDimensionMismatchErrorIsVerbatim() throws {
        let hdr = try fixture("golden-512", "rawf16")
        let sdr = try fixture("golden-512-sdr", "jpg")
        do {
            _ = try GMUltraHDR.encode(hdr, width: 256, height: 1024,
                                         sdrJPEG: sdr, cgamut: 0, sgamut: 0, clamps: nil)
            XCTFail("expected a dimension-mismatch error")
        } catch {
            let msg = (error as NSError).localizedDescription
            XCTAssertTrue(msg.hasPrefix("dimension mismatch:"), "got: \(msg)")
        }
    }

    // MARK: Cancellation (the REAL encoder, not a seam stub)

    /// P2 regression (review finding): cancellation must be live inside the
    /// encoder itself — a detached task would never see it. A cancelled task
    /// gets .failure("Stopped.") and no output file.
    func testCancelledTaskStopsRealEncoderAndWritesNothing() async throws {
        let hdr = try fixture("golden-512", "rawf16")
        let sdrData = try fixture("golden-512-sdr", "jpg")
        let dir = FileManager.default.temporaryDirectory
        let sdrURL = dir.appendingPathComponent("\(UUID().uuidString).jpg")
        let outURL = dir.appendingPathComponent("\(UUID().uuidString)_UltraHDR.jpg")
        try sdrData.write(to: sdrURL)
        defer {
            try? FileManager.default.removeItem(at: sdrURL)
            try? FileManager.default.removeItem(at: outURL)
        }
        let job = UHDRRunner.Job(
            hdr: .rawBuffer(AutoHDR.RawBuffer(data: hdr, width: 512, height: 512)),
            sdr: sdrURL, out: outURL)

        let run = Task { await InProcessEncoder.run(job) }
        run.cancel()   // cancel immediately — any boundary check must catch it
        let outcome = await run.value

        XCTAssertEqual(outcome, .failure(message: "Stopped."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outURL.path),
                       "a stopped encode must not leave an output file")
    }

    // MARK: The seam end-to-end (InProcessEncoder behind runTool)

    func testInProcessEncoderRunWritesOutputAndReadout() async throws {
        let hdr = try fixture("golden-512", "rawf16")
        let sdrData = try fixture("golden-512-sdr", "jpg")
        let golden = try fixture("golden-512-out", "jpg")

        let dir = FileManager.default.temporaryDirectory
        let sdrURL = dir.appendingPathComponent("\(UUID().uuidString).jpg")
        let outURL = dir.appendingPathComponent("\(UUID().uuidString)_UltraHDR.jpg")
        try sdrData.write(to: sdrURL)
        defer {
            try? FileManager.default.removeItem(at: sdrURL)
            try? FileManager.default.removeItem(at: outURL)
        }

        let job = UHDRRunner.Job(
            hdr: .rawBuffer(AutoHDR.RawBuffer(data: hdr, width: 512, height: 512)),
            sdr: sdrURL, out: outURL)
        let outcome = await InProcessEncoder.run(job)

        guard case let .success(url, readout) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(url, outURL)
        XCTAssertEqual(try Data(contentsOf: outURL), golden)
        XCTAssertEqual(readout?.targetNits, 919)
        XCTAssertEqual(readout?.maxBoost ?? 0, 4.754, accuracy: 1e-12)
    }
}
