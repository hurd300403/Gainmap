//
//  ContentView.swift
//  Gainmap (Mac)
//
//  The single Gainmap window: a warm-dark bench with the pinned EDR preview on
//  the left and the filmstrip + HDR-look controls on the right. Drop SDR JPEGs,
//  tune the glow per photo, save UltraHDR copies beside the originals.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GainmapCore

struct ContentView: View {
    // Owned by GainmapApp (P5): the sync coordinator re-attaches the model's
    // store when auth state changes, so the model must outlive this view's
    // identity churn.
    @ObservedObject var model: MergeModel
    @Environment(\.scenePhase) private var scenePhase
    // Look-panel disclosure state lives HERE (session lifetime), not in the
    // panel: the panel is torn down when the queue empties, and these must
    // survive the "clear the strip, start the next batch" cycle (1.5 behavior).
    @State private var showAdvancedLook = false
    @State private var expandedGroups: Set<String> = ["glow", "color", "hdr"]
    @State private var window: NSWindow?
    @State private var shareHover = false
    @State private var showShareModal = false
    // Confirm + explain before baking the glow into the SDR base (it makes the
    // non-HDR/fallback version look brighter/blown, which surprises people).
    @State private var showGlowInSDRInfo = false
    // Auto-dismiss timer for the skipped-files drop notice.
    @State private var dropNoticeTask: Task<Void, Never>?

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
                                       bake: model.bloom.bakeGlowIntoSDR,
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
                            // Before any photo exists the look controls are inert —
                            // show how to produce the input file instead.
                            if model.items.isEmpty {
                                firstRunHowto.padding(.top, 14)
                            } else {
                                LookControlsPanel(model: model,
                                                  showAdvancedLook: $showAdvancedLook,
                                                  expandedGroups: $expandedGroups,
                                                  onGlowInSDRInfo: { showGlowInSDRInfo = true })
                                    .padding(.top, 14)
                                autoResultStrip
                            }
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
                    appliesToAll: model.sameLookForAll,
                    onEnable: {
                        model.bloom.bakeGlowIntoSDR = true
                        withAnimation(.easeOut(duration: 0.18)) { showGlowInSDRInfo = false }
                    },
                    onCancel: {
                        withAnimation(.easeOut(duration: 0.18)) { showGlowInSDRInfo = false }
                    })
                .transition(.opacity)
                .zIndex(10)
            }

            // Transient toast when dropped files were skipped — a rejected drop
            // must never be a silent no-op.
            if let notice = model.dropNotice {
                VStack {
                    Spacer()
                    NoticeBanner(message: notice)
                        .frame(maxWidth: 480)
                        .padding(.bottom, 110)   // clear the pinned action bar
                }
                .transition(.opacity)
                .zIndex(9)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.dropNotice)
        .onChange(of: model.dropNotice) { _, notice in
            dropNoticeTask?.cancel()
            guard notice != nil else { return }
            dropNoticeTask = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                model.dropNotice = nil
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .onAppear {
            #if DEBUG
            model.applyDebugSeedIfRequested()
            #endif
        }
        // P3 persistence: adopt the store + resume the last session. Signed
        // out this is the classic local store; once auth resolves, the
        // SyncCoordinator re-attaches the per-uid store (adopting these
        // sessions). Ephemeral launches (-gm-seed screenshots, -gm-no-store
        // test host) skip stores entirely.
        .task {
            if !SyncCoordinator.isEphemeralLaunch {
                await model.attachStoreAndRestore(FileSessionStore())
            }
        }
        // Live-look flush: debounce covers editing; background/quit flush the
        // rest (willTerminate needs the synchronous path — no async grace).
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await model.flushSession() } }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification)) { _ in
            model.flushNowForTermination()
        }
        .background(WindowAccessor { window = $0 })
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        // Resize the window to the FIRST imported photo's aspect (auto mode) so the
        // preview fills with no letterbox bars. Doesn't re-resize as you navigate.
        .onChange(of: model.items.isEmpty) { wasEmpty, isEmpty in
            guard wasEmpty, !isEmpty,
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
        var urls = [URL?](repeating: nil, count: providers.count)
        let lock = NSLock()   // loadObject callbacks land on arbitrary threads
        let group = DispatchGroup()
        for (i, p) in providers.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                lock.lock(); urls[i] = u; lock.unlock()
                group.leave()
            }
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
                Text("Turn your SDR JPEG into an UltraHDR that glows on HDR screens — clean fallback everywhere else.")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.stoneDim)
            }
            GainmapEmblem()
                .frame(width: 54, height: 54)
                .shadow(color: .black.opacity(0.5), radius: 7, y: 4)
        }
    }

    // MARK: Bench (idle / error / merging)

    @ViewBuilder private var autoResultStrip: some View {
        if let sel = model.selectedItem {
            if sel.looksMerged, sel.status != .done {
                NoticeBanner(message: "This photo already looks like an UltraHDR export — merging it again doubles the glow.")
                    .padding(.top, 16)
            }
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
        if !model.items.isEmpty {
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
                    .keyboardShortcut(.leftArrow, modifiers: .command)

                if model.sameLookForAll {
                    // Batch mode: exporting the whole queue IS the primary action.
                    primaryCapsule(enabled: model.canExportAll && !model.isExportingAll,
                                   spinning: model.isExportingAll,
                                   glyph: "sun.max.fill",
                                   label: model.isExportingAll
                                       ? "Exporting… \(min(model.batchDone + 1, max(model.batchTotal, 1))) of \(model.batchTotal)"
                                       : "Export all · \(model.items.count) photo\(model.items.count == 1 ? "" : "s")") {
                        model.startExportAll()
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Merge every photo with the shared look — re-exports saved ones and replaces their _UltraHDR files (⌘S)")
                } else {
                    primaryCapsule(enabled: model.canSaveSelected,
                                   spinning: model.phase == .merging,
                                   glyph: saveGlyph,
                                   label: saveLabel) {
                        Task { await model.saveSelectedAndAdvance() }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Merge this photo and move to the next (⌘S)")
                }

                stepButton(system: "chevron.right", label: "Next",
                           enabled: model.hasNext) { model.selectNext() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)

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
                if model.canPaste && model.items.count > 1 && !model.sameLookForAll {
                    Button("Paste to all") { model.pasteLookToAll() }
                        .buttonStyle(.plain)
                        .font(Theme.mono(11, .semibold)).foregroundStyle(Theme.stone)
                        .help("Apply the copied look to every photo in the queue")
                }
                if model.isExportingAll {
                    Button(action: { model.stopExportAll() }) {
                        HStack(spacing: 5) {
                            Image(systemName: "stop.fill").font(.system(size: 8))
                            Text("Stop · \(model.batchDone) of \(model.batchTotal)")
                        }
                        .font(Theme.mono(11, .semibold))
                        .foregroundStyle(Theme.accentHot)
                    }
                    .buttonStyle(.plain)
                    .help("Stop after the photo currently merging")
                } else if !model.sameLookForAll {
                    // Per-photo mode keeps the batch action as a secondary button
                    // (in batch mode the primary capsule IS Export all).
                    Button(action: { model.startExportAll() }) {
                        Text(model.pendingCount > 0 ? "Export all · \(model.pendingCount) left" : "All saved ✓")
                            .font(Theme.mono(10.5, .semibold))
                            .foregroundStyle(model.canExportAll ? Theme.accentHot : Theme.stoneDim)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(model.canExportAll ? Theme.accentHot.opacity(0.45) : Theme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canExportAll)
                    .help("Merge every photo that hasn't been saved yet")
                }
            }
        }
    }

    /// The queue bar's primary action capsule (Save & Next / Export all).
    private func primaryCapsule(enabled: Bool, spinning: Bool, glyph: String,
                                label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if spinning {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: glyph)
                }
                Text(label).font(Theme.ui(14.5, .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(LinearGradient(
                    colors: enabled ? [Theme.accentHot, Theme.accent]
                                    : [Theme.surfaceHi, Theme.surface],
                    startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().stroke(Theme.accent.opacity(enabled ? 0.4 : 0), lineWidth: 1))
            .shadow(color: Theme.accent.opacity(enabled ? 0.45 : 0), radius: 16, y: 7)
        }
        .buttonStyle(.plain)
        // Disabled while spinning too: a live button under a spinner invites
        // reentrant ⌘S taps that interleave merges and can skip a photo.
        .disabled(!enabled)
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
                Text("Saved beside the original · Re-save replaces it")
                    .font(Theme.ui(11.5, .medium)).foregroundStyle(.white)
                Text(item.outputURL?.lastPathComponent ?? "—")
                    .font(Theme.mono(9.5)).foregroundStyle(Theme.stoneDim)
                    .lineLimit(1).truncationMode(.middle)
                Text("Glows on HDR screens & apps (Photos, iOS, Android 14+); everywhere else shows the clean SDR.")
                    .font(Theme.ui(9.5)).foregroundStyle(Theme.stoneDim)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// Empty-queue guidance: how to export the right JPEG from Lightroom.
    /// (The old how-to lived in the hidden two-file settings panel, so new users
    /// had NO reachable instructions.)
    private var firstRunHowto: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GETTING STARTED")
                .font(Theme.mono(10, .semibold)).tracking(1)
                .foregroundStyle(Theme.goldDeep)
            howtoRow("Export your finished edit from Lightroom as a JPEG — sRGB or Display P3, quality 90+, full size")
            howtoRow("Drop it anywhere in this window, or click the preview to browse — batches welcome")
            howtoRow("Gainmap builds the HDR glow from the JPEG's own highlights and saves an UltraHDR copy beside the original")
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
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.stone)
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
    /// SAME-LOOK mode: the toggle applies to the whole queue, not one photo.
    var appliesToAll: Bool = false
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
                    Text("Turning this on layers just the soft haze into that copy, so the glow carries to those places too. Your edit's tones stay exactly as exported — only the haze is added, and it fades out near white, so highlights can't blow out.")
                    (Text("Leaving it off ").foregroundStyle(Theme.stone)
                     + Text("(recommended)").foregroundStyle(Theme.gold)
                     + Text(" keeps that copy identical to your original; the glow then shows only on HDR displays.").foregroundStyle(Theme.stone))
                    if appliesToAll {
                        (Text("Same look for all is on").foregroundStyle(Theme.gold)
                         + Text(" — this applies to every photo in the queue.").foregroundStyle(Theme.stone))
                    }
                }
                .font(Theme.ui(12.5)).foregroundStyle(Theme.stone)
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

// MARK: - Notice banner (transient / advisory, non-error)

struct NoticeBanner: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.gold)
            Text(message).font(Theme.ui(12)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inset.opacity(0.97), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.gold.opacity(0.35), lineWidth: 1))
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
