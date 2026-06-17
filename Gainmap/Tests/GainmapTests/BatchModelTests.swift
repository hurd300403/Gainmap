//
//  BatchModelTests.swift
//  GainmapTests
//
//  Tests for the auto-mode batch queue logic in MergeModel (selection, look
//  inheritance / carry-forward, dedup, removal) and the new TINT look control.
//  Run in Xcode with ⌘U.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreImage
@testable import Gainmap

@MainActor
final class BatchModelTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).jpg") }

    // MARK: Queue building

    func testAddFilesDedupsByPath() {
        let m = MergeModel()
        m.addFiles([url("a"), url("b"), url("a")])   // "a" twice
        XCTAssertEqual(m.items.count, 2)
        XCTAssertEqual(m.items.map(\.sdrURL.lastPathComponent), ["a.jpg", "b.jpg"])
    }

    func testAddFilesIgnoresNonJPEG() {
        let m = MergeModel()
        m.addFiles([url("a"), URL(fileURLWithPath: "/tmp/c.tif"), URL(fileURLWithPath: "/tmp/d.png")])
        XCTAssertEqual(m.items.count, 1)
    }

    func testFirstAddedIsSelected() {
        let m = MergeModel()
        m.addFiles([url("a"), url("b")])
        XCTAssertEqual(m.selectedID, m.items.first?.id)
        XCTAssertEqual(m.sdrURL, m.items.first?.sdrURL)
    }

    // MARK: Navigation

    func testNextPreviousBounds() {
        let m = MergeModel()
        m.addFiles([url("a"), url("b"), url("c")])
        XCTAssertFalse(m.hasPrevious)
        XCTAssertTrue(m.hasNext)
        m.selectNext(); m.selectNext()
        XCTAssertEqual(m.selectedIndex, 2)
        XCTAssertTrue(m.hasPrevious)
        XCTAssertFalse(m.hasNext)
        m.selectNext()  // no-op past the end
        XCTAssertEqual(m.selectedIndex, 2)
    }

    // MARK: Look inheritance / carry-forward

    func testUntouchedPhotoInheritsRunningLook() {
        let m = MergeModel()
        m.addFiles([url("a"), url("b")])
        // Dial the look on photo A.
        m.bloom.glow = 1.3
        XCTAssertEqual(m.runningLook.glow, 1.3, accuracy: 1e-9)
        XCTAssertEqual(m.items[0].look?.glow, 1.3)   // A now has its own look
        // Move to B (untouched) — it should arrive at A's dialed look.
        m.selectNext()
        XCTAssertEqual(m.bloom.glow, 1.3, accuracy: 1e-9)
        XCTAssertNil(m.items[1].look)                // still inheriting until tweaked
    }

    func testTweakingKeepsPerPhotoLook() {
        let m = MergeModel()
        m.addFiles([url("a"), url("b")])
        m.bloom.glow = 1.3            // A = 1.3
        m.selectNext()
        m.bloom.glow = 0.5           // B = 0.5 (now customized)
        XCTAssertEqual(m.items[1].look?.glow, 0.5)
        m.selectPrevious()           // back to A
        XCTAssertEqual(m.bloom.glow, 1.3, accuracy: 1e-9)   // A unchanged
        m.selectNext()               // back to B
        XCTAssertEqual(m.bloom.glow, 0.5, accuracy: 1e-9)   // B remembered
    }

    // MARK: Removal

    func testRemoveSelectedMovesToNeighbor() {
        let m = MergeModel()
        m.addFiles([url("a"), url("b"), url("c")])
        m.selectNext()                       // select B
        m.remove(m.items[1].id)              // remove B
        XCTAssertEqual(m.items.count, 2)
        XCTAssertEqual(m.selectedItem?.sdrURL.lastPathComponent, "c.jpg")  // slid to C
    }

    func testRemoveLastClearsSelection() {
        let m = MergeModel()
        m.addFiles([url("a")])
        m.remove(m.items[0].id)
        XCTAssertTrue(m.items.isEmpty)
        XCTAssertNil(m.selectedID)
        XCTAssertNil(m.sdrURL)
    }

    // MARK: TINT look control

    func testTintDefaultsNeutral() {
        XCTAssertEqual(AutoHDR.BloomParams().tint, 0.0)
    }

    /// A warm tint must push the synthesized glow redder than a cool tint.
    func testWarmTintShiftsGlowRedderThanCool() throws {
        let jpeg = try makeGradientJPEG(w: 96, h: 64)
        defer { try? FileManager.default.removeItem(at: jpeg) }

        var warm = AutoHDR.BloomParams(); warm.glow = 1.2; warm.threshold = 0.3; warm.tint = 0.9
        var cool = warm; cool.tint = -0.9

        let warmRB = try redMinusBluePeak(of: jpeg, params: warm)
        let coolRB = try redMinusBluePeak(of: jpeg, params: cool)
        XCTAssertGreaterThan(warmRB, coolRB,
            "warm tint should raise red relative to blue more than cool tint")
    }

    // MARK: Helpers

    /// Peak (R-B) of the synthesized HDR buffer — positive = warmer glow.
    private func redMinusBluePeak(of sdr: URL, params: AutoHDR.BloomParams) throws -> Float {
        let buf = try AutoHDR.synthesize(from: sdr, params: params)
        defer { try? FileManager.default.removeItem(at: buf.url) }
        let data = try Data(contentsOf: buf.url)
        // RGBA f16, 8 bytes/pixel.
        return data.withUnsafeBytes { raw -> Float in
            let halfs = raw.bindMemory(to: UInt16.self)
            var best: Float = -.greatestFiniteMagnitude
            let pixels = halfs.count / 4
            for i in 0..<pixels {
                let r = float(fromHalf: halfs[i * 4])
                let b = float(fromHalf: halfs[i * 4 + 2])
                best = max(best, r - b)
            }
            return best
        }
    }

    /// Minimal IEEE-754 half → float decode for reading the f16 buffer.
    private func float(fromHalf h: UInt16) -> Float {
        let sign = Float((h >> 15) & 0x1) == 0 ? 1 : -1
        let exp = Int((h >> 10) & 0x1F)
        let frac = Int(h & 0x3FF)
        if exp == 0 { return Float(sign) * Float(frac) * pow(2, -24) }
        if exp == 0x1F { return frac == 0 ? Float(sign) * .infinity : .nan }
        return Float(sign) * Float(1024 + frac) / 1024 * pow(2, Float(exp - 15))
    }

    // MARK: Non-HDR-screen (SDR fallback) preview

    /// The SDR fallback the preview shows must land in SDR range (≤ ~1.0) — that's
    /// what guarantees it looks different from the HDR pop on ANY display, unlike
    /// the old headroom clamp which no-op'd above the panel's headroom. Renders a
    /// real bloom (extended values up to ~peak·headroom) through sdrFallbackCIImage
    /// and confirms the shoulder pulls the peak back into SDR.
    func testSDRFallbackLandsInSDRRange() throws {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let ctx = CIContext(options: [.workingColorSpace: space])
        let base = CIImage(contentsOf: try makeGradientJPEG(w: 64, h: 8))!

        func maxChannel(_ img: CIImage) -> Float {
            let w = Int(img.extent.width), h = Int(img.extent.height)
            var px = [Float](repeating: 0, count: w * h * 4)
            ctx.render(img, toBitmap: &px, rowBytes: w * 16, bounds: img.extent,
                       format: .RGBAf, colorSpace: space)
            return stride(from: 0, to: px.count, by: 4).reduce(Float(0)) {
                max($0, max(px[$1], max(px[$1 + 1], px[$1 + 2])))
            }
        }

        var p = AutoHDR.BloomParams()
        p.glow = 1.5; p.headroom = 1.5     // a strong look → bloom peaks well above 1.0

        // The raw HDR bloom exceeds SDR white…
        let bloom = try XCTUnwrap(AutoHDR.bloomCIImage(base: base, params: p))
        XCTAssertGreaterThan(maxChannel(bloom), 1.05, "bloom proxy should exceed SDR white")

        // …but the baked SDR fallback is shouldered back into SDR range.
        let baked = try XCTUnwrap(AutoHDR.sdrFallbackCIImage(base: base, params: p, bake: true))
        XCTAssertLessThanOrEqual(maxChannel(baked), 1.02, "baked SDR fallback must stay ≤ ~1.0")

        // With bake OFF the fallback is the untouched base (also SDR).
        let plain = try XCTUnwrap(AutoHDR.sdrFallbackCIImage(base: base, params: p, bake: false))
        XCTAssertLessThanOrEqual(maxChannel(plain), 1.02, "un-baked fallback is the SDR base")
    }

    /// A horizontal black→white gradient JPEG, so highlights exist above the knee.
    private func makeGradientJPEG(w: Int, h: Int) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in 0..<w {
            let v = CGFloat(x) / CGFloat(w - 1)
            ctx.setFillColor(red: v, green: v, blue: v, alpha: 1)
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
        }
        let cg = ctx.makeImage()!
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-test-\(UUID().uuidString).jpg")
        let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return out
    }
}
