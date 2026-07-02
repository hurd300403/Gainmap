//
//  AutoHDR.swift
//  Gainmap
//
//  One-file auto mode: synthesize a highlight-boosted "bloom-as-HDR" rendition
//  from a single SDR JPEG. With the glow kept out of the SDR base (the default),
//  uhdrtool passes the original JPEG through untouched, so the SDR fallback stays
//  pixel-identical while HDR displays get a clean highlight pop that lives only in
//  the gain map.
//
//  The look is built by `bloomCIImage`: extract highlights above a threshold,
//  blur them for the halo (spread), shape the ramp (falloff), then composite the
//  glow back over the linear base and lift the brights into HDR headroom. The same
//  CIImage feeds both the export (rendered to an RGBA f16 buffer for
//  `uhdrtool --raw-hdr`) and the live EDR preview, so the two match by construction.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import CoreImage.CIFilterBuiltins

enum AutoHDR {

    static let ciContext: CIContext = {
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        return CIContext(options: [.workingColorSpace: cs])
    }()

    /// Single-pass combine kept in one kernel so alpha stays 1.0 throughout.
    /// (Chaining CIAdditionCompositing inflates alpha to 2–3; a later colorClamp
    /// on that alpha unpremultiplies and collapses the HDR headroom — the "export
    /// stays SDR" bug.) Does: glow = mix(soft, sharp, punch), saturation-adjusted;
    /// out = min(base + glow·amount, peak), alpha = 1.
    static let combineKernel = CIColorKernel(source: """
    kernel vec4 gmCombine(__sample soft, __sample sharp, __sample base, float punch, float amount, float peak, float saturation, float tint, float headroom) {
        vec3 g = mix(soft.rgb, sharp.rgb, punch);
        float l = dot(g, vec3(0.2126, 0.7152, 0.0722));
        g = mix(vec3(l), g, saturation);
        // Tint the glow warm (golden-hour) or cool. tint in [-1,1]; 0 = neutral.
        g *= vec3(1.0 + 0.18 * tint, 1.0 + 0.05 * tint, 1.0 - 0.18 * tint);
        g = max(g, vec3(0.0));
        // Bloom result, linear. SDR range (<=1) is preserved exactly; only the
        // portion ABOVE SDR white is expanded by `headroom` — pushing how hard HDR
        // displays glow (and raising the auto-derived target nits) without touching
        // the SDR fallback or the bloom's shape. headroom=1 => unchanged.
        // HEADROOM: a smooth highlight LIFT that pushes the brighter tones up into
        // HDR while shadows/mids stay ~SDR — so HDR displays glow harder (and the
        // encoded target-nits rise). headroom=1 => gain 1 everywhere (exact no-op).
        float bl = dot(base.rgb, vec3(0.2126, 0.7152, 0.0722));
        float hgain = 1.0 + (headroom - 1.0) * smoothstep(0.30, 1.0, bl);
        vec3 lit = base.rgb * hgain + g * amount;
        vec3 rgb = min(lit, vec3(peak * headroom));
        return vec4(rgb, 1.0);
    }
    """)!

    /// GLOW-IN-SDR bake: the ORIGINAL base with ONLY the soft haze screen-blended
    /// in — `out = base + haze·(1−base)` — so the fallback keeps the edit's exact
    /// tonality (no headroom lift, no peak expansion, no shoulder) and the blend
    /// mathematically can't clip: the haze fades out as the base nears white.
    /// (The previous bake tone-mapped the FULL HDR rendition into [0,1], dragging
    /// the 1.5× highlight lift along — which read as overexposed, over-contrasty
    /// highlights on every non-HDR screen.)
    static let sdrGlowBakeKernel = CIColorKernel(source: """
    kernel vec4 gmSdrGlowBake(__sample soft, __sample base, float amount, float saturation, float tint) {
        vec3 g = max(soft.rgb, vec3(0.0));
        float l = dot(g, vec3(0.2126, 0.7152, 0.0722));
        g = mix(vec3(l), g, saturation);
        g *= vec3(1.0 + 0.18 * tint, 1.0 + 0.05 * tint, 1.0 - 0.18 * tint);
        vec3 haze = clamp(g * amount, 0.0, 1.0);
        vec3 b = clamp(base.rgb, 0.0, 1.0);
        vec3 o = b + haze * (vec3(1.0) - b);   // screen blend: haze only, never clips
        return vec4(o, 1.0);
    }
    """)!

    /// The full set of dials for the bloom-as-HDR look.
    struct BloomParams: Equatable, Codable {
        var glow: Double = 0.40        // bloom intensity (0…1.5)
        var threshold: Double = 0.58   // highlight cutoff, gamma 0…1 (lower = more glows)
        var spread: Double = 0.006     // blur radius as fraction of width (halo size)
        var punch: Double = 0.0        // 0 = soft dreamy bloom … 1 = sharp crisp pop
        var peak: Double = 3.0         // max linear boost ceiling (×)
        var falloff: Double = 1.0      // gamma on the highlight ramp (>1 softer onset)
        var saturation: Double = 1.0   // glow color: 0 = white, 1 = as-shot, >1 = vivid
        var tint: Double = 0.0         // glow hue: -1 = cool, 0 = neutral, +1 = warm
        var headroom: Double = 1.0     // HDR headroom: expand highlights above SDR
                                       // white (1 = unchanged … pushes target nits up)
        // Per-photo: bake the soft bloom into the SDR base too (glow shows on every
        // screen) vs. HDR-only glow with a pixel-faithful SDR fallback. Travels with
        // the look (copy/paste + running-look inheritance). Default OFF (clean base).
        var bakeGlowIntoSDR: Bool = false
    }

    /// The built-in "signature" look — the dialed-in favorite that the single
    /// Intensity slider treats as 100%. Power users can override it (Set as default).
    static let signatureLook: BloomParams = {
        var p = BloomParams()
        p.glow = 1.5; p.headroom = 1.5; p.threshold = 0.67; p.spread = 0.025
        p.punch = 0.30; p.falloff = 1.54; p.saturation = 0.74; p.tint = -1.0
        return p
    }()

    /// Blend a signature look down by a single 0…1 intensity: at 1 it's the full
    /// signature; toward 0 the pop fades (glow/headroom/punch scale to neutral)
    /// while the look's character (threshold/spread/tone/tint) is preserved.
    static func look(intensity t: Double, signature s: BloomParams = signatureLook) -> BloomParams {
        let t = min(1, max(0, t))
        var p = s
        p.glow = s.glow * t
        p.punch = s.punch * t
        p.headroom = 1.0 + (s.headroom - 1.0) * t
        return p
    }

    // MARK: Pure math (unit-tested)

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        guard e1 > e0 else { return x < e0 ? 0 : 1 }
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// sRGB EOTF (gamma → linear) for a normalized channel.
    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    // MARK: Color spaces (gamut-matched render targets)

    /// The extended-linear space the HDR buffer is rendered into — matched to the
    /// job's gamut so `--cgamut` describes the pixels truthfully.
    static func linearSpace(for g: Gamut) -> CGColorSpace {
        switch g {
        case .rec709:    return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        case .displayP3: return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        case .rec2020:   return CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        }
    }

    /// The display (gamma) space the bake-on SDR JPEG is written in — matched to
    /// the SOURCE's profile so a P3 photo isn't silently squeezed to sRGB and
    /// `--sgamut` agrees with the embedded ICC (a mismatch hard-fails the tool).
    static func gammaSpace(for g: Gamut) -> CGColorSpace {
        switch g {
        case .rec709:    return CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
        case .rec2020:   return CGColorSpace(name: CGColorSpace.itur_2020)!
        }
    }

    /// The source photo's identity metadata, re-attached to derived JPEGs.
    /// Core Image's JPEG writer drops ALL properties — without this, the bake-on
    /// SDR base (which libultrahdr passes through into the final export) would
    /// ship stripped of copyright, credits, GPS, and orientation.
    static func carriedProperties(from src: CGImageSource) -> [CFString: Any] {
        guard let all = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        var out: [CFString: Any] = [:]
        for key in [kCGImagePropertyOrientation, kCGImagePropertyExifDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyGPSDictionary] {
            if let v = all[key] { out[key] = v }
        }
        return out
    }

    // MARK: Synthesis (side-effecting; call off the main thread)

    struct RawBuffer { let url: URL; let width: Int; let height: Int }

    enum SynthError: LocalizedError {
        case decode, context
        var errorDescription: String? {
            switch self {
            case .decode:  return "Couldn't read that JPEG — is it a valid image?"
            case .context: return "Couldn't prepare the image for HDR synthesis."
            }
        }
    }

    /// Write a downscaled JPEG copy of `url` (for fast preview rendering). The
    /// preview's gain map is computed at this smaller size so it's cheap to
    /// regenerate as the slider moves; the final merge still uses full res.
    static func downscaledJPEG(of url: URL, maxDim: CGFloat, quality: CGFloat = 0.92) -> URL? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-prev-sdr-\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out
    }

    /// The shared highlight-extraction pipeline: the linear base, the sharp
    /// thresholded/falloff-shaped highlights, and their blurred soft haze.
    private static func bloomPieces(base: CIImage, params p: BloomParams)
        -> (lin: CIImage, hi: CIImage, soft: CIImage)? {
        let bounds = base.extent
        // The base is sampled into the extendedLinearSRGB working space, so Core
        // Image already linearizes it (sRGB→linear) for us. An explicit
        // sRGBToneCurveToLinear here would DOUBLE-linearize and crush midtones
        // ~5.6× — making the live proxy far darker than the saved file (whose 1.0
        // gain-map floor snaps those midtones back up to SDR: the "snaps back to
        // the original edit" mismatch). Feed `base` straight through.
        let lin = base

        let kneeLin = srgbToLinear(p.threshold)
        let sub = CIFilter.colorMatrix()
        sub.inputImage = lin
        sub.biasVector = CIVector(x: -kneeLin, y: -kneeLin, z: -kneeLin, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = sub.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 10, y: 10, z: 10, w: 1)

        let shaped = CIFilter.gammaAdjust()       // Falloff
        shaped.inputImage = clamp.outputImage
        shaped.power = Float(p.falloff)
        guard let hi = shaped.outputImage?.cropped(to: bounds) else { return nil }

        let blur = CIFilter.gaussianBlur()         // Spread (soft glow)
        blur.inputImage = hi
        blur.radius = Float(bounds.width * p.spread)
        guard let soft = blur.outputImage?.cropped(to: bounds) else { return nil }
        return (lin, hi, soft)
    }

    /// The bloom-as-HDR rendition as a linear, extended-range CIImage. SHARED by
    /// the export (rendered to the f16 buffer / gain map) and the live EDR preview
    /// so the two are guaranteed identical. `base` is the sRGB source; spread scales
    /// with its width.
    static func bloomCIImage(base: CIImage, params p: BloomParams) -> CIImage? {
        guard let pieces = bloomPieces(base: base, params: p) else { return nil }
        return combineKernel.apply(
            extent: base.extent,
            arguments: [pieces.soft, pieces.hi, pieces.lin, p.punch, p.glow, p.peak, p.saturation, p.tint, p.headroom]
        )?.cropped(to: base.extent)
    }

    /// The bake-on SDR primary: the untouched edit + only the soft haze. Uses the
    /// SAME extraction (threshold/falloff/spread/saturation/tint/glow) as the HDR
    /// rendition, so the haze matches what HDR screens see — minus punch (the
    /// sharp component brightens the highlights themselves, which is exactly the
    /// overexposed look the bake must avoid) and minus headroom/peak.
    static func sdrWithBakedGlow(base: CIImage, params p: BloomParams) -> CIImage? {
        guard let pieces = bloomPieces(base: base, params: p) else { return nil }
        return sdrGlowBakeKernel.apply(
            extent: base.extent,
            arguments: [pieces.soft, pieces.lin, p.glow, p.saturation, p.tint]
        )?.cropped(to: base.extent)
    }

    /// Build the bloom-as-HDR rendition and render it to the engine's RGBA f16 buffer.
    static func synthesize(from sdrURL: URL, params p: BloomParams, gamut: Gamut = .rec709) throws -> RawBuffer {
        guard let src = CGImageSourceCreateWithURL(sdrURL as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw SynthError.decode
        }
        let w = cg.width, h = cg.height
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        guard let hdr = bloomCIImage(base: CIImage(cgImage: cg), params: p) else {
            throw SynthError.context
        }

        var data = Data(count: w * h * 8)
        let cs = linearSpace(for: gamut)
        data.withUnsafeMutableBytes { ptr in
            ciContext.render(hdr, toBitmap: ptr.baseAddress!, rowBytes: w * 8,
                             bounds: bounds, format: .RGBAh, colorSpace: cs)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gainmap-\(UUID().uuidString).rawf16")
        try data.write(to: url)
        return RawBuffer(url: url, width: w, height: h)
    }

    /// The two inputs uhdrtool needs for the bake-on gain map: the full-range HDR
    /// rendition AND an SDR primary that is the ORIGINAL edit plus only the soft
    /// haze (screen-blended, `sdrGlowBakeKernel`). Encoding gain = fullHDR / that
    /// SDR puts the haze on every screen while the highlight lift/pop stays in
    /// the gain map for HDR displays. The fallback keeps the edit's tonality; it
    /// is NOT pixel-identical to the input only where the haze lands.
    struct UltraHDRInputs { let hdr: RawBuffer; let sdrJPEG: URL }

    static func synthesizeInputs(from sdrURL: URL, params p: BloomParams, gamut: Gamut = .rec709) throws -> UltraHDRInputs {
        guard let src = CGImageSourceCreateWithURL(sdrURL as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw SynthError.decode }
        let w = cg.width, h = cg.height
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        guard let hdr = bloomCIImage(base: CIImage(cgImage: cg), params: p) else { throw SynthError.context }

        // Full-range HDR buffer (RGBA f16, extended-linear, gamut-matched).
        let linCS = linearSpace(for: gamut)
        var data = Data(count: w * h * 8)
        data.withUnsafeMutableBytes { ptr in
            ciContext.render(hdr, toBitmap: ptr.baseAddress!, rowBytes: w * 8,
                             bounds: bounds, format: .RGBAh, colorSpace: linCS)
        }
        let hdrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gainmap-\(UUID().uuidString).rawf16")
        try data.write(to: hdrURL)

        // SDR primary: the original edit + only the soft haze (screen blend — no
        // headroom lift, no peak, no shoulder), so the fallback's tonality stays
        // exactly as exported. Written as a gamma JPEG in the SOURCE's gamut, then
        // re-wrapped with the source photo's metadata (orientation, EXIF/IPTC/
        // TIFF/GPS) — AddImageFromSource copies the compressed bitstream, so the
        // metadata attach is lossless.
        guard let sdrImg = sdrWithBakedGlow(base: CIImage(cgImage: cg), params: p)
        else { throw SynthError.context }
        let sdrURLout = FileManager.default.temporaryDirectory
            .appendingPathComponent("gainmap-sdr-\(UUID().uuidString).jpg")
        let q = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let jpeg = ciContext.jpegRepresentation(of: sdrImg, colorSpace: gammaSpace(for: gamut),
                                                      options: [q: 0.95]),
              let wrapped = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let dest = CGImageDestinationCreateWithURL(sdrURLout as CFURL,
                                                         UTType.jpeg.identifier as CFString, 1, nil)
        else { throw SynthError.context }
        CGImageDestinationAddImageFromSource(dest, wrapped, 0,
                                             carriedProperties(from: src) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw SynthError.context }

        return UltraHDRInputs(hdr: RawBuffer(url: hdrURL, width: w, height: h), sdrJPEG: sdrURLout)
    }
}

extension AutoHDR.BloomParams {
    // Tolerant decoder: read every field with a default so older saved looks —
    // one missing the newer `bakeGlowIntoSDR`, or still carrying the removed AUTO
    // keys (autoAdapt / adaptAmount / highlightGuard) — decode cleanly instead of
    // throwing. Swift's synthesized Decodable does NOT fall back to a property's
    // default value for a missing key (it throws keyNotFound), and
    // `SignatureStore.load()` swallows that with `try?` → nil → a user's saved
    // default look would be silently wiped. Encoding stays synthesized (uses these
    // same keys), so a re-saved look no longer carries the dead AUTO fields.
    private enum CodingKeys: String, CodingKey {
        case glow, threshold, spread, punch, peak, falloff, saturation, tint, headroom, bakeGlowIntoSDR
    }

    init(from decoder: Decoder) throws {
        var p = AutoHDR.BloomParams()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        p.glow           = try c.decodeIfPresent(Double.self, forKey: .glow)           ?? p.glow
        p.threshold      = try c.decodeIfPresent(Double.self, forKey: .threshold)      ?? p.threshold
        p.spread         = try c.decodeIfPresent(Double.self, forKey: .spread)         ?? p.spread
        p.punch          = try c.decodeIfPresent(Double.self, forKey: .punch)          ?? p.punch
        p.peak           = try c.decodeIfPresent(Double.self, forKey: .peak)           ?? p.peak
        p.falloff        = try c.decodeIfPresent(Double.self, forKey: .falloff)        ?? p.falloff
        p.saturation     = try c.decodeIfPresent(Double.self, forKey: .saturation)     ?? p.saturation
        p.tint           = try c.decodeIfPresent(Double.self, forKey: .tint)           ?? p.tint
        p.headroom       = try c.decodeIfPresent(Double.self, forKey: .headroom)       ?? p.headroom
        p.bakeGlowIntoSDR = try c.decodeIfPresent(Bool.self, forKey: .bakeGlowIntoSDR) ?? p.bakeGlowIntoSDR
        self = p
    }
}
