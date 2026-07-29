//
//  GainmapIOSApp.swift
//  Gainmap for iPhone (P5)
//
//  The app shell: Firebase bootstrap, auth gate, session grid, editor.
//  Everything substantive lives in GainmapCore — this target is UI glue.
//

import SwiftUI
import GainmapCore

@main
struct GainmapIOSApp: App {
    @StateObject private var auth = AuthController()
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FirebaseBootstrap.configureApp()
        CrashReporting.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onOpenURL { FirebaseBootstrap.handleOpenURL($0) }
                .task { auth.start() }
                .onChange(of: auth.state) { _, state in
                    Task { await model.authStateChanged(state) }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.appBecameActive() } }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var auth: AuthController

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch auth.state {
            case .signedOut, .failed:
                SignInScreen()
            case .admitting, .ready, .waitlisted:
                SessionGridScreen()
            }
        }
    }
}
