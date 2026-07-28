//
//  UHDRRunnerTests.swift
//  GainmapTests
//
//  Unit tests for the pure (non-side-effecting) logic in UHDRRunner: file-role
//  classification, argv construction, output-path derivation, stderr clamp
//  parsing, and outcome mapping. Run in Xcode with ⌘U.
//

import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import GainmapCore

final class UHDRRunnerTests: XCTestCase {

    // MARK: File role

    func testRoleByExtension() {
        XCTAssertEqual(FileRole.role(for: URL(fileURLWithPath: "/a/b.tif")), .hdr)
        XCTAssertEqual(FileRole.role(for: URL(fileURLWithPath: "/a/b.TIFF")), .hdr)
        XCTAssertEqual(FileRole.role(for: URL(fileURLWithPath: "/a/b.jpg")), .sdr)
        XCTAssertEqual(FileRole.role(for: URL(fileURLWithPath: "/a/b.JPEG")), .sdr)
        XCTAssertNil(FileRole.role(for: URL(fileURLWithPath: "/a/b.png")))
        XCTAssertNil(FileRole.role(for: URL(fileURLWithPath: "/a/b.heic")))
    }

    // MARK: Arguments

    func testArgumentsTiffSource() {
        let job = UHDRRunner.Job(
            hdr: .tiff(URL(fileURLWithPath: "/in/shot hdr.tif")),   // note the space
            sdr: URL(fileURLWithPath: "/in/shot sdr.jpg"),
            out: URL(fileURLWithPath: "/out/shot_UltraHDR.jpg"),
            cgamut: .displayP3, sgamut: .rec2020)
        XCTAssertEqual(UHDRRunner.arguments(for: job), [
            "--hdr", "/in/shot hdr.tif",
            "--sdr", "/in/shot sdr.jpg",
            "--out", "/out/shot_UltraHDR.jpg",
            "--cgamut", "1",
            "--sgamut", "2",
        ])
    }

    func testArgumentsRawSource() {
        let job = UHDRRunner.Job(
            hdr: .raw(URL(fileURLWithPath: "/tmp/buf.rawf16"), w: 6000, h: 4000),
            sdr: URL(fileURLWithPath: "/in/shot.jpg"),
            out: URL(fileURLWithPath: "/out/shot_UltraHDR.jpg"))
        XCTAssertEqual(UHDRRunner.arguments(for: job), [
            "--raw-hdr", "/tmp/buf.rawf16", "--raw-w", "6000", "--raw-h", "4000",
            "--sdr", "/in/shot.jpg",
            "--out", "/out/shot_UltraHDR.jpg",
            "--cgamut", "0",
            "--sgamut", "0",
        ])
    }

    // MARK: Output path

    func testDefaultOutputURL() {
        let sdr = URL(fileURLWithPath: "/Users/x/Pictures/sunset-ridge_sdr.jpg")
        let out = UHDRRunner.defaultOutputURL(forSDR: sdr)
        XCTAssertEqual(out.lastPathComponent, "sunset-ridge_sdr_UltraHDR.jpg")
        XCTAssertEqual(out.deletingLastPathComponent().path, "/Users/x/Pictures")
    }

    // MARK: Gamut mapping

    func testGamutRawValues() {
        XCTAssertEqual(Gamut.rec709.rawValue, 0)
        XCTAssertEqual(Gamut.displayP3.rawValue, 1)
        XCTAssertEqual(Gamut.rec2020.rawValue, 2)
        XCTAssertEqual(Gamut.rec709.sdrLabel, "sRGB")
        XCTAssertEqual(Gamut.rec709.hdrLabel, "Rec.709")
    }

    // MARK: Clamp parsing

    func testParseClampsRealLine() {
        let stderr = """
        hdr: 6000x4000 RGBA f16 (192000000 bytes)
        clamps: peak=3.973 (1.99 stops)  K=4.171  L=806
        wrote /out/shot_UltraHDR.jpg
        """
        let c = UHDRRunner.parseClamps(stderr)
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.peakBoost ?? 0, 3.973, accuracy: 0.0001)
        XCTAssertEqual(c?.stops ?? 0, 1.99, accuracy: 0.0001)
        XCTAssertEqual(c?.maxBoost ?? 0, 4.171, accuracy: 0.0001)
        XCTAssertEqual(c?.targetNits, 806)
    }

    func testParseClampsMissing() {
        XCTAssertNil(UHDRRunner.parseClamps("error: --hdr is required\n"))
    }

    // MARK: Outcome

    func testOutcomeSuccess() {
        let out = URL(fileURLWithPath: "/out/x.jpg")
        let outcome = UHDRRunner.parseOutcome(
            exitCode: 0,
            stderr: "clamps: peak=2.0 (1.00 stops)  K=2.1  L=406\nwrote /out/x.jpg\n",
            output: out)
        guard case let .success(url, readout) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(url, out)
        XCTAssertEqual(readout?.targetNits, 406)
    }

    func testOutcomeFailureSurfacesToolError() {
        let outcome = UHDRRunner.parseOutcome(
            exitCode: 1,
            stderr: "hdr: 6000x4000 RGBA f16\nerror: dimension mismatch: SDR JPEG is 6000x4000 but HDR TIFF is 3000x2000; both renditions must export at the same resolution\n",
            output: URL(fileURLWithPath: "/out/x.jpg"))
        guard case let .failure(message) = outcome else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(message.hasPrefix("dimension mismatch:"), "got: \(message)")
        XCTAssertFalse(message.contains("error:"), "the error: prefix should be stripped")
    }

    func testOutcomeFailureNoErrorLine() {
        let outcome = UHDRRunner.parseOutcome(
            exitCode: 2, stderr: "garbage\n", output: URL(fileURLWithPath: "/o.jpg"))
        guard case let .failure(message) = outcome else { return XCTFail() }
        XCTAssertTrue(message.contains("code 2"))
    }

    // MARK: Export path responds to the sliders (real AutoHDR.synthesize)

    func testSynthesizeRespondsToGlow() throws {
        let jpg = try makeHighlightJPEG()
        defer { try? FileManager.default.removeItem(at: jpg) }
        var low = AutoHDR.BloomParams();  low.glow = 0.2
        var high = low;                   high.glow = 1.3
        let bLow = try AutoHDR.synthesize(from: jpg, params: low)
        let bHigh = try AutoHDR.synthesize(from: jpg, params: high)
        defer { try? FileManager.default.removeItem(at: bLow.url); try? FileManager.default.removeItem(at: bHigh.url) }
        let mLow = maxHalf(bLow.url), mHigh = maxHalf(bHigh.url)
        XCTAssertGreaterThan(mLow, 1.0, "any glow should push highlights past SDR white")
        XCTAssertGreaterThan(mHigh, mLow + 0.1, "more Glow must produce a meaningfully brighter export")
    }

    func testSynthesizeRespondsToThreshold() throws {
        let jpg = try makeHighlightJPEG()
        defer { try? FileManager.default.removeItem(at: jpg) }
        var open = AutoHDR.BloomParams(); open.glow = 1.2; open.threshold = 0.30
        var tight = open;                 tight.threshold = 0.95
        let bOpen = try AutoHDR.synthesize(from: jpg, params: open)
        let bTight = try AutoHDR.synthesize(from: jpg, params: tight)
        defer { try? FileManager.default.removeItem(at: bOpen.url); try? FileManager.default.removeItem(at: bTight.url) }
        // Lower threshold (more of the frame glows) must produce a stronger lift.
        XCTAssertGreaterThan(maxHalf(bOpen.url), maxHalf(bTight.url) + 0.1)
    }

    /// Max half-float channel value in a raw RGBA f16 buffer file.
    private func maxHalf(_ url: URL) -> Float {
        guard let d = try? Data(contentsOf: url) else { return -1 }
        var m: Float = 0
        d.withUnsafeBytes { raw in
            let u = raw.bindMemory(to: UInt16.self)
            for i in 0..<u.count { let f = Float(Float16(bitPattern: u[i])); if f > m { m = f } }
        }
        return m
    }

    /// A 256×256 mid-gray JPEG with a bright near-white square (highlight region).
    private func makeHighlightJPEG() throws -> URL {
        let w = 256, h = 256
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let bright = (x >= 80 && x < 176 && y >= 80 && y < 176)
                let v: UInt8 = bright ? 252 : 90
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = px.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        }
        let cg = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testSmoothstepEndpoints() {
        XCTAssertEqual(AutoHDR.smoothstep(0, 1, -0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(AutoHDR.smoothstep(0, 1, 1.5), 1, accuracy: 1e-9)
        XCTAssertEqual(AutoHDR.smoothstep(0, 1, 0.5), 0.5, accuracy: 1e-9)
    }

    // MARK: BloomParams Codable migration (forward/backward compatible)

    func testBloomParamsDecodesLegacyJSONWithRemovedAndMissingKeys() throws {
        // A saved look from an older build: it still carries the removed AUTO keys
        // (autoAdapt/adaptAmount/highlightGuard) and lacks the newer bakeGlowIntoSDR.
        // It must decode cleanly (NOT throw — SignatureStore.load swallows throws and
        // would silently wipe the user's saved default), keep the known values, drop
        // the dead keys, and default bake OFF.
        let legacy = """
        {"glow":1.25,"threshold":0.7,"spread":0.02,"punch":0.4,"peak":3.5,
         "falloff":1.3,"saturation":0.8,"tint":-0.5,"headroom":1.8,
         "autoAdapt":true,"adaptAmount":1.0,"highlightGuard":0.19}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(AutoHDR.BloomParams.self, from: legacy)
        XCTAssertEqual(p.glow, 1.25, accuracy: 1e-9)
        XCTAssertEqual(p.headroom, 1.8, accuracy: 1e-9)
        XCTAssertEqual(p.tint, -0.5, accuracy: 1e-9)
        XCTAssertFalse(p.bakeGlowIntoSDR, "a missing bake key must default OFF")
    }

    func testBloomParamsRoundTripsBakeAndDropsDeadKeys() throws {
        var p = AutoHDR.BloomParams(); p.bakeGlowIntoSDR = true; p.glow = 0.9
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(AutoHDR.BloomParams.self, from: data)
        XCTAssertEqual(p, back)
        XCTAssertTrue(back.bakeGlowIntoSDR)
        // The removed AUTO fields are no longer emitted.
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("autoAdapt"))
    }

    // MARK: Live preview responds to the slider

    /// The proxy preview IS AutoHDR.bloomCIImage (the exact graph the export
    /// renders), so it must respond visibly to the look params.
    func testProxyPreviewRespondsToParams() throws {
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 96, height: 96))
        let midHighlight = CIImage(color: CIColor(red: 0.72, green: 0.66, blue: 0.58))
            .cropped(to: CGRect(x: 20, y: 20, width: 56, height: 56))
        let base = midHighlight.composited(over: black)

        var subtle = AutoHDR.BloomParams()
        subtle.glow = 0.0

        var visible = AutoHDR.BloomParams()
        visible.glow = 1.0
        visible.threshold = 0.45
        visible.spread = 0.02
        visible.peak = 4.0

        let low = mean(try XCTUnwrap(AutoHDR.bloomCIImage(base: base, params: subtle)))
        let high = mean(try XCTUnwrap(AutoHDR.bloomCIImage(base: base, params: visible)))
        XCTAssertGreaterThan(high, low + 0.01, "look params must visibly affect the live preview")
    }

    /// Mean brightness of a CIImage via CIAreaAverage → 1×1 readback.
    private func mean(_ image: CIImage) -> Double {
        let ctx = CIContext()
        let avg = CIFilter.areaAverage()
        avg.inputImage = image
        avg.extent = image.extent
        guard let out = avg.outputImage,
              let cg = ctx.createCGImage(out, from: CGRect(x: 0, y: 0, width: 1, height: 1))
        else { return -1 }
        var px = [UInt8](repeating: 0, count: 4)
        let bm = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bm.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(px[0]) + Double(px[1]) + Double(px[2])) / 3 / 255
    }
}

// MARK: - Queue intake (drop feedback + double-merge guard)

final class QueueIntakeTests: XCTestCase {

    func testMergedOutputNameDetected() {
        XCTAssertTrue(UHDRRunner.nameLooksLikeMergedOutput(
            URL(fileURLWithPath: "/tmp/wedding 042_UltraHDR.jpg")))
        XCTAssertFalse(UHDRRunner.nameLooksLikeMergedOutput(
            URL(fileURLWithPath: "/tmp/wedding 042.jpg")))
        // The suffix must be at the END of the basename, not merely present.
        XCTAssertFalse(UHDRRunner.nameLooksLikeMergedOutput(
            URL(fileURLWithPath: "/tmp/x_UltraHDR_final.jpg")))
    }

    func testDropNoticeSilentWhenNothingSkipped() {
        XCTAssertNil(MergeModel.dropNoticeText(tiffCount: 0, otherCount: 0))
    }

    func testDropNoticeExplainsSkippedTIFFs() {
        let one = MergeModel.dropNoticeText(tiffCount: 1, otherCount: 0)
        XCTAssertNotNil(one)
        XCTAssertTrue(one!.contains("TIFF"))
        let many = MergeModel.dropNoticeText(tiffCount: 3, otherCount: 0)
        XCTAssertTrue(many!.contains("3"))
    }

    func testDropNoticeForOtherTypes() {
        let out = MergeModel.dropNoticeText(tiffCount: 0, otherCount: 2)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("JPEG"))
    }
}
