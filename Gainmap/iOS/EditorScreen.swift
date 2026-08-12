//
//  EditorScreen.swift
//  Gainmap for iPhone (P5)
//
//  The compact editor, built around SCREEN REAL ESTATE: back/share use spare
//  gutters or a top rail when the fitted image leaves room, and fall back to
//  contrast-sampled overlays only when it fills the stage. The session title
//  cubbyholes into the controls sheet; and the sheet's RESTING height is
//  computed from the photo's aspect ratio, so it rises to kiss the bottom of
//  the image (landscape = tall sheet, portrait = image gets the room) instead
//  of covering it. Same LookControlsPanel as the Mac, tabbed (concept D).
//

import SwiftUI
import CoreImage
import ImageIO
import PhotosUI
import GainmapCore

private enum PreviewChromePlacement: Equatable {
    case topRail
    case sideGutters
    case overlay
}

private struct PreviewChromeTone: Equatable, Sendable {
    var leadingIsDark = true
    var trailingIsDark = true
}

struct EditorScreen: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var auth: AuthController
    @Environment(\.dismiss) private var dismiss
    @AppStorage("gainmap.ios.instagramPinningGuideSuppressed.v1")
    private var instagramPinningGuideSuppressed = false
    @AppStorage("gainmap.ios.instagramMixedAspectGuideSuppressed.v1")
    private var instagramMixedAspectGuideSuppressed = false

    @StateObject private var model: MergeModel
    @State private var showAdvancedLook = false
    @State private var expandedGroups: Set<String> = ["glow", "color", "hdr"]
    // Starts FALSE: presenting a sheet while the fullScreenCover is still
    // animating in gets silently dropped by UIKit — prepare() raises it once
    // the cover has settled.
    @State private var controlsPresented = false
    @State private var comparing = false
    @State private var baseImage: CIImage?
    @State private var previewChromeTone = PreviewChromeTone()
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
    /// Ordered multi-photo export promoted from the successful Instagram
    /// activity-sheet spike. It remains target-agnostic: every destination
    /// receives one file URL per photo, in filmstrip order.
    @State private var sessionShareTask: Task<Void, Never>?
    @State private var sessionShareRunning = false
    @State private var sessionSharePayload: SessionSharePayload?
    @State private var removalCandidate: PhotoRemovalCandidate?
    @State private var reorderRequest: PhotoReorderRequest?
    @State private var instagramShareGuidePresented = false
    @State private var instagramShareGuideSuppressPinning = false
    @State private var instagramShareGuideSuppressMixedAspect = false
    @State private var resumeShareAfterInstagramGuide = false
    @State private var instagramGuideShowsPinningTip = false
    @State private var instagramGuideAspectAssessment: InstagramAspectAssessment?
    @State private var instagramGuideAssessedIDs: [UUID] = []
    @State private var instagramAspectAssessmentTask: Task<Void, Never>?
    @State private var instagramAspectAssessmentRunning = false

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
    private let chromeRailHeight: CGFloat = 42

    private var controlsCollapsed: Bool {
        detentSelection == .height(collapsedDetentHeight)
    }

    /// Queue mutations are frozen while bytes or exports are in flight. This
    /// keeps a context-menu action from invalidating an ordered share snapshot.
    private var editorMutationBusy: Bool {
        importing || hydrating || exporting || sessionShareRunning
            || instagramAspectAssessmentRunning
            || model.phase == .merging || model.isExportingAll
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.bg.ignoresSafeArea()
                let fitted = fittedImageSize(in: geo)
                let chromePlacement = previewChromePlacement(in: geo, fitted: fitted)
                VStack(spacing: hGap) {
                    previewStage(
                        fitted: fitted,
                        availableWidth: geo.size.width - 20,
                        placement: chromePlacement)
                        .frame(height: fitted.height
                               + (chromePlacement == .topRail ? chromeRailHeight : 0))
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
        .task(id: editorThumbnailHydrationIdentity) {
            appModel.beginEditing(model)
            await appModel.prepareEditorThumbnails(
                sessionID: model.session.id)
        }
        .onDisappear {
            sessionShareTask?.cancel()
            sessionShareTask = nil
            instagramAspectAssessmentTask?.cancel()
            instagramAspectAssessmentTask = nil
            instagramAspectAssessmentRunning = false
            resumeShareAfterInstagramGuide = false
            instagramGuideAssessedIDs = []
            controlsPresented = false
            appModel.endEditing(model)
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
        let chromeHeight = previewChromePlacement(in: geo, fitted: fitted) == .topRail
            ? chromeRailHeight : 0
        let usedAbove = fitted.height + chromeHeight + stripHeight + hGap * 2 + 2
        let free = geo.size.height + geo.safeAreaInsets.bottom - usedAbove
        let clamped = max(minResting, min(free, geo.size.height * 0.48))
        guard abs(clamped - restingDetent) > 1 else { return }
        let wasResting = detentSelection == .height(restingDetent)
        restingDetent = clamped
        if wasResting { detentSelection = .height(clamped) }
    }

    private func previewChromePlacement(
        in geo: GeometryProxy,
        fitted: CGSize
    ) -> PreviewChromePlacement {
        let availableWidth = geo.size.width - 20
        let sideGutter = max(0, (availableWidth - fitted.width) / 2)
        if sideGutter >= 42 { return .sideGutters }

        let maxImageHeight = geo.size.height - stripHeight - hGap * 2
            - max(0, minResting - geo.safeAreaInsets.bottom)
        if maxImageHeight - fitted.height >= chromeRailHeight {
            return .topRail
        }
        return .overlay
    }

    // ------------------------------------------------------------- pieces

    @ViewBuilder
    private func previewStage(
        fitted: CGSize,
        availableWidth: CGFloat,
        placement: PreviewChromePlacement
    ) -> some View {
        switch placement {
        case .topRail:
            VStack(spacing: 0) {
                previewChrome(
                    width: availableWidth,
                    leadingImageIsDark: nil,
                    trailingImageIsDark: nil)
                    .frame(height: chromeRailHeight)
                previewSurface
                    .frame(width: fitted.width, height: fitted.height)
            }
        case .sideGutters:
            ZStack {
                previewSurface
                    .frame(width: fitted.width, height: fitted.height)
                previewChrome(
                    width: availableWidth,
                    leadingImageIsDark: nil,
                    trailingImageIsDark: nil)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        case .overlay:
            ZStack {
                previewSurface
                    .frame(width: fitted.width, height: fitted.height)
                previewChrome(
                    width: fitted.width,
                    leadingImageIsDark: previewChromeTone.leadingIsDark,
                    trailingImageIsDark: previewChromeTone.trailingIsDark)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func previewChrome(
        width: CGFloat,
        leadingImageIsDark: Bool?,
        trailingImageIsDark: Bool?
    ) -> some View {
        HStack {
            floatingButton(
                system: "chevron.left",
                disabled: editorMutationBusy,
                imageIsDark: leadingImageIsDark
            ) {
                controlsPresented = false
                Task {
                    await model.flushSession()
                    dismiss()
                }
            }
            Spacer()
            HStack(spacing: 7) {
                editorSyncIndicator
                floatingButton(
                    system: exporting ? nil : "square.and.arrow.up",
                    spinning: exporting,
                    disabled: !model.canSaveSelected || editorMutationBusy,
                    imageIsDark: trailingImageIsDark
                ) {
                    exportSelected()
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: chromeRailHeight)
    }

    private var previewSurface: some View {
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
                                imageIsDark: Bool? = nil,
                                action: @escaping () -> Void) -> some View {
        let fill = floatingButtonFill(imageIsDark: imageIsDark)
        let foreground = floatingButtonForeground(imageIsDark: imageIsDark)
        return Button(action: action) {
            ZStack {
                Circle()
                    .fill(fill)
                    .overlay {
                        Circle().stroke(
                            foreground.opacity(imageIsDark == nil ? 0.22 : 0.48),
                            lineWidth: 1)
                    }
                if spinning {
                    ProgressView()
                        .tint(imageIsDark == true ? Theme.bgDeep : Theme.gold)
                        .controlSize(.small)
                } else if let system {
                    Image(systemName: system)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            disabled ? foreground.opacity(0.38) : foreground)
                }
            }
            .frame(width: 34, height: 34)
            .shadow(color: .black.opacity(0.32), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func floatingButtonFill(imageIsDark: Bool?) -> Color {
        switch imageIsDark {
        case .some(true): return Theme.stone.opacity(0.92)
        case .some(false): return .black.opacity(0.76)
        case .none: return Theme.surfaceHi.opacity(0.96)
        }
    }

    private func floatingButtonForeground(imageIsDark: Bool?) -> Color {
        imageIsDark == true ? Theme.bgDeep : Theme.stone
    }

    private var editorSyncIndicator: some View {
        ZStack {
            Circle()
                .fill(Theme.surfaceHi.opacity(0.96))
            GainmapEmblem()
                .frame(width: 25, height: 25)
            SessionSyncRing(state: editorSyncState, lineWidth: 2.2)
                .frame(width: 36, height: 36)
        }
        .frame(width: 38, height: 38)
        .shadow(color: .black.opacity(0.32), radius: 4, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sync status: \(editorSyncState.label)")
        .accessibilityHint(editorSyncState.accessibilityDescription)
    }

    private var editorSyncState: SessionEditorSyncState {
        let card = appModel.cards.first { $0.id == model.session.id }
        switch auth.state {
        case .signedOut, .failed, .checking, .localOnly:
            return .resolve(
                card: card,
                localOnly: true,
                unavailable: false,
                initialSyncComplete: appModel.initialSyncComplete,
                hasUnflushedChanges: model.hasUnflushedSessionChanges)
        case .ready:
            return .resolve(
                card: card,
                localOnly: false,
                unavailable: false,
                initialSyncComplete: appModel.initialSyncComplete,
                hasUnflushedChanges: model.hasUnflushedSessionChanges)
        }
    }

    private var editorThumbnailHydrationIdentity: [String] {
        model.session.photos.map {
            "\($0.id.uuidString):\($0.contentHash ?? "local")"
        }
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
        FilmstripThumb(url: editorThumbnailURL(for: item),
                       sourceRevision: model.sourceRevision(for: item.id),
                       selected: item.id == model.selectedID,
                       done: item.status == .done,
                       tooLarge: item.tooLargeToSync)
            .onTapGesture {
                guard !editorMutationBusy else { return }
                select(item.id)
            }
            .contextMenu {
                Button {
                    presentReorder(startingAt: item.id)
                } label: {
                    Label("Reorder Photos…", systemImage: "arrow.up.arrow.down")
                }
                .disabled(model.items.count < 2 || editorMutationBusy)

                Button(role: .destructive) {
                    removalCandidate = PhotoRemovalCandidate(
                        id: item.id,
                        position: (model.items.firstIndex {
                            $0.id == item.id
                        } ?? 0) + 1)
                } label: {
                    Label("Remove from Session", systemImage: "trash")
                }
                .disabled(editorMutationBusy)
            }
            .accessibilityAction(named: "Reorder photos") {
                presentReorder(startingAt: item.id)
            }
            .accessibilityAction(named: "Remove from session") {
                guard !editorMutationBusy else { return }
                removalCandidate = PhotoRemovalCandidate(
                    id: item.id,
                    position: (model.items.firstIndex {
                        $0.id == item.id
                    } ?? 0) + 1)
            }
    }

    private func editorThumbnailURL(
        for item: MergeModel.BatchItem
    ) -> URL? {
        if let resolved = appModel.editorThumbnailURLs[item.id] {
            return resolved
        }
        return FileManager.default.fileExists(atPath: item.sdrURL.path)
            ? item.sdrURL
            : nil
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
        .disabled(editorMutationBusy)
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
                            .disabled(editorMutationBusy)
                        if model.items.count > 1 {
                            sessionShareControl
                        }
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
        .sheet(
            isPresented: $instagramShareGuidePresented,
            onDismiss: resumePendingShareAfterInstagramGuide
        ) {
            InstagramShareGuide(
                showsPinningTip: instagramGuideShowsPinningTip,
                mixedAspectAssessment: instagramGuideAspectAssessment,
                suppressPinningTip: $instagramShareGuideSuppressPinning,
                suppressMixedAspectTip: $instagramShareGuideSuppressMixedAspect,
                onContinue: {
                    finishInstagramShareGuide(continueSharing: true)
                },
                onCancel: {
                    finishInstagramShareGuide(continueSharing: false)
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.bgDeep)
        }
        .sheet(item: $shareURL) { url in
            PhotoExportShareSheet(
                urls: [url],
                onPhotoLibraryFailure: showPhotoLibrarySaveFailure)
        }
        .sheet(item: $sessionSharePayload) { payload in
            PhotoExportShareSheet(
                urls: payload.urls,
                onCompletion: { activityType, completed, error in
                    recordSessionShareResult(
                        payload: payload,
                        activityType: activityType,
                        completed: completed,
                        error: error)
                },
                onPhotoLibraryFailure: showPhotoLibrarySaveFailure)
        }
        .sheet(item: $reorderRequest) { request in
            PhotoReorderSheet(request: request) { orderedIDs in
                applyReorder(orderedIDs)
            }
            .presentationBackground(Theme.bgDeep)
        }
        .photosPicker(isPresented: $addPickerPresented,
                      selection: $addPickerItems,
                      matching: .images, photoLibrary: .shared())
        .confirmationDialog(
            "Remove Photo?",
            isPresented: removalConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let candidate = removalCandidate {
                Button("Remove Photo \(candidate.position)", role: .destructive) {
                    removePhoto(candidate.id)
                    removalCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) {
                removalCandidate = nil
            }
        } message: {
            Text("This removes it from this session on every synced device. "
                 + "The original in Photos is not deleted.")
        }
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

    private var removalConfirmationPresented: Binding<Bool> {
        Binding(
            get: { removalCandidate != nil },
            set: { presented in
                if !presented { removalCandidate = nil }
            })
    }

    private var sessionShareBusy: Bool {
        editorMutationBusy
    }

    private func requestSessionShare() {
        guard model.items.count > 1, !sessionShareBusy else { return }

        if instagramMixedAspectGuideSuppressed {
            presentInstagramShareGuideOrStart(assessment: nil)
            return
        }

        let candidates = instagramAspectCandidates()
        let orderedIDs = candidates.map(\.id)
        let syncEngine = appModel.engine
        instagramAspectAssessmentRunning = true
        instagramAspectAssessmentTask?.cancel()
        instagramAspectAssessmentTask = Task { @MainActor in
            defer {
                instagramAspectAssessmentTask = nil
                instagramAspectAssessmentRunning = false
            }

            if let syncEngine {
                await hydrateMissingAspectThumbnails(
                    candidates,
                    using: syncEngine)
            }
            guard !Task.isCancelled else { return }

            let assessment = await Task.detached(priority: .utility) {
                InstagramAspectAssessment.assess(candidates)
            }.value

            guard !Task.isCancelled else { return }
            guard model.items.map(\.id) == orderedIDs,
                  controlsPresented,
                  model.items.count > 1 else { return }
            // The no-guide route starts the ordered share immediately, whose
            // guard must no longer see the metadata probe as active.
            instagramAspectAssessmentRunning = false
            presentInstagramShareGuideOrStart(assessment: assessment)
        }
    }

    private func instagramAspectCandidates() -> [InstagramAspectCandidate] {
        let hashByID = model.session.photos.reduce(into: [UUID: String]()) {
            partial, photo in
            if let hash = photo.contentHash {
                partial[photo.id] = hash
            }
        }
        return model.items.map { item in
            let thumbnailURL = hashByID[item.id].flatMap { hash in
                store?.thumbnailURL(forContentHash: hash)
            }
            return InstagramAspectCandidate(
                id: item.id,
                sourceURL: item.sdrURL,
                thumbnailURL: thumbnailURL,
                contentHash: hashByID[item.id])
        }
    }

    private func hydrateMissingAspectThumbnails(
        _ candidates: [InstagramAspectCandidate],
        using engine: SyncEngine
    ) async {
        let fm = FileManager.default
        let hashes = candidates.compactMap { candidate -> String? in
            if fm.fileExists(atPath: candidate.sourceURL.path) {
                return nil
            }
            if let thumbnailURL = candidate.thumbnailURL,
               fm.fileExists(atPath: thumbnailURL.path) {
                return nil
            }
            return candidate.contentHash
        }
        guard !hashes.isEmpty else { return }

        let wanted = Array(Set(hashes))
        await withTaskGroup(of: Void.self) { group in
            var next = min(4, wanted.count)
            for hash in wanted.prefix(next) {
                group.addTask {
                    _ = await engine.hydrateThumb(hash: hash)
                }
            }
            while await group.next() != nil {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if next < wanted.count {
                    let hash = wanted[next]
                    next += 1
                    group.addTask {
                        _ = await engine.hydrateThumb(hash: hash)
                    }
                }
            }
        }
    }

    private func presentInstagramShareGuideOrStart(
        assessment: InstagramAspectAssessment?
    ) {
        let showsPinningTip = !instagramPinningGuideSuppressed
        let mixedAssessment = assessment.flatMap {
            $0.requiresMixedMode && !instagramMixedAspectGuideSuppressed ? $0 : nil
        }
        guard showsPinningTip || mixedAssessment != nil else {
            startSessionShare()
            return
        }

        instagramGuideShowsPinningTip = showsPinningTip
        instagramGuideAspectAssessment = mixedAssessment
        instagramGuideAssessedIDs = model.items.map(\.id)
        instagramShareGuideSuppressPinning = false
        instagramShareGuideSuppressMixedAspect = false
        resumeShareAfterInstagramGuide = false
        instagramShareGuidePresented = true
    }

    private func finishInstagramShareGuide(continueSharing: Bool) {
        resumeShareAfterInstagramGuide = continueSharing
        instagramShareGuidePresented = false
    }

    private func resumePendingShareAfterInstagramGuide() {
        let shouldResume = resumeShareAfterInstagramGuide
        let assessedIDs = instagramGuideAssessedIDs
        resumeShareAfterInstagramGuide = false

        if instagramGuideShowsPinningTip && instagramShareGuideSuppressPinning {
            instagramPinningGuideSuppressed = true
        }
        if instagramGuideAspectAssessment != nil
            && instagramShareGuideSuppressMixedAspect {
            instagramMixedAspectGuideSuppressed = true
        }
        instagramShareGuideSuppressPinning = false
        instagramShareGuideSuppressMixedAspect = false
        instagramGuideShowsPinningTip = false
        instagramGuideAspectAssessment = nil
        instagramGuideAssessedIDs = []

        guard shouldResume else { return }
        Task { @MainActor in
            // Let UIKit finish dismissing the guide before the ordered export
            // eventually presents the activity controller from this same sheet.
            await Task.yield()
            guard controlsPresented,
                  model.items.count > 1,
                  !sessionShareBusy else { return }
            guard model.items.map(\.id) == assessedIDs else {
                notice = EditorNotice(
                    title: "Session changed",
                    message: "The filmstrip changed while the Instagram guide "
                        + "was open. Tap Share Session again so Gainmap can "
                        + "recheck the photo shapes.")
                return
            }
            startSessionShare()
        }
    }

    private var sessionShareControl: some View {
        VStack(spacing: 6) {
            Button {
                requestSessionShare()
            } label: {
                HStack(spacing: 8) {
                    if sessionShareRunning || instagramAspectAssessmentRunning {
                        ProgressView()
                            .tint(Theme.accent)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text("SHARE SESSION")
                        .font(Theme.mono(10, .bold))
                        .tracking(1.2)
                    Spacer()
                    Text("\(model.items.count) PHOTOS")
                        .font(Theme.mono(8, .semibold))
                        .foregroundStyle(Theme.stoneDim)
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Theme.inset,
                            in: RoundedRectangle(cornerRadius: 10,
                                                 style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.accent.opacity(0.55), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(sessionShareBusy)
            .opacity(sessionShareBusy ? 0.48 : 1)

            Text(sessionShareHelpCopy)
                .font(Theme.mono(8))
                .foregroundStyle(Theme.stoneDim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 2)
    }

    private var sessionShareHelpCopy: String {
        if instagramAspectAssessmentRunning {
            return "Checking photo shapes before Instagram opens…"
        }
        if sessionShareBusy {
            return sessionShareRunning
                ? "Hydrating and exporting every photo in filmstrip order…"
                : "Wait for the current import, download, or export to finish."
        }
        return "Exports every photo in filmstrip order. Gainmap flags mixed "
            + "photo shapes before Instagram opens."
    }

    // ------------------------------------------------------------- preview data

    /// Small LRU of decoded preview bases: each entry is a materialized
    /// ~1600px bitmap (~8 MB), so an unbounded dictionary jetsammed the app
    /// on big sessions (P5 review). Six covers back-and-forth comparison
    /// without holding a whole filmstrip walk.
    @State private var decodedBase: [UUID: CIImage] = [:]
    @State private var decodedChromeTone: [UUID: PreviewChromeTone] = [:]
    @State private var decodedOrder: [UUID] = []
    private static let decodedCap = 6

    private func cacheDecoded(
        _ image: CIImage,
        tone: PreviewChromeTone,
        for id: UUID
    ) {
        decodedBase[id] = image
        decodedChromeTone[id] = tone
        decodedOrder.removeAll { $0 == id }
        decodedOrder.append(id)
        while decodedOrder.count > Self.decodedCap {
            let evict = decodedOrder.removeFirst()
            decodedBase.removeValue(forKey: evict)
            decodedChromeTone.removeValue(forKey: evict)
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
        model.onSessionPersisted = { [weak appModel, weak model] session, before in
            Task { @MainActor in
                guard let model else { return }
                appModel?.sessionPersisted(
                    session,
                    before: before,
                    sourceModel: model)
            }
        }
        // Inbound sync folds into THIS model while the editor is open.
        appModel.beginEditing(model)
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

    private func presentReorder(startingAt id: UUID) {
        guard model.items.count > 1, !editorMutationBusy else { return }
        let photos = model.items.map {
            ReorderPhoto(
                id: $0.id,
                thumbnailURL: editorThumbnailURL(for: $0),
                sourceRevision: model.sourceRevision(for: $0.id),
                filename: $0.sdrURL.lastPathComponent)
        }
        reorderRequest = PhotoReorderRequest(
            photos: photos,
            highlightedID: id)
    }

    private func applyReorder(_ orderedIDs: [UUID]) {
        let currentIDs = model.items.map(\.id)
        guard !editorMutationBusy,
              orderedIDs.count == currentIDs.count,
              Set(orderedIDs) == Set(currentIDs),
              model.reorderItems(to: orderedIDs)
        else {
            notice = EditorNotice(
                title: "Order changed",
                message: "The session changed while the reorder window was open. "
                    + "Open Reorder Photos and try again.")
            return
        }
        Task { await model.flushSession() }
    }

    private func removePhoto(_ id: UUID) {
        guard !editorMutationBusy,
              model.items.contains(where: { $0.id == id }) else { return }
        let wasSelected = model.selectedID == id
        model.remove(id)
        decodedBase.removeValue(forKey: id)
        decodedChromeTone.removeValue(forKey: id)
        decodedOrder.removeAll { $0 == id }
        if hydrateFailedID == id { hydrateFailedID = nil }

        if model.items.isEmpty {
            baseImage = nil
            previewChromeTone = PreviewChromeTone()
        } else if wasSelected {
            baseImage = nil
        }

        Task {
            if wasSelected, !model.items.isEmpty {
                await loadSelectedBase()
            }
            await model.flushSession()
        }
    }

    /// Decode the selected photo's ORIGINAL at preview size — hydrating it
    /// from the cloud first when this device doesn't hold the bytes yet.
    private func loadSelectedBase() async {
        guard let item = model.selectedItem else { return }
        if let cached = decodedBase[item.id] {
            baseImage = cached
            previewChromeTone = decodedChromeTone[item.id] ?? PreviewChromeTone()
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
            guard let image = Self.decodeBase(url) else {
                return Optional<(CIImage, PreviewChromeTone)>.none
            }
            return (image, Self.chromeTone(for: image))
        }.value
        if let (image, tone) = decoded {
            cacheDecoded(image, tone: tone, for: item.id)
            if model.selectedItem?.id == item.id {
                baseImage = image
                previewChromeTone = tone
            }
        }
    }

    /// The photo's original bytes on THIS device — hydrating from the cloud
    /// when needed. Returns nil when the bytes can't be produced (offline,
    /// not yet uploaded by the peer).
    private func ensureLocalOriginal(_ item: MergeModel.BatchItem) async -> URL? {
        if FileManager.default.fileExists(atPath: item.sdrURL.path) {
            appModel.editorOriginalBecameAvailable(
                sessionID: model.session.id,
                photoID: item.id,
                url: item.sdrURL)
            return item.sdrURL
        }
        hydrating = true
        defer { hydrating = false }
        guard let session = await appModel.session(id: model.session.id),
              let hash = session.photos.first(where: { $0.id == item.id })?.contentHash,
              let hydrated = await appModel.engine?.hydrateOriginal(hash: hash) else {
            return nil
        }
        // The portable blob URL does not change when bytes land. Explicitly
        // invalidate every source consumer and publish a filmstrip source now,
        // rather than waiting for the editor to be closed and recreated.
        model.markSourceAvailable(item.id)
        appModel.editorOriginalBecameAvailable(
            sessionID: model.session.id,
            photoID: item.id,
            url: hydrated)
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

    nonisolated private static func chromeTone(for image: CIImage) -> PreviewChromeTone {
        let extent = image.extent
        guard !extent.isEmpty else { return PreviewChromeTone() }
        let sampleWidth = max(1, extent.width * 0.24)
        let sampleHeight = max(1, extent.height * 0.18)
        let top = extent.maxY - sampleHeight
        let leadingRect = CGRect(
            x: extent.minX, y: top,
            width: sampleWidth, height: sampleHeight)
        let trailingRect = CGRect(
            x: extent.maxX - sampleWidth, y: top,
            width: sampleWidth, height: sampleHeight)
        let context = CIContext(options: [.cacheIntermediates: false])
        return PreviewChromeTone(
            leadingIsDark: averageLuminance(
                image: image, rect: leadingRect, context: context) < 0.46,
            trailingIsDark: averageLuminance(
                image: image, rect: trailingRect, context: context) < 0.46)
    }

    nonisolated private static func averageLuminance(
        image: CIImage,
        rect: CGRect,
        context: CIContext
    ) -> Double {
        guard let average = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: image,
                kCIInputExtentKey: CIVector(cgRect: rect),
            ])?.outputImage else { return 0 }
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        context.render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: colorSpace)
        let red = Double(pixel[0]) / 255
        let green = Double(pixel[1]) / 255
        let blue = Double(pixel[2]) / 255
        return red * 0.2126 + green * 0.7152 + blue * 0.0722
    }

    // ------------------------------------------------------------- export

    @MainActor
    private func startSessionShare() {
        guard model.items.count > 1, !sessionShareBusy else { return }

        // This immutable snapshot is the authority for hydration, encoding,
        // validation, and the eventual activity-item order.
        let orderedIDs = model.items.map(\.id)
        sessionShareRunning = true
        sessionShareTask = Task { @MainActor in
            await performSessionShare(orderedIDs: orderedIDs)
            sessionShareTask = nil
        }
    }

    @MainActor
    private func performSessionShare(orderedIDs: [UUID]) async {
        defer { sessionShareRunning = false }
        let total = orderedIDs.count

        // Finish every download before starting even the first encode. A
        // partial export must never reach the share sheet.
        for (offset, id) in orderedIDs.enumerated() {
            guard !Task.isCancelled else { return }
            guard let item = model.items.first(where: { $0.id == id }) else {
                stopSessionShare(
                    position: offset + 1,
                    total: total,
                    reason: "was removed before it could be downloaded. Try sharing again.")
                return
            }
            guard let localURL = await ensureLocalOriginal(item),
                  Self.isExistingFile(localURL),
                  Self.isExistingFile(item.sdrURL) else {
                guard !Task.isCancelled else { return }
                stopSessionShare(
                    position: offset + 1,
                    total: total,
                    reason: "is not available on this iPhone. Check sync and your connection, then retry.")
                return
            }
        }

        guard !Task.isCancelled else { return }
        guard model.items.map(\.id) == orderedIDs else {
            stopSessionShare(
                position: Self.firstOrderMismatchPosition(
                    expected: orderedIDs,
                    actual: model.items.map(\.id)),
                total: total,
                reason: "no longer matches the filmstrip after downloading. Wait for sync to settle, then retry.")
            return
        }

        // The managed iOS output policy is basename-derived. Detect collisions
        // before encoding so two same-named originals can never replace one
        // another and only then fail validation.
        var plannedOutputPositions: [URL: Int] = [:]
        for (offset, id) in orderedIDs.enumerated() {
            guard let item = model.items.first(where: { $0.id == id }) else {
                stopSessionShare(
                    position: offset + 1,
                    total: total,
                    reason: "was removed before export. No files were changed.")
                return
            }
            let plannedURL = model.outputPolicy
                .outputURL(forSource: item.sdrURL)
                .standardizedFileURL
            if let earlierPosition = plannedOutputPositions[plannedURL] {
                stopSessionShare(
                    position: offset + 1,
                    total: total,
                    reason: "shares its export filename with photo \(earlierPosition) of \(total). Re-import one with a unique filename, then retry.")
                return
            }
            plannedOutputPositions[plannedURL] = offset + 1
        }

        do {
            try FileManager.default.createDirectory(
                at: Self.exportsDir,
                withIntermediateDirectories: true)
        } catch {
            notice = EditorNotice(
                title: "Share session stopped",
                message: "Gainmap couldn't prepare the export folder: \(error.localizedDescription)")
            return
        }

        // Reuse the product's ordered batch exporter. It snapshots its target
        // IDs/look before its first await and places successful files atomically.
        await model.exportAll()
        guard !Task.isCancelled else { return }

        guard model.items.map(\.id) == orderedIDs else {
            stopSessionShare(
                position: Self.firstOrderMismatchPosition(
                    expected: orderedIDs,
                    actual: model.items.map(\.id)),
                total: total,
                reason: "no longer matches the filmstrip after export. No share sheet was opened; retry once sync is idle.")
            return
        }

        var orderedURLs: [URL] = []
        var seenURLs: Set<URL> = []
        for (offset, id) in orderedIDs.enumerated() {
            guard let item = model.items.first(where: { $0.id == id }) else {
                stopSessionShare(
                    position: offset + 1,
                    total: total,
                    reason: "disappeared during export. No files were shared.")
                return
            }
            guard item.status == .done,
                  let outputURL = item.outputURL,
                  outputURL.isFileURL,
                  Self.isExistingFile(outputURL) else {
                let detail = item.error ?? model.errorMessage
                    ?? "the UltraHDR file was not produced"
                stopSessionShare(
                    position: offset + 1,
                    total: total,
                    reason: "failed to export: \(detail).")
                return
            }

            let standardized = outputURL.standardizedFileURL
            guard seenURLs.insert(standardized).inserted else {
                stopSessionShare(
                    position: offset + 1,
                    total: total,
                    reason: "resolved to the same output file as an earlier photo. Re-import it with a unique filename and retry.")
                return
            }
            orderedURLs.append(standardized)
        }

        let payload = SessionSharePayload(urls: orderedURLs)
        #if DEBUG
        print("[SessionShare] presenting orderedFilenames=\(payload.orderedFilenames)")
        #endif
        sessionSharePayload = payload
    }

    nonisolated private static func firstOrderMismatchPosition(
        expected: [UUID],
        actual: [UUID]
    ) -> Int {
        let sharedCount = min(expected.count, actual.count)
        if let mismatch = (0..<sharedCount).first(
            where: { expected[$0] != actual[$0] }) {
            return mismatch + 1
        }
        // A pure insertion/removal has no mismatched element on the shorter
        // side. Attribute it to the nearest valid snapshotted position.
        return max(1, min(expected.count, sharedCount + 1))
    }

    nonisolated private static func isExistingFile(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    @MainActor
    private func stopSessionShare(
        position: Int,
        total: Int,
        reason: String
    ) {
        let message = "Photo \(position) of \(total) \(reason)"
        #if DEBUG
        print("[SessionShare] aborted position=\(position) total=\(total) reason=\(reason)")
        #endif
        notice = EditorNotice(
            title: "Share session stopped",
            message: message)
    }

    private func recordSessionShareResult(
        payload: SessionSharePayload,
        activityType: UIActivity.ActivityType?,
        completed: Bool,
        error: Error?
    ) {
        #if DEBUG
        let activity = activityType?.rawValue ?? "none"
        let errorDescription = error?.localizedDescription ?? "none"
        print(
            "[SessionShare] activityType=\(activity) "
                + "completed=\(completed) error=\(errorDescription) "
                + "orderedFilenames=\(payload.orderedFilenames)")
        #endif
        guard let error else { return }
        Task { @MainActor in
            notice = EditorNotice(
                title: "Sharing failed",
                message: error.localizedDescription)
        }
    }

    private func showPhotoLibrarySaveFailure(_ error: Error) {
        notice = EditorNotice(
            title: "Couldn't save to Photos",
            message: error.localizedDescription)
    }

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

/// Immutable activity payload produced only after every snapshotted photo has
/// a verified UltraHDR file. Keeping the URLs together preserves filmstrip
/// order through SwiftUI's sheet handoff.
private struct SessionSharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]

    var orderedFilenames: [String] {
        urls.map(\.lastPathComponent)
    }
}

/// A no-decode probe target used to decide whether Instagram's Mixed layout
/// guidance is relevant. Synced thumbnails are a safe fallback because their
/// pixels have already been rotated into display orientation.
private struct InstagramAspectCandidate: Sendable {
    let id: UUID
    let sourceURL: URL
    let thumbnailURL: URL?
    let contentHash: String?
}

private struct InstagramAspectAssessment: Equatable, Sendable {
    let totalPhotoCount: Int
    let displayRatios: [Double]

    /// Thumbnail rounding can move an otherwise identical ratio by a few
    /// pixels. 1.5% ignores that noise while still separating common 3:4 and
    /// 4:5 portrait crops.
    private static let relativeTolerance = 0.015

    var requiresMixedMode: Bool {
        guard let minimum = displayRatios.min(),
              let maximum = displayRatios.max(),
              maximum > 0 else { return false }
        return (maximum - minimum) / maximum > Self.relativeTolerance
    }

    /// Instagram documents feed-photo support from 3:4 portrait (0.75) to
    /// 1.91:1 landscape. Mixed preserves differing shapes but cannot promise
    /// uncropped output outside that range.
    var hasPhotoOutsideDocumentedRange: Bool {
        displayRatios.contains { $0 < 0.75 || $0 > 1.91 }
    }

    static func assess(
        _ candidates: [InstagramAspectCandidate]
    ) -> InstagramAspectAssessment {
        let fm = FileManager.default
        let ratios = candidates.compactMap { candidate -> Double? in
            let availableURLs = [candidate.sourceURL, candidate.thumbnailURL]
                .compactMap { $0 }
                .filter { fm.fileExists(atPath: $0.path) }
            for url in availableURLs {
                guard let size = ImageInfo.displayPixelSize(of: url),
                      size.width > 0,
                      size.height > 0 else { continue }
                return Double(size.width / size.height)
            }
            return nil
        }
        return InstagramAspectAssessment(
            totalPhotoCount: candidates.count,
            displayRatios: ratios)
    }
}

private struct PhotoRemovalCandidate {
    let id: UUID
    let position: Int
}

private struct ReorderPhoto: Identifiable, Hashable {
    let id: UUID
    let thumbnailURL: URL?
    let sourceRevision: Int
    let filename: String
}

private struct PhotoReorderRequest: Identifiable {
    let id = UUID()
    let photos: [ReorderPhoto]
    let highlightedID: UUID
}

// MARK: - bits

private struct FilmstripThumb: View {
    let url: URL?
    let sourceRevision: Int
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
        .task(id: SourceIdentity(
            url: url,
            revision: sourceRevision)) {
            thumb = nil
            guard let url else { return }
            let image: CGImage? = await Task.detached(priority: .utility) { () -> CGImage? in
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 160,
                ]
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            thumb = image
        }
    }

    private struct SourceIdentity: Equatable {
        let url: URL?
        let revision: Int
    }
}

private struct PhotoReorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let highlightedID: UUID
    private let onSave: ([UUID]) -> Void
    @State private var photos: [ReorderPhoto]

    init(
        request: PhotoReorderRequest,
        onSave: @escaping ([UUID]) -> Void
    ) {
        highlightedID = request.highlightedID
        self.onSave = onSave
        _photos = State(initialValue: request.photos)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(photos) { photo in
                        HStack(spacing: 12) {
                            FilmstripThumb(
                                url: photo.thumbnailURL,
                                sourceRevision: photo.sourceRevision,
                                selected: photo.id == highlightedID,
                                done: false,
                                tooLarge: false)
                                .allowsHitTesting(false)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("PHOTO \(position(of: photo.id))")
                                    .font(Theme.mono(9, .bold))
                                    .tracking(1)
                                    .foregroundStyle(Theme.gold)
                                Text(photo.filename)
                                    .font(Theme.mono(9))
                                    .foregroundStyle(Theme.stoneDim)
                                    .lineLimit(1)
                            }
                        }
                        .listRowBackground(Theme.surface)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "Photo \(position(of: photo.id)), \(photo.filename)")
                    }
                    .onMove { source, destination in
                        photos.move(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    Text("DRAG INTO FILMSTRIP ORDER")
                        .font(Theme.mono(9, .bold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.gold)
                } footer: {
                    Text("Share Session keeps this exact order. If the photos "
                         + "have different shapes, choose Mixed in Instagram.")
                        .font(Theme.mono(8))
                        .foregroundStyle(Theme.stoneDim)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgDeep)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(photos.map(\.id))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.gold)
    }

    private func position(of id: UUID) -> Int {
        (photos.firstIndex { $0.id == id } ?? 0) + 1
    }
}

private struct InstagramShareGuide: View {
    let showsPinningTip: Bool
    let mixedAspectAssessment: InstagramAspectAssessment?
    @Binding var suppressPinningTip: Bool
    @Binding var suppressMixedAspectTip: Bool
    let onContinue: () -> Void
    let onCancel: () -> Void

    private var showsMixedAspectTip: Bool {
        mixedAspectAssessment != nil
    }

    private var title: String {
        switch (showsPinningTip, showsMixedAspectTip) {
        case (true, true):
            return "Share without surprises"
        case (true, false):
            return "Keep Instagram within reach"
        case (false, true):
            return "Keep every photo’s shape"
        case (false, false):
            return "Share Session"
        }
    }

    private var introduction: String {
        switch (showsPinningTip, showsMixedAspectTip) {
        case (true, true):
            return "Two quick Instagram choices keep the app easy to find "
                + "and this mixed-shape carousel framed correctly."
        case (true, false):
            return "iOS chooses the app row. If Instagram isn’t already "
                + "visible, favorite it once so it stays easy to find."
        case (false, true):
            return "Gainmap found different photo shapes in this session. "
                + "Choose Mixed in Instagram to preserve them."
        case (false, false):
            return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("INSTAGRAM SHARE TIP", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(Theme.gold)

                        Text(title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Theme.stone)

                        Text(introduction)
                            .font(.body)
                            .foregroundStyle(Theme.stone.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if showsPinningTip {
                        instagramPinningSection
                    }

                    if showsPinningTip && showsMixedAspectTip {
                        Divider()
                            .overlay(Theme.line)
                    }

                    if let assessment = mixedAspectAssessment {
                        instagramMixedAspectSection(assessment)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)

            Divider()
                .overlay(Theme.line)

            VStack(spacing: 10) {
                if showsPinningTip {
                    Toggle(
                        "Don’t show the Instagram shortcut tip again",
                        isOn: $suppressPinningTip)
                        .font(.subheadline)
                        .foregroundStyle(Theme.stone)
                        .tint(Theme.accentHot)
                }

                if showsMixedAspectTip {
                    Toggle(
                        "Don’t warn me about mixed photo shapes again",
                        isOn: $suppressMixedAspectTip)
                        .font(.subheadline)
                        .foregroundStyle(Theme.stone)
                        .tint(Theme.accentHot)
                }

                Button(action: onContinue) {
                    Label("CONTINUE TO SHARE", systemImage: "arrow.up.forward.app")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(Color.white)
                        .background(
                            LinearGradient(
                                colors: [Theme.accentHot, Theme.accent],
                                startPoint: .leading,
                                endPoint: .trailing),
                            in: RoundedRectangle(
                                cornerRadius: 12,
                                style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Continue to share session")

                Button("Not Now", action: onCancel)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.stone.opacity(0.78))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.plain)
                    .accessibilityHint(
                        "Closes this guide without opening the share sheet")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.surface.opacity(0.72))
        }
        .background(Theme.bgDeep.ignoresSafeArea())
    }

    @ViewBuilder
    private var instagramPinningSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("KEEP INSTAGRAM CLOSE", symbol: "star")

            InstagramPinningIllustration()

            VStack(alignment: .leading, spacing: 13) {
                InstagramGuideStep(
                    number: 1,
                    title: "Open More",
                    detail: "Swipe the share app row left and tap More.")
                InstagramGuideStep(
                    number: 2,
                    title: "Choose Edit",
                    detail: "Tap Edit at the top of the activity list.")
                InstagramGuideStep(
                    number: 3,
                    title: "Favorite Instagram",
                    detail: "Tap + beside Instagram, then drag it near "
                        + "the top of Favorites.")
            }

            Text(
                "If Instagram is already in the app row, there’s nothing "
                    + "to change—just continue.")
                .font(.footnote)
                .foregroundStyle(Theme.stone.opacity(0.64))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func instagramMixedAspectSection(
        _ assessment: InstagramAspectAssessment
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("MIXED SHAPES DETECTED", symbol: "aspectratio")

            Text(
                "This \(assessment.totalPhotoCount)-photo session contains "
                    + "different aspect ratios. In Instagram’s carousel "
                    + "preview, use the control at the lower left.")
                .font(.body)
                .foregroundStyle(Theme.stone.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            InstagramMixedAspectIllustration()

            VStack(alignment: .leading, spacing: 13) {
                InstagramGuideStep(
                    number: 1,
                    title: "Open the aspect menu",
                    detail: "Tap the resize button at the lower left of "
                        + "Instagram’s carousel preview.")
                InstagramGuideStep(
                    number: 2,
                    title: "Choose Mixed",
                    detail: "Mixed lets each slide keep its own shape.")
                InstagramGuideStep(
                    number: 3,
                    title: "Check every slide",
                    detail: "Swipe through the carousel and verify framing "
                        + "and filmstrip order before posting.")
            }

            if assessment.hasPhotoOutsideDocumentedRange {
                Label(
                    "At least one photo is outside Instagram’s documented "
                        + "3:4–1.91:1 feed range, so it may still be cropped.",
                    systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.gold.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                "If Mixed is missing or any slide still looks cropped, "
                    + "cancel instead of publishing.")
                .font(.footnote)
                .foregroundStyle(Theme.stone.opacity(0.64))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionLabel(
        _ text: String,
        symbol: String
    ) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(Theme.gold)
    }
}

private struct InstagramPinningIllustration: View {
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("SHARE APP ROW")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(Theme.stone.opacity(0.62))
                Spacer()
                Label("SWIPE LEFT", systemImage: "arrow.left")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.gold)
            }

            HStack(spacing: 11) {
                shareTile(
                    title: "Messages",
                    symbol: "message.fill",
                    color: Color(hex: 0x3AAE55))
                shareTile(
                    title: "Mail",
                    symbol: "envelope.fill",
                    color: Color(hex: 0x3578E5))
                Spacer(minLength: 2)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.stone.opacity(0.42))
                shareTile(
                    title: "More",
                    symbol: "ellipsis",
                    color: Theme.surfaceHi,
                    highlighted: true)
            }

            HStack(spacing: 9) {
                Text("EDIT")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.gold)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 30)
                    .background(
                        Theme.inset,
                        in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Theme.gold.opacity(0.48), lineWidth: 1)
                    }

                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.stone.opacity(0.42))

                HStack(spacing: 9) {
                    ZStack {
                        LinearGradient(
                            colors: [
                                Color(hex: 0x6A3DE8),
                                Color(hex: 0xD8398B),
                                Color(hex: 0xF0823D),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.white)
                    }
                    .frame(width: 30, height: 30)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text("Instagram")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.stone)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.syncGreen)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    Theme.inset,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
        }
        .padding(14)
        .background(
            Theme.surface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func shareTile(
        title: String,
        symbol: String,
        color: Color,
        highlighted: Bool = false
    ) -> some View {
        VStack(spacing: 5) {
            ZStack {
                color
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .frame(width: iconSize, height: iconSize)
            .clipShape(
                RoundedRectangle(cornerRadius: iconSize * 0.26,
                                 style: .continuous))
            .overlay {
                if highlighted {
                    RoundedRectangle(
                        cornerRadius: iconSize * 0.26,
                        style: .continuous)
                        .stroke(Theme.gold, lineWidth: 2)
                }
            }

            Text(title)
                .font(.caption2)
                .foregroundStyle(
                    highlighted ? Theme.gold : Theme.stone.opacity(0.72))
                .lineLimit(1)
        }
    }
}

private struct InstagramMixedAspectIllustration: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("INSTAGRAM CAROUSEL")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(Theme.stone.opacity(0.62))
                Spacer()
                Text("LOWER LEFT")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.gold)
            }

            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.inset)

                HStack(alignment: .center, spacing: 9) {
                    samplePhoto(
                        width: 64,
                        height: 104,
                        colors: [Color(hex: 0x34515E), Color(hex: 0x9D7259)])
                    samplePhoto(
                        width: 82,
                        height: 82,
                        colors: [Color(hex: 0x765471), Color(hex: 0xC49A68)])
                    samplePhoto(
                        width: 104,
                        height: 64,
                        colors: [Color(hex: 0x334F3D), Color(hex: 0xA87955)])
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 43)
                .opacity(0.78)

                Button(action: {}) {
                    Image(systemName: "aspectratio")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.72), in: Circle())
                        .overlay {
                            Circle()
                                .stroke(Theme.gold, lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .allowsHitTesting(false)
                .padding(.leading, 12)
                .padding(.bottom, 12)

                VStack(spacing: 0) {
                    aspectMenuRow("Mixed", selected: true)
                    Divider().overlay(Color.white.opacity(0.10))
                    aspectMenuRow("Portrait")
                    Divider().overlay(Color.white.opacity(0.10))
                    aspectMenuRow("Square")
                }
                .frame(width: 148)
                .background(
                    Color(hex: 0x292727).opacity(0.97),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.gold.opacity(0.54), lineWidth: 1)
                }
                .padding(.leading, 65)
                .padding(.bottom, 12)
            }
            .frame(height: 190)
        }
        .padding(14)
        .background(
            Theme.surface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func samplePhoto(
        width: CGFloat,
        height: CGFloat,
        colors: [Color]
    ) -> some View {
        ZStack {
            LinearGradient(
                colors: colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            Image(systemName: "photo.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.64))
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
    }

    private func aspectMenuRow(
        _ title: String,
        selected: Bool = false
    ) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(
                    selected ? Color.white : Color.white.opacity(0.72))
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.white)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }
}

private struct InstagramGuideStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.bgDeep)
                .frame(width: 28, height: 28)
                .background(Theme.gold, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.stone)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.stone.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number). \(title). \(detail)")
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
