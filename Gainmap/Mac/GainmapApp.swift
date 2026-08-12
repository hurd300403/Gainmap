//
//  GainmapApp.swift
//  Gainmap — a Legacy Lab instrument.
//
//  Turns an SDR JPEG into an UltraHDR (ISO 21496-1) gain-map JPEG — synthesized
//  highlight glow on HDR screens, clean fallback everywhere else — by driving
//  the bundled `uhdrtool` (libultrahdr) helper.
//

import SwiftUI
import Combine
import AppKit
import Sparkle
import GainmapCore

@MainActor
final class GainmapApplicationDelegate: NSObject, NSApplicationDelegate {
    private weak var model: MergeModel?
    private weak var sync: SyncCoordinator?

    func configure(model: MergeModel, sync: SyncCoordinator) {
        self.model = model
        self.sync = sync
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, let sync else { return .terminateNow }
        let hadUnflushedEdit = model.hasUnflushedSessionChanges

        // "Quit Anyway" is never "throw away my edit": make the local file
        // durable before asking about the still-in-flight cloud copy.
        if hadUnflushedEdit {
            model.flushNowForTermination()
        }

        guard sync.syncing,
              hadUnflushedEdit || sync.hasOutstandingCloudWork else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Gainmap is still syncing"
        if sync.pendingWorkCount > 0 {
            let count = sync.pendingWorkCount
            alert.informativeText =
                "\(count) sync item\(count == 1 ? " is" : "s are") still pending. "
                + "Keep Gainmap open until the flask ring turns green so the latest "
                + "images and looks are available on your iPhone. If you quit now, "
                + "everything remains saved on this Mac and will resume next launch."
        } else {
            alert.informativeText =
                "Your latest session change is still being sent. Keep Gainmap open "
                + "until the flask ring turns green so it is available on your iPhone. "
                + "If you quit now, it remains saved on this Mac and will resume next launch."
        }
        alert.addButton(withTitle: "Keep Syncing")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn
            ? .terminateNow
            : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Termination is now irrevocable. Ignore the bounded gRPC/OpenSSL
        // exit wait without weakening hang detection while the app is usable.
        CrashReporting.prepareForTermination()
        model?.flushNowForTermination()
    }
}

@main
struct GainmapApp: App {
    @NSApplicationDelegateAdaptor(GainmapApplicationDelegate.self)
    private var applicationDelegate

    // Arm crash reporting FIRST — declared before any other stored property so
    // Swift's in-order initialization runs it before Sparkle starts (so an
    // early-launch crash is still captured). No-op if the user opted out or no DSN.
    private let crashBootstrap: Void = CrashReporting.bootstrap()

    // Firebase (P5 sync). SKIPPED for ephemeral launches: -gm-seed screenshot
    // runs, and CRITICALLY the emulator-test HOST (-gm-no-store) — configuring
    // the production app there would wedge configureForEmulator, whose
    // FirebaseApp.configure(options:) only runs when no app exists yet.
    private let firebaseBootstrap: Void = {
        if !SyncCoordinator.isEphemeralLaunch { FirebaseBootstrap.configureApp() }
    }()

    // Sparkle auto-update. Starts the updater; checks the appcast at SUFeedURL
    // (GitHub Releases) and verifies updates against SUPublicEDKey in Info.plist.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    @StateObject private var versionGate = VersionGate()
    @StateObject private var model = MergeModel()
    @StateObject private var auth = AuthController()
    @StateObject private var sync = SyncCoordinator()

    var body: some Scene {
        Window("Gainmap", id: "main") {
            MacRootView(model: model)
                .environmentObject(auth)
                .environmentObject(sync)
                .modifier(IntelUnsupportedNotice())
                .modifier(FirstRunCrashNotice())
                .modifier(VersionGateOverlay(gate: versionGate, updater: updaterController.updater))
                .task { await versionGate.check() }
                .task {
                    applicationDelegate.configure(model: model, sync: sync)
                    await sync.bind(model: model)
                    guard !SyncCoordinator.isEphemeralLaunch else { return }
                    auth.start()
                    await sync.retryPendingLocalAccountCleanup()
                }
                .task(id: auth.state) {
                    guard !SyncCoordinator.isEphemeralLaunch else { return }
                    let state = auth.state
                    await sync.apply(authState: state, model: model)
                }
                // Foreground revival: retry parked transfers and refresh the
                // server-owned Patreon entitlement. Transport failure retains
                // the last approved state for this running session.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    guard !SyncCoordinator.isEphemeralLaunch else { return }
                    Task { await sync.appBecameActive() }
                    Task { await sync.retryPendingLocalAccountCleanup() }
                    auth.refreshCloudAccess()
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") {
                    NotificationCenter.default.post(name: .gainmapNewSession, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Settings { SettingsView().environmentObject(auth).environmentObject(sync) }
    }
}

/// "Check for Updates…" menu item, enabled only when Sparkle can check.
struct CheckForUpdatesView: View {
    private let updater: SPUUpdater
    @State private var canCheck = false

    init(updater: SPUUpdater) { self.updater = updater }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!canCheck)
            .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}

// MARK: - Settings (Preferences ⌘,)

struct SettingsView: View {
    @AppStorage(CrashReporting.defaultsKey) private var crashReporting = true
    @EnvironmentObject private var auth: AuthController
    @EnvironmentObject private var sync: SyncCoordinator
    @State private var deleteAccountConfirmationPresented = false
    @State private var deletingAccount = false
    @State private var deletionError: String?

    var body: some View {
        Form {
            Section {
                switch auth.state {
                case .signedOut, .failed:
                    HStack(spacing: 10) {
                        Button("Sign in with Apple…") { auth.appleWebSignIn() }
                        Button("Sign in with Google…") { auth.googleWebSignIn() }
                    }
                    Text("Gainmap works without an account. An arbitrary email address cannot unlock "
                         + "Cloud Sync. A verified email matching an active patron may receive "
                         + "temporary access; connecting Patreon confirms membership.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .failed(let message) = auth.state {
                        Text(message).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .checking:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking Cloud Sync access…").foregroundStyle(.secondary)
                    }
                case .ready, .localOnly:
                    VStack(alignment: .leading, spacing: 3) {
                        Text(auth.email ?? "Signed in")
                            .fontWeight(.medium)
                        Text(cloudAccessMessage)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let expiry = auth.cloudAccess?.entitlement.graceExpiresAt {
                            Text("Grace access ends \(expiry.formatted(date: .abbreviated, time: .shortened)).")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    if shouldOfferPatreonConnection {
                        Button("Connect Patreon…") {
                            auth.connectPatreon()
                        }
                        .disabled(auth.isConnectingPatreon)
                    }
                    HStack(spacing: 10) {
                        Button("Check Access Again") { auth.refreshCloudAccess() }
                            .disabled(auth.isRefreshingCloudAccess || auth.isConnectingPatreon)
                        Button("Sign out of Cloud Sync", role: .destructive) { auth.signOut() }
                    }
                    Button("Delete Account…", role: .destructive) {
                        deleteAccountConfirmationPresented = true
                    }
                    .disabled(deletingAccount || auth.isConnectingPatreon)
                    if deletingAccount {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Deleting account and cloud library…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let error = auth.cloudActionError {
                        Text(error).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Cloud deletion changes auth state to signed out, so this
                // warning must live outside the signed-in switch to remain
                // visible when best-effort local cleanup needs a retry.
                if let deletionError {
                    Text(deletionError).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Sync")
            }
            Section {
                Toggle("Send anonymous crash reports", isOn: $crashReporting)
                // Scoped to crash reports on purpose (P4): sync — when you
                // sign in — uploads your photos to your private library, so a
                // blanket "no photos are ever sent" would be untrue. Crash
                // reports never include them.
                Text("Helps fix bugs. Crash reports never include your photos, "
                     + "file names, or IP address. Takes effect on next launch.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
        // Width fixed, height fits the current auth state — a hard-coded
        // height left a scrollbar in one state and dead space in another.
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog(
            "Delete your Gainmap account?",
            isPresented: $deleteAccountConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account, synced sessions, private cloud photos, and this Mac's local copies for that account. Your signed-out local library and exported images remain.")
        }
    }

    private var cloudAccessMessage: String {
        guard let access = auth.cloudAccess else {
            return "Cloud Sync access has not been checked yet."
        }
        if let message = access.admissionBlockMessage {
            return message + " The local app remains fully available."
        }
        if access.canSync {
            return access.entitlement.status == .grace
                ? access.entitlement.message
                : (sync.syncing
                   ? "Patreon active — sessions follow you to your iPhone."
                   : "Patreon active — Cloud Sync is starting…")
        }
        return access.entitlement.message
    }

    private var shouldOfferPatreonConnection: Bool {
        guard let entitlement = auth.cloudAccess?.entitlement else { return true }
        return entitlement.linkRequired
    }

    @MainActor
    private func deleteAccount() async {
        deletionError = nil
        deletingAccount = true
        defer { deletingAccount = false }
        do {
            let uid = try await auth.deleteAccountOnMac()
            var cleanupError: Error?
            do {
                try await sync.purgeLocalAccountData(uid: uid)
                AuthController.completePendingLocalCleanup(uid: uid)
            } catch {
                cleanupError = error
                AuthController.recordPendingLocalCleanup(uid: uid)
            }
            auth.finishAccountDeletion(uid: uid)
            if cleanupError != nil {
                deletionError = "Your cloud account was deleted, but Gainmap couldn't remove every local copy from this Mac. It will retry automatically next launch. You can also remove Gainmap's data in Library/Application Support/Gainmap."
            }
        } catch AccountDeletionError.cancelled {
            return
        } catch {
            deletionError = error.localizedDescription
        }
    }
}

// MARK: - Intel notice

/// uhdrtool ships arm64-only, so on an Intel Mac every merge would die with a
/// cryptic exit code. Say it plainly once at launch instead.
struct IntelUnsupportedNotice: ViewModifier {
    @State private var present = false
    func body(content: Content) -> some View {
        content
            .onAppear {
                #if arch(x86_64)
                present = true
                #endif
            }
            .alert("Apple Silicon required", isPresented: $present) {
                Button("OK") {}
            } message: {
                Text("Gainmap's HDR engine is built for Apple Silicon (M-series) Macs. "
                     + "On this Intel Mac, merges will not work.")
            }
    }
}

// MARK: - First-run crash-reporting notice

/// A one-time, non-blocking notice that crash reporting is on (with how to opt out).
struct FirstRunCrashNotice: ViewModifier {
    @AppStorage("gainmap.crashNoticeShown") private var shown = false
    @State private var present = false

    func body(content: Content) -> some View {
        content
            .onAppear { if !shown { present = true } }
            .alert("Anonymous crash reports", isPresented: $present) {
                Button("OK") { shown = true }
            } message: {
                Text("Gainmap sends anonymous crash reports to help fix bugs — they never "
                     + "include photos, file names, or your IP address. You can turn this "
                     + "off in Settings (⌘,).")
            }
    }
}

// MARK: - Version gate (blocking "please update" overlay)

/// Non-dismissible overlay shown when the remote gate marks this build too old.
/// Always offers a working path forward (Update Now via Sparkle + a download link).
struct VersionGateOverlay: ViewModifier {
    @ObservedObject var gate: VersionGate
    let updater: SPUUpdater

    func body(content: Content) -> some View {
        content.overlay {
            if gate.blocked {
                ZStack {
                    Rectangle().fill(.black.opacity(0.94)).ignoresSafeArea()
                    VStack(spacing: 18) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(Theme.warn)
                        Text("Update required")
                            .font(Theme.mono(17, .semibold)).foregroundStyle(.white)
                        Text(gate.message)
                            .font(Theme.mono(12)).foregroundStyle(Theme.stone)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Button("Update Now") { updater.checkForUpdates() }
                                .keyboardShortcut(.defaultAction)
                            Link("Download", destination: gate.downloadURL)
                                .font(Theme.mono(12))
                        }
                        .padding(.top, 4)
                    }
                    .padding(44)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: gate.blocked)
    }
}
