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
@testable import GainmapCore

@MainActor
final class BatchModelTests: XCTestCase {

    // MergeModel reads UserDefaults.standard directly; a persisted SAME-LOOK
    // flag from another test (or the app) would silently flip every model here
    // into batch mode and break the commit-on-leave assertions.
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: MergeModel.sameLookKey)
    }
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: MergeModel.sameLookKey)
        super.tearDown()
    }

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

    func testImportJumpsToFreshlyAddedPhoto() {
        let m = MergeModel()
        m.addFiles([url("a")])
        XCTAssertEqual(m.selectedItem?.sdrURL.lastPathComponent, "a.jpg")
        // A single new file becomes the displayed one.
        m.addFiles([url("b")])
        XCTAssertEqual(m.selectedItem?.sdrURL.lastPathComponent, "b.jpg")
        // A batch jumps to the FIRST of the new set, not the last.
        m.addFiles([url("c"), url("d")])
        XCTAssertEqual(m.selectedItem?.sdrURL.lastPathComponent, "c.jpg")
        // Importing only duplicates adds nothing → selection is left alone.
        m.addFiles([url("a")])
        XCTAssertEqual(m.selectedItem?.sdrURL.lastPathComponent, "c.jpg")
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
        // Move to B — leaving A commits the dialed look onto it (the commit
        // happens on LEAVE, not per slider tick, to avoid 60 Hz items churn).
        m.selectNext()
        XCTAssertEqual(m.items[0].look?.glow, 1.3)   // A keeps its own look
        XCTAssertEqual(m.bloom.glow, 1.3, accuracy: 1e-9)  // B arrives pre-dialed
    }

    func testTweakingKeepsPerPhotoLook() {
        let m = MergeModel()
        m.addFiles([url("a"), url("b")])
        m.bloom.glow = 1.3            // A = 1.3
        m.selectNext()
        m.bloom.glow = 0.5           // B = 0.5 (now customized)
        m.selectPrevious()           // back to A (leaving B commits 0.5 onto it)
        XCTAssertEqual(m.items[1].look?.glow, 0.5)
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

    // MARK: GLOW-IN-SDR is per-photo (travels with the look)

    func testBakeIsPerPhotoAndIndependent() {
        let m = MergeModel()
        m.addFiles([url("a"), url("b")])
        // Turn bake ON for photo A only.
        m.bloom.bakeGlowIntoSDR = true
        // Move to B (commits A's look) and turn it OFF; A must be unaffected.
        m.selectNext()
        XCTAssertEqual(m.items[0].look?.bakeGlowIntoSDR, true)
        m.bloom.bakeGlowIntoSDR = false
        m.selectPrevious()   // commits B's look on leave
        XCTAssertEqual(m.items[1].look?.bakeGlowIntoSDR, false)
        XCTAssertTrue(m.bloom.bakeGlowIntoSDR, "photo A keeps its own bake setting")
    }

    func testCopyPasteLookCarriesBake() {
        let m = MergeModel()
        m.addFiles([url("a"), url("b")])
        m.bloom.bakeGlowIntoSDR = true
        m.copyLook()
        m.selectNext()                     // photo B, bake currently on via running-look
        m.bloom.bakeGlowIntoSDR = false    // turn B off
        XCTAssertFalse(m.bloom.bakeGlowIntoSDR)
        m.pasteLook()                      // paste A's look (bake on) onto B
        XCTAssertTrue(m.bloom.bakeGlowIntoSDR, "pasting a look brings its bake along")
    }

    func testTogglingBakeDoesNotResetIntensity() {
        let m = MergeModel()
        m.addFiles([url("a")])
        m.setIntensity(0.4)                       // dial Intensity down
        XCTAssertEqual(m.intensity, 0.4, accuracy: 1e-9)
        let glowBefore = m.bloom.glow
        m.bloom.bakeGlowIntoSDR = true            // flipping bake is not a look-strength change
        XCTAssertEqual(m.intensity, 0.4, accuracy: 1e-9, "bake toggle must not snap Intensity to 100%")
        XCTAssertEqual(m.bloom.glow, glowBefore, accuracy: 1e-9)
        // And a later Intensity move must PRESERVE the toggle (anchor stayed in sync).
        m.setIntensity(0.8)
        XCTAssertTrue(m.bloom.bakeGlowIntoSDR)
    }

    func testSaveAsDefaultNormalizesBakeOff() {
        let m = MergeModel()
        m.addFiles([url("a")])
        m.bloom.bakeGlowIntoSDR = true
        m.setSignatureFromCurrent()
        XCTAssertFalse(m.signature.bakeGlowIntoSDR, "the saved default look never carries bake")
        // The current photo keeps its own bake, though.
        XCTAssertTrue(m.bloom.bakeGlowIntoSDR)
        // A subsequent Reset (snap to default) turns bake off.
        m.resetToDefault()
        XCTAssertFalse(m.bloom.bakeGlowIntoSDR)
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
