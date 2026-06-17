//
//  GainmapApp.swift
//  Gainmap — a Legacy Lab instrument.
//
//  Fuses a Lightroom SDR edit + its HDR edit into one UltraHDR (ISO 21496-1)
//  gain-map JPEG, by driving the bundled `uhdrtool` (libultrahdr) helper.
//

import SwiftUI

@main
struct GainmapApp: App {
    var body: some Scene {
        Window("Gainmap", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}  // single-window app
        }
    }
}
