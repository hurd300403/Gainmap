//
//  GainmapApp.swift
//  Gainmap — a Legacy Lab instrument.
//
//  Fuses a Lightroom SDR edit + its HDR edit into one UltraHDR (ISO 21496-1)
//  gain-map JPEG, by driving the bundled `uhdrtool` (libultrahdr) helper.
//

import SwiftUI
import Combine
import Sparkle

@main
struct GainmapApp: App {
    // Sparkle auto-update. Starts the updater; checks the appcast at SUFeedURL
    // (GitHub Releases) and verifies updates against SUPublicEDKey in Info.plist.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        Window("Gainmap", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}  // single-window app
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
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
