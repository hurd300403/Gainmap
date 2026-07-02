//
//  GlowBakeTests.swift
//  GainmapTests
//
//  The GLOW-IN-SDR bake contract: the fallback SDR is the ORIGINAL edit plus
//  only the soft haze. The old bake tone-mapped the full HDR rendition (headroom
//  lift included) into [0,1], which overexposed highlights and boosted contrast
//  on every non-HDR screen — these tests pin the new behavior so it can't creep
//  back.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Gainmap

final class GlowBakeTests: XCTestCase {

    // MARK: Helpers

    /// Write a JPEG filled by `paint` (sRGB), return its URL.
    private func makeJPEG(w: Int, h: Int, paint: (CGContext) -> Void) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        paint(ctx)
        let cg = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-bake-test-\(UUID().uuidString).jpg")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.98] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Decode a JPEG and sample the sRGB value (0…1) of one channel at (x, y).
    private func sample(_ url: URL, x: Int, y: Int) throws -> Double {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height,
                                          bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let buf = try XCTUnwrap(ctx.data).bindMemory(to: UInt8.self, capacity: cg.width * cg.height * 4)
        return Double(buf[(y * cg.width + x) * 4]) / 255
    }

    private func bake(_ sdr: URL, _ p: AutoHDR.BloomParams) throws -> URL {
        let inputs = try AutoHDR.synthesizeInputs(from: sdr, params: p)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: inputs.hdr.url)
            try? FileManager.default.removeItem(at: inputs.sdrJPEG)
        }
        return inputs.sdrJPEG
    }

    // MARK: The contract

    /// Where nothing glows, the baked SDR must keep the edit's tonality EXACTLY —
    /// the old tone-mapped bake lifted this bright gray ~10–15% via headroom.
    func testBakePreservesTonalityWhereNoGlow() throws {
        let gray = 0.90
        let sdr = try makeJPEG(w: 96, h: 96) { ctx in
            ctx.setFillColor(CGColor(gray: gray, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }
        var p = AutoHDR.signatureLook       // glow 1.5, headroom 1.5 — the works
        p.threshold = 0.95                  // …but nothing crosses the knee
        p.bakeGlowIntoSDR = true

        let out = try bake(sdr, p)
        let v = try sample(out, x: 48, y: 48)
        XCTAssertEqual(v, gray, accuracy: 0.03,
                       "no-glow regions must pass through untouched (old bake lifted them)")
    }

    /// The haze itself must still land: pixels beside a bright patch pick up glow,
    /// far-away shadows stay black, and nothing exceeds white.
    func testBakeAddsOnlyTheHaze() throws {
        let sdr = try makeJPEG(w: 96, h: 96) { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 36, y: 36, width: 24, height: 24))
        }
        var p = AutoHDR.BloomParams()
        p.glow = 1.2; p.threshold = 0.5; p.spread = 0.05; p.headroom = 1.5
        p.bakeGlowIntoSDR = true

        let out = try bake(sdr, p)
        let nearPatch = try sample(out, x: 33, y: 48)   // 3px outside the patch
        let farCorner = try sample(out, x: 4, y: 4)
        let inPatch = try sample(out, x: 48, y: 48)

        XCTAssertGreaterThan(nearPatch, 0.06, "the soft haze must spill just outside the highlight")
        XCTAssertLessThan(farCorner, 0.03, "shadows away from highlights stay untouched")
        XCTAssertLessThanOrEqual(inPatch, 1.0, "screen blend can never clip past white")
    }
}
