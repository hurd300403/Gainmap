//
//  GainmapIOSApp.swift
//  Gainmap for iPhone (P5)
//
//  The app shell: Firebase bootstrap, auth gate, session grid, editor.
//  Everything substantive lives in GainmapCore — this target is UI glue.
//

import SwiftUI
import UIKit
import GainmapCore

enum GainmapQuickAction: String {
    case newSession = "com.legacylab.gainmap.ios.quick-action.new-session"
    case continueLatest = "com.legacylab.gainmap.ios.quick-action.continue-latest"
}

@MainActor
final class GainmapSceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject {
    @Published private(set) var requestedQuickAction: GainmapQuickAction?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        request(connectionOptions.shortcutItem)
    }

    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        request(shortcutItem)
    }

    @discardableResult
    private func request(_ shortcutItem: UIApplicationShortcutItem?) -> Bool {
        guard let shortcutItem,
              let action = GainmapQuickAction(rawValue: shortcutItem.type) else {
            return false
        }
        requestedQuickAction = action
        return true
    }

    func consume(_ action: GainmapQuickAction) {
        guard requestedQuickAction == action else { return }
        requestedQuickAction = nil
    }

    func updateContinueLatestShortcut(hasSessions: Bool) {
        UIApplication.shared.shortcutItems = hasSessions ? [
            UIApplicationShortcutItem(
                type: GainmapQuickAction.continueLatest.rawValue,
                localizedTitle: "Continue Latest",
                localizedSubtitle: "Open your most recent session",
                icon: UIApplicationShortcutIcon(systemImageName: "clock.arrow.circlepath"),
                userInfo: nil)
        ] : []
    }
}

@MainActor
final class GainmapAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = GainmapSceneDelegate.self
        }
        return configuration
    }
}

@main
struct GainmapIOSApp: App {
    @UIApplicationDelegateAdaptor(GainmapAppDelegate.self) private var appDelegate
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
                    guard phase == .active else { return }
                    Task { await model.appBecameActive() }
                    // A "waitlist" caused by an unreachable network retries
                    // automatically on foreground — a real waitlist doesn't.
                    if case .waitlisted = auth.state, auth.admissionError != nil {
                        auth.retryAdmission()
                    }
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
