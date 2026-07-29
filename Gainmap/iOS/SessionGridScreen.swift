//
//  SessionGridScreen.swift
//  Gainmap for iPhone (P5)
//
//  The home screen: shared SessionGridView + waitlist banner + account menu.
//

import SwiftUI
import PhotosUI
import GainmapCore

/// What the editor cover opens: an existing session, or a brand-new one
/// seeded with photos picked on this phone.
struct EditorRequest: Identifiable {
    let id = UUID()
    let session: Session
    let importItems: [PhotosPickerItem]
}

struct SessionGridScreen: View {
    @EnvironmentObject private var auth: AuthController
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var quickActions: GainmapSceneDelegate
    @State private var editorRequest: EditorRequest?
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var newSessionPickerPresented = false
    @State private var renaming: SessionCard?
    @State private var renameText = ""
    @State private var deleting: SessionCard?
    @State private var exportShare: SessionExportShare?
    @State private var partialExportFailures = 0
    @State private var notice: GridNotice?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    if case .waitlisted = auth.state {
                        waitlistBanner
                    }
                    if model.cards.isEmpty {
                        if model.initialLoadDone {
                            emptyState
                        } else {
                            // Don't claim "No sessions yet" before we've looked.
                            VStack {
                                Spacer()
                                ProgressView().tint(Theme.stoneDim)
                                Spacer()
                            }.frame(maxWidth: .infinity)
                        }
                    } else {
                        SessionGridView(
                            cards: model.cards,
                            onOpen: { id in
                                Task {
                                    if let session = await model.session(id: id) {
                                        editorRequest = EditorRequest(
                                            session: session, importItems: [])
                                    }
                                }
                            },
                            onExport: exportSession,
                            onRename: beginRename,
                            onDelete: { id in
                                deleting = model.cards.first(where: { $0.id == id })
                            },
                            syncState: cardSyncState)
                    }
                }

                if model.exportingSessionID != nil {
                    exportProgressOverlay
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Phone-native session: pick photos, land in the editor.
                    Button {
                        newSessionPickerPresented = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(Theme.gold)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        let state = syncVisualState
                        notice = GridNotice(title: state.title, message: state.message)
                    } label: {
                        IOSSyncIndicator(state: syncVisualState)
                    }
                    .accessibilityLabel("Sync status: \(syncVisualState.title)")

                    Menu {
                        if let email = auth.email {
                            Text(email)
                        }
                        Button("Sign out", role: .destructive) { auth.signOut() }
                    } label: {
                        Image(systemName: "person.circle")
                            .foregroundStyle(Theme.stoneDim)
                    }
                }
            }
            .photosPicker(isPresented: $newSessionPickerPresented,
                          selection: $pickedItems,
                          matching: .images,
                          photoLibrary: .shared())
            .fullScreenCover(item: $editorRequest, onDismiss: {
                Task { await model.refresh() }
            }) { request in
                EditorScreen(session: request.session,
                             store: model.store,
                             importItems: request.importItems)
                    .environmentObject(model)
            }
            .sheet(item: $exportShare, onDismiss: {
                guard partialExportFailures > 0 else { return }
                let count = partialExportFailures
                partialExportFailures = 0
                notice = GridNotice(
                    title: "Some photos weren't exported",
                    message: "\(count) photo\(count == 1 ? "" : "s") could not be downloaded or encoded. The completed exports are ready.")
            }) { share in
                SessionShareSheet(items: share.urls)
            }
            .alert("Rename Session", isPresented: renameAlertPresented) {
                TextField("Session name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    guard let id = renaming?.id else { return }
                    let title = renameText
                    renaming = nil
                    Task { await model.renameSession(id: id, to: title) }
                }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("This name syncs to your other devices.")
            }
            .confirmationDialog(
                "Delete “\(deletingTitle)”?",
                isPresented: deleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Delete Session", role: .destructive) {
                    guard let id = deleting?.id else { return }
                    deleting = nil
                    Task { await model.deleteSession(id: id) }
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("This removes the session from Gainmap on every synced device.")
            }
            .alert(item: $notice) { notice in
                Alert(title: Text(notice.title), message: Text(notice.message),
                      dismissButton: .default(Text("OK")))
            }
            .onChange(of: pickedItems) { _, items in
                guard !items.isEmpty else { return }
                pickedItems = []
                editorRequest = EditorRequest(session: Session(), importItems: items)
            }
            .onChange(of: quickActions.requestedQuickAction) { _, action in
                Task { await handleQuickAction(action) }
            }
            .onChange(of: model.cards.count) { _, count in
                quickActions.updateContinueLatestShortcut(hasSessions: count > 0)
            }
            .onChange(of: model.initialLoadDone) { _, loaded in
                guard loaded else { return }
                Task { await handleQuickAction(quickActions.requestedQuickAction) }
            }
            .task {
                await model.refresh()
                quickActions.updateContinueLatestShortcut(hasSessions: !model.cards.isEmpty)
                await handleQuickAction(quickActions.requestedQuickAction)
            }
            .refreshable { await model.refresh() }
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } })
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } })
    }

    private var deletingTitle: String {
        guard let title = deleting?.title, !title.isEmpty else {
            return "Untitled session"
        }
        return title
    }

    private func beginRename(_ card: SessionCard) {
        renameText = card.title
        renaming = card
    }

    private func exportSession(_ id: UUID) {
        guard model.exportingSessionID == nil else {
            notice = GridNotice(
                title: "Export in progress",
                message: "Finish the current session export before starting another.")
            return
        }
        Task {
            do {
                let result = try await model.exportSession(id: id)
                partialExportFailures = result.failedCount
                exportShare = SessionExportShare(urls: result.urls)
            } catch {
                notice = GridNotice(
                    title: "Export failed",
                    message: error.localizedDescription)
            }
        }
    }

    private var exportProgressOverlay: some View {
        VStack(spacing: 10) {
            ProgressView(
                value: Double(model.exportCompletedCount),
                total: Double(max(model.exportTotalCount, 1)))
                .tint(Theme.gold)
                .frame(width: 180)
            Text("EXPORTING SESSION")
                .font(Theme.mono(10, .bold))
                .tracking(1.4)
                .foregroundStyle(Theme.stone)
            Text("\(model.exportCompletedCount) of \(model.exportTotalCount)")
                .font(Theme.mono(9))
                .foregroundStyle(Theme.stoneDim)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private func cardSyncState(_ card: SessionCard) -> SessionCardSyncState {
        switch auth.state {
        case .signedOut, .waitlisted:
            return .neutral
        case .failed:
            return card.pendingSync ? .issue(card.syncProgress) : .neutral
        case .admitting:
            return .pending(0)
        case .ready:
            if card.syncIssue {
                return .issue(card.syncProgress)
            }
            if !model.initialSyncComplete {
                return .pending(card.pendingSync ? card.syncProgress : 0)
            }
            if card.pendingSync { return .pending(card.syncProgress) }
            return .synced
        }
    }

    private var syncVisualState: IOSSyncVisualState {
        switch auth.state {
        case .signedOut, .waitlisted:
            return .localOnly
        case .failed:
            return .issue
        case .admitting:
            return .connecting
        case .ready:
            if model.hasSyncIssue { return .issue }
            if !model.initialSyncComplete { return .connecting }
            if model.syncPassInFlight || model.pendingWorkCount > 0 {
                return .syncing(model.pendingWorkCount)
            }
            return .synced
        }
    }

    @MainActor
    private func handleQuickAction(_ action: GainmapQuickAction?) async {
        // On a cold launch the auth transition may still be creating the
        // per-user store. Leave the request pending; initialLoadDone will retry.
        guard model.store != nil,
              let action,
              quickActions.requestedQuickAction == action else { return }

        switch action {
        case .newSession:
            newSessionPickerPresented = true
        case .continueLatest:
            if let session = await model.store?.mostRecent() {
                editorRequest = EditorRequest(session: session, importItems: [])
            } else {
                // A stale dynamic shortcut can survive a reinstall or account
                // change. Starting a session remains a useful, non-dead end.
                newSessionPickerPresented = true
            }
        }
        quickActions.consume(action)
    }

    private var waitlistBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: auth.admissionError == nil ? "hourglass" : "wifi.exclamationmark")
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                // Tell the truth: a network failure is NOT a waitlist.
                Text(auth.admissionError
                     ?? "Sync is full right now — you're on the waitlist.")
                    .font(Theme.ui(12, .medium)).foregroundStyle(Theme.stone)
                Text(auth.admissionError == nil
                     ? "Everything works offline; sessions sync once a spot opens."
                     : "Everything works offline; sync connects automatically.")
                    .font(Theme.mono(9)).foregroundStyle(Theme.stoneDim)
            }
            Spacer()
            Button("Re-check") { auth.retryAdmission() }
                .font(Theme.mono(10, .semibold)).foregroundStyle(Theme.gold)
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(Theme.surface.opacity(0.6))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line),
                 alignment: .bottom)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 40)).foregroundStyle(Theme.stoneFaint)
            Text("No sessions yet")
                .font(Theme.ui(16, .semibold)).foregroundStyle(Theme.stone)
            Text("Tap + to import photos from this phone,\nor drop them into Gainmap on your Mac —\neither way they show up everywhere.")
                .font(Theme.ui(13)).foregroundStyle(Theme.stoneDim)
                .multilineTextAlignment(.center)
            if model.syncing {
                ProgressView().tint(Theme.stoneDim).padding(.top, 8)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SessionExportShare: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct GridNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum IOSSyncVisualState: Equatable {
    case localOnly
    case connecting
    case syncing(Int)
    case synced
    case issue

    var title: String {
        switch self {
        case .localOnly: return "Saved on this iPhone"
        case .connecting: return "Connecting to Sync"
        case .syncing(let count):
            return count > 0 ? "Syncing \(count) Item\(count == 1 ? "" : "s")" : "Syncing"
        case .synced: return "Up to Date"
        case .issue: return "Sync Needs Attention"
        }
    }

    var message: String {
        switch self {
        case .localOnly:
            return "These sessions are available on this iPhone only. Sign in to sync with your Mac."
        case .connecting:
            return "Gainmap is connecting. The latest sessions may not be visible on your other devices yet."
        case .syncing:
            return "Keep Gainmap open while the latest images and looks are sent to your other devices."
        case .synced:
            return "The latest sessions and looks should now be available on your Mac."
        case .issue:
            return "One or more sessions could not finish syncing. Check your connection and try again."
        }
    }

    var color: Color {
        switch self {
        case .localOnly: return Theme.stoneFaint
        case .connecting: return Theme.gold
        case .syncing: return Theme.accent
        case .synced: return Theme.syncGreen
        case .issue: return .red
        }
    }
}

private struct IOSSyncIndicator: View {
    let state: IOSSyncVisualState

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.line, lineWidth: 2)
            switch state {
            case .connecting, .syncing:
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(state.color)
                    .scaleEffect(0.62)
            case .synced:
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(state.color)
            case .issue:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(state.color)
            case .localOnly:
                Image(systemName: "iphone")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(state.color)
            }
        }
        .frame(width: 24, height: 24)
        .overlay(Circle().stroke(state.color.opacity(0.9), lineWidth: 1.5))
    }
}

private struct SessionShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController,
                                context: Context) {}
}
