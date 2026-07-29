//
//  EditorScreen.swift
//  Gainmap for iPhone (P5)
//
//  The compact editor: full-bleed EDR preview + horizontal filmstrip up top,
//  the SAME LookControlsPanel as the Mac in a persistent bottom sheet
//  (150pt / medium / large detents) with the tabbed advanced groups
//  (concept D). Press-and-hold the preview to compare against the original;
//  an "SDR SCREEN" badge appears when the display can't show EDR.
//

import SwiftUI
import CoreImage
import ImageIO
import GainmapCore

struct EditorScreen: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: MergeModel
    @State private var showAdvancedLook = false
    @State private var expandedGroups: Set<String> = ["glow", "color", "hdr"]
    @State private var controlsPresented = true
    @State private var comparing = false
    @State private var baseImage: CIImage?
    @State private var hydrating = false
    @State private var showGlowInSDRModal = false
    @State private var shareURL: URL?
    @State private var exporting = false

    private let sessionTitle: String

    init(session: Session) {
        sessionTitle = session.title
        // store: nil — the editor mutates its in-memory copy; saves flow
        // through flushSession -> AppModel.sessionPersisted (the sync bridge).
        _model = StateObject(wrappedValue: MergeModel(session: session,
                                                      store: nil,
                                                      output: .managedDirectory(Self.exportsDir)))
    }

    static var exportsDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gm-exports",
                                                                      isDirectory: true)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 10) {
                header
                preview
                filmstrip
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
        }
        .sheet(isPresented: $controlsPresented) {
            controlsSheet
        }
        .sheet(item: $shareURL) { url in
            ShareSheet(items: [url])
        }
        .alert("Glow in SDR", isPresented: $showGlowInSDRModal) {
            Button("Turn on") { model.bloom.bakeGlowIntoSDR = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bakes the soft glow into the standard (non-HDR) version too, so your look shows on every screen. The SDR fallback will be brighter than your original file.")
        }
        .task { await prepare() }
        .onDisappear {
            controlsPresented = false
            Task { await model.flushSession() }
        }
    }

    // ------------------------------------------------------------- pieces

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                controlsPresented = false
                Task {
                    await model.flushSession()
                    dismiss()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    Text("Sessions").font(Theme.ui(14, .medium))
                }
                .foregroundStyle(Theme.stoneDim)
            }
            .buttonStyle(.plain)
            Spacer()
            Text(sessionTitle.isEmpty ? "Untitled session" : sessionTitle)
                .font(Theme.ui(14, .semibold)).foregroundStyle(Theme.stone)
                .lineLimit(1)
            Spacer()
            Button {
                exportSelected()
            } label: {
                if exporting {
                    ProgressView().tint(Theme.gold)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(model.canSaveSelected ? Theme.gold : Theme.stoneFaint)
                }
            }
            .buttonStyle(.plain)
            .disabled(!model.canSaveSelected || exporting)
        }
        .padding(.top, 8)
    }

    private var preview: some View {
        ZStack {
            if let image = comparing ? baseImage : previewImage {
                EDRMetalView(image: image)
            } else {
                Theme.inset
                if hydrating {
                    VStack(spacing: 8) {
                        ProgressView().tint(Theme.stoneDim)
                        Text("Downloading original…")
                            .font(Theme.mono(9)).foregroundStyle(Theme.stoneDim)
                    }
                }
            }
        }
        .aspectRatio(previewAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Theme.line, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if !screenSupportsEDR {
                Text("SDR SCREEN")
                    .font(Theme.mono(8, .bold)).tracking(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Theme.gold, in: Capsule())
                    .padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
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

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.items) { item in
                    FilmstripThumb(url: item.sdrURL,
                                   selected: item.id == model.selectedID,
                                   done: item.status == .done,
                                   tooLarge: item.tooLargeToSync)
                        .onTapGesture { select(item.id) }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 64)
    }

    private var controlsSheet: some View {
        ScrollView {
            LookControlsPanel(model: model,
                              showAdvancedLook: $showAdvancedLook,
                              expandedGroups: $expandedGroups,
                              advancedStyle: .tabbed,
                              onGlowInSDRInfo: { showGlowInSDRModal = true })
                .padding(.horizontal, 10)
                .padding(.top, 12)
        }
        .presentationDetents([.height(170), .medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(true)
        .presentationBackground(Theme.bgDeep)
    }

    // ------------------------------------------------------------- preview data

    @State private var decodedBase: [UUID: CIImage] = [:]

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
        model.onSessionPersisted = { [weak appModel] session in
            Task { @MainActor in appModel?.sessionPersisted(session) }
        }
        if model.selectedID == nil, let first = model.items.first?.id {
            model.select(first)
        }
        await loadSelectedBase()
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
            return
        }
        baseImage = nil
        var url = item.sdrURL
        if !FileManager.default.fileExists(atPath: url.path) {
            hydrating = true
            defer { hydrating = false }
            guard let session = await appModel.session(id: model.session.id),
                  let hash = session.photos.first(where: { $0.id == item.id })?.contentHash,
                  let hydrated = await appModel.engine?.hydrateOriginal(hash: hash) else {
                return
            }
            url = hydrated
        }
        let decoded = Self.decodeBase(url)
        if let decoded {
            decodedBase[item.id] = decoded
            if model.selectedItem?.id == item.id { baseImage = decoded }
        }
    }

    private static func decodeBase(_ url: URL) -> CIImage? {
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
        guard let id = model.selectedID else { return }
        exporting = true
        Task {
            try? FileManager.default.createDirectory(at: Self.exportsDir,
                                                     withIntermediateDirectories: true)
            await model.mergeItem(id)
            exporting = false
            if let out = model.items.first(where: { $0.id == id })?.outputURL {
                shareURL = out
            }
        }
    }
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
        .frame(width: 56, height: 56)
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
