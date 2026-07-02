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
import Sparkle

@main
struct GainmapApp: App {
    // Arm crash reporting FIRST — declared before any other stored property so
    // Swift's in-order initialization runs it before Sparkle starts (so an
    // early-launch crash is still captured). No-op if the user opted out or no DSN.
    private let crashBootstrap: Void = CrashReporting.bootstrap()

    // Sparkle auto-update. Starts the updater; checks the appcast at SUFeedURL
    // (GitHub Releases) and verifies updates against SUPublicEDKey in Info.plist.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    @StateObject private var versionGate = VersionGate()

    var body: some Scene {
        Window("Gainmap", id: "main") {
            ContentView()
                .modifier(IntelUnsupportedNotice())
                .modifier(FirstRunCrashNotice())
                .modifier(VersionGateOverlay(gate: versionGate, updater: updaterController.updater))
                .task { await versionGate.check() }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}  // single-window app
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Settings { SettingsView() }
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

    var body: some View {
        Form {
            Section {
                Toggle("Send anonymous crash reports", isOn: $crashReporting)
                Text("Helps fix bugs. No photos, file names, or IP address are ever sent. "
                     + "Takes effect on next launch.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 160)
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
                Text("Gainmap sends anonymous crash reports — no photos, no file names, "
                     + "no IP address — to help fix bugs. You can turn this off in Settings (⌘,).")
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
