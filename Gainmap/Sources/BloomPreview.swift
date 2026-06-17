//
//  BloomPreview.swift
//  Gainmap
//
//  A live, display-independent preview of the HDR pop. True HDR brightening is
//  only visible on an HDR display, so for in-app feedback we render a Core Image
//  "bloom" of the highlights whose intensity tracks the strength slider — it
//  visibly responds on any screen, so users can feel what Subtle→Strong does.
//  (The exported file is real UltraHDR; this is an approximate preview, labeled
//  as such.)
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

struct BloomPreview: View {
    let url: URL?
    let strength: Double

    @State private var base: CIImage?       // downscaled + materialized, cached per url
    @State private var rendered: NSImage?

    nonisolated static let ctx = CIContext(options: [.useSoftwareRenderer: false])

    var body: some View {
        ZStack {
            if let rendered {
                Image(nsImage: rendered).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Theme.surface, Theme.surfaceHi], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 8) {
                    GainmapEmblem().frame(width: 34, height: 34).opacity(0.5)
                    Text("HDR preview").font(Theme.mono(11)).foregroundStyle(Theme.stoneDim)
                }
            }
        }
        .frame(height: 203).frame(maxWidth: .infinity).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 10)
        .overlay(alignment: .topLeading) {
            Text("HDR PREVIEW")
                .font(Theme.mono(10, .semibold)).tracking(1.2).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.accent.opacity(0.92), in: RoundedRectangle(cornerRadius: 5))
                .padding(10)
        }
        .overlay(alignment: .bottomTrailing) {
            if url != nil {
                Text(String(format: "≈ %.1f×", strength))
                    .font(Theme.mono(11, .semibold)).foregroundStyle(Theme.inset)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.gold, in: RoundedRectangle(cornerRadius: 5))
                    .padding(10)
            }
        }
        .onChange(of: url) { _, u in loadBase(u) }
        .onChange(of: strength) { _, _ in renderBloom() }
        .onAppear { loadBase(url) }
    }

    // MARK: Pipeline

    private func loadBase(_ u: URL?) {
        guard let u else { base = nil; rendered = nil; return }
        Task.detached(priority: .userInitiated) {
            guard let img = CIImage(contentsOf: u) else { return }
            // Downscale and MATERIALIZE so each bloom render is cheap (no re-decode).
            let scale = min(1, 760 / max(1, img.extent.width))
            let small = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = Self.ctx.createCGImage(small, from: small.extent) else { return }
            let materialized = CIImage(cgImage: cg)
            await MainActor.run { base = materialized; renderBloom() }
        }
    }

    private func renderBloom() {
        guard let base else { return }
        var params = AutoHDR.BloomParams()
        params.glow = max(0, (strength - 1.0) * 0.50)
        params.peak = max(1.2, strength)
        Task.detached(priority: .userInitiated) {
            let out = Self.bloom(base, params: params)
            guard let cg = Self.ctx.createCGImage(out, from: base.extent) else { return }
            let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            await MainActor.run { rendered = ns }
        }
    }

    /// Highlight bloom whose intensity scales with `strength` — a perceptual
    /// stand-in for the HDR pop, visible on any display. Matches the recipe used
    /// in the browser tuner so the on-screen intensity reads the same: a smooth
    /// highlight mask × the image, blurred, scaled by (strength−1)·0.33, then
    /// SCREEN-blended (not added) so it rolls off instead of blowing out.
    nonisolated static func bloom(_ base: CIImage, strength: Double) -> CIImage {
        var params = AutoHDR.BloomParams()
        params.glow = max(0, (strength - 1.0) * 0.50)
        params.peak = max(1.2, strength)
        return bloom(base, params: params)
    }

    /// SDR-visible preview of the full HDR-look parameter set. This deliberately
    /// compresses the HDR lift back into display SDR so slider movement remains
    /// visible even when AppKit chooses the UltraHDR file's SDR fallback.
    nonisolated static func bloom(_ base: CIImage, params p: AutoHDR.BloomParams) -> CIImage {
        let knee = min(0.98, max(0.02, p.threshold))
        let amt = min(4.0, max(0, p.glow * (1.0 + max(0, p.peak - 1.0) * 0.60)))
        let bounds = base.extent

        // Highlight color layer, leveled [knee,1] -> [0,1]. This is
        // deliberately per-channel for a visible tuning preview; the export
        // path still uses the linear-light synthesis in AutoHDR.
        let s = 1.0 / (1.0 - knee)
        let level = CIFilter.colorMatrix()
        level.inputImage = base
        level.rVector = CIVector(x: s, y: 0, z: 0, w: 0)
        level.gVector = CIVector(x: 0, y: s, z: 0, w: 0)
        level.bVector = CIVector(x: 0, y: 0, z: s, w: 0)
        level.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        level.biasVector = CIVector(x: -knee * s, y: -knee * s, z: -knee * s, w: 0)
        let lift = CIFilter.colorClamp()
        lift.inputImage = level.outputImage
        lift.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        lift.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)

        let soft = CIFilter.gammaAdjust()
        soft.inputImage = lift.outputImage
        soft.power = Float(p.falloff)

        // Soft glow = blurred highlights; sharp pop = unblurred highlights.
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = soft.outputImage
        blur.radius = Float(bounds.width * p.spread)

        let softScaled = scaleRGB(blur.outputImage?.cropped(to: bounds), by: 1.0 - p.punch)
        let sharpScaled = scaleRGB(soft.outputImage?.cropped(to: bounds), by: p.punch)
        let mixed = CIFilter.additionCompositing()
        mixed.inputImage = softScaled
        mixed.backgroundImage = sharpScaled

        var glowImage = mixed.outputImage?.cropped(to: bounds)
        if p.saturation != 1.0 {
            let sat = CIFilter.colorControls()
            sat.inputImage = glowImage
            sat.saturation = Float(p.saturation)
            glowImage = sat.outputImage?.cropped(to: bounds)
        }

        let scaled = scaleRGB(glowImage, by: amt)

        // Add onto the base, then clamp to SDR white. This is display-only:
        // it makes control movement obvious without changing the UltraHDR export.
        let comp = CIFilter.additionCompositing()
        comp.inputImage = scaled
        comp.backgroundImage = base
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = comp.outputImage?.cropped(to: bounds)
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage?.cropped(to: bounds) ?? base
    }

    nonisolated private static func scaleRGB(_ image: CIImage?, by k: Double) -> CIImage? {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: k, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return m.outputImage
    }
}
