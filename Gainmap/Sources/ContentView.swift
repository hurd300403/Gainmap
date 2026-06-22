//
//  ContentView.swift
//  Gainmap
//
//  The single Gainmap window. Mirrors mockups/gainmap.html: a warm-dark bench
//  with two input plates fusing through the aperture, a merge action, a
//  collapsible export-settings panel, and a result card with the instrument
//  readout. Translation of the HTML spec 1:1.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = MergeModel()
    @State private var showSettings = false
    @State private var showAdvancedLook = false
    // Which advanced groups are expanded. All open by default so nothing is hidden
    // on first look; the grouping (not the collapse) is what tames the complexity.
    @State private var expandedGroups: Set<String> = ["glow", "color", "hdr", "auto"]
    @State private var window: NSWindow?
    @State private var shareHover = false
    @State private var showShareModal = false
    // Confirm + explain before baking the glow into the SDR base (it makes the
    // non-HDR/fallback version look brighter/blown, which surprises people).
    @State private var showGlowInSDRInfo = false

    // The Patreon post where the app can be downloaded — shown in the share modal
    // so patrons can copy/pass the link along. TODO: confirm exact download-post URL.
    private let shareURL = URL(string: "https://www.patreon.com/samhurd")!

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            // Warm glow behind the bench.
            RadialGradient(colors: [Theme.accent.opacity(0.10), .clear],
                           center: .top, startRadius: 0, endRadius: 380)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 38)
                    .padding(.top, 18)
                    .padding(.bottom, 16)

                // Two static columns: the live preview is pinned on the left and
                // never moves; only the controls column on the right scrolls — so
                // dialing settings never nudges the photo you're judging.
                HStack(alignment: .top, spacing: 22) {
                    VStack(spacing: 10) {
                        HDRPreviewPane(sdrURL: model.sdrURL, params: model.bloom,
                                       cgamut: model.cgamut, sgamut: model.sgamut, bake: model.bakeGlowIntoSDR,
                                       expanded: true,
                                       onRequestAdd: model.items.isEmpty ? { addPhotos() } : nil)
                        Text(model.items.isEmpty ? "click the preview or drop SDR JPEGs anywhere to begin"
                                                 : "live HDR preview · press & hold to compare original")
                            .font(Theme.mono(10)).foregroundStyle(Theme.stoneDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            BatchFilmstrip(model: model)
                            bloomControls.padding(.top, 14)
                            if !model.items.isEmpty { autoResultStrip }
                            footer.padding(.top, 24)
                        }
                        .padding(.bottom, 10)
                    }
                    .frame(width: 408)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 38)
                .padding(.bottom, 14)
            }
            // Drop SDR JPEGs anywhere in the window to add to the queue.
            .onDrop(of: [.fileURL], isTargeted: nil, perform: handleWindowDrop)
            // Pin the Save/Prev/Next bar to the bottom so it's ALWAYS reachable.
            .safeAreaInset(edge: .bottom, spacing: 0) { pinnedActionBar }
            // Reclaim the ~28pt the hidden title bar reserves as top safe area, so
            // the (right-justified) header rides right up to the window edge. Safe
            // because the macOS traffic lights live top-LEFT, where we keep empty.
            .ignoresSafeArea(.container, edges: .top)

            if showShareModal {
                ShareModal(url: shareURL) {
                    withAnimation(.easeOut(duration: 0.18)) { showShareModal = false }
                }
                .transition(.opacity)
                .zIndex(10)
            }

            if showGlowInSDRInfo {
                GlowInSDRModal(
                    onEnable: {
                        model.bakeGlowIntoSDR = true
                        withAnimation(.easeOut(duration: 0.18)) { showGlowInSDRInfo = false }
                    },
                    onCancel: {
                        withAnimation(.easeOut(duration: 0.18)) { showGlowInSDRInfo = false }
                    })
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(WindowAccessor { window = $0 })
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        // Resize the window to the FIRST imported photo's aspect (auto mode) so the
        // preview fills with no letterbox bars. Doesn't re-resize as you navigate.
        .onChange(of: model.items.isEmpty) { wasEmpty, isEmpty in
            guard wasEmpty, !isEmpty, model.mode == .auto,
                  let url = model.items.first?.sdrURL,
                  let size = ImageInfo.pixelSize(of: url), size.height > 0 else { return }
            sizeWindowToAspect(size.width / size.height)
        }
    }

    /// Set the window so the left preview column matches `aspect` (no bars).
    private func sizeWindowToAspect(_ aspect: CGFloat) {
        guard let window else { return }
        let controlsColumn: CGFloat = 408
        let horizontalChrome: CGFloat = 38 * 2 + 22      // outer padding + column spacing
        let verticalChrome: CGFloat = 320               // header + labels + footer + paddings (approx)
        let targetPreviewH: CGFloat = 660
        let previewW = min(1280, max(420, targetPreviewH * aspect))
        let previewH = previewW / aspect
        let contentW = max(900, previewW + controlsColumn + horizontalChrome)
        let contentH = max(620, previewH + verticalChrome)
        var frame = window.frame
        let newContent = NSSize(width: contentW, height: contentH)
        let delta = window.frameRect(forContentRect: NSRect(origin: .zero, size: newContent)).size
        frame.origin.y += frame.size.height - delta.height   // keep top-left anchored
        frame.size = delta
        window.setFrame(frame, display: true, animate: true)
    }

    private func addPhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg]
        panel.prompt = "Add"
        panel.message = "Choose SDR JPEGs to add"
        if panel.runModal() == .OK { model.addFiles(panel.urls) }
    }

    private func handleWindowDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.mode == .auto else { return false }
        var urls = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (i, p) in providers.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in urls[i] = u; group.leave() }
        }
        group.notify(queue: .main) { model.addFiles(urls.compactMap { $0 }) }
        return true
    }

    // MARK: Header

    private var header: some View {
        // Branding right-justified (clears the macOS traffic-light buttons); a small
        // native share button fills the otherwise-empty top-left.
        HStack(spacing: 16) {
            shareButton
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                (Text("Gain").foregroundStyle(Color.white)
                 + Text("map").foregroundStyle(Theme.accent))
                    .font(Theme.display(30, .semibold))
                Text("Fuse an SDR + HDR edit into one UltraHDR JPEG — clean highlights everywhere.")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.stoneDim)
            }
            GainmapEmblem()
                .frame(width: 54, height: 54)
                .shadow(color: .black.opacity(0.5), radius: 7, y: 4)
        }
    }

    // MARK: Bench (idle / error / merging)

    // NOTE: the Auto/Advanced mode picker is hidden for now — the app runs the
    // one-photo (Auto) flow only. The two-file (Advanced) views below are kept
    // intact so the mode can be re-enabled later without rebuilding them.

    // Advanced = HDR TIFF + SDR JPEG, one shot.
    private var advancedSection: some View {
        VStack(spacing: 0) {
            if model.phase == .error, let msg = model.errorMessage {
                ErrorBanner(message: msg).padding(.bottom, 16)
            }
            advancedBench
            mergeAction.padding(.top, 24)
        }
    }

    @ViewBuilder private var autoResultStrip: some View {
        if let sel = model.selectedItem {
            if sel.status == .done {
                savedStrip(sel).padding(.top, 16)
            } else if sel.status == .error, let e = sel.error {
                ErrorBanner(message: e).padding(.top, 16)
            }
        }
    }

    // MARK: Queue navigation + save bar (auto mode)

    /// The Save/Prev/Next bar, pinned to the bottom of the window (auto mode) so
    /// the slider stack can never push it off-screen.
    @ViewBuilder private var pinnedActionBar: some View {
        if model.mode == .auto, !model.items.isEmpty {
            queueBar
                .padding(.horizontal, 38)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .background(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                .background(Theme.inset.opacity(0.97))
        }
    }

    private var queueBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                stepButton(system: "chevron.left", label: "Prev",
                           enabled: model.hasPrevious) { model.selectPrevious() }

                Button(action: { Task { await model.saveSelectedAndAdvance() } }) {
                    HStack(spacing: 10) {
                        if model.phase == .merging {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: saveGlyph)
                        }
                        Text(saveLabel).font(Theme.ui(14.5, .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: model.canSaveSelected ? [Theme.accentHot, Theme.accent]
                                                          : [Theme.surfaceHi, Theme.surface],
                            startPoint: .top, endPoint: .bottom)))
                    .overlay(Capsule().stroke(Theme.accent.opacity(model.canSaveSelected ? 0.4 : 0), lineWidth: 1))
                    .shadow(color: Theme.accent.opacity(model.canSaveSelected ? 0.45 : 0), radius: 16, y: 7)
                }
                .buttonStyle(.plain)
                .disabled(!model.canSaveSelected)

                stepButton(system: "chevron.right", label: "Next",
                           enabled: model.hasNext) { model.selectNext() }

                if model.selectedItem?.status == .done {
                    stepButton(system: "magnifyingglass", label: "Finder",
                               enabled: true) { revealSelected() }
                }
            }

            HStack(spacing: 14) {
                if let i = model.selectedIndex {
                    Text("\(i + 1) of \(model.items.count)")
                        .font(Theme.mono(11, .semibold)).foregroundStyle(.white)
                }
                Text("\(model.savedCount) saved")
                    .font(Theme.mono(11)).foregroundStyle(Theme.goldDeep)
                Spacer()
                if model.canPaste && model.items.count > 1 {
                    Button("Paste to all") { model.pasteLookToAll() }
                        .buttonStyle(.plain)
                        .font(Theme.mono(11, .semibold)).foregroundStyle(Theme.stone)
                        .help("Apply the copied look to every photo in the queue")
                }
                Button(action: { Task { await model.exportAll() } }) {
                    Text(model.pendingCount > 0 ? "Export all · \(model.pendingCount) left" : "All saved ✓")
                        .font(Theme.mono(11, .semibold))
                        .foregroundStyle(model.canExportAll ? Theme.accentHot : Theme.stoneDim)
                }
                .buttonStyle(.plain)
                .disabled(!model.canExportAll)
            }
        }
    }

    private func stepButton(system: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: system).font(.system(size: 13, weight: .semibold))
                Text(label).font(Theme.mono(8.5, .semibold)).tracking(0.5)
            }
            .foregroundStyle(enabled ? Theme.stone : Theme.stoneFaint)
            .frame(width: 58)
            .padding(.vertical, 11)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var saveGlyph: String {
        guard let s = model.selectedItem?.status else { return "sun.max.fill" }
        return s == .done ? "arrow.clockwise" : "sun.max.fill"
    }

    private var saveLabel: String {
        if model.phase == .merging { return "Saving…" }
        let done = model.selectedItem?.status == .done
        if model.hasNext { return done ? "Re-save & Next" : "Save & Next" }
        return done ? "Re-save" : "Save"
    }

    private func savedStrip(_ item: MergeModel.BatchItem) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 17)).foregroundStyle(Theme.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved beside the original")
                    .font(Theme.ui(11.5, .medium)).foregroundStyle(.white)
                Text(item.outputURL?.lastPathComponent ?? "—")
                    .font(Theme.mono(9.5)).foregroundStyle(Theme.stoneDim)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let r = item.readout {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.2f× · %d nits", r.peakBoost, r.targetNits))
                        .font(Theme.mono(11, .medium)).foregroundStyle(Theme.gold)
                    Text(String(format: "%.2f stops headroom", r.stops))
                        .font(Theme.mono(9)).foregroundStyle(Theme.stoneDim)
                }
                .fixedSize()
            }
        }
        .padding(13)
        .background(Theme.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.gold.opacity(0.3), lineWidth: 1))
    }

    private func revealSelected() {
        if let url = model.selectedItem?.outputURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private var advancedBench: some View {
        HStack(spacing: 10) {
            DropWell(role: .hdr, url: model.hdrURL) { model.accept($0) }
            ApertureIris(spinning: model.phase == .merging).frame(width: 74, height: 74)
            DropWell(role: .sdr, url: model.sdrURL) { model.accept($0) }
        }
    }

    // Binding that drives the whole look from one 0…1 intensity.
    private var intensityBinding: Binding<Double> {
        Binding(get: { model.intensity }, set: { model.setIntensity($0) })
    }

    private var bloomControls: some View {
        VStack(spacing: 13) {
            HStack(spacing: 12) {
                Text("HDR LOOK").font(Theme.mono(11, .semibold)).tracking(2).foregroundStyle(Theme.gold)
                Spacer()
                Button("Copy") { model.copyLook() }
                    .buttonStyle(.plain)
                    .font(Theme.mono(10, .semibold)).foregroundStyle(Theme.stoneDim)
                    .help("Copy this photo's look")
                Button("Paste") { model.pasteLook() }
                    .buttonStyle(.plain)
                    .font(Theme.mono(10, .semibold))
                    .foregroundStyle(model.canPaste ? Theme.stone : Theme.stoneFaint)
                    .disabled(!model.canPaste)
                    .help("Paste the copied look onto this photo")
                Button("Reset") { model.resetToDefault() }
                    .buttonStyle(.plain)
                    .font(Theme.mono(10, .semibold)).foregroundStyle(Theme.accentHot)
                    .help("Snap this photo back to your default look (set it under Advanced controls ▸ Save as default).")
            }

            // The one slider most people ever touch: blend the signature look from
            // subtle to full.
            sliderRow("INTENSITY", intensityBinding, 0...1, fmt: "%.0f%%", "subtle", "full", scale: 100,
                      resetTo: 1.0,
                      help: "Overall strength of the HDR pop. Slide down for a subtle effect, up for full punch — it blends all the Advanced settings at once.")

            Divider().overlay(Theme.line)
            Button(action: { withAnimation(.easeOut(duration: 0.22)) { showAdvancedLook.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showAdvancedLook ? 90 : 0))
                    Text("Advanced controls")
                        .font(Theme.mono(10, .semibold)).tracking(1.5)
                    Spacer()
                }
                .foregroundStyle(Theme.stoneDim)
            }
            .buttonStyle(.plain)

            if showAdvancedLook {
                // The saved "default look" the top "Reset" (and double-click) snap back
                // to. Real boxed buttons so it's obviously clickable; left-justified
                // with an inline caption so it doesn't waste the row's width.
                HStack(spacing: 9) {
                    boxedButton(model.hasCustomDefault ? "Update default" : "Save as default",
                                tint: Theme.gold) {
                        model.setSignatureFromCurrent()
                    }
                    .help("Make the current look your default — the 100% Intensity preset and what “Reset” (and double-clicking a slider) snaps back to. Kept across launches.")
                    if model.hasCustomDefault {
                        boxedButton("Restore app default", tint: Theme.stoneDim) {
                            model.restoreBuiltInDefault()
                        }
                        .help("Replace your saved default with the look Gainmap originally shipped with. “Reset” will then snap to that.")
                    } else {
                        // "Reset" tinted to match the actual Reset button (accentHot).
                        (Text("what ").foregroundStyle(Theme.stoneDim)
                         + Text("“Reset”").foregroundStyle(Theme.accentHot)
                         + Text(" snaps to").foregroundStyle(Theme.stoneDim))
                            .font(Theme.mono(8.5))
                    }
                    Spacer(minLength: 0)
                }

                // THE GLOW — shape & strength of the bloom.
                lookGroup("glow", "THE GLOW", "how the highlights bloom") {
                    sliderRow("GLOW", $model.bloom.glow, 0...1.5, fmt: "%.2f", "none", "bright",
                              resetTo: model.signature.glow,
                              help: "How much the bright areas bloom and spill light. Higher = brighter, dreamier highlights.")
                    sliderRow("SPREAD", $model.bloom.spread, 0.002...0.025, fmt: "%.1f%%", "tight", "wide", scale: 100,
                              resetTo: model.signature.spread,
                              help: "Size of the glow halo around bright areas. Tight = crisp and contained; wide = soft and dreamy.")
                    sliderRow("PUNCH", $model.bloom.punch, 0...1, fmt: "%.2f", "soft glow", "sharp pop",
                              resetTo: model.signature.punch,
                              help: "The character of the glow. Left = soft, dreamy bloom; right = sharp, snappy highlights.")
                    sliderRow("FALLOFF", $model.bloom.falloff, 0.5...2.0, fmt: "%.2f", "hard", "smooth",
                              resetTo: model.signature.falloff,
                              help: "How abruptly the glow ramps up in the highlights. Hard = sudden onset; smooth = gradual and gentle.")
                }

                // COLOR — the color of the glow.
                lookGroup("color", "COLOR", "the color of that light") {
                    sliderRow("GLOW COLOR", $model.bloom.saturation, 0...1.5, fmt: "%.2f", "white", "vivid",
                              resetTo: model.signature.saturation,
                              help: "How colorful the glow is. White = neutral light; vivid = keeps the scene's own color in the glow.")
                    sliderRow("TINT", $model.bloom.tint, -1...1, fmt: "%+.2f", "cool", "warm",
                              resetTo: model.signature.tint,
                              help: "Warmth of the glow. Cool leans blue; warm leans golden-hour.")
                }

                // HDR & SCREENS — how the effect shows across displays.
                lookGroup("hdr", "HDR & SCREENS", "how it shows across displays") {
                    sliderRow("HEADROOM", $model.bloom.headroom, 1...3, fmt: "%.1f×", "natural", "intense",
                              resetTo: model.signature.headroom,
                              help: "How far the bright tones climb on HDR screens. Higher makes highlights glow harder on HDR-capable displays (little effect on regular screens or the SDR fallback).")
                    sliderRow("THRESHOLD", $model.bloom.threshold, 0.3...0.95, fmt: "%.0f%%", "everything", "specular", scale: 100,
                              resetTo: model.signature.threshold,
                              help: "Which areas get the HDR treatment. Left = most of the image brightens; right = only the very brightest spots, like the sun or shiny reflections.")
                    HStack {
                        // Turning it ON opens an explainer first (so the brighter/blown
                        // SDR fallback doesn't surprise anyone); turning OFF is instant.
                        Toggle("GLOW IN SDR", isOn: Binding(
                            get: { model.bakeGlowIntoSDR },
                            set: { wantOn in
                                if wantOn && !model.bakeGlowIntoSDR {
                                    showGlowInSDRInfo = true
                                } else {
                                    model.bakeGlowIntoSDR = wantOn
                                }
                            }))
                            .toggleStyle(.switch)
                            .font(Theme.mono(10, .semibold))
                            .foregroundStyle(Theme.stoneDim)
                            .help("SDR = the standard, non-HDR version of your photo (a regular JPEG — what most screens and apps show). On: the soft glow is baked into that SDR version so it shows on every screen. Off: the SDR version stays pixel-identical to your input, and the glow appears only on HDR displays.")
                        InfoButton(title: "GLOW IN SDR",
                                   text: "“SDR” is the standard, non-HDR version of your photo — a regular JPEG, the kind every screen and app can show. Your export always tucks one inside as the fallback for non-HDR screens.\n\nOn: the soft glow is baked into that SDR version, so your look carries everywhere (the fallback is your bloomed photo, not the untouched original).\n\nOff: the SDR version is pixel-identical to the file you started with, and the glow lives only in the HDR layer — so it appears only on HDR-capable displays.")
                        Spacer()
                        Text(model.bakeGlowIntoSDR ? "shows on every screen" : "HDR screens only")
                            .font(Theme.mono(9)).foregroundStyle(Theme.stoneFaint)
                    }
                }

                // AUTO — per-photo auto-tuning (Adapt + HL Guard only matter when on).
                lookGroup("auto", "AUTO", "let Gainmap tune each photo") {
                    HStack {
                        Toggle("AUTO", isOn: $model.bloom.autoAdapt)
                            .toggleStyle(.switch)
                            .font(Theme.mono(10, .semibold))
                            .foregroundStyle(Theme.stoneDim)
                            .help("Auto-adjusts the look for each photo based on how bright it is. Off = your sliders apply exactly as set.")
                        Spacer()
                        Text(model.bloom.autoAdapt ? "tunes each photo" : "sliders apply as set")
                            .font(Theme.mono(9)).foregroundStyle(Theme.stoneFaint)
                    }
                    if model.bloom.autoAdapt {
                        sliderRow("ADAPT", $model.bloom.adaptAmount, 0...1, fmt: "%.0f%%", "fixed", "dynamic", scale: 100,
                                  resetTo: model.signature.adaptAmount,
                                  help: "How strongly AUTO retunes the look per photo. Fixed = your settings as-is; dynamic = more automatic adjustment.")
                        sliderRow("HL GUARD", $model.bloom.highlightGuard, 0...1, fmt: "%.0f%%", "loose", "strict", scale: 100,
                                  resetTo: model.signature.highlightGuard,
                                  help: "Protects already-bright photos from blowing out. Stricter pulls the effect back more on high-key images.")
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                           fmt: String, _ left: String, _ right: String, scale: Double = 1,
                           resetTo: Double? = nil, help: String = "") -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Text(title).font(Theme.mono(10, .semibold)).tracking(1)
                    .foregroundStyle(Theme.stoneDim).lineLimit(1)
                if !help.isEmpty { InfoButton(title: title, text: help) }
            }
            .frame(width: 108, alignment: .leading)
            VStack(spacing: 2) {
                // Double-click the slider snaps this one control back to the saved
                // default (the same value the top "Reset" uses). Native Slider can't
                // see the click, so this wraps NSSlider with a real double-click
                // recognizer that coexists with normal dragging.
                ResettableSlider(value: value, range: range) {
                    if let d = resetTo { value.wrappedValue = d }
                }
                HStack { Text(left); Spacer(); Text(right) }
                    .font(Theme.mono(8.5)).foregroundStyle(Theme.stoneFaint)
            }
            Text(String(format: fmt, value.wrappedValue * scale))
                .font(Theme.mono(11)).foregroundStyle(Theme.gold)
                .frame(width: 44, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .help(resetTo == nil || help.isEmpty ? help
              : help + "\n\nDouble-click the slider to reset it to your default.")
    }

    /// A small bordered, tappable button matching the clustered advanced-controls
    /// style — used for the "default look" actions so they read clearly as buttons.
    private func boxedButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.mono(10, .semibold)).foregroundStyle(tint)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    /// A collapsible, titled card that groups related look controls. The plain-language
    /// subtitle does the explaining the info buttons used to, so the panel reads at a glance.
    @ViewBuilder
    private func lookGroup<Content: View>(_ id: String, _ title: String, _ subtitle: String,
                                          @ViewBuilder _ content: () -> Content) -> some View {
        let expanded = expandedGroups.contains(id)
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    if expanded { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(title).font(Theme.mono(10, .semibold)).tracking(1).foregroundStyle(Theme.stone)
                    Text(subtitle).font(Theme.ui(11)).foregroundStyle(Theme.stoneDim)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.stoneDim)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .padding(.horizontal, 13).padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(spacing: 4) { content() }
                    .padding(.horizontal, 13)
                    .padding(.top, 1)
                    .padding(.bottom, 10)
            }
        }
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
    }

    private var mergeAction: some View {
        VStack(spacing: 14) {
            Button(action: { Task { await model.mergeAdvanced() } }) {
                HStack(spacing: 11) {
                    if model.phase == .merging {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "sun.max.fill")
                    }
                    Text(model.phase == .merging ? "Merging…" : "Merge to UltraHDR")
                        .font(Theme.ui(15, .semibold))
                }
                .foregroundStyle(.white)
                .padding(.vertical, 15).padding(.horizontal, 38)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: model.canMergeAdvanced ? [Theme.accentHot, Theme.accent]
                                                       : [Theme.surfaceHi, Theme.surface],
                        startPoint: .top, endPoint: .bottom)))
                .overlay(Capsule().stroke(Theme.accent.opacity(model.canMergeAdvanced ? 0.4 : 0), lineWidth: 1))
                .shadow(color: Theme.accent.opacity(model.canMergeAdvanced ? 0.5 : 0), radius: 18, y: 8)
            }
            .buttonStyle(.plain)
            .disabled(!model.canMergeAdvanced)

            HStack(spacing: 8) {
                Circle().fill(Theme.goldDeep).frame(width: 5, height: 5)
                    .shadow(color: Theme.goldDeep, radius: 4)
                Text("99.9th-pct peak · K=1.05 margin · ISO 21496-1 gain map")
            }
            .font(Theme.mono(11))
            .foregroundStyle(Theme.stoneDim)
        }
    }

    // MARK: Export settings (disclosure)

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Theme.line)
            Button(action: { withAnimation(.easeOut(duration: 0.28)) { showSettings.toggle() } }) {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(showSettings ? 90 : 0))
                    Text("Export settings & Lightroom how-to")
                        .font(Theme.ui(12, .semibold)).tracking(1)
                        .textCase(.uppercase)
                }
                .foregroundStyle(Theme.stoneDim)
            }
            .buttonStyle(.plain)
            .padding(.top, 18)

            if showSettings {
                HStack(alignment: .top, spacing: 22) {
                    gamutField("HDR color gamut", flag: "--cgamut",
                               selection: $model.cgamut, label: \.hdrLabel,
                               recommended: "Rec.709 (recommended)")
                    gamutField("SDR color gamut", flag: "--sgamut",
                               selection: $model.sgamut, label: \.sdrLabel,
                               recommended: "sRGB (recommended)")
                }
                .padding(.top, 18)
                howto.padding(.top, 18)
            }
        }
    }

    private func gamutField(_ title: String, flag: String,
                            selection: Binding<Gamut>,
                            label: KeyPath<Gamut, String>,
                            recommended: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title).font(Theme.ui(11)).foregroundStyle(Theme.stoneDim)
                Text(flag).font(Theme.mono(10)).foregroundStyle(Theme.stoneFaint)
            }
            GamutSegments(selection: selection, label: label)
            Text(recommended).font(Theme.mono(9.5)).foregroundStyle(Theme.goldDeep)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var howto: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EXPORTING FROM LIGHTROOM CLASSIC")
                .font(Theme.mono(10, .semibold)).tracking(1)
                .foregroundStyle(Theme.goldDeep)
            howtoRow("HDR copy → TIFF · 32-bit float · HDR display on · Maximize Compatibility OFF · no compression")
            howtoRow("SDR base → JPEG · sRGB · quality ~92 · same resolution as the TIFF")
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
    }

    private func howtoRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("›").foregroundStyle(Theme.accent).font(Theme.ui(12, .bold))
            Text(text).font(Theme.ui(12)).foregroundStyle(Theme.stoneDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Text("A ").foregroundStyle(Theme.stoneFaint)
                Text("LEGACY LAB")
                    .foregroundStyle(Theme.accent)
                    .onTapGesture {
                        if let u = URL(string: "https://thisisthelegacylab.com/") { NSWorkspace.shared.open(u) }
                    }
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    .help("thisisthelegacylab.com")
                Text(" INSTRUMENT · BUILT ON LIBULTRAHDR").foregroundStyle(Theme.stoneFaint)
            }
            .font(Theme.mono(10)).tracking(1.4)

            patronsLink
        }
        .frame(maxWidth: .infinity)
    }

    /// Patron credit — a direct link to Patreon so anyone the app is shared with
    /// can find it. (Confirm the exact URL.)
    private var patronsLink: some View {
        (Text("Made possible by my ").foregroundStyle(Theme.stoneDim)
         + Text("patrons").foregroundStyle(Theme.accent)
         + Text(" ❤️"))
            .font(Theme.mono(10)).tracking(1.0)
            .onTapGesture {
                if let u = URL(string: "https://www.patreon.com/samhurd") { NSWorkspace.shared.open(u) }
            }
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("Support Sam on Patreon")
    }

    /// Native macOS share button (top-left) — pops Messages / Mail / AirDrop /
    /// Opens the in-app share card with the Patreon download link.
    private var shareButton: some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { showShareModal = true } } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 14, weight: .semibold))
                Text("Share a link").font(Theme.mono(13, .semibold)).tracking(1.5)
            }
            .foregroundStyle(shareHover ? .white : Theme.accent)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Capsule().fill(shareHover ? Theme.accent : Theme.accent.opacity(0.14)))
            .overlay(Capsule().stroke(Theme.accent.opacity(shareHover ? 0 : 0.55), lineWidth: 1))
            .shadow(color: Theme.accent.opacity(shareHover ? 0.45 : 0), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.leading, 44)        // clear the macOS traffic-light buttons
        .onHover { shareHover = $0 }
        .help("Share the download link with someone")
    }
}

// MARK: - Share modal (in-app share card → Patreon download link)

/// A custom share card: a hero shot of Sam's Patreon, a short "this is supported
/// by patrons" note, the download link, and Copy-link / Open-Patreon actions.
private struct ShareModal: View {
    let url: URL
    var onClose: () -> Void
    @State private var copied = false

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.62)).ignoresSafeArea()
                .onTapGesture(perform: onClose)

            card
                .frame(width: 460)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.85), .black.opacity(0.45))
                            .padding(10)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
                .shadow(color: .black.opacity(0.55), radius: 34, y: 14)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image("PatreonHero")
                .resizable().aspectRatio(contentMode: .fill)
                .frame(height: 184)          // matches the 2.5:1 banner crop at 460pt wide
                .frame(maxWidth: .infinity)
                .clipped()

            VStack(alignment: .leading, spacing: 14) {
                Text("Share Gainmap")
                    .font(Theme.mono(17, .semibold)).foregroundStyle(.white)

                Text("Gainmap is free for my Patreon community. If it's useful to you, passing the download link along is the kindest thanks — and a great way to support the work that keeps it free. ❤️")
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.stone)
                    .lineSpacing(3.5)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Image(systemName: "link").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.stoneDim)
                    Text(url.absoluteString.replacingOccurrences(of: "https://", with: ""))
                        .font(Theme.mono(10)).foregroundStyle(Theme.stoneDim)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))

                HStack(spacing: 10) {
                    Button(action: copyLink) {
                        HStack(spacing: 7) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc.fill")
                            Text(copied ? "Copied!" : "Copy link")
                        }
                        .font(Theme.mono(12.5, .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Capsule().fill(Theme.accent))
                    }
                    .buttonStyle(.plain)

                    Button { NSWorkspace.shared.open(url); onClose() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.up.forward")
                            Text("Open Patreon")
                        }
                        .font(Theme.mono(12.5, .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Capsule().fill(Theme.accent.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        withAnimation { copied = true }
    }
}

/// Explainer shown the moment someone flips "Glow in SDR" on, so the brighter /
/// blown-looking non-HDR fallback reads as a deliberate trade-off, not a bug.
private struct GlowInSDRModal: View {
    var onEnable: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.62)).ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 11) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.warn)
                    Text("Bake the glow into SDR?")
                        .font(Theme.mono(16, .semibold)).foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 11) {
                    Text("“SDR” is the standard, non-HDR copy tucked inside every export — what thumbnails, social apps, and any screen that ignores the gain map fall back to.")
                    Text("Turning this on bakes the soft glow into that copy, so your look carries to those places too. The trade-off: the non-HDR copy reads brighter, and bright areas can look blown out. That's expected — not a bug.")
                    (Text("Leaving it off ").foregroundStyle(Theme.stone)
                     + Text("(recommended)").foregroundStyle(Theme.gold)
                     + Text(" keeps that copy identical to your original; the glow then shows only on HDR displays.").foregroundStyle(Theme.stone))
                }
                .font(Theme.mono(11.5)).foregroundStyle(Theme.stone)
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(action: onCancel) {
                        Text("Keep it off")
                            .font(Theme.mono(12.5, .semibold)).foregroundStyle(Theme.stone)
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Capsule().fill(Theme.surfaceHi))
                            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)

                    Button(action: onEnable) {
                        Text("Turn it on")
                            .font(Theme.mono(12.5, .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Capsule().fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
            .frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 34, y: 14)
        }
    }
}

// MARK: - Window accessor (to resize to the first image's aspect)

struct WindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onResolve(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { onResolve(w) } }
    }
}

// MARK: - Info button (click for a plain-English explanation)

struct InfoButton: View {
    let title: String
    let text: String
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(show ? Theme.accent : Theme.info)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.mono(10, .semibold)).tracking(1).foregroundStyle(Theme.gold)
                Text(text).font(Theme.ui(12.5)).foregroundStyle(Theme.stone)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 260)
            .background(Theme.surface)
        }
    }
}

// MARK: - Segmented gamut control

struct GamutSegments: View {
    @Binding var selection: Gamut
    let label: KeyPath<Gamut, String>

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Gamut.allCases) { g in
                let on = g == selection
                Button(action: { selection = g }) {
                    Text(g[keyPath: label])
                        .font(Theme.ui(11.5, .medium))
                        .foregroundStyle(on ? .white : Theme.stoneDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(on ? Theme.surfaceHi : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
    }
}

// MARK: - Error banner

struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.accentHot)
            VStack(alignment: .leading, spacing: 3) {
                Text("Couldn't merge").font(Theme.ui(13, .semibold)).foregroundStyle(.white)
                Text(message).font(Theme.ui(12)).foregroundStyle(Theme.stoneDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.accent.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Result card

struct ResultCard: View {
    @ObservedObject var model: MergeModel
    @State private var preview: CIImage?

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let preview {
                            // Render the exported gain-map file as true EDR (same
                            // path as the live preview) so the result matches it —
                            // a plain thumbnail would show only the flat SDR base.
                            EDRMetalView(image: preview)
                        } else {
                            LinearGradient(stops: [
                                .init(color: Color(hex: 0x3A2D22), location: 0),
                                .init(color: Color(hex: 0x8A5A32), location: 0.38),
                                .init(color: Theme.gold, location: 0.70),
                                .init(color: Color(hex: 0xFFF6E6), location: 1.0),
                            ], startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                    }
                    .frame(height: 230).frame(maxWidth: .infinity).clipped()

                    Text("HDR ✓")
                        .font(Theme.mono(11, .semibold)).tracking(1.2)
                        .foregroundStyle(Theme.inset)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(LinearGradient(colors: [Color(hex: 0xF6E4C0), Theme.gold],
                                                   startPoint: .top, endPoint: .bottom),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .shadow(color: Theme.gold.opacity(0.5), radius: 10)
                        .padding(14)
                }
                readoutBar
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 22, y: 12)

            HStack(spacing: 12) {
                Button("Merge another") { model.reset() }
                    .buttonStyle(GMButton(kind: .ghost))
                Button("Reveal in Finder") { reveal() }
                    .buttonStyle(GMButton(kind: .primary))
            }
        }
        .onAppear(perform: loadPreview)
    }

    private var readoutBar: some View {
        HStack(spacing: 26) {
            stat("Peak boost", value: model.readout.map { fmt($0.peakBoost) } ?? "—", unit: "×")
            stat("Headroom", value: model.readout.map { fmt($0.stops) } ?? "—", unit: " stops")
            stat("Target peak", value: model.readout.map { String($0.targetNits) } ?? "—", unit: " nits")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.outputURL?.lastPathComponent ?? "—")
                    .font(Theme.ui(12.5, .medium)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.middle)
                Text(model.outputURL?.deletingLastPathComponent().path ?? "")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.stoneDim)
                    .lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(Theme.inset)
    }

    private func stat(_ key: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key.uppercased()).font(Theme.ui(10)).tracking(1)
                .foregroundStyle(Theme.stoneDim)
            (Text(value).foregroundStyle(Theme.gold)
             + Text(unit).foregroundStyle(Theme.stoneDim).font(Theme.mono(11)))
                .font(Theme.mono(16, .medium))
        }
    }

    private func fmt(_ d: Double) -> String { String(format: "%.2f", d) }

    private func reveal() {
        guard let url = model.outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func loadPreview() {
        guard let url = model.outputURL else { return }
        Task.detached(priority: .userInitiated) {
            // Decode applying the gain map so the result shows real HDR (EDR),
            // matching the live preview — not the SDR fallback.
            let img = CIImage(contentsOf: url, options: [.expandToHDR: true])
            await MainActor.run { self.preview = img }
        }
    }
}

// MARK: - Button style

struct GMButton: ButtonStyle {
    enum Kind { case primary, ghost }
    let kind: Kind
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(13.5, .semibold))
            .foregroundStyle(kind == .primary ? .white : Theme.stone)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background {
                if kind == .primary {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(LinearGradient(colors: [Theme.accentHot, Theme.accent],
                                             startPoint: .top, endPoint: .bottom))
                        .shadow(color: Theme.accent.opacity(0.5), radius: 12, y: 6)
                } else {
                    RoundedRectangle(cornerRadius: 11).fill(Theme.surface)
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.line, lineWidth: 1))
                }
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

/// A native NSSlider (so its fill uses the app accent + matches the rest of the UI)
/// with a double-click recognizer that resets the control to its default. The
/// recognizer requires two clicks, so it coexists with normal single-click dragging.
struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onReset: () -> Void

    func makeNSView(context: Context) -> NSSlider {
        let s = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        s.isContinuous = true
        s.controlSize = .small
        let dbl = NSClickGestureRecognizer(target: context.coordinator,
                                           action: #selector(Coordinator.doubleClicked))
        dbl.numberOfClicksRequired = 2
        s.addGestureRecognizer(dbl)
        s.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return s
    }

    func updateNSView(_ s: NSSlider, context: Context) {
        context.coordinator.parent = self
        s.minValue = range.lowerBound
        s.maxValue = range.upperBound
        if abs(s.doubleValue - value) > .ulpOfOne { s.doubleValue = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: ResettableSlider
        init(_ parent: ResettableSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.doubleValue }
        @objc func doubleClicked() { parent.onReset() }
    }
}
