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
                    await sync.apply(authState: auth.state, model: model)
                }
                .onChange(of: auth.state) { _, state in
                    Task { await sync.apply(authState: state, model: model) }
                }
                // Foreground revival: parked transfers retry, pending drains
                // run, and a network-failure "waitlist" re-checks admission.
                // (Never wired before — parked uploads stayed parked until
                // relaunch; P5 review.)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    guard !SyncCoordinator.isEphemeralLaunch else { return }
                    Task { await sync.appBecameActive() }
                    if case .waitlisted = auth.state, auth.admissionError != nil {
                        auth.retryAdmission()
                    }
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

    var body: some View {
        Form {
            Section {
                switch auth.state {
                case .signedOut, .failed:
                    HStack(spacing: 10) {
                        Button("Sign in with Apple…") { auth.appleWebSignIn() }
                        Button("Sign in with Google…") { auth.googleWebSignIn() }
                    }
                    Text("Sessions and looks sync to your other devices. "
                         + "Photos upload to your private library only.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .failed(let message) = auth.state {
                        Text(message).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .admitting:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Setting up sync…").foregroundStyle(.secondary)
                    }
                case .ready:
                    VStack(alignment: .leading, spacing: 3) {
                        Text(auth.email ?? "Signed in")
                            .fontWeight(.medium)
                        Text(sync.syncing
                             ? "Sync is on — sessions follow you to your iPhone."
                             : "Sync is starting…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Sign out", role: .destructive) { auth.signOut() }
                case .waitlisted:
                    VStack(alignment: .leading, spacing: 3) {
                        Text(auth.email ?? "Signed in")
                            .fontWeight(.medium)
                        // A network failure is not a waitlist — say which it is.
                        Text(auth.admissionError.map {
                                 "\($0) Everything keeps working on this Mac."
                             }
                             ?? ("Sync is full right now — you're on the waitlist. "
                                 + "Everything keeps working on this Mac."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        Button("Re-check") { auth.retryAdmission() }
                        Button("Sign out", role: .destructive) { auth.signOut() }
                    }
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
