//
//  HDRPreview.swift
//  Gainmap
//
//  A true-EDR preview that renders the EXACT same synthesized HDR CIImage the
//  export writes (AutoHDR.bloomCIImage), via a Metal-backed CAMetalLayer with
//  extended dynamic range. On an HDR display the pop matches the exported file
//  by construction; on a standard display it shows the SDR-range result.
//

import SwiftUI
import AppKit
import Metal
import CoreImage
import ImageIO

// MARK: - Metal EDR view

/// Renders an extended-range (linear, values >1) CIImage to screen as true EDR.
/// CAMetalLayer + rgba16Float + wantsExtendedDynamicRangeContent is the reliable
/// HDR-on-macOS path (NSImageView's gain-map auto-EDR is inconsistent).
final class EDRMetalNSView: NSView {
    private let device = MTLCreateSystemDefaultDevice()
    private var queue: MTLCommandQueue?
    private var ciContext: CIContext?
    private let edrSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    var ciImage: CIImage? { didSet { render() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        if let device {
            queue = device.makeCommandQueue()
            ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: edrSpace])
        }
    }
    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = device
        l.pixelFormat = .rgba16Float
        l.framebufferOnly = false
        l.wantsExtendedDynamicRangeContent = true
        l.colorspace = edrSpace
        l.isOpaque = true
        return l
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale(); render()
    }
    override func layout() { super.layout(); updateScale(); render() }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer?.contentsScale = scale
        metalLayer?.drawableSize = CGSize(width: max(1, bounds.width * scale),
                                          height: max(1, bounds.height * scale))
    }

    private func render() {
        guard let metalLayer, let ciContext, let queue, let ciImage,
              bounds.width > 1 else { return }
        let ds = metalLayer.drawableSize
        guard ds.width > 1, let drawable = metalLayer.nextDrawable(),
              let cb = queue.makeCommandBuffer() else { return }

        // Aspect-FIT the image into the drawable (show the whole frame in its
        // native aspect, never cropped), composited over black for the letterbox.
        let ext = ciImage.extent
        let scale = min(ds.width / ext.width, ds.height / ext.height)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let sExt = scaled.extent
        let positioned = scaled.transformed(by: CGAffineTransform(
            translationX: (ds.width - sExt.width) / 2 - sExt.minX,
            y: (ds.height - sExt.height) / 2 - sExt.minY))
        let drawableRect = CGRect(origin: .zero, size: ds)
        let framed = positioned.composited(over: CIImage(color: .black).cropped(to: drawableRect))

        ciContext.render(framed, to: drawable.texture, commandBuffer: cb,
                         bounds: drawableRect, colorSpace: edrSpace)
        cb.present(drawable)
        cb.commit()
    }
}

struct EDRMetalView: NSViewRepresentable {
    let image: CIImage?
    func makeNSView(context: Context) -> EDRMetalNSView {
        let v = EDRMetalNSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        return v
    }
    func updateNSView(_ v: EDRMetalNSView, context: Context) { v.ciImage = image }
}

// MARK: - Debounced renderer (runs the REAL export, small, then decodes it)

@MainActor
final class PreviewRenderer: ObservableObject {
    @Published var image: CIImage?       // the synthesized HDR look
    @Published var original: CIImage?    // the untouched SDR base (for A/B compare)
    @Published var aspect: CGFloat?      // native width / height of the photo
    @Published var rendering = false

    // The cached, downscaled SDR base + its scene stats (for the live proxy).
    private var baseURL: URL?
    private var baseImage: CIImage?
    private var baseStats: AutoHDR.SceneStats?
    private var loadTask: Task<Void, Never>?
    private var accurateTask: Task<Void, Never>?
    private var lastFile: URL?
    // Bumped on every request(); the accurate pass only applies if it's still the
    // current generation, so a slow stale render can't overwrite a fresh proxy.
    private var generation = 0
    // Latest inputs, so a base-load that finishes later renders with current values.
    private var curParams = AutoHDR.BloomParams()
    private var curCgamut: Gamut = .rec709
    private var curSgamut: Gamut = .rec709
    private var curBake = true

    /// Two-stage preview for real-time scrubbing:
    ///   • PROXY — render `bloomCIImage` (the same linear-HDR the export encodes)
    ///     straight to the EDR view on every change. No process spawn → instant,
    ///     so the look tracks the slider live.
    ///   • ACCURATE — ~200 ms after you stop, run the REAL gain-map export and
    ///     decode it, snapping the preview to the exact file (its L/K encoding).
    ///
    /// CRUCIAL: both stages use the SAME *effective* params — i.e. the Adaptive
    /// layer (AUTO) is resolved up-front from cached scene stats and baked in, so
    /// the live proxy can't show a stronger look than the file actually saves.
    func request(sdr: URL?, params: AutoHDR.BloomParams,
                 cgamut: Gamut = .rec709, sgamut: Gamut = .rec709, bake: Bool = true) {
        // Stash the latest inputs so a base-load that finishes later renders with
        // CURRENT params/gamut, not whatever they were when the load kicked off.
        curParams = params; curCgamut = cgamut; curSgamut = sgamut; curBake = bake
        generation &+= 1
        guard let sdr else {
            loadTask?.cancel(); accurateTask?.cancel()
            image = nil; original = nil; aspect = nil
            baseImage = nil; baseStats = nil; baseURL = nil; rendering = false
            return
        }

        if sdr != baseURL {
            // New photo: cancel any in-flight render of the previous photo, drop
            // the stale original immediately (so the before/after compare can't
            // show the photo you came from), then load this base + stats.
            baseURL = sdr
            baseImage = nil; baseStats = nil; original = nil
            loadTask?.cancel(); accurateTask?.cancel()
            loadTask = Task { [weak self] in
                let (base, stats) = await Task.detached(priority: .userInitiated) {
                    (Self.baseCIImage(for: sdr), AutoHDR.sceneStats(of: sdr))
                }.value
                if Task.isCancelled { return }
                // Guard by PHOTO IDENTITY, not generation: a same-photo re-request
                // (param/gamut change) must NOT discard this load, or baseImage /
                // original get stuck on the previous photo.
                guard let self, self.baseURL == sdr else { return }
                self.baseImage = base
                self.baseStats = stats
                self.original = base
                self.aspect = base.map { $0.extent.width / max(1, $0.extent.height) }
                self.renderCurrent()
            }
            return
        }

        renderCurrent()
    }

    /// Render the current photo with the latest stored params/gamut.
    private func renderCurrent() {
        guard let sdr = baseURL else { return }
        let eff = effective(curParams)
        renderProxy(params: eff)
        scheduleAccurate(sdr: sdr, params: eff, cgamut: curCgamut, sgamut: curSgamut, bake: curBake, gen: generation)
    }

    /// Resolve the Adaptive (AUTO) layer once from cached stats and bake it in,
    /// disabling further adaptation so the export path won't re-apply it.
    private func effective(_ params: AutoHDR.BloomParams) -> AutoHDR.BloomParams {
        guard params.autoAdapt, let stats = baseStats else { return params }
        var e = AutoHDR.adaptedBloomParams(params, stats: stats)
        e.autoAdapt = false
        return e
    }

    /// Instant: build the bloom CIImage graph (cheap) and hand it to the EDR view.
    private func renderProxy(params: AutoHDR.BloomParams) {
        guard let base = baseImage,
              let proxy = AutoHDR.bloomCIImage(base: base, params: params) else { return }
        image = proxy
    }

    /// Debounced: replace the proxy with the real exported gain-map file.
    /// `params` are already effective (autoAdapt baked off), so synthesize won't
    /// re-adapt — the file matches the proxy exactly.
    private func scheduleAccurate(sdr: URL, params: AutoHDR.BloomParams,
                                  cgamut: Gamut, sgamut: Gamut, bake: Bool, gen: Int) {
        accurateTask?.cancel()
        rendering = true
        accurateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)   // settle after last change
            if Task.isCancelled { return }
            let (ci, file) = await Self.renderExport(sdr: sdr, params: params,
                                                     cgamut: cgamut, sgamut: sgamut, bake: bake)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                // Ignore a stale render whose params/photo were superseded.
                guard gen == self.generation else {
                    if let file { try? FileManager.default.removeItem(at: file) }
                    return
                }
                if let ci { self.image = ci }
                if let old = self.lastFile { try? FileManager.default.removeItem(at: old) }
                self.lastFile = file
                self.rendering = false
            }
        }
    }

    /// A downscaled CIImage of the SDR base for fast per-frame proxy rendering.
    /// Capped so the bloom (gaussian blur) stays interactive on big files.
    nonisolated private static func baseCIImage(for url: URL, maxDim: CGFloat = 1600) -> CIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return CIImage(cgImage: cg)
    }

    nonisolated private static func renderExport(sdr: URL, params: AutoHDR.BloomParams,
                                                 cgamut: Gamut, sgamut: Gamut, bake: Bool) async -> (CIImage?, URL?) {
        await Task.detached(priority: .userInitiated) { () -> (CIImage?, URL?) in
            guard let smallSDR = AutoHDR.downscaledJPEG(of: sdr, maxDim: 1600),
                  let tool = try? UHDRRunner.bundledToolURL() else { return (nil, nil) }
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("gm-preview-\(UUID().uuidString).jpg")
            var cleanup: [URL] = [smallSDR]
            let job: UHDRRunner.Job
            if bake {
                guard let inputs = try? AutoHDR.synthesizeInputs(from: smallSDR, params: params) else { return (nil, nil) }
                cleanup += [inputs.hdr.url, inputs.sdrJPEG]
                job = UHDRRunner.Job(hdr: .raw(inputs.hdr.url, w: inputs.hdr.width, h: inputs.hdr.height),
                                     sdr: inputs.sdrJPEG, out: out, cgamut: cgamut, sgamut: sgamut)
            } else {
                guard let buf = try? AutoHDR.synthesize(from: smallSDR, params: params) else { return (nil, nil) }
                cleanup.append(buf.url)
                job = UHDRRunner.Job(hdr: .raw(buf.url, w: buf.width, h: buf.height), sdr: smallSDR,
                                     out: out, cgamut: cgamut, sgamut: sgamut)
            }
            let outcome = await UHDRRunner().run(job, toolURL: tool)
            for u in cleanup { try? FileManager.default.removeItem(at: u) }
            guard case .success(let o, _) = outcome else { return (nil, nil) }
            // Decode with the gain map applied (true HDR), kept lazy → keep the file.
            return (CIImage(contentsOf: o, options: [.expandToHDR: true]), o)
        }.value
    }
}

// MARK: - Styled pane

struct HDRPreviewPane: View {
    let sdrURL: URL?
    let params: AutoHDR.BloomParams
    /// Gamuts threaded through so the settled preview matches the saved file's
    /// color (the accurate stage encodes with these; default rec709/sRGB).
    var cgamut: Gamut = .rec709
    var sgamut: Gamut = .rec709
    /// Bake the soft bloom into the SDR base (vs HDR-only glow) — affects the
    /// settled render so the preview reflects the chosen export mode.
    var bake: Bool = true
    /// Inline height (ignored when `expanded`, which fills the docked column).
    var height: CGFloat = 203
    /// Docked-to-side mode: taller, fills available height, collapse icon.
    var expanded: Bool = false
    /// Toggle the docked side layout (owned by the parent).
    var onToggleExpand: (() -> Void)? = nil
    /// When there's no image yet, clicking the empty preview triggers this (add a photo).
    var onRequestAdd: (() -> Void)? = nil

    @StateObject private var renderer = PreviewRenderer()
    @State private var showingOriginal = false

    // While the original is still loading, fall back to the HDR image so the
    // compare never flashes a previous photo.
    private var shown: CIImage? { showingOriginal ? (renderer.original ?? renderer.image) : renderer.image }
    private var hasImage: Bool { renderer.image != nil }

    var body: some View {
        ZStack {
            Color.black
            if let shown {
                EDRMetalView(image: shown)
            } else {
                LinearGradient(colors: [Theme.surface, Theme.surfaceHi], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 8) {
                    Image(systemName: onRequestAdd != nil ? "plus.circle" : "photo")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.stoneDim)
                    Text(onRequestAdd != nil ? "Click to add a photo" : "HDR preview")
                        .font(Theme.mono(11)).foregroundStyle(Theme.stoneDim)
                    if onRequestAdd != nil {
                        Text("or drop SDR JPEGs anywhere")
                            .font(Theme.mono(9)).foregroundStyle(Theme.stoneFaint)
                    }
                }
            }
        }
        .modifier(PreviewFrame(height: height, expanded: expanded, aspect: renderer.aspect))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 10)
        .overlay(alignment: .topLeading) { stateBadge }
        .overlay(alignment: .topTrailing) { controls }
        .overlay(alignment: .bottom) { compareHint }
        .contentShape(Rectangle())
        // Press-and-hold to peek the original (SDR); release snaps back to HDR.
        // Empty state: a tap requests adding a photo.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard hasImage, !showingOriginal else { return }
                    withAnimation(.easeOut(duration: 0.1)) { showingOriginal = true }
                }
                .onEnded { _ in
                    if hasImage {
                        withAnimation(.easeOut(duration: 0.1)) { showingOriginal = false }
                    } else {
                        onRequestAdd?()
                    }
                }
        )
        .onChange(of: sdrURL) { _, _ in showingOriginal = false; rerender() }
        // Editing a slider while viewing the original would otherwise leave a
        // frozen image and a dead-looking control — flip back to HDR so the change
        // is visible.
        .onChange(of: params) { _, _ in showingOriginal = false; rerender() }
        .onChange(of: cgamut) { _, _ in rerender() }
        .onChange(of: sgamut) { _, _ in rerender() }
        .onChange(of: bake) { _, _ in rerender() }
        .onAppear { rerender() }
    }

    private func rerender() {
        renderer.request(sdr: sdrURL, params: params, cgamut: cgamut, sgamut: sgamut, bake: bake)
    }

    // The top-left tag flips between the HDR look and the original SDR edit.
    private var stateBadge: some View {
        Text(showingOriginal ? "ORIGINAL · SDR" : "LIVE HDR")
            .font(Theme.mono(10, .semibold)).tracking(1.2)
            .foregroundStyle(showingOriginal ? Theme.inset : .white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((showingOriginal ? Theme.stone : Theme.accent).opacity(0.92),
                        in: RoundedRectangle(cornerRadius: 5))
            .padding(10)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if renderer.rendering {
                ProgressView().controlSize(.small).tint(.white)
            }
            if onToggleExpand != nil, hasImage {
                Button { onToggleExpand?() } label: {
                    Image(systemName: expanded
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(expanded ? "Dock preview back inline" : "Expand preview to the side")
            }
        }
        .padding(10)
    }

    @ViewBuilder private var compareHint: some View {
        if hasImage {
            Text(showingOriginal ? "showing your original — release for HDR"
                                 : "press & hold to compare original")
                .font(Theme.mono(9))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.black.opacity(0.4), in: Capsule())
                .padding(10)
        }
    }
}

/// Inline = fixed height; expanded = take the image's native aspect ratio so the
/// preview fills with NO letterbox bars (sized by the docked column's width).
private struct PreviewFrame: ViewModifier {
    let height: CGFloat
    let expanded: Bool
    let aspect: CGFloat?
    func body(content: Content) -> some View {
        if expanded {
            content
                .aspectRatio(aspect ?? (3.0 / 2.0), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.frame(height: height).frame(maxWidth: .infinity)
        }
    }
}
