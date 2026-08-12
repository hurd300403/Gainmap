//
//  SessionGridScreen.swift
//  Gainmap for iPhone (P5)
//
//  The home screen: always-available local library + optional Cloud Sync.
//

import SwiftUI
import PhotosUI
import AuthenticationServices
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
    @State private var photoLibrarySaveFailure: String?
    @State private var notice: GridNotice?
    @State private var deleteAccountConfirmationPresented = false
    @State private var appleDeletionSheetPresented = false
    @State private var deletingAccount = false
    @State private var cloudSettingsPresented = false
    @State private var showsEmptyLibraryCloudCoachmark = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    if shouldShowCloudBanner {
                        cloudAccessBanner
                    }
                    if !model.initialLoadDone {
                        VStack {
                            Spacer()
                            ProgressView().tint(Theme.stoneDim)
                            Spacer()
                        }.frame(maxWidth: .infinity)
                    } else {
                        SessionGridView(
                            cards: model.cards,
                            onCreate: { newSessionPickerPresented = true },
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
                            syncState: cardSyncState,
                            showsCloudSyncCoachmark:
                                showsEmptyLibraryCloudCoachmark,
                            onSetUpCloudSync: {
                                cloudSettingsPresented = true
                            })
                    }
                }

                if model.exportingSessionID != nil {
                    exportProgressOverlay
                }
                if deletingAccount && !appleDeletionSheetPresented {
                    accountDeletionProgressOverlay
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        if auth.canSync {
                            let state = syncVisualState
                            notice = GridNotice(title: state.title, message: state.message)
                        } else {
                            cloudSettingsPresented = true
                        }
                    } label: {
                        IOSSyncIndicator(state: syncVisualState)
                    }
                    .accessibilityLabel("Sync status: \(syncVisualState.title)")

                    if auth.uid == nil {
                        Button {
                            cloudSettingsPresented = true
                        } label: {
                            Image(systemName: "person.circle")
                                .foregroundStyle(Theme.stoneDim)
                        }
                        .accessibilityLabel("Set Up Cloud Sync")
                    } else {
                        Menu {
                            if let email = auth.email {
                                Text(email)
                            }
                            Button("Cloud Sync Settings…") {
                                cloudSettingsPresented = true
                            }
                            Button("Sign out of Cloud Sync", role: .destructive) {
                                auth.signOut()
                            }
                            Button("Delete Account", role: .destructive) {
                                deleteAccountConfirmationPresented = true
                            }
                            .disabled(deletingAccount)
                        } label: {
                            Image(systemName: "person.circle")
                                .foregroundStyle(Theme.stoneDim)
                        }
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
                if let failure = photoLibrarySaveFailure {
                    photoLibrarySaveFailure = nil
                    let failedCount = partialExportFailures
                    partialExportFailures = 0
                    let suffix = failedCount == 0 ? "" :
                        "\n\n\(failedCount) photo\(failedCount == 1 ? "" : "s") also could not be exported."
                    notice = GridNotice(
                        title: "Couldn't save to Photos",
                        message: failure + suffix)
                    return
                }
                guard partialExportFailures > 0 else { return }
                let count = partialExportFailures
                partialExportFailures = 0
                notice = GridNotice(
                    title: "Some photos weren't exported",
                    message: "\(count) photo\(count == 1 ? "" : "s") could not be downloaded or encoded. The completed exports are ready.")
            }) { share in
                PhotoExportShareSheet(
                    urls: share.urls,
                    onPhotoLibraryFailure: { error in
                        photoLibrarySaveFailure = error.localizedDescription
                    })
            }
            .sheet(isPresented: $appleDeletionSheetPresented) {
                AppleAccountDeletionSheet(
                    deleting: deletingAccount,
                    prepareRequest: auth.prepareAppleAccountDeletionRequest,
                    onCompletion: { result in
                        Task { await deleteAccount(withAppleAuthorization: result) }
                    },
                    onCancel: { appleDeletionSheetPresented = false })
                .interactiveDismissDisabled(deletingAccount)
            }
            .sheet(isPresented: $cloudSettingsPresented) {
                SignInScreen()
                    .environmentObject(auth)
                    .presentationBackground(Theme.bg)
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
                Text(auth.canSync
                     ? "This name syncs to your other devices."
                     : "This name is saved on this iPhone.")
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
                Text(auth.canSync
                     ? "This removes the session from Gainmap on every synced device."
                     : "This removes the session from this iPhone.")
            }
            .confirmationDialog(
                "Delete your Gainmap account?",
                isPresented: $deleteAccountConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    beginAccountDeletion()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes your account, synced sessions, and private cloud photos. Gainmap also removes its local copies from this iPhone. Images already saved to Photos or Files remain.")
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
                refreshEmptyLibraryCloudCoachmark()
            }
            .onChange(of: model.initialLoadDone) { _, loaded in
                guard loaded else { return }
                refreshEmptyLibraryCloudCoachmark()
                Task { await handleQuickAction(quickActions.requestedQuickAction) }
            }
            .onChange(of: auth.state) {
                refreshEmptyLibraryCloudCoachmark()
            }
            .onChange(of: auth.hasRestoredAuthState) {
                refreshEmptyLibraryCloudCoachmark()
            }
            .task {
                await model.refresh()
                quickActions.updateContinueLatestShortcut(hasSessions: !model.cards.isEmpty)
                refreshEmptyLibraryCloudCoachmark()
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

    private func beginAccountDeletion() {
        if auth.providers.contains("apple.com") {
            appleDeletionSheetPresented = true
        } else if auth.providers.contains("google.com") {
            Task { await deleteAccountWithGoogle() }
        } else {
            notice = GridNotice(
                title: "Sign in again",
                message: "Gainmap couldn't identify the sign-in method for this account. Sign out, sign back in, and try again.")
        }
    }

    @MainActor
    private func deleteAccountWithGoogle() async {
        await performAccountDeletion {
            try await auth.deleteAccountWithGoogle()
        }
    }

    @MainActor
    private func deleteAccount(
        withAppleAuthorization result: Result<ASAuthorization, Error>
    ) async {
        await performAccountDeletion {
            try await auth.deleteAccount(withAppleAuthorization: result)
        }
    }

    @MainActor
    private func performAccountDeletion(
        _ operation: () async throws -> String
    ) async {
        deletingAccount = true
        defer { deletingAccount = false }
        do {
            let uid = try await operation()
            var cleanupError: Error?
            do {
                try await model.purgeLocalAccountData(uid: uid)
                AuthController.completePendingLocalCleanup(uid: uid)
            } catch {
                cleanupError = error
                AuthController.recordPendingLocalCleanup(uid: uid)
            }
            // Cloud deletion is irreversible, so always leave the now-deleted
            // identity. A failed filesystem cleanup is queued durably and
            // reported instead of silently contradicting the privacy promise.
            auth.finishAccountDeletion(uid: uid)
            appleDeletionSheetPresented = false
            if cleanupError != nil {
                notice = GridNotice(
                    title: "Cloud account deleted",
                    message: "Your cloud account and synced data were deleted, but Gainmap couldn't remove every local copy from this iPhone. It will retry automatically next launch. You can also remove all app data by deleting Gainmap from this iPhone.")
            }
        } catch AccountDeletionError.cancelled {
            appleDeletionSheetPresented = false
        } catch {
            appleDeletionSheetPresented = false
            notice = GridNotice(
                title: "Couldn't delete account",
                message: error.localizedDescription)
        }
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

    private var accountDeletionProgressOverlay: some View {
        VStack(spacing: 10) {
            ProgressView().tint(Theme.stone)
            Text("DELETING ACCOUNT")
                .font(Theme.mono(10, .bold))
                .tracking(1.4)
                .foregroundStyle(Theme.stone)
            Text("Removing your cloud library and local copies…")
                .font(Theme.ui(11))
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
        case .signedOut, .failed, .checking, .localOnly:
            return .neutral
        case .ready:
            if card.syncIssue {
                return .issue(card.syncProgress)
            }
            if card.pendingSync { return .pending(card.syncProgress) }
            return card.knownSynced ? .synced : .pending(0)
        }
    }

    private var syncVisualState: IOSSyncVisualState {
        switch auth.state {
        case .signedOut, .failed, .localOnly:
            return .localOnly
        case .checking:
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

    private var shouldShowCloudBanner: Bool {
        switch cloudDisplayState.kind {
        case .needsPatreon, .inactive, .grace, .waitlist,
             .setupPending, .unavailable:
            return auth.uid != nil
        case .signedOut, .signInFailed, .checking, .enabled:
            return false
        }
    }

    private var cloudAccessBanner: some View {
        return HStack(spacing: 10) {
            Image(systemName: cloudBannerIcon)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(cloudDisplayState.title)
                    .font(Theme.ui(12, .medium)).foregroundStyle(Theme.stone)
                Text(cloudDisplayState.detail)
                    .font(Theme.mono(9)).foregroundStyle(Theme.stoneDim)
            }
            Spacer()
            Button(cloudBannerActionLabel) {
                if cloudDisplayState.action == .retry {
                    auth.refreshCloudAccess()
                } else {
                    cloudSettingsPresented = true
                }
            }
                .font(Theme.mono(10, .semibold)).foregroundStyle(Theme.gold)
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(Theme.surface.opacity(0.6))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line),
                 alignment: .bottom)
    }

    private var cloudDisplayState: CloudSyncDisplayState {
        .resolve(
            authState: auth.state,
            access: auth.cloudAccess,
            signedInEmail: auth.email,
            preferPatreonAccountSwitch: auth.shouldOfferPatreonAccountSwitch)
    }

    private var cloudBannerActionLabel: String {
        switch cloudDisplayState.action {
        case .connectPatreon: return "Connect"
        case .switchPatreon: return "Try Another"
        case .retry: return "Try Again"
        case .none, .signIn: return "Details"
        }
    }

    private var cloudBannerIcon: String {
        switch cloudDisplayState.kind {
        case .grace: return "clock"
        case .needsPatreon: return "link.badge.plus"
        case .waitlist: return "hourglass"
        case .setupPending, .unavailable: return "exclamationmark.icloud"
        case .inactive: return "pause.circle"
        case .signedOut, .signInFailed, .checking, .enabled: return "icloud"
        }
    }

    private func refreshEmptyLibraryCloudCoachmark() {
        guard model.initialLoadDone, auth.hasRestoredAuthState else {
            showsEmptyLibraryCloudCoachmark = false
            return
        }
        let signedOut: Bool
        if case .signedOut = auth.state {
            signedOut = true
        } else {
            signedOut = false
        }
        showsEmptyLibraryCloudCoachmark =
            EmptyLibraryCloudCoachmarkGate.visibility(
                libraryIsEmpty: model.cards.isEmpty,
                signedOut: signedOut,
                authStateRestored: auth.hasRestoredAuthState)
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

private struct AppleAccountDeletionSheet: View {
    let deleting: Bool
    let prepareRequest: (ASAuthorizationAppleIDRequest) -> Void
    let onCompletion: (Result<ASAuthorization, Error>) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "person.crop.circle.badge.xmark")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Theme.accentHot)
                Text("Confirm with Apple")
                    .font(Theme.display(28, .semibold))
                    .foregroundStyle(Theme.stone)
                Text("Apple requires a fresh sign-in before Gainmap can revoke access and permanently delete your account.")
                    .font(Theme.ui(14))
                    .foregroundStyle(Theme.stoneDim)
                    .fixedSize(horizontal: false, vertical: true)

                SignInWithAppleButton(.continue,
                                      onRequest: prepareRequest,
                                      onCompletion: onCompletion)
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(deleting)

                if deleting {
                    HStack(spacing: 10) {
                        ProgressView().tint(Theme.stone)
                        Text("Deleting account and cloud library…")
                            .font(Theme.ui(13, .medium))
                            .foregroundStyle(Theme.stoneDim)
                    }
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(deleting)
                }
            }
        }
        .presentationDetents([.medium])
    }
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
