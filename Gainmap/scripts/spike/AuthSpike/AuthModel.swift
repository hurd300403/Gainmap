//  S3 auth spike — the logic under test:
//   * Sign in with Apple -> Firebase (nonce flow), REAL App IDs
//   * Google Sign-In -> Firebase, both platforms
//   * keychain persistence across relaunch (the -34018 failure mode on a
//     notarized Developer ID Mac build is the #1 risk this spike exists for)
//   * catch-and-link skeleton: accountExistsWithDifferentCredential ->
//     pending credential -> sign in with existing provider -> link
//   * App Check: DCAppAttestService.isSupported, recorded empirically
import SwiftUI
import CryptoKit
import AuthenticationServices
import DeviceCheck
import FirebaseCore
import FirebaseAuth
import GoogleSignIn

final class AuthModel: ObservableObject {
    @Published var lines: [String] = []
    @Published var uid: String?
    @Published var providers: [String] = []
    @Published var email: String?
    @Published var pendingLinkHint: String?

    private var pendingCredential: AuthCredential?
    var currentNonce: String?

    // MARK: lifecycle

    func start() {
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        let u = Auth.auth().currentUser
        refresh()
        if let u {
            say("LAUNCH/persisted: uid \(u.uid) [\(u.providerData.map(\.providerID).joined(separator: ","))]")
        } else {
            say("LAUNCH/persisted: NONE (fresh install, signed out, or keychain failure -34018)")
        }
        let supported = DCAppAttestService.shared.isSupported
        say("APPCHECK/DCAppAttestService.isSupported = \(supported)")
    }

    private func refresh() {
        let u = Auth.auth().currentUser
        uid = u?.uid
        email = u?.email
        providers = u?.providerData.map(\.providerID) ?? []
    }

    func say(_ s: String) {
        DispatchQueue.main.async {
            self.lines.append(s)
            print("SPIKE: \(s)")
        }
    }

    // MARK: Sign in with Apple — macOS web flow
    // Developer ID distribution does NOT support the applesignin entitlement
    // (S3 finding), so the Mac goes through Firebase's browser-based OAuth flow.

    // FirebaseAuth's own web flow is `#if os(iOS)`-gated (SDK finding), so the
    // Mac needs a hand-rolled ASWebAuthenticationSession against appleid.apple.com,
    // then OAuthProvider.credential(withProviderID:idToken:rawNonce:) — which IS
    // cross-platform. That flow requires a Services ID in the Apple portal;
    // stubbed until it exists.
    #if os(macOS)
    func appleWebSignIn() {
        say("APPLE/web flow not yet wired — needs the Services ID + return-URL portal setup.")
    }
    #endif

    // MARK: Sign in with Apple — native nonce flow (iOS)

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.email, .fullName]
        request.nonce = SHA256.hash(data: Data(nonce.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let err):
            say("APPLE/authorization failed: \(err.localizedDescription)")
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let token = String(data: tokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                say("APPLE/missing identity token or nonce")
                return
            }
            say("APPLE/authorized sub \(String(cred.user.prefix(12)))… email \(cred.email ?? "hidden/relay")")
            let fbCred = OAuthProvider.appleCredential(
                withIDToken: token, rawNonce: nonce, fullName: cred.fullName)
            signIn(with: fbCred, label: "APPLE")
        }
    }

    // MARK: Google

    #if os(macOS)
    func googleSignIn(presenting window: NSWindow) {
        GIDSignIn.sharedInstance.signIn(withPresenting: window) { [weak self] result, error in
            self?.handleGoogle(result: result, error: error)
        }
    }
    #else
    func googleSignIn(presenting vc: UIViewController) {
        GIDSignIn.sharedInstance.signIn(withPresenting: vc) { [weak self] result, error in
            self?.handleGoogle(result: result, error: error)
        }
    }
    #endif

    private func handleGoogle(result: GIDSignInResult?, error: Error?) {
        if let error {
            say("GOOGLE/sign-in failed: \(error.localizedDescription)")
            return
        }
        guard let gUser = result?.user, let idToken = gUser.idToken?.tokenString else {
            say("GOOGLE/no idToken")
            return
        }
        say("GOOGLE/authorized \(gUser.profile?.email ?? "?")")
        let fbCred = GoogleAuthProvider.credential(
            withIDToken: idToken, accessToken: gUser.accessToken.tokenString)
        signIn(with: fbCred, label: "GOOGLE")
    }

    // MARK: Firebase sign-in + catch-and-link skeleton

    private func signIn(with credential: AuthCredential, label: String) {
        Auth.auth().signIn(with: credential) { [weak self] result, error in
            guard let self else { return }
            if let error = error as NSError? {
                if error.code == AuthErrorCode.accountExistsWithDifferentCredential.rawValue {
                    // The recovery path the plan requires us to reach.
                    self.pendingCredential =
                        error.userInfo[AuthErrorUserInfoUpdatedCredentialKey] as? AuthCredential
                    let mail = error.userInfo[AuthErrorUserInfoEmailKey] as? String ?? "this email"
                    DispatchQueue.main.async {
                        self.pendingLinkHint =
                            "\(mail) already has an account with a different provider. " +
                            "Sign in with the other provider; I will then LINK this one."
                    }
                    self.say("\(label)/CATCH-AND-LINK: accountExistsWithDifferentCredential — pending credential stashed")
                    return
                }
                self.say("\(label)/Firebase sign-in failed: [\(error.code)] \(error.localizedDescription)")
                return
            }
            guard let user = result?.user else { return }
            self.say("\(label)/Firebase uid \(user.uid) [\(user.providerData.map(\.providerID).joined(separator: ","))]")

            if let pending = self.pendingCredential {
                self.pendingCredential = nil
                user.link(with: pending) { linkResult, linkError in
                    if let linkError {
                        self.say("LINK/failed: \(linkError.localizedDescription)")
                    } else if let lu = linkResult?.user {
                        self.say("LINK/success: uid \(lu.uid) now [\(lu.providerData.map(\.providerID).joined(separator: ","))]")
                    }
                    DispatchQueue.main.async { self.pendingLinkHint = nil; self.refresh() }
                }
            }
            DispatchQueue.main.async { self.refresh() }
        }
    }

    func signOut() {
        do {
            GIDSignIn.sharedInstance.signOut()
            try Auth.auth().signOut()
            say("SIGNED OUT")
        } catch {
            say("sign-out failed: \(error.localizedDescription)")
        }
        refresh()
    }

    // MARK: helpers

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { charset[Int($0) % charset.count] })
    }
}
