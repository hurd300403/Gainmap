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
    @State private var window: NSWindow?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            // Warm glow behind the bench.
            RadialGradient(colors: [Theme.accent.opacity(0.10), .clear],
                           center: .top, startRadius: 0, endRadius: 380)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, 38)
                        .padding(.top, 30)
                        .padding(.bottom, 26)

                    if model.mode == .advanced && model.phase == .done {
                        ResultCard(model: model).padding(.horizontal, 38)
                    } else {
                        benchSection.padding(.horizontal, 38)
                    }

                    footer.padding(.top, 28).padding(.bottom, 22)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Drop SDR JPEGs anywhere in the window (auto mode) to add to the queue.
            .onDrop(of: [.fileURL], isTargeted: nil, perform: handleWindowDrop)
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
        HStack(spacing: 16) {
            GainmapEmblem()
                .frame(width: 54, height: 54)
                .shadow(color: .black.opacity(0.5), radius: 7, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                (Text("Gain").foregroundStyle(Color.white)
                 + Text("map").foregroundStyle(Theme.accent))
                    .font(Theme.display(30, .semibold))
                Text("Fuse an SDR + HDR edit into one UltraHDR JPEG — clean highlights everywhere.")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.stoneDim)
            }
            Spacer()
        }
    }

    // MARK: Bench (idle / error / merging)

    private var benchSection: some View {
        VStack(spacing: 0) {
            modePicker.padding(.bottom, 16)

            if model.mode == .auto {
                autoSection
            } else {
                advancedSection
                // Gamut pickers + Lightroom how-to are only relevant to the
                // two-file workflow, so they live in the Advanced tab only.
                settingsPanel.padding(.top, 26)
            }
        }
    }

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

    // Auto = a queue of SDR JPEGs. Always a big preview on the left, controls on
    // the right. Drop images anywhere in the window to add them.
    private var autoSection: some View {
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
            .frame(maxWidth: .infinity)

            VStack(spacing: 0) {
                BatchFilmstrip(model: model)
                bloomControls.padding(.top, 14)
                if !model.items.isEmpty {
                    queueBar.padding(.top, 20)
                    autoResultStrip
                }
            }
            .frame(width: 408)
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

    // Auto = one SDR JPEG → popped; Advanced = HDR TIFF + SDR JPEG.
    private var modePicker: some View {
        HStack(spacing: 3) {
            modeButton("Auto · one photo", .auto)
            modeButton("Advanced · two files", .advanced)
        }
        .padding(3)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
    }

    private func modeButton(_ title: String, _ m: MergeModel.Mode) -> some View {
        let on = model.mode == m
        return Button(action: { withAnimation(.easeOut(duration: 0.2)) { model.mode = m } }) {
            Text(title)
                .font(Theme.ui(12.5, .semibold))
                .foregroundStyle(on ? .white : Theme.stoneDim)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(on ? Theme.surfaceHi : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    // MARK: Queue navigation + save bar (auto mode)

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
                    .help("Restore the default look")
            }

            // The one slider most people ever touch: blend the signature look from
            // subtle to full.
            sliderRow("INTENSITY", intensityBinding, 0...1, fmt: "%.0f%%", "subtle", "full", scale: 100,
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
                HStack {
                    Toggle("AUTO", isOn: $model.bloom.autoAdapt)
                        .toggleStyle(.switch)
                        .font(Theme.mono(10, .semibold))
                        .foregroundStyle(Theme.stoneDim)
                        .help("Auto-adjusts the look for each photo based on how bright it is. Off = your sliders apply exactly as set.")
                    Spacer()
                    Button("Save as default") { model.setSignatureFromCurrent() }
                        .buttonStyle(.plain)
                        .font(Theme.mono(10, .semibold)).foregroundStyle(Theme.gold)
                        .help("Save the current look as your default — it becomes the 100% Intensity preset and what Reset returns to (kept across launches).")
                }
                HStack {
                    Toggle("GLOW IN SDR", isOn: $model.bakeGlowIntoSDR)
                        .toggleStyle(.switch)
                        .font(Theme.mono(10, .semibold))
                        .foregroundStyle(Theme.stoneDim)
                        .help("On: the soft glow is baked into the SDR fallback so it shows on every screen (the fallback is your bloomed look, not the untouched original). Off: the SDR fallback is pixel-identical to your input and the glow appears only on HDR displays.")
                    if !model.bakeGlowIntoSDR { InfoButton(title: "GLOW IN SDR (off)", text: "SDR fallback stays pixel-identical to your input; the glow lives only in the gain map and shows only where the display has HDR headroom.") }
                    Spacer()
                    Text(model.bakeGlowIntoSDR ? "visible everywhere" : "pixel-identical SDR")
                        .font(Theme.mono(9)).foregroundStyle(Theme.stoneFaint)
                }
                sliderRow("GLOW", $model.bloom.glow, 0...1.5, fmt: "%.2f", "none", "bright",
                          help: "How much the bright areas bloom and spill light. Higher = brighter, dreamier highlights.")
                sliderRow("HEADROOM", $model.bloom.headroom, 1...3, fmt: "%.1f×", "natural", "intense",
                          help: "How far the bright tones climb on HDR screens. Higher makes highlights glow harder on HDR-capable displays (little effect on regular screens or the SDR fallback).")
                sliderRow("THRESHOLD", $model.bloom.threshold, 0.3...0.95, fmt: "%.0f%%", "everything", "specular", scale: 100,
                          help: "Which areas get the HDR treatment. Left = most of the image brightens; right = only the very brightest spots, like the sun or shiny reflections.")
                sliderRow("SPREAD", $model.bloom.spread, 0.002...0.025, fmt: "%.1f%%", "tight", "wide", scale: 100,
                          help: "Size of the glow halo around bright areas. Tight = crisp and contained; wide = soft and dreamy.")
                sliderRow("PUNCH", $model.bloom.punch, 0...1, fmt: "%.2f", "soft glow", "sharp pop",
                          help: "The character of the glow. Left = soft, dreamy bloom; right = sharp, snappy highlights.")
                if model.bloom.autoAdapt {
                    sliderRow("ADAPT", $model.bloom.adaptAmount, 0...1, fmt: "%.0f%%", "fixed", "dynamic", scale: 100,
                              help: "How strongly AUTO retunes the look per photo. Fixed = your settings as-is; dynamic = more automatic adjustment.")
                    sliderRow("HL GUARD", $model.bloom.highlightGuard, 0...1, fmt: "%.0f%%", "loose", "strict", scale: 100,
                              help: "Protects already-bright photos from blowing out. Stricter pulls the effect back more on high-key images.")
                }
                sliderRow("FALLOFF", $model.bloom.falloff, 0.5...2.0, fmt: "%.2f", "hard", "smooth",
                          help: "How abruptly the glow ramps up in the highlights. Hard = sudden onset; smooth = gradual and gentle.")
                sliderRow("GLOW COLOR", $model.bloom.saturation, 0...1.5, fmt: "%.2f", "white", "vivid",
                          help: "How colorful the glow is. White = neutral light; vivid = keeps the scene's own color in the glow.")
                sliderRow("TINT", $model.bloom.tint, -1...1, fmt: "%+.2f", "cool", "warm",
                          help: "Warmth of the glow. Cool leans blue; warm leans golden-hour.")
            }
        }
        .padding(16)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                           fmt: String, _ left: String, _ right: String, scale: Double = 1,
                           help: String = "") -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Text(title).font(Theme.mono(10, .semibold)).tracking(1)
                    .foregroundStyle(Theme.stoneDim).lineLimit(1)
                if !help.isEmpty { InfoButton(title: title, text: help) }
            }
            .frame(width: 108, alignment: .leading)
            VStack(spacing: 2) {
                Slider(value: value, in: range).tint(Theme.accent)
                HStack { Text(left); Spacer(); Text(right) }
                    .font(Theme.mono(8.5)).foregroundStyle(Theme.stoneFaint)
            }
            Text(String(format: fmt, value.wrappedValue * scale))
                .font(Theme.mono(11)).foregroundStyle(Theme.gold)
                .frame(width: 44, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .help(help)
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

            Text("Made possible by my patrons ❤️")
                .font(Theme.mono(10)).tracking(1.0)
                .foregroundStyle(Theme.stoneDim)
        }
        .frame(maxWidth: .infinity)
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
                .font(.system(size: 10))
                .foregroundStyle(show ? Theme.accent : Theme.stoneFaint)
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
