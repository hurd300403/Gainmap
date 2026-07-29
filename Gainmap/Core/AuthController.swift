//
//  AuthController.swift
//  GainmapCore
//
//  P5: production port of the S3 auth spike. Sign in with Apple (native on
//  iOS; the Mac uses the S3 web flow via the appleReturn Cloud Function) +
//  Google Sign-In, one-account-per-email with catch-and-link, and the sync
//  ADMISSION step (admitSyncUser callable: signup cap + waitlist).
//
//  Lives in Core because Firebase links statically INTO GainmapCore — app
//  targets never import Firebase/GoogleSignIn directly; they observe this
//  controller and call its intents.
//

import Foundation
import SwiftUI
import CryptoKit
import AuthenticationServices
import FirebaseCore
import FirebaseAuth
import FirebaseFunctions
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - App bootstrap (the pieces an app target can't do itself)

public enum FirebaseBootstrap {
    /// Configure the production Firebase app from the bundled
    /// GoogleService-Info.plist.
    public static func configureApp() {
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
    }

    /// FirebaseAuth's OAuth web flow round-trips land here (onOpenURL).
    @discardableResult
    public static func handleOpenURL(_ url: URL) -> Bool {
        #if canImport(UIKit)
        return Auth.auth().canHandle(url)
        #else
        return false
        #endif
    }
}

// MARK: - Auth state

/// What the UI renders. `.ready` is the only state the sync engine runs in.
public enum AuthState: Equatable, Sendable {
    case signedOut
    /// Signed in to Firebase; admitSyncUser is in flight.
    case admitting(uid: String)
    /// Admitted: sync runs.
    case ready(uid: String)
    /// Signed in but the signup cap is reached — the app works fully offline.
    case waitlisted(uid: String)
    case failed(String)
}

// MARK: - Controller

@MainActor
public final class AuthController: ObservableObject {

    @Published public private(set) var state: AuthState = .signedOut
    @Published public private(set) var email: String?
    @Published public private(set) var providers: [String] = []
    /// Cross-provider collision: "sign in with your other provider, then we
    /// link this one" (S3 catch-and-link).
    @Published public private(set) var linkHint: String?
    /// Non-nil when the last admission attempt FAILED (offline, cold start,
    /// callable error) rather than genuinely waitlisting — the UI must not
    /// claim "sync is full" over a network blip (P5 review).
    @Published public private(set) var admissionError: String?

    private var pendingCredential: AuthCredential?
    private var currentNonce: String?

    public init() {}

    /// Call once at launch (after FirebaseBootstrap.configureApp()).
    public func start() {
        if let user = Auth.auth().currentUser {
            adoptSignedIn(user)
        } else {
            state = .signedOut
        }
    }

    public var uid: String? {
        switch state {
        case .ready(let uid), .waitlisted(let uid), .admitting(let uid): return uid
        case .signedOut, .failed: return nil
        }
    }

    // ------------------------------------------------- Sign in with Apple (iOS)

    /// Wire to SwiftUI's SignInWithAppleButton(onRequest:).
    public func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.email, .fullName]
        request.nonce = SHA256.hash(data: Data(nonce.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Wire to SignInWithAppleButton(onCompletion:).
    public func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            let ns = error as NSError
            // User-cancelled is not an error state.
            if ns.domain == ASAuthorizationError.errorDomain,
               ns.code == ASAuthorizationError.canceled.rawValue { return }
            state = .failed(error.localizedDescription)
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let token = String(data: tokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                state = .failed("Apple sign-in returned no identity token.")
                return
            }
            let fbCred = OAuthProvider.appleCredential(
                withIDToken: token, rawNonce: nonce, fullName: cred.fullName)
            signIn(with: fbCred)
        }
    }

    // ------------------------------------------------- Google
    // Via FirebaseAuth's generic OAuth web flow — deliberately NOT the
    // GoogleSignIn SDK, whose fetcher pin is incompatible with Firebase 12
    // (see project.yml). Same one-uid outcome; web-sheet UX.

    #if canImport(UIKit)
    private var googleProvider: OAuthProvider?

    public func googleSignIn() {
        let provider = OAuthProvider(providerID: "google.com")
        provider.scopes = ["email", "profile"]
        googleProvider = provider   // keep alive for the flow's duration
        provider.getCredentialWith(nil) { [weak self] credential, error in
            Task { @MainActor in
                guard let self else { return }
                self.googleProvider = nil
                if let error {
                    let ns = error as NSError
                    // User-cancelled web sheet is not an error state.
                    if ns.code == AuthErrorCode.webContextCancelled.rawValue { return }
                    self.state = .failed(error.localizedDescription)
                    return
                }
                guard let credential else { return }
                self.signIn(with: credential)
            }
        }
    }
    #endif

    // ------------------------------------------------- Firebase + catch-and-link

    private func signIn(with credential: AuthCredential) {
        Auth.auth().signIn(with: credential) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let error = error as NSError? {
                    if error.code == AuthErrorCode.accountExistsWithDifferentCredential.rawValue {
                        // One-account-per-email: stash this credential, ask
                        // for the other provider, LINK after that succeeds.
                        self.pendingCredential =
                            error.userInfo[AuthErrorUserInfoUpdatedCredentialKey] as? AuthCredential
                        let mail = error.userInfo[AuthErrorUserInfoEmailKey] as? String ?? "This email"
                        self.linkHint =
                            "\(mail) already has a Gainmap account with a different sign-in method. "
                            + "Sign in with the one you used before — I'll connect this one to it."
                        return
                    }
                    self.state = .failed(error.localizedDescription)
                    return
                }
                guard let user = result?.user else { return }
                if let pending = self.pendingCredential {
                    self.pendingCredential = nil
                    self.linkHint = nil
                    user.link(with: pending) { _, _ in
                        // Link failure is non-fatal (the account works; the
                        // second provider just isn't attached).
                        Task { @MainActor in self.adoptSignedIn(user) }
                    }
                } else {
                    self.adoptSignedIn(user)
                }
            }
        }
    }

    private func adoptSignedIn(_ user: User) {
        email = user.email
        providers = user.providerData.map(\.providerID)
        linkHint = nil
        state = .admitting(uid: user.uid)
        Task { await requestAdmission(uid: user.uid) }
    }

    // ------------------------------------------------- admission (signup cap)

    /// admitSyncUser is idempotent: it provisions users/{uid} within the cap
    /// or reports the waitlist. The app is FULLY usable either way — only
    /// sync is gated.
    /// Once admitSyncUser has said yes for a uid, admission is durable
    /// server-side — remember it so a transient failure on a later launch
    /// can't downgrade a synced user to "waitlisted" (which nils the engine
    /// and silently stops journaling edits; P5 review, critical).
    private static func admittedKey(_ uid: String) -> String { "gm-admitted-\(uid)" }

    private func requestAdmission(uid: String) async {
        do {
            let result = try await Functions.functions(region: "us-central1")
                .httpsCallable("admitSyncUser").call([:])
            let data = result.data as? [String: Any]
            let admitted = (data?["admitted"] as? Bool)
                ?? (data?["syncAdmitted"] as? Bool)
                ?? ((data?["status"] as? String) == "admitted")
            admissionError = nil
            if admitted { UserDefaults.standard.set(true, forKey: Self.admittedKey(uid)) }
            state = admitted ? .ready(uid: uid) : .waitlisted(uid: uid)
        } catch {
            if UserDefaults.standard.bool(forKey: Self.admittedKey(uid)) {
                // Already admitted on a previous launch: run sync anyway.
                // Firestore is offline-tolerant; the check was a formality.
                admissionError = nil
                state = .ready(uid: uid)
            } else {
                // Never admitted + unreachable: stay usable locally, tell the
                // truth about why, retry on foreground/Re-check.
                admissionError = "Couldn't reach sync — check your connection."
                state = .waitlisted(uid: uid)
            }
        }
    }

    /// Waitlist screens call this to re-check (a spot may have opened).
    public func retryAdmission() {
        guard let uid else { return }
        state = .admitting(uid: uid)
        Task { await requestAdmission(uid: uid) }
    }

    // ------------------------------------------------- Sign in with Apple (Mac)
    // Developer ID distribution does not support the applesignin entitlement
    // (S3 finding), so the Mac runs Apple's browser OAuth flow: form_post to
    // the appleReturn Cloud Function (Hosting rewrite), which bounces the
    // fields to gainmapauth://callback where ASWebAuthenticationSession picks
    // them up. Ported verbatim from the S3 spike (proved on a notarized build).
    #if os(macOS)
    private static let servicesID = "com.legacylab.gainmap.auth"
    private static let returnHost = "gainmap-production.firebaseapp.com"
    private static let returnPath = "/auth/apple-return/"
    private static let callbackScheme = "gainmapauth"

    private let webPresenter = WebAuthPresenter()
    private var webSession: ASWebAuthenticationSession?
    private var webState: String?

    public func appleWebSignIn() {
        let rawNonce = Self.randomNonce()
        currentNonce = rawNonce
        let hashedNonce = SHA256.hash(data: Data(rawNonce.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let state = Self.randomNonce(length: 16)
        webState = state

        var c = URLComponents(string: "https://appleid.apple.com/auth/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: Self.servicesID),
            .init(name: "redirect_uri", value: "https://\(Self.returnHost)\(Self.returnPath)"),
            .init(name: "response_type", value: "code id_token"),
            .init(name: "response_mode", value: "form_post"),  // required once scopes are requested
            .init(name: "scope", value: "name email"),
            .init(name: "state", value: state),
            .init(name: "nonce", value: hashedNonce),
        ]
        let session = ASWebAuthenticationSession(
            url: c.url!,
            callbackURLScheme: Self.callbackScheme
        ) { [weak self] url, error in
            Task { @MainActor in
                self?.handleAppleWebCallback(url: url, error: error, rawNonce: rawNonce)
            }
        }
        session.presentationContextProvider = webPresenter
        webSession = session
        session.start()
    }

    private func handleAppleWebCallback(url: URL?, error: Error?, rawNonce: String) {
        webSession = nil
        if let error {
            let ns = error as NSError
            if ns.domain == ASWebAuthenticationSessionError.errorDomain,
               ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue { return }
            state = .failed(error.localizedDescription)
            return
        }
        guard let url,
              let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment else {
            state = .failed("Apple sign-in returned no data.")
            return
        }
        var params: [String: String] = [:]
        for pair in fragment.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            params[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
        }
        guard params["state"] == webState else {
            state = .failed("Apple sign-in state mismatch — try again.")
            return
        }
        guard let idToken = params["id_token"] else {
            state = .failed("Apple sign-in returned no identity token.")
            return
        }
        let credential = OAuthProvider.appleCredential(
            withIDToken: idToken, rawNonce: rawNonce, fullName: nil)
        signIn(with: credential)
    }

    // ------------------------------------------------- Google (Mac)
    // FirebaseAuth's OAuthProvider web flow is iOS-only (S3 finding), so the
    // Mac hand-rolls Google's authorization-code + PKCE flow: ASWebAuth ->
    // accounts.google.com -> custom-scheme redirect (the plist's reversed
    // client ID) -> token exchange -> GoogleAuthProvider credential. No
    // client secret — Google's iOS-type OAuth clients use PKCE alone.
    public func googleWebSignIn() {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            state = .failed("Google sign-in is not configured.")
            return
        }
        // "NNN-xxx.apps.googleusercontent.com" -> "com.googleusercontent.apps.NNN-xxx"
        let reversed = clientID.split(separator: ".").reversed().joined(separator: ".")
        let redirectURI = "\(reversed):/oauth2redirect"

        let verifier = Self.randomNonce(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let state = Self.randomNonce(length: 16)
        webState = state

        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        let session = ASWebAuthenticationSession(
            url: c.url!,
            callbackURLScheme: String(reversed)
        ) { [weak self] url, error in
            Task { @MainActor in
                await self?.handleGoogleWebCallback(url: url, error: error,
                                                    clientID: clientID,
                                                    redirectURI: redirectURI,
                                                    verifier: verifier)
            }
        }
        session.presentationContextProvider = webPresenter
        webSession = session
        session.start()
    }

    private func handleGoogleWebCallback(url: URL?, error: Error?, clientID: String,
                                         redirectURI: String, verifier: String) async {
        webSession = nil
        if let error {
            let ns = error as NSError
            if ns.domain == ASWebAuthenticationSessionError.errorDomain,
               ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue { return }
            state = .failed(error.localizedDescription)
            return
        }
        guard let url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "state" })?.value == webState,
              let code = items.first(where: { $0.name == "code" })?.value else {
            state = .failed("Google sign-in returned no authorization code.")
            return
        }
        // Exchange the code for tokens (PKCE — no secret).
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
        ]
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idToken = json["id_token"] as? String else {
                state = .failed("Google sign-in token exchange failed.")
                return
            }
            let accessToken = json["access_token"] as? String ?? ""
            let credential = GoogleAuthProvider.credential(withIDToken: idToken,
                                                           accessToken: accessToken)
            signIn(with: credential)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
    #endif

    // ------------------------------------------------- sign-out

    public func signOut() {
        try? Auth.auth().signOut()
        email = nil
        providers = []
        linkHint = nil
        admissionError = nil
        state = .signedOut
    }

    // ------------------------------------------------- helpers

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { charset[Int($0) % charset.count] })
    }
}


#if os(macOS)
final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
#endif
