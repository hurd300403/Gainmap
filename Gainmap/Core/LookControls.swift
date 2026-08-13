//
//  LookControls.swift
//  GainmapCore
//
//  The HDR-look control panel, extracted from the Mac ContentView so both
//  platforms drive the SAME controls against the SAME MergeModel — the parity
//  mechanism: an iOS build gets the identical slider stack, groups, copy, and
//  bindings, so a look dialed on one platform reads the same on the other.
//
//  The one thing that differs per platform is the slider itself
//  (ResettableSlider below): AppKit NSSlider with a double-click-to-reset
//  recognizer on macOS; SwiftUI Slider with long-press-to-reset on iOS
//  (a double-tap on a touch slider fights the drag recognizer).
//

import SwiftUI

public struct LookControlsPanel: View {
    /// How the ADVANCED section renders. `.accordion` = the Mac's boxed
    /// collapsible groups (concept A). `.tabbed` = a segmented picker with one
    /// group visible at a time (concept D) — the compact-iPhone layout, where
    /// three stacked open groups would outgrow the bottom sheet.
    public enum AdvancedStyle { case accordion, tabbed }

    @ObservedObject var model: MergeModel
    let advancedStyle: AdvancedStyle
    @State private var selectedGroup = "glow"
    @State private var confirmSameLook = false
    /// Turning GLOW IN SDR on opens an explainer first (so the brighter/blown
    /// SDR fallback doesn't surprise anyone) — the host app owns that modal.
    var onGlowInSDRInfo: () -> Void

    // Disclosure state is OWNED BY THE HOST (bound in), not the panel: on the
    // Mac the panel is torn down whenever the queue empties, and panel-local
    // @State would reset Advanced/group disclosure between batches — 1.5 kept
    // it for the whole session, so the host holds it at session lifetime.
    @Binding var showAdvancedLook: Bool
    // Which advanced groups are expanded. All open by default so nothing is hidden
    // on first look; the grouping (not the collapse) is what tames the complexity.
    @Binding var expandedGroups: Set<String>

    public init(model: MergeModel,
                showAdvancedLook: Binding<Bool>,
                expandedGroups: Binding<Set<String>>,
                advancedStyle: AdvancedStyle = .accordion,
                onGlowInSDRInfo: @escaping () -> Void) {
        self.model = model
        self._showAdvancedLook = showAdvancedLook
        self._expandedGroups = expandedGroups
        self.advancedStyle = advancedStyle
        self.onGlowInSDRInfo = onGlowInSDRInfo
    }

    // Binding that drives the whole look from one 0…1 intensity.
    private var intensityBinding: Binding<Double> {
        Binding(get: { model.intensity }, set: { model.setIntensity($0) })
    }

    private var sameLookBinding: Binding<Bool> {
        Binding(get: { model.sameLookForAll }, set: { on in
            if on && model.needsSameLookForAllConfirmation {
                confirmSameLook = true
            } else {
                model.setSameLookForAll(on)
            }
        })
    }

    public var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 12) {
                Text("HDR LOOK").font(Theme.mono(11, .semibold)).tracking(2)
                    .foregroundStyle(model.bloom.hdrLookEnabled ? Theme.gold : Theme.stoneDim)
                Button {
                    model.setHDRLookEnabled(!model.bloom.hdrLookEnabled)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "power")
                            .font(.system(size: 9, weight: .bold))
                        Text(model.bloom.hdrLookEnabled ? "ON" : "OFF")
                            .font(Theme.mono(9.5, .bold)).tracking(0.7)
                    }
                    .foregroundStyle(model.bloom.hdrLookEnabled ? Theme.gold : Theme.stone)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(model.bloom.hdrLookEnabled
                                ? Theme.gold.opacity(0.10) : Theme.inset,
                                in: Capsule())
                    .overlay(Capsule().stroke(model.bloom.hdrLookEnabled
                                              ? Theme.gold.opacity(0.5) : Theme.line,
                                              lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(model.bloom.hdrLookEnabled
                      ? "Turn off the HDR look. Your settings stay saved."
                      : "Restore the saved HDR look.")
                .accessibilityLabel(model.bloom.hdrLookEnabled
                                    ? "HDR Look on" : "HDR Look off")
                Spacer()
                HStack(spacing: 12) {
                    if !model.sameLookForAll {
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
                    }
                    Button("Reset") { model.resetToDefault() }
                        .buttonStyle(.plain)
                        .font(Theme.mono(10, .semibold)).foregroundStyle(Theme.stone)
                        .help("Snap this photo back to your default look (set it under Advanced controls ▸ Save as default).")
                }
                .disabled(!model.bloom.hdrLookEnabled)
                .opacity(model.bloom.hdrLookEnabled ? 1 : 0.38)
            }

            // SAME LOOK FOR ALL — reframes the whole slider stack from
            // this-photo to whole-queue. With one photo there is no "all", so
            // don't spend scarce editor space on a control that cannot change scope.
            if model.items.count > 1 {
                HStack(spacing: 10) {
                    Toggle(isOn: sameLookBinding) {
                        Text("Same Look for All")
                            .font(Theme.mono(10, .semibold)).tracking(1.5)
                            .foregroundStyle(model.sameLookForAll ? Theme.gold : Theme.stone)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.gold)
                    .disabled(model.isExportingAll)
                    .help("Use the current look on every photo. Turn it off to edit photos independently from that shared starting point.")
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9).padding(.horizontal, 12)
                .background(model.sameLookForAll ? Theme.gold.opacity(0.07) : Theme.inset.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(model.sameLookForAll ? Theme.gold.opacity(0.35) : Theme.line, lineWidth: 1))
            }

            VStack(spacing: 13) {
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

                    switch advancedStyle {
                    case .accordion:
                        lookGroup("glow", "THE GLOW", "how the highlights bloom") { glowControls }
                        lookGroup("color", "COLOR", "the color of that light") { colorControls }
                        lookGroup("hdr", "HDR & SCREENS", "how it shows across displays") { hdrControls }
                    case .tabbed:
                        Picker("", selection: $selectedGroup) {
                            Text("THE GLOW").tag("glow")
                            Text("COLOR").tag("color")
                            Text("HDR").tag("hdr")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        VStack(spacing: 4) {
                            switch selectedGroup {
                            case "color": colorControls
                            case "hdr": hdrControls
                            default: glowControls
                            }
                        }
                        .padding(12)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
                    }
                }
            }
            .disabled(!model.bloom.hdrLookEnabled)
            .opacity(model.bloom.hdrLookEnabled ? 1 : 0.38)
        }
        .padding(16)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
        .onChange(of: expandedGroups) { _, groups in
            // The GLOW-IN-SDR teaser inserts "hdr" — mirror it onto the tab.
            if advancedStyle == .tabbed, groups.contains("hdr") { selectedGroup = "hdr" }
        }
        .alert("Use this look for every photo?", isPresented: $confirmSameLook) {
            Button("Cancel", role: .cancel) {}
            Button("Apply to All") { model.setSameLookForAll(true) }
        } message: {
            Text("Photos have different looks. This replaces them with the current look.")
        }
    }

    // MARK: group contents (shared by both advanced styles)

    @ViewBuilder private var glowControls: some View {
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

    @ViewBuilder private var colorControls: some View {
        sliderRow("GLOW COLOR", $model.bloom.saturation, 0...1.5, fmt: "%.2f", "white", "vivid",
                  resetTo: model.signature.saturation,
                  help: "How colorful the glow is. White = neutral light; vivid = keeps the scene's own color in the glow.")
        sliderRow("TINT", $model.bloom.tint, -1...1, fmt: "%+.2f", "cool", "warm",
                  resetTo: model.signature.tint,
                  help: "Warmth of the glow. Cool leans blue; warm leans golden-hour.")
    }

    @ViewBuilder private var hdrControls: some View {
                    sliderRow("HEADROOM", $model.bloom.headroom, 1...3, fmt: "%.1f×", "natural", "intense",
                              resetTo: model.signature.headroom,
                              help: "How far the bright tones climb on HDR screens. Higher makes highlights glow harder on HDR-capable displays (little effect on regular screens or the SDR fallback).")
                    sliderRow("THRESHOLD", $model.bloom.threshold, 0.3...0.95, fmt: "%.0f%%", "everything", "specular", scale: 100,
                              resetTo: model.signature.threshold,
                              help: "Which areas get the HDR treatment. Left = most of the image brightens; right = only the very brightest spots, like the sun or shiny reflections. Shapes the HDR / gain-map layer either way — it still applies when “Glow in SDR” is off (it just doesn't change the untouched SDR fallback).")
                    HStack {
                        // Turning it ON opens an explainer first (so the brighter/blown
                        // SDR fallback doesn't surprise anyone); turning OFF is instant.
                        Toggle("GLOW IN SDR", isOn: Binding(
                            get: { model.bloom.bakeGlowIntoSDR },
                            set: { wantOn in
                                if wantOn && !model.bloom.bakeGlowIntoSDR {
                                    onGlowInSDRInfo()
                                } else {
                                    model.bloom.bakeGlowIntoSDR = wantOn
                                }
                            }))
                            .toggleStyle(.switch)
                            .font(Theme.mono(10, .semibold))
                            .foregroundStyle(Theme.stoneDim)
                            .help("SDR = the standard, non-HDR version of your photo (a regular JPEG — what most screens and apps show). On: the soft glow is baked into that SDR version so it shows on every screen. Off: the SDR version stays pixel-identical to your input, and the glow appears only on HDR displays.")
                        InfoButton(title: "GLOW IN SDR",
                                   text: "“SDR” is the standard, non-HDR version of your photo — a regular JPEG, the kind every screen and app can show. Your export always tucks one inside as the fallback for non-HDR screens.\n\nOn: the soft glow is baked into that SDR version, so your look carries everywhere (the fallback is your bloomed photo, not the untouched original).\n\nOff: the SDR version is pixel-identical to the file you started with, and the glow lives only in the HDR layer — so it appears only on HDR-capable displays.")
                        Spacer()
                        Text(model.bloom.bakeGlowIntoSDR ? "shows on every screen" : "HDR screens only")
                            .font(Theme.mono(9)).foregroundStyle(Theme.stoneFaint)
                    }
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
                // Double-click (macOS) / long-press (iOS) snaps this one control
                // back to the saved default (the same value the top "Reset" uses).
                ResettableSlider(value: value, range: range) {
                    if let d = resetTo { value.wrappedValue = d }
                }
                HStack { Text(left); Spacer(); Text(right) }
                    .font(Theme.mono(9.5)).foregroundStyle(Theme.stoneFaint)
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
}

// MARK: - Info button (click for a plain-English explanation)

public struct InfoButton: View {
    let title: String
    let text: String
    @State private var show = false

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }

    public var body: some View {
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

// MARK: - Resettable slider (per-platform)

#if os(macOS)

import AppKit

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

#else

/// iOS twin: SwiftUI Slider with long-press-to-reset (a double-tap on a touch
/// slider fights the drag recognizer; long-press coexists with it).
struct ResettableSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onReset: () -> Void

    var body: some View {
        Slider(value: $value, in: range)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in onReset() })
    }
}

#endif
