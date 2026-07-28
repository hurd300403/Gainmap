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
import GainmapCore

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

    // The cached, downscaled SDR base (for the live proxy).
    private var baseURL: URL?
    private var baseImage: CIImage?
    private var loadTask: Task<Void, Never>?
    private var accurateTask: Task<Void, Never>?
    private var lastFile: URL?
    // Bumped on every request(); the accurate pass only applies if it's still the
    // current generation, so a slow stale render can't overwrite a fresh proxy.
    private var generation = 0

    deinit {
        // The settled preview keeps its decoded file alive (lazy CIImage);
        // reclaim it when the renderer goes away instead of waiting for macOS
        // to purge the temp directory.
        if let f = lastFile { try? FileManager.default.removeItem(at: f) }
    }
    // Latest inputs, so a base-load that finishes later renders with current values.
    private var curParams = AutoHDR.BloomParams()
    private var curBake = false

    /// Two-stage preview for real-time scrubbing:
    ///   • PROXY — render `bloomCIImage` (the same linear-HDR the export encodes)
    ///     straight to the EDR view on every change. No process spawn → instant,
    ///     so the look tracks the slider live.
    ///   • ACCURATE — ~200 ms after you stop, run the REAL gain-map export and
    ///     decode it, snapping the preview to the exact file (its L/K encoding).
    ///
    /// Both stages use the SAME params, so the live proxy can't show a different
    /// look than the file actually saves.
    func request(sdr: URL?, params: AutoHDR.BloomParams, bake: Bool = false) {
        // Stash the latest inputs so a base-load that finishes later renders with
        // CURRENT params, not whatever they were when the load kicked off.
        curParams = params; curBake = bake
        generation &+= 1
        guard let sdr else {
            loadTask?.cancel(); accurateTask?.cancel()
            image = nil; original = nil; aspect = nil
            baseImage = nil; baseURL = nil; rendering = false
            return
        }

        if sdr != baseURL {
            // New photo: cancel any in-flight render of the previous photo and drop
            // BOTH the stale HDR render and its original immediately — otherwise a
            // press-and-hold in the brief load window would compare against (or show)
            // the photo you came from. `hasImage` then stays false until this photo's
            // own render lands, so the gesture can't arm against a stale frame.
            baseURL = sdr
            baseImage = nil; original = nil; image = nil
            loadTask?.cancel(); accurateTask?.cancel()
            loadTask = Task { [weak self] in
                let base = await Task.detached(priority: .userInitiated) {
                    Self.baseCIImage(for: sdr)
                }.value
                if Task.isCancelled { return }
                // Guard by PHOTO IDENTITY, not generation: a same-photo re-request
                // (param/gamut change) must NOT discard this load, or baseImage /
                // original get stuck on the previous photo.
                guard let self, self.baseURL == sdr else { return }
                self.baseImage = base
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
        renderProxy(params: curParams)
        scheduleAccurate(sdr: sdr, params: curParams, bake: curBake, gen: generation)
    }

    /// Instant: build the bloom CIImage graph (cheap) and hand it to the EDR view.
    private func renderProxy(params: AutoHDR.BloomParams) {
        guard let base = baseImage,
              let proxy = AutoHDR.bloomCIImage(base: base, params: params) else { return }
        image = proxy
    }

    /// Debounced: replace the proxy with the real exported gain-map file, which
    /// uses the same `params` as the proxy — so the file matches it exactly.
    private func scheduleAccurate(sdr: URL, params: AutoHDR.BloomParams,
                                  bake: Bool, gen: Int) {
        accurateTask?.cancel()
        rendering = true
        accurateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)   // settle after last change
            if Task.isCancelled { return }
            let (ci, file) = await Self.renderExport(sdr: sdr, params: params, bake: bake)
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
                                                 bake: Bool) async -> (CIImage?, URL?) {
        await Task.detached(priority: .userInitiated) { () -> (CIImage?, URL?) in
            guard let smallSDR = AutoHDR.downscaledJPEG(of: sdr, maxDim: 1600) else { return (nil, nil) }
            // Same per-photo ICC-matched gamut as the real merge (a --sgamut that
            // disagrees with the JPEG's embedded profile hard-fails the tool, so a
            // fixed sRGB flag would break the settled preview for P3 photos).
            let gamut = Gamut.detect(of: smallSDR)
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("gm-preview-\(UUID().uuidString).jpg")
            var cleanup: [URL] = [smallSDR]
            let job: UHDRRunner.Job
            if bake {
                guard let inputs = try? AutoHDR.synthesizeInputs(from: smallSDR, params: params, gamut: gamut) else { return (nil, nil) }
                cleanup.append(inputs.sdrJPEG)
                job = UHDRRunner.Job(hdr: .rawBuffer(inputs.hdr),
                                     sdr: inputs.sdrJPEG, out: out, cgamut: gamut, sgamut: gamut)
            } else {
                guard let buf = try? AutoHDR.synthesize(from: smallSDR, params: params, gamut: gamut) else { return (nil, nil) }
                job = UHDRRunner.Job(hdr: .rawBuffer(buf), sdr: smallSDR,
                                     out: out, cgamut: gamut, sgamut: gamut)
            }
            // Same seam as real exports (in-process by default, CLI rollback
            // flag honored) — the settled preview IS the shipping encode path.
            let outcome = await UHDREncoding.run(job)
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
    /// Bake the soft bloom into the SDR base (vs HDR-only glow) — affects the
    /// settled render so the preview reflects the chosen export mode.
    var bake: Bool = false
    /// Inline height (ignored when `expanded`, which fills the docked column).
    var height: CGFloat = 203
    /// Docked-to-side mode: taller, fills available height, collapse icon.
    var expanded: Bool = false
    /// Toggle the docked side layout (owned by the parent).
    var onToggleExpand: (() -> Void)? = nil
    /// When there's no image yet, clicking the empty preview triggers this (add a photo).
    var onRequestAdd: (() -> Void)? = nil

    @StateObject private var renderer = PreviewRenderer()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Hold-to-lock state machine: idle → arming (peek + ring filling) → locked.
    // A quick release during arming is the momentary peek; holding past
    // `holdDuration` locks to SDR (persists after release); a tap unlocks.
    private enum HoldState { case idle, arming, locked }
    @State private var holdState: HoldState = .idle
    @State private var ringProgress: CGFloat = 0
    @State private var ringVisible = false           // gated by the grace delay
    @State private var cursor: CGPoint = .zero
    @State private var isPressing = false
    @State private var pressStart: Date?
    @State private var lockedThisGesture = false     // keeps the locking hold from self-unlocking
    @State private var holdTask: Task<Void, Never>?
    @State private var graceTask: Task<Void, Never>?

    private let holdDuration: TimeInterval = 1.0     // press → lock
    private let graceDelay: TimeInterval = 0.15      // ring stays hidden this long (pure peeks never flash it)

    private var locked: Bool { holdState == .locked }
    private var showSDR: Bool { holdState == .arming || holdState == .locked }
    // While the original is still loading, fall back to the HDR image so the
    // compare never flashes a previous photo.
    private var shown: CIImage? { showSDR ? (renderer.original ?? renderer.image) : renderer.image }
    private var hasImage: Bool { renderer.image != nil }

    var body: some View {
        ZStack {
            Color.black
            if let shown {
                EDRMetalView(image: shown).allowsHitTesting(false)
            } else {
                LinearGradient(colors: [Theme.surface, Theme.surfaceHi], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 10) {
                    if onRequestAdd != nil {
                        GainmapAddEmblem().frame(width: 60, height: 60)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Theme.stoneDim)
                    }
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
        // The hold-to-lock token: an amber padlock ring that fills at the cursor
        // while arming, then flies to the bottom-right corner and stays there as a
        // clickable chip while locked. Rendered after clipShape so it floats
        // unclipped; only hit-testable (to unlock) once locked.
        .overlay {
            GeometryReader { geo in
                if (holdState == .arming && ringVisible) || holdState == .locked {
                    let corner = CGPoint(x: geo.size.width - 28, y: geo.size.height - 28)
                    HoldLockRing(progress: ringProgress, locked: locked)
                        .position(locked ? corner : cursor)
                        .allowsHitTesting(locked)
                        .onTapGesture { unlock() }
                        .help(locked ? "Unlock — back to HDR" : "")
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .coordinateSpace(name: "preview")
        .contentShape(Rectangle())
        // Press-and-hold to peek the original (SDR); keep holding to lock it; tap to
        // unlock. Empty state: a tap requests adding a photo.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("preview"))
                .onChanged { v in
                    if !isPressing {
                        isPressing = true
                        pressStart = Date()
                        if holdState == .locked {
                            lockedThisGesture = false        // a fresh press on a locked preview = unlock intent
                        } else if holdState == .idle, hasImage {
                            beginArming(at: v.location)
                        }
                    } else if holdState == .arming {
                        cursor = v.location
                    }
                }
                .onEnded { v in
                    let elapsed = pressStart.map { Date().timeIntervalSince($0) } ?? 0
                    let dist = hypot(v.translation.width, v.translation.height)
                    let isTap = elapsed < 0.2 && dist < 6
                    switch holdState {
                    case .arming:
                        cancelArming(); holdState = .idle    // released before lock → momentary peek
                    case .locked:
                        if lockedThisGesture { break }       // release of the very hold that locked → keep
                        if isTap { unlock() }                // a tap → unlock to HDR
                    case .idle:
                        if !hasImage, isTap { onRequestAdd?() }
                    }
                    isPressing = false
                }
        )
        .onChange(of: sdrURL) { _, _ in resetHold(); rerender() }
        // Editing while viewing/locked to the original would leave a frozen,
        // dead-looking control (the SDR base doesn't change with HDR params) —
        // auto-unlock back to HDR so the change is visible.
        .onChange(of: params) { _, _ in resetHold(); rerender() }
        .onChange(of: bake) { _, _ in resetHold(); rerender() }
        .onAppear { rerender() }
    }

    private func rerender() {
        renderer.request(sdr: sdrURL, params: params, bake: bake)
    }

    // MARK: Hold-to-lock helpers

    private func beginArming(at loc: CGPoint) {
        holdState = .arming
        cursor = loc
        lockedThisGesture = false
        ringProgress = 0
        ringVisible = false
        // Grace: keep the ring hidden briefly so a reflexive quick-peek never flashes it.
        graceTask?.cancel()
        graceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(graceDelay))
            guard !Task.isCancelled, holdState == .arming else { return }
            ringVisible = true
            withAnimation(.linear(duration: holdDuration - graceDelay)) { ringProgress = 1 }
        }
        // Authoritative lock clock (independent of the fill animation).
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(holdDuration))
            guard !Task.isCancelled, holdState == .arming else { return }
            fireLock()
        }
    }

    private func cancelArming() {
        holdTask?.cancel(); holdTask = nil
        graceTask?.cancel(); graceTask = nil
        ringVisible = false
        withAnimation(.easeOut(duration: 0.18)) { ringProgress = 0 }
    }

    private func fireLock() {
        lockedThisGesture = true
        ringProgress = 1
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        // Animate the ring flying to the corner + morphing into the lock chip.
        withAnimation(reduceMotion ? .easeOut(duration: 0.2)
                                   : .spring(response: 0.45, dampingFraction: 0.72)) {
            holdState = .locked
        }
    }

    private func unlock() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        withAnimation(reduceMotion ? .easeOut(duration: 0.18)
                                   : .spring(response: 0.4, dampingFraction: 0.8)) {
            holdState = .idle
        }
    }

    /// Drop any peek/lock/arming state (used on new photo or on edit auto-unlock).
    /// Also clears the press latch — otherwise a gesture whose `onEnded` was dropped
    /// (interrupted by a re-render mid-press) would leave `isPressing` stuck true, so
    /// the next press hits the wrong branch and the hold silently stops working.
    private func resetHold() {
        cancelArming()
        holdState = .idle
        isPressing = false
        pressStart = nil
    }

    // The top-left tag: LIVE HDR (accent), ORIGINAL · SDR (stone, while peeking),
    // or LOCKED · SDR (amber + lock, while pinned to SDR).
    private var stateBadge: some View {
        let text = locked ? "LOCKED · SDR" : (showSDR ? "ORIGINAL · SDR" : "LIVE HDR")
        let fg: Color = (showSDR || locked) ? Theme.inset : .white
        let bg: Color = locked ? Theme.warn : (showSDR ? Theme.stone : Theme.accent)
        return HStack(spacing: 4) {
            if locked {
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
            }
            Text(text)
        }
        .font(Theme.mono(10, .semibold)).tracking(1.2)
        .foregroundStyle(fg)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(bg.opacity(0.92), in: RoundedRectangle(cornerRadius: 5))
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
                .accessibilityLabel(expanded ? "Dock preview back inline" : "Expand preview")
            }
        }
        .padding(10)
    }

    @ViewBuilder private var compareHint: some View {
        if hasImage {
            Text(locked ? "tap the lock to return to HDR"
                        : "press & hold to compare · keep holding to lock")
                .font(Theme.mono(9))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.black.opacity(0.4), in: Capsule())
                .padding(10)
        }
    }
}

/// The hold-to-lock indicator: while arming it's a JumpScrollKit-style amber
/// progress ring with an open padlock that fills at the cursor; on lock it morphs
/// into a compact amber-bordered chip with a closed padlock that lives in the
/// corner as the click-to-unlock target. On a dark backing disc so it reads over
/// any photo.
private struct HoldLockRing: View {
    let progress: CGFloat
    let locked: Bool
    private var disc: CGFloat { locked ? 30 : 40 }
    var body: some View {
        ZStack {
            // Legibility backing — a dark disc with a hairline (amber once locked).
            Circle()
                .fill(.black.opacity(locked ? 0.5 : 0.42))
                .overlay(Circle().stroke(locked ? Theme.warn.opacity(0.9) : .white.opacity(0.08),
                                         lineWidth: locked ? 1.5 : 1))
                .frame(width: disc, height: disc)
                .shadow(color: .black.opacity(0.5), radius: 6)
            // Track + amber progress arc — only while filling (fades out on lock).
            if !locked {
                Circle().stroke(.white.opacity(0.25), lineWidth: 3)
                    .frame(width: 26, height: 26)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.warn, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 26, height: 26)
            }
            // open padlock while filling → closed amber padlock once locked.
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .font(.system(size: locked ? 13 : 11, weight: .bold))
                .foregroundStyle(locked ? Theme.warn : .white)
                .contentTransition(.symbolEffect(.replace))
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
