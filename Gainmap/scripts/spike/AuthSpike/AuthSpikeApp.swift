//  S3 auth spike UI — status header, the two sign-in buttons, running log.
import SwiftUI
import AuthenticationServices
import GoogleSignIn

@main
struct AuthSpikeApp: App {
    @StateObject private var model = AuthModel()

    var body: some Scene {
        WindowGroup {
            SpikeView()
                .environmentObject(model)
                .onAppear { model.start() }
                .onOpenURL { url in _ = GIDSignIn.sharedInstance.handle(url) }
        }
    }
}

struct SpikeView: View {
    @EnvironmentObject var model: AuthModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let uid = model.uid {
                    Text("uid: \(uid)").font(.system(.footnote, design: .monospaced)).bold()
                    Text("providers: \(model.providers.joined(separator: ", "))  email: \(model.email ?? "—")")
                        .font(.system(.footnote, design: .monospaced))
                } else {
                    Text("signed out").font(.headline)
                }
            }

            if let hint = model.pendingLinkHint {
                Text(hint).font(.footnote).foregroundStyle(.orange)
            }

            #if os(macOS)
            // Developer ID builds cannot carry the applesignin entitlement, so
            // the Mac uses Firebase's web flow instead of the native button.
            Button("Sign in with Apple (web flow)") { model.appleWebSignIn() }
            #else
            SignInWithAppleButton(.signIn) { request in
                model.prepareAppleRequest(request)
            } onCompletion: { result in
                model.handleAppleCompletion(result)
            }
            .frame(width: 240, height: 36)
            #endif

            Button("Sign in with Google") {
                #if os(macOS)
                if let window = NSApp.keyWindow ?? NSApp.windows.first {
                    model.googleSignIn(presenting: window)
                }
                #else
                if let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first,
                   let root = scene.keyWindow?.rootViewController {
                    model.googleSignIn(presenting: root)
                }
                #endif
            }

            Button("Sign out") { model.signOut() }

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            Text("Relaunch the app: the LAUNCH/persisted line is the keychain test.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 520, minHeight: 480)
    }
}
