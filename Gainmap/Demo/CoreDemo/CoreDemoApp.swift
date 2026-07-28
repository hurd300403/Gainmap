//
//  CoreDemoApp.swift
//  CoreDemo — dev-only P1 demonstration shell.
//
//  Proves the extracted GainmapCore framework on a physical iPhone: the SAME
//  LookControlsPanel and the SAME AutoHDR look engine the Mac app uses, with a
//  true-EDR Metal preview (a minimal UIKit twin of the Mac's EDRMetalNSView —
//  the production twin ships in P5). No encoder, no sync, no export: the P2/P4
//  phases bring those. This target is throwaway scaffolding and is replaced by
//  the real GainmapIOS target in P5.
//

import SwiftUI
import CoreImage
import ImageIO
import GainmapCore

@main
struct CoreDemoApp: App {
    var body: some Scene {
        WindowGroup { DemoRootView() }
    }
}

struct DemoRootView: View {
    @StateObject private var model = MergeModel()
    @State private var showAdvancedLook = false
    @State private var expandedGroups: Set<String> = ["glow", "color", "hdr"]

    /// The bundled sample photo, decoded once at 1600px (same proxy cap as the
    /// Mac's live preview).
    private static let base: CIImage? = {
        guard let url = Bundle.main.url(forResource: "demo", withExtension: "jpg"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return CIImage(cgImage: cg)
    }()

    /// The live proxy: the exact CIImage graph the Mac preview (and the export)
    /// build — identical params, identical kernel, different GPU.
    private var preview: CIImage? {
        guard let base = Self.base else { return nil }
        return AutoHDR.bloomCIImage(base: base, params: model.bloom)
    }

    private var aspect: CGFloat {
        guard let base = Self.base, base.extent.height > 0 else { return 3.0 / 2.0 }
        return base.extent.width / base.extent.height
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        (Text("Gain").foregroundStyle(Color.white)
                         + Text("map").foregroundStyle(Theme.accent))
                            .font(Theme.display(26, .semibold))
                        Text("GainmapCore on iPhone — P1 demo · live EDR preview · same engine, same controls as the Mac")
                            .font(Theme.mono(10)).foregroundStyle(Theme.stoneDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    EDRMetalView(image: preview)
                        .aspectRatio(aspect, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Theme.line, lineWidth: 1))

                    LookControlsPanel(model: model,
                                      showAdvancedLook: $showAdvancedLook,
                                      expandedGroups: $expandedGroups,
                                      onGlowInSDRInfo: { model.bloom.bakeGlowIntoSDR = true })

                    Text("dev-only demo — export & sync arrive with P2/P4, the real app with P5")
                        .font(Theme.mono(9)).foregroundStyle(Theme.stoneFaint)
                }
                .padding(16)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}
