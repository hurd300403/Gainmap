//
//  AutoHDR.swift
//  Gainmap
//
//  One-file auto mode: synthesize a highlight-boosted HDR rendition from a single
//  SDR JPEG, so the SDR fallback stays pixel-identical (uhdrtool passes the JPEG
//  through untouched) while HDR displays get a clean highlight pop.
//
//  The synthesis is inverse tone-mapping: linearize the SDR, and multiply each
//  pixel by a gain that is 1.0 through shadows/midtones and ramps up to `maxBoost`
//  in the highlights (above a luma `knee`). The result is written as an RGBA f16
//  buffer for `uhdrtool --raw-hdr` — same layout as the engine's --dump-raw.
//
//  The gain math here mirrors the ImageMagick recipe used to tune the default
//  strength (knee ≈ 0.55, default maxBoost 2.5×).
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import CoreImage.CIFilterBuiltins

enum AutoHDR {

    static let defaultMaxBoost = 2.5   // legacy (per-pixel multiply); kept for tests
    static let defaultKnee = 0.55

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

    /// Folds an extended-range (>1) bloom into [0,1] for the SDR primary: IDENTITY
    /// below `knee` so the soft glow passes through UNCHANGED (→ gain ≈ 1 there, so
    /// it shows identically on SDR and HDR), then a Reinhard shoulder on the excess
    /// so highlights compress into [knee,1] instead of hard-clipping to white.
    static let sdrShoulderKernel = CIColorKernel(source: """
    kernel vec4 sdrShoulder(__sample s, float knee) {
        vec3 x = max(s.rgb, vec3(0.0));
        vec3 e = max(x - vec3(knee), vec3(0.0));
        vec3 o = min(x, vec3(knee)) + (1.0 - knee) * (e / (e + vec3(1.0 - knee)));
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
        var autoAdapt: Bool = false    // OFF by default: sliders drive the export directly
                                       // (on = scale the look per photo from scene stats)
        var adaptAmount: Double = 0.65 // 0 = fixed preset, 1 = full scene-aware correction
        var highlightGuard: Double = 0.85 // dampen high-key / highlight-heavy scenes
    }

    /// The built-in "signature" look — the dialed-in favorite that the single
    /// Intensity slider treats as 100%. Power users can override it (Set as default).
    static let signatureLook: BloomParams = {
        var p = BloomParams()
        p.glow = 1.5; p.headroom = 1.5; p.threshold = 0.67; p.spread = 0.025
        p.punch = 0.30; p.falloff = 1.54; p.saturation = 0.74; p.tint = -1.0
        p.autoAdapt = true; p.adaptAmount = 1.0; p.highlightGuard = 0.19
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

    /// The intensity implied by a look (glow-anchored), so the macro slider can
    /// reflect a manually-edited or saved-default look.
    static func intensity(of p: BloomParams, signature s: BloomParams = signatureLook) -> Double {
        guard s.glow > 0 else { return 1 }
        return min(1, max(0, p.glow / s.glow))
    }

    /// Cheap thumbnail-derived scene description used to adapt the user's base
    /// look. Values are gamma-space fractions, stable enough for per-photo style
    /// scaling without reading the full-resolution image twice.
    struct SceneStats: Equatable {
        var meanLuma: Double
        var highlightLoad: Double
        var specularLoad: Double
        var shadowLoad: Double
    }

    // MARK: Pure math (unit-tested)

    /// Highlight gain for a perceptual luma in [0,1]. 1.0 below the knee, ramping
    /// smoothly to `maxBoost` at full white.
    static func gain(luma: Double, maxBoost: Double, knee: Double = defaultKnee) -> Double {
        1.0 + (maxBoost - 1.0) * smoothstep(knee, 1.0, luma)
    }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        guard e1 > e0 else { return x < e0 ? 0 : 1 }
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    // MARK: Adaptive boost (per-image)

    static let minBoost = 1.8
    static let maxBoostCap = 3.4

    /// Pick a max boost from the image's mean perceptual luma. Brighter images
    /// (more highlight data) over-blow easily, so they get LESS boost; darker
    /// images have headroom and get more pop. The line is calibrated to Sam's
    /// tuning: meanLuma 0.81→2.0×, 0.55→2.6×, 0.35→3.0×.
    static func recommendedBoost(meanLuma: Double) -> Double {
        let b = 3.0 - (meanLuma - 0.351) * 2.188
        return min(maxBoostCap, max(minBoost, b))
    }

    /// Mean perceptual luma (gamma space) of a downsampled copy. Side-effecting;
    /// call off the main thread.
    static func meanLuma(of url: URL, sample: CGFloat = 256) -> Double? {
        sceneStats(of: url, sample: sample)?.meanLuma
    }

    /// Analyze a small thumbnail for broad image character. The thresholds are
    /// intentionally perceptual: enough to tell high-key frames from isolated
    /// speculars, not a replacement for the real HDR encode.
    static func sceneStats(of url: URL, sample: CGFloat = 384) -> SceneStats? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: sample,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = px.withUnsafeMutableBytes({ ptr in
                  CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
              }) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        var highlights = 0
        var speculars = 0
        var shadows = 0
        var p = 0
        for _ in 0..<(w * h) {
            let luma = (0.2126 * Double(px[p]) + 0.7152 * Double(px[p + 1]) + 0.0722 * Double(px[p + 2])) / 255.0
            sum += luma
            if luma >= 0.72 { highlights += 1 }
            if luma >= 0.92 { speculars += 1 }
            if luma <= 0.22 { shadows += 1 }
            p += 4
        }
        let n = Double(w * h)
        return SceneStats(meanLuma: sum / n,
                          highlightLoad: Double(highlights) / n,
                          specularLoad: Double(speculars) / n,
                          shadowLoad: Double(shadows) / n)
    }

    /// sRGB EOTF (gamma → linear) for a normalized channel.
    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Apply the dynamic preset layer. The user's sliders remain the base look;
    /// this only scales them from scene statistics, mainly to keep highlight-rich
    /// frames from becoming overwhelming while letting isolated speculars pop.
    static func adaptedBloomParams(_ params: BloomParams, stats: SceneStats) -> BloomParams {
        guard params.autoAdapt, params.adaptAmount > 0 else { return params }

        let amount = clamp01(params.adaptAmount)
        let guardAmount = amount * clamp01(params.highlightGuard)
        let highlightPressure = clamp01(
            smoothstep(0.08, 0.38, stats.highlightLoad) * 0.75 +
            smoothstep(0.50, 0.80, stats.meanLuma) * 0.25
        )
        let shadowPressure = smoothstep(0.45, 0.75, stats.shadowLoad)
        let specularFocus = clamp01(
            smoothstep(0.003, 0.035, stats.specularLoad) *
            (1.0 - smoothstep(0.18, 0.45, stats.highlightLoad))
        )

        var out = params
        out.glow = clamp(params.glow * max(0.25, 1.0 - guardAmount * (0.45 * highlightPressure + 0.12 * shadowPressure)),
                         0.0, 1.5)
        out.peak = clamp(1.0 + (params.peak - 1.0) * max(0.40, 1.0 - guardAmount * 0.35 * highlightPressure),
                         1.2, 5.0)
        out.spread = clamp(params.spread * max(0.65, 1.0 - guardAmount * 0.25 * highlightPressure),
                           0.002, 0.025)
        out.threshold = clamp(params.threshold + guardAmount * 0.12 * highlightPressure - amount * 0.035 * specularFocus,
                              0.30, 0.95)
        out.punch = clamp(params.punch + amount * 0.22 * specularFocus - guardAmount * 0.10 * highlightPressure,
                          0.0, 1.0)
        out.falloff = clamp(params.falloff + guardAmount * 0.45 * highlightPressure + amount * 0.18 * shadowPressure,
                            0.5, 2.0)
        out.saturation = clamp(params.saturation * (1.0 - guardAmount * 0.18 * highlightPressure),
                               0.0, 1.5)
        return out
    }

    static func effectiveBloomParams(_ params: BloomParams, for url: URL) -> BloomParams {
        guard params.autoAdapt, let stats = sceneStats(of: url) else { return params }
        return adaptedBloomParams(params, stats: stats)
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

    /// The bloom-as-HDR rendition as a linear, extended-range CIImage. SHARED by
    /// the export (rendered to the f16 buffer / gain map) and the live EDR preview
    /// so the two are guaranteed identical. `p` must already be the effective
    /// (adapted) params. `base` is the sRGB source; spread scales with its width.
    static func bloomCIImage(base: CIImage, params p: BloomParams) -> CIImage? {
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
        let hi = shaped.outputImage?.cropped(to: bounds)

        let blur = CIFilter.gaussianBlur()         // Spread (soft glow)
        blur.inputImage = hi
        blur.radius = Float(bounds.width * p.spread)
        let soft = blur.outputImage?.cropped(to: bounds)

        guard let hiImg = hi, let softImg = soft else { return nil }
        return combineKernel.apply(
            extent: bounds,
            arguments: [softImg, hiImg, lin, p.punch, p.glow, p.peak, p.saturation, p.tint, p.headroom]
        )?.cropped(to: bounds)
    }

    /// Build the bloom-as-HDR rendition and render it to the engine's RGBA f16 buffer.
    static func synthesize(from sdrURL: URL, params: BloomParams) throws -> RawBuffer {
        let p = effectiveBloomParams(params, for: sdrURL)
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
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        data.withUnsafeMutableBytes { ptr in
            ciContext.render(hdr, toBitmap: ptr.baseAddress!, rowBytes: w * 8,
                             bounds: bounds, format: .RGBAh, colorSpace: cs)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gainmap-\(UUID().uuidString).rawf16")
        try data.write(to: url)
        return RawBuffer(url: url, width: w, height: h)
    }

    /// The two inputs uhdrtool needs for the HYBRID gain map: a full-range HDR
    /// rendition AND a bloomed SDR primary (the same bloom tone-mapped into 0…1).
    /// Encoding gain = fullBloom / bloomedSDR puts the soft (sub-white) glow into
    /// the SDR base — so it shows on ANY display/headroom — and leaves only the
    /// supra-white highlight pop in the gain map. The SDR fallback is therefore the
    /// bloomed look, NOT pixel-identical to the input (that's the trade-off).
    struct UltraHDRInputs { let hdr: RawBuffer; let sdrJPEG: URL }

    static func synthesizeInputs(from sdrURL: URL, params: BloomParams) throws -> UltraHDRInputs {
        let p = effectiveBloomParams(params, for: sdrURL)
        guard let src = CGImageSourceCreateWithURL(sdrURL as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw SynthError.decode }
        let w = cg.width, h = cg.height
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        guard let hdr = bloomCIImage(base: CIImage(cgImage: cg), params: p) else { throw SynthError.context }

        // Full-range HDR buffer (RGBA f16, extended-linear).
        let linCS = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        var data = Data(count: w * h * 8)
        data.withUnsafeMutableBytes { ptr in
            ciContext.render(hdr, toBitmap: ptr.baseAddress!, rowBytes: w * 8,
                             bounds: bounds, format: .RGBAh, colorSpace: linCS)
        }
        let hdrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gainmap-\(UUID().uuidString).rawf16")
        try data.write(to: hdrURL)

        // Bloomed SDR primary: the bloom folded into [0,1] with a soft highlight
        // shoulder (identity below the knee so the glow passes through unchanged;
        // highlights roll off instead of hard-clipping ~42% of a bright frame to
        // flat white). Written as a real sRGB-gamma JPEG.
        guard let sdrImg = sdrShoulderKernel.apply(extent: bounds, arguments: [hdr, 0.85])?
            .cropped(to: bounds) else { throw SynthError.context }
        let sdrURLout = FileManager.default.temporaryDirectory
            .appendingPathComponent("gainmap-sdr-\(UUID().uuidString).jpg")
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let q = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        try ciContext.writeJPEGRepresentation(of: sdrImg, to: sdrURLout, colorSpace: srgb,
                                              options: [q: 0.95])

        return UltraHDRInputs(hdr: RawBuffer(url: hdrURL, width: w, height: h), sdrJPEG: sdrURLout)
    }

    private static func clamp01(_ x: Double) -> Double {
        min(1, max(0, x))
    }

    private static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, x))
    }
}
