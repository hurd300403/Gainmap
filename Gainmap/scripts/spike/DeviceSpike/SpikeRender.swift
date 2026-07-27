//  SpikeRender.swift — S1 cross-GPU render-parity probe.
//
//  A VERBATIM copy of the bloom pipeline from Gainmap/Sources/AutoHDR.swift
//  (combineKernel, bloomPieces, bloomCIImage, srgbToLinear, ciContext), reduced
//  to the pieces the probe needs. Both the macOS reference tool and the iOS
//  spike app compile THIS file, so the Mac-vs-device diff measures GPU/driver
//  divergence of the identical Core Image graph — nothing else.
//  Params are pinned to the app's built-in signature look so every kernel
//  argument is exercised.

import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

enum SpikeRender {

    struct Params {
        var glow = 1.5
        var threshold = 0.67
        var spread = 0.025
        var punch = 0.30
        var peak = 3.0
        var falloff = 1.54
        var saturation = 0.74
        var tint = -1.0
        var headroom = 1.5
    }

    static let ciContext: CIContext = {
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        return CIContext(options: [.workingColorSpace: cs])
    }()

    // Verbatim from AutoHDR.combineKernel.
    static let combineKernel = CIColorKernel(source: """
    kernel vec4 gmCombine(__sample soft, __sample sharp, __sample base, float punch, float amount, float peak, float saturation, float tint, float headroom) {
        vec3 g = mix(soft.rgb, sharp.rgb, punch);
        float l = dot(g, vec3(0.2126, 0.7152, 0.0722));
        g = mix(vec3(l), g, saturation);
        g *= vec3(1.0 + 0.18 * tint, 1.0 + 0.05 * tint, 1.0 - 0.18 * tint);
        g = max(g, vec3(0.0));
        float bl = dot(base.rgb, vec3(0.2126, 0.7152, 0.0722));
        float hgain = 1.0 + (headroom - 1.0) * smoothstep(0.30, 1.0, bl);
        vec3 lit = base.rgb * hgain + g * amount;
        vec3 rgb = min(lit, vec3(peak * headroom));
        return vec4(rgb, 1.0);
    }
    """)!

    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    // Verbatim from AutoHDR.bloomPieces + bloomCIImage.
    static func bloomCIImage(base: CIImage, params p: Params) -> CIImage? {
        let bounds = base.extent
        let lin = base

        let kneeLin = srgbToLinear(p.threshold)
        let sub = CIFilter.colorMatrix()
        sub.inputImage = lin
        sub.biasVector = CIVector(x: -kneeLin, y: -kneeLin, z: -kneeLin, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = sub.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 10, y: 10, z: 10, w: 1)

        let shaped = CIFilter.gammaAdjust()
        shaped.inputImage = clamp.outputImage
        shaped.power = Float(p.falloff)
        guard let hi = shaped.outputImage?.cropped(to: bounds) else { return nil }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = hi
        blur.radius = Float(bounds.width * p.spread)
        guard let soft = blur.outputImage?.cropped(to: bounds) else { return nil }

        return combineKernel.apply(
            extent: bounds,
            arguments: [soft, hi, lin, p.punch, p.glow, p.peak, p.saturation, p.tint, p.headroom]
        )?.cropped(to: bounds)
    }

    /// Decode `jpegData`, render the bloom rendition, return the RGBA-f16 buffer.
    static func renderF16(jpegData: Data) -> (data: Data, width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        guard let hdr = bloomCIImage(base: CIImage(cgImage: cg), params: Params()) else { return nil }
        var data = Data(count: w * h * 8)
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        data.withUnsafeMutableBytes { ptr in
            ciContext.render(hdr, toBitmap: ptr.baseAddress!, rowBytes: w * 8,
                             bounds: CGRect(x: 0, y: 0, width: w, height: h),
                             format: .RGBAh, colorSpace: cs)
        }
        return (data, w, h)
    }

    /// Compare two RGBA-f16 buffers: (maxAbsDiff, meanAbsDiff, psnrDB vs peak 3·1.5).
    static func compare(_ a: Data, _ b: Data) -> (maxAbs: Double, meanAbs: Double, psnr: Double)? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var maxAbs = 0.0, sumAbs = 0.0, sumSq = 0.0
        let n = a.count / 2
        a.withUnsafeBytes { pa in
            b.withUnsafeBytes { pb in
                let ha = pa.bindMemory(to: Float16.self)
                let hb = pb.bindMemory(to: Float16.self)
                for i in 0..<n {
                    let d = abs(Double(ha[i]) - Double(hb[i]))
                    if d > maxAbs { maxAbs = d }
                    sumAbs += d
                    sumSq += d * d
                }
            }
        }
        let mse = sumSq / Double(n)
        let peak = 3.0 * 1.5  // params.peak * headroom — the pipeline's ceiling
        let psnr = mse == 0 ? Double.infinity : 10 * log10(peak * peak / mse)
        return (maxAbs, sumAbs / Double(n), psnr)
    }
}
