//
//  MetadataPipelineTests.swift
//  GainmapTests
//
//  Regression tests for two empirically-found export bugs:
//
//  1. GAMUT: libultrahdr hard-fails when --sgamut disagrees with the JPEG's
//     embedded ICC profile ("configured color gamut does not match with color
//     gamut specified in icc box"), so Display P3 exports refused to merge under
//     the old fixed sRGB flag. Gamut.detect must match the profile.
//
//  2. METADATA: Core Image's JPEG writer drops every property, so the bake-on
//     temp SDR (which libultrahdr passes through into the final export) used to
//     ship stripped of copyright/orientation and squeezed to sRGB.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Gainmap

final class MetadataPipelineTests: XCTestCase {

    // MARK: Fixture

    /// Write a small tagged JPEG: chosen ICC profile, EXIF orientation 6
    /// (rotate 90 CW), IPTC copyright, TIFF artist.
    private func makeFixture(colorSpaceName: CFString) throws -> URL {
        let w = 96, h = 64
        let cs = CGColorSpace(name: colorSpaceName)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.9, 0.6, 0.2, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let cg = ctx.makeImage()!

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-test-fixture-\(UUID().uuidString).jpg")
        let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                   UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCopyrightNotice: "© Test Client Shoot",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFArtist: "Sam Hurd",
            ],
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func properties(of url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return [:] }
        return p
    }

    // MARK: Gamut detection

    func testGamutMatchingByProfileName() {
        XCTAssertEqual(Gamut.matching(profileName: "Display P3"), .displayP3)
        XCTAssertEqual(Gamut.matching(profileName: "sRGB IEC61966-2.1"), .rec709)
        XCTAssertEqual(Gamut.matching(profileName: "ITU-R BT.2020"), .rec2020)
        XCTAssertEqual(Gamut.matching(profileName: "Rec. ITU-R BT.2100 PQ"), .rec2020)
        XCTAssertEqual(Gamut.matching(profileName: "Adobe RGB (1998)"), .rec709) // closest safe default
    }

    func testDetectGamutFromEmbeddedProfile() throws {
        let p3 = try makeFixture(colorSpaceName: CGColorSpace.displayP3)
        XCTAssertEqual(Gamut.detect(of: p3), .displayP3)
        let srgb = try makeFixture(colorSpaceName: CGColorSpace.sRGB)
        XCTAssertEqual(Gamut.detect(of: srgb), .rec709)
    }

    func testDetectGamutMissingFileDefaultsToRec709() {
        XCTAssertEqual(Gamut.detect(of: URL(fileURLWithPath: "/nonexistent/x.jpg")), .rec709)
    }

    // MARK: Bake-on SDR primary keeps identity metadata + profile

    func testSynthesizedSDRCarriesMetadataProfileAndDims() throws {
        let fixture = try makeFixture(colorSpaceName: CGColorSpace.displayP3)
        let inputs = try AutoHDR.synthesizeInputs(from: fixture,
                                                  params: AutoHDR.signatureLook,
                                                  gamut: .displayP3)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: inputs.hdr.url)
            try? FileManager.default.removeItem(at: inputs.sdrJPEG)
        }

        let p = properties(of: inputs.sdrJPEG)

        // Orientation must ride along: the pixels are written UNROTATED (same
        // encoded orientation as the raw HDR buffer, keeping the gain map
        // aligned), so the tag is what keeps portrait photos upright.
        XCTAssertEqual(p[kCGImagePropertyOrientation] as? Int, 6)

        // Copyright / credit survive.
        let iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCCopyrightNotice] as? String, "© Test Client Shoot")
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFArtist] as? String, "Sam Hurd")

        // The P3 source stays P3 (not silently squeezed to sRGB) — and therefore
        // agrees with the --sgamut flag the merge passes.
        let profile = (p[kCGImagePropertyProfileName] as? String) ?? ""
        XCTAssertTrue(profile.contains("P3"), "expected P3 profile, got '\(profile)'")

        // Encoded pixel dims match the source (and the HDR buffer).
        XCTAssertEqual(p[kCGImagePropertyPixelWidth] as? Int, 96)
        XCTAssertEqual(p[kCGImagePropertyPixelHeight] as? Int, 64)
        XCTAssertEqual(inputs.hdr.width, 96)
        XCTAssertEqual(inputs.hdr.height, 64)
    }
}
