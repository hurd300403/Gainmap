//
//  EditorScreen.swift
//  Gainmap for iPhone (P5)
//
//  The compact editor, built around SCREEN REAL ESTATE: no header row —
//  back/share float over the photo; the session title cubbyholes into the
//  controls sheet; and the sheet's RESTING height is computed from the
//  photo's aspect ratio, so it rises to kiss the bottom of the image
//  (landscape = tall sheet, portrait = image gets the room) instead of
//  covering it. Same LookControlsPanel as the Mac, tabbed (concept D).
//

import SwiftUI
import CoreImage
import ImageIO
import PhotosUI
import GainmapCore

struct EditorScreen: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: MergeModel
    @State private var showAdvancedLook = false
    @State private var expandedGroups: Set<String> = ["glow", "color", "hdr"]
    // Starts FALSE: presenting a sheet while the fullScreenCover is still
    // animating in gets silently dropped by UIKit — prepare() raises it once
    // the cover has settled.
    @State private var controlsPresented = false
    @State private var comparing = false
    @State private var baseImage: CIImage?
    @State private var hydrating = false
    @State private var showGlowInSDRModal = false
    @State private var shareURL: URL?
    @State private var exporting = false

    // Dynamic sheet: the resting detent hugs the fitted image.
    @State private var restingDetent: CGFloat = 190
    @State private var detentSelection: PresentationDetent = .height(190)
    /// Nearly-dismissed controls state. The sheet stays alive so its nested
    /// picker/share presentations retain a valid presenter.
    private let collapsedDetentHeight: CGFloat = 54

    private let sessionTitle: String
    private let store: FileSessionStore?
    /// Photos picked for a brand-new session — imported in prepare().
    private let importItems: [PhotosPickerItem]
    @State private var importing = false
    /// Filmstrip "+": add more photos to THIS session. The picker PRESENTS
    /// from the controls sheet — the sheet is always up, and UIKit silently
    /// drops a second presentation from the base view (P5 review; same
    /// reason the share sheet lives on the sheet).
    @State private var addPickerPresented = false
    @State private var addPickerItems: [PhotosPickerItem] = []
    /// User-visible failure notice (export/hydration) — alert on the sheet.
    @State private var notice: EditorNotice?
    /// Selected photo whose original couldn't be downloaded (retry UI).
    @State private var hydrateFailedID: UUID?

    init(session: Session, store: FileSessionStore?, importItems: [PhotosPickerItem] = []) {
        sessionTitle = session.title
        self.store = store
        self.importItems = importItems
        // The REAL store: flushSession persists the session file AND fires
        // onSessionPersisted — the sync bridge. (A nil store would silently
        // disable persistence and sync for everything edited here.)
        _model = StateObject(wrappedValue: MergeModel(session: session,
                                                      store: store,
                                                      output: .managedDirectory(Self.exportsDir)))
    }

    static var exportsDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gm-exports",
                                                                      isDirectory: true)
    }

    // ------------------------------------------------------------- layout

    private let stripHeight: CGFloat = 58
    private let hGap: CGFloat = 10
    private let minResting: CGFloat = 190

    private var controlsCollapsed: Bool {
        detentSelection == .height(collapsedDetentHeight)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.bg.ignoresSafeArea()
                let fitted = fittedImageSize(in: geo)
                VStack(spacing: hGap) {
                    preview
                        .frame(width: fitted.width, height: fitted.height)
                        .frame(maxWidth: .infinity)
                    if controlsCollapsed {
                        thumbnailGrid
                    } else {
                        filmstrip
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .animation(.easeInOut(duration: 0.18), value: controlsCollapsed)
            }
            .onAppear { recomputeResting(geo: geo) }
            .onChange(of: previewAspect) { _, _ in recomputeResting(geo: geo) }
        }
        .sheet(isPresented: $controlsPresented) {
            controlsSheet
        }
        .onChange(of: addPickerItems) { _, items in
            guard !items.isEmpty else { return }
            addPickerItems = []
            Task { await importPhotos(items, selectFirstNew: true) }
        }
        .task { await prepare() }
        .onDisappear {
            controlsPresented = false
            if appModel.activeEditorModel === model { appModel.activeEditorModel = nil }
            Task { await model.flushSession() }
        }
    }

    /// Fit the image between the top of the content area and the resting
    /// sheet: portrait shrinks to leave the sheet its minimum; landscape
    /// keeps its natural height (the sheet grows into the leftover instead).
    private func fittedImageSize(in geo: GeometryProxy) -> CGSize {
        let w = geo.size.width - 20
        let aspect = previewAspect
        let naturalH = w / aspect
        let maxH = geo.size.height - stripHeight - hGap * 2
            - max(0, minResting - geo.safeAreaInsets.bottom)
        let h = max(120, min(naturalH, maxH))
        return CGSize(width: min(w, h * aspect), height: h)
    }

    /// The sheet's resting height = whatever the image + strip leave free
    /// (clamped so it never eats more than ~half the screen at rest).
    private func recomputeResting(geo: GeometryProxy) {
        let fitted = fittedImageSize(in: geo)
        let usedAbove = fitted.height + stripHeight + hGap * 2 + 2
        let free = geo.size.height + geo.safeAreaInsets.bottom - usedAbove
        let clamped = max(minResting, min(free, geo.size.height * 0.48))
        guard abs(clamped - restingDetent) > 1 else { return }
        let wasResting = detentSelection == .height(restingDetent)
        restingDetent = clamped
        if wasResting { detentSelection = .height(clamped) }
    }

    // ------------------------------------------------------------- pieces

    private var preview: some View {
        ZStack {
            if let image = comparing ? baseImage : previewImage {
                EDRMetalView(image: image)
            } else {
                Theme.inset
                if hydrating || importing {
                    VStack(spacing: 8) {
                        ProgressView().tint(Theme.stoneDim)
                        Text(importing ? "Importing…" : "Downloading original…")
                            .font(Theme.mono(9)).foregroundStyle(Theme.stoneDim)
                    }
                } else if let failed = hydrateFailedID, failed == model.selectedID {
                    // Download failed: say so and offer a retry — a silent
                    // grey frame read as "the app is broken" (P5 review).
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 22)).foregroundStyle(Theme.stoneDim)
                        Text("Couldn't download this photo")
                            .font(Theme.mono(10)).foregroundStyle(Theme.stoneDim)
                        Button("Retry") {
                            hydrateFailedID = nil
                            Task { await loadSelectedBase() }
                        }
                        .font(Theme.mono(11, .semibold)).foregroundStyle(Theme.gold)
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Theme.line, lineWidth: 1))
        // Floating chrome: no header row — these ride ON the photo.
        .overlay(alignment: .topLeading) {
            floatingButton(system: "chevron.left") {
                controlsPresented = false
                Task {
                    await model.flushSession()
                    dismiss()
                }
            }
            .padding(8)
        }
        .overlay(alignment: .topTrailing) {
            floatingButton(system: exporting ? nil : "square.and.arrow.up",
                           spinning: exporting,
                           disabled: !model.canSaveSelected || exporting) {
                exportSelected()
            }
            .padding(8)
        }
        .overlay(alignment: .bottomLeading) {
            if !screenSupportsEDR {
                Text("SDR SCREEN")
                    .font(Theme.mono(8, .bold)).tracking(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Theme.gold, in: Capsule())
                    .padding(8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if comparing {
                Text("ORIGINAL")
                    .font(Theme.mono(8, .bold)).tracking(1)
                    .foregroundStyle(Theme.stone)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(8)
            }
        }
        .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 50) {
        } onPressingChanged: { pressing in
            comparing = pressing
        }
    }

    private func floatingButton(system: String?, spinning: Bool = false,
                                disabled: Bool = false,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.black.opacity(0.55))
                if spinning {
                    ProgressView().tint(Theme.gold).controlSize(.small)
                } else if let system {
                    Image(systemName: system)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(disabled ? Theme.stoneFaint : Theme.stone)
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Lazy: a big synced session must not decode every thumb on open.
            LazyHStack(spacing: 8) {
                ForEach(model.items) { item in
                    thumbnail(item)
                }
                addPhotosTile
            }
            .padding(.vertical, 1)
        }
        .frame(height: stripHeight)
    }

    /// Spend the space reclaimed from the controls on the queue. Six 52pt
    /// cells fit on a typical Pro phone, so 30 photos take roughly five rows
    /// instead of one long filmstrip.
    private var thumbnailGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 52, maximum: 52), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(model.items) { item in
                    thumbnail(item)
                }
                addPhotosTile
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func thumbnail(_ item: MergeModel.BatchItem) -> some View {
        FilmstripThumb(url: item.sdrURL,
                       selected: item.id == model.selectedID,
                       done: item.status == .done,
                       tooLarge: item.tooLargeToSync)
            .onTapGesture { select(item.id) }
    }

    /// The picker is presented from the controls sheet, which remains alive
    /// even in its compact state.
    private var addPhotosTile: some View {
        Button {
            addPickerPresented = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.inset)
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.gold)
            }
            .frame(width: 52, height: 52)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var controlsSheet: some View {
        Group {
            if controlsCollapsed {
                Button {
                    detentSelection = .height(restingDetent)
                } label: {
                    HStack(spacing: 8) {
                        Text("HDR LOOK")
                            .font(Theme.mono(10, .bold)).tracking(2)
                            .foregroundStyle(Theme.gold)
                        Spacer()
                        Text(liveTitle.isEmpty ? "Untitled session" : liveTitle)
                            .font(Theme.mono(8, .semibold)).tracking(1.2)
                            .foregroundStyle(Theme.stoneFaint)
                            .lineLimit(1)
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.stoneDim)
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show HDR controls")
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Text(liveTitle.isEmpty ? "Untitled session" : liveTitle)
                                .font(Theme.mono(9, .semibold)).tracking(1.5)
                                .foregroundStyle(Theme.stoneFaint)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                            Button {
                                detentSelection = .height(collapsedDetentHeight)
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.stoneDim)
                                    .frame(width: 28, height: 24)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Collapse HDR controls")
                        }
                        LookControlsPanel(model: model,
                                          showAdvancedLook: $showAdvancedLook,
                                          expandedGroups: $expandedGroups,
                                          advancedStyle: .tabbed,
                                          onGlowInSDRInfo: { showGlowInSDRModal = true })
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                }
            }
        }
        .presentationDetents([.height(collapsedDetentHeight),
                              .height(restingDetent), .medium, .large],
                             selection: $detentSelection)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(true)
        .presentationBackground(Theme.bgDeep)
        // Stacked presentations live ON the persistent sheet — presenting
        // them from the base view while this sheet is up silently fails.
        .sheet(item: $shareURL) { url in
            ShareSheet(items: [url])
        }
        .photosPicker(isPresented: $addPickerPresented,
                      selection: $addPickerItems,
                      matching: .images, photoLibrary: .shared())
        .alert(item: $notice) { n in
            Alert(title: Text(n.title), message: Text(n.message),
                  dismissButton: .default(Text("OK")))
        }
        .alert("Glow in SDR", isPresented: $showGlowInSDRModal) {
            Button("Turn on") { model.bloom.bakeGlowIntoSDR = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bakes the soft glow into the standard (non-HDR) version too, so your look shows on every screen. The SDR fallback will be brighter than your original file.")
        }
    }

    // ------------------------------------------------------------- preview data

    /// Small LRU of decoded preview bases: each entry is a materialized
    /// ~1600px bitmap (~8 MB), so an unbounded dictionary jetsammed the app
    /// on big sessions (P5 review). Six covers back-and-forth comparison
    /// without holding a whole filmstrip walk.
    @State private var decodedBase: [UUID: CIImage] = [:]
    @State private var decodedOrder: [UUID] = []
    private static let decodedCap = 6

    private func cacheDecoded(_ image: CIImage, for id: UUID) {
        decodedBase[id] = image
        decodedOrder.removeAll { $0 == id }
        decodedOrder.append(id)
        while decodedOrder.count > Self.decodedCap {
            let evict = decodedOrder.removeFirst()
            decodedBase.removeValue(forKey: evict)
        }
    }

    private var liveTitle: String {
        model.session.title.isEmpty ? sessionTitle : model.session.title
    }

    private var previewImage: CIImage? {
        guard let base = baseImage else { return nil }
        return AutoHDR.bloomCIImage(base: base, params: model.bloom)
    }

    private var previewAspect: CGFloat {
        guard let base = baseImage, base.extent.height > 0 else { return 3.0 / 2.0 }
        return base.extent.width / base.extent.height
    }

    private var screenSupportsEDR: Bool {
        #if canImport(UIKit)
        return UIScreen.main.potentialEDRHeadroom > 1.0
        #else
        return true
        #endif
    }

    private func prepare() async {
        model.onSessionPersisted = { [weak appModel] session, before in
            Task { @MainActor in appModel?.sessionPersisted(session, before: before) }
        }
        // Inbound sync folds into THIS model while the editor is open.
        appModel.activeEditorModel = model
        // Raise the controls once the cover's own transition has settled.
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            detentSelection = .height(restingDetent)
            controlsPresented = true
        }
        if !importItems.isEmpty {
            await importPhotos(importItems, selectFirstNew: false)
        }
        if model.selectedID == nil, let first = model.items.first?.id {
            model.select(first)
        }
        await loadSelectedBase()
    }

    /// Phone-native import (P5): stage the picked photos as JPEGs in the
    /// store's managed files, then feed them through the same addFiles
    /// pipeline the Mac drop uses (hashing, dedup, naming, persistence —
    /// and from there the sync bridge uploads them). Used both for a new
    /// session's initial pick and the filmstrip's "+".
    private func importPhotos(_ items: [PhotosPickerItem], selectFirstNew: Bool) async {
        guard let store else { return }
        importing = true
        defer { importing = false }
        let existingIDs = Set(model.items.map(\.id))
        let managedRoot = store.managedFilesDir
        var staged: [URL] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if let url = try? PhotoImport.stage(data: data, managedRoot: managedRoot) {
                staged.append(url)
            }
        }
        guard !staged.isEmpty else { return }
        model.addFiles(staged)
        await model.flushSession()
        if selectFirstNew,
           let firstNew = model.items.first(where: { !existingIDs.contains($0.id) }) {
            model.select(firstNew.id)
            await loadSelectedBase()
        } else if model.selectedID == nil, let first = model.items.first?.id {
            model.select(first)
            await loadSelectedBase()
        }
    }

    private func select(_ id: UUID) {
        model.select(id)
        Task { await loadSelectedBase() }
    }

    /// Decode the selected photo's ORIGINAL at preview size — hydrating it
    /// from the cloud first when this device doesn't hold the bytes yet.
    private func loadSelectedBase() async {
        guard let item = model.selectedItem else { return }
        if let cached = decodedBase[item.id] {
            baseImage = cached
            hydrateFailedID = nil
            return
        }
        baseImage = nil
        guard let url = await ensureLocalOriginal(item) else {
            hydrateFailedID = item.id
            return
        }
        hydrateFailedID = nil
        let decoded = await Task.detached(priority: .userInitiated) {
            Self.decodeBase(url)
        }.value
        if let decoded {
            cacheDecoded(decoded, for: item.id)
            if model.selectedItem?.id == item.id { baseImage = decoded }
        }
    }

    /// The photo's original bytes on THIS device — hydrating from the cloud
    /// when needed. Returns nil when the bytes can't be produced (offline,
    /// not yet uploaded by the peer).
    private func ensureLocalOriginal(_ item: MergeModel.BatchItem) async -> URL? {
        if FileManager.default.fileExists(atPath: item.sdrURL.path) { return item.sdrURL }
        hydrating = true
        defer { hydrating = false }
        guard let session = await appModel.session(id: model.session.id),
              let hash = session.photos.first(where: { $0.id == item.id })?.contentHash,
              let hydrated = await appModel.engine?.hydrateOriginal(hash: hash) else {
            return nil
        }
        return hydrated
    }

    nonisolated private static func decodeBase(_ url: URL) -> CIImage? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return CIImage(cgImage: cg)
    }

    // ------------------------------------------------------------- export

    private func exportSelected() {
        guard let id = model.selectedID, let item = model.selectedItem else { return }
        exporting = true
        Task {
            defer { exporting = false }
            // The encoder needs the original bytes locally — hydrate first
            // (a Mac-originated photo may not be downloaded yet).
            guard await ensureLocalOriginal(item) != nil else {
                notice = EditorNotice(
                    title: "Can't export yet",
                    message: "This photo hasn't finished downloading. "
                        + "Check your connection and try again.")
                return
            }
            try? FileManager.default.createDirectory(at: Self.exportsDir,
                                                     withIntermediateDirectories: true)
            await model.mergeItem(id)
            if let out = model.items.first(where: { $0.id == id })?.outputURL {
                shareURL = out
            } else {
                // A failed merge previously looked like a dead button.
                let detail = model.items.first(where: { $0.id == id })?.error
                    ?? model.errorMessage
                notice = EditorNotice(
                    title: "Export failed",
                    message: detail ?? "The HDR merge didn't complete. Please try again.")
            }
        }
    }
}

/// Alert payload for editor failures (alert(item:) needs Identifiable).
private struct EditorNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - bits

private struct FilmstripThumb: View {
    let url: URL
    let selected: Bool
    let done: Bool
    let tooLarge: Bool

    @State private var thumb: CGImage?

    var body: some View {
        ZStack {
            if let thumb {
                Image(decorative: thumb, scale: 1)
                    .resizable().aspectRatio(contentMode: .fill)
            } else {
                Theme.inset
                Image(systemName: "photo").font(.system(size: 12))
                    .foregroundStyle(Theme.stoneFaint)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(selected ? Theme.gold : Theme.line, lineWidth: selected ? 2 : 1))
        .overlay(alignment: .bottomTrailing) {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10)).foregroundStyle(Theme.gold)
                    .padding(3)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if tooLarge {
                Image(systemName: "externaldrive")
                    .font(.system(size: 8)).foregroundStyle(Theme.stoneDim)
                    .padding(3)
            }
        }
        .task(id: url) {
            thumb = await Task.detached(priority: .utility) {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 160,
                ]
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            }.value
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
