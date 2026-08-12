//
//  AuthController.swift
//  GainmapCore
//
//  Sign in with Apple (native on iOS; browser OAuth on Mac) + Google Sign-In,
//  one-account-per-email with catch-and-link, and Patreon-gated Cloud Sync.
//  Authentication is optional: signed-out and non-entitled people retain the
//  complete local app. Only the sync engine depends on `AuthState.ready`.
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

    /// Retained for Firebase-managed callback compatibility. Gainmap's direct
    /// Google/Patreon ASWebAuthenticationSession callbacks are consumed by
    /// their active sessions before reaching the app lifecycle.
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

public enum PatreonEntitlementStatus: String, Equatable, Sendable {
    case active
    case grace
    case inactive
    case unlinked
    case error
}

public enum PatreonEntitlementSource: String, Equatable, Sendable {
    case none
    case patreonEmail = "patreon_email"
    case patreonOAuth = "patreon_oauth"
}

public enum PatreonConnectionAction: String, Equatable, Sendable {
    case none
    case connect
    case switchAccount = "switch"
}

public enum PatreonConnectionMode: Sendable {
    case reuseSession
    case switchAccount

    var attemptKind: String {
        switch self {
        case .reuseSession: return "reuse_session"
        case .switchAccount: return "switch_account"
        }
    }

    var prefersEphemeralBrowserSession: Bool {
        switch self {
        case .reuseSession: return false
        case .switchAccount: return true
        }
    }
}

/// Safe, displayable entitlement data returned by Gainmap's trusted backend.
/// Patreon tokens and membership payloads never enter the app.
public struct PatreonEntitlement: Equatable, Sendable {
    public let status: PatreonEntitlementStatus
    public let effective: Bool
    public let source: PatreonEntitlementSource
    public let connectionAction: PatreonConnectionAction
    /// Build-11 compatibility. New UI uses the explicit connectionAction.
    public let linkRequired: Bool
    public let graceExpiresAt: Date?
    public let lastVerifiedAt: Date?
    public let verificationExpiresAt: Date?
    public let message: String

    public init(status: PatreonEntitlementStatus, effective: Bool,
                source: PatreonEntitlementSource = .none,
                connectionAction: PatreonConnectionAction? = nil,
                linkRequired: Bool? = nil,
                graceExpiresAt: Date? = nil, lastVerifiedAt: Date? = nil,
                verificationExpiresAt: Date? = nil,
                message: String) {
        self.status = status
        self.effective = effective
        self.source = source
        let legacyLinkRequired = linkRequired ?? (status == .unlinked)
        self.connectionAction = connectionAction
            ?? (legacyLinkRequired ? .connect : .none)
        self.linkRequired = legacyLinkRequired
        self.graceExpiresAt = graceExpiresAt
        self.lastVerifiedAt = lastVerifiedAt
        self.verificationExpiresAt = verificationExpiresAt
        self.message = message
    }

    /// Firebase callable timestamps are Unix milliseconds. Keep parsing here
    /// deterministic and testable rather than spreading NSNumber casts across
    /// the UI and auth lifecycle.
    public init?(payload: [String: Any]) {
        guard let rawState = payload["state"] as? String,
              let status = PatreonEntitlementStatus(rawValue: rawState),
              let effective = Self.bool(payload["effective"]),
              let message = payload["message"] as? String else { return nil }
        self.status = status
        self.effective = effective
        self.source = (payload["source"] as? String)
            .flatMap(PatreonEntitlementSource.init(rawValue:)) ?? .none
        let legacyLinkRequired = Self.bool(payload["linkRequired"])
            ?? (status == .unlinked)
        self.connectionAction = (payload["connectionAction"] as? String)
            .flatMap(PatreonConnectionAction.init(rawValue:))
            ?? (legacyLinkRequired ? .connect : .none)
        self.linkRequired = legacyLinkRequired
        self.graceExpiresAt = Self.date(payload["graceExpiresAt"])
        self.lastVerifiedAt = Self.date(payload["lastVerifiedAt"])
        self.verificationExpiresAt = Self.date(payload["verificationExpiresAt"])
        self.message = message
    }

    public static let unavailable = PatreonEntitlement(
        status: .error,
        effective: false,
        message: "Cloud Sync couldn't verify Patreon right now. Your local library is unaffected.")

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        let milliseconds: Double?
        if let value = value as? NSNumber {
            milliseconds = value.doubleValue
        } else if let value = value as? Double {
            milliseconds = value
        } else if let value = value as? Int {
            milliseconds = Double(value)
        } else {
            milliseconds = nil
        }
        return milliseconds.map { Date(timeIntervalSince1970: $0 / 1_000) }
    }
}

public struct CloudSyncAccess: Equatable, Sendable {
    public let entitlement: PatreonEntitlement
    public let admitted: Bool
    /// Safe backend reason when entitlement is valid but provisioning did not
    /// complete (currently `waitlist` or `patreon_required`).
    public let admissionReason: String?

    public init(entitlement: PatreonEntitlement, admitted: Bool,
                admissionReason: String? = nil) {
        self.entitlement = entitlement
        self.admitted = admitted
        self.admissionReason = admissionReason
    }

    public var canSync: Bool { admitted && entitlement.effective }
    public var isWaitlisted: Bool {
        !admitted && entitlement.effective && admissionReason == "waitlist"
    }
    public var admissionBlockMessage: String? {
        guard !admitted, entitlement.effective else { return nil }
        if isWaitlisted {
            return "Your Patreon access is valid, but Cloud Sync is currently at capacity. You're on the waitlist."
        }
        return "Your Patreon access is valid, but Cloud Sync couldn't be provisioned yet. Try checking access again."
    }
}

/// Authentication and cloud-access lifecycle. `.ready` is the only state in
/// which the sync engine runs; every other state remains a full local app.
public enum AuthState: Equatable, Sendable {
    case signedOut
    /// Signed in to Firebase; Patreon entitlement/admission is in flight.
    case checking(uid: String)
    /// Authenticated, entitled, and admitted: sync runs.
    case ready(uid: String)
    /// Authenticated but Cloud Sync is unavailable; local features still work.
    case localOnly(uid: String)
    /// A provider sign-in failed. The local app still works.
    case failed(String)
}

public enum AccountDeletionError: LocalizedError, Sendable {
    case cancelled
    case notSignedIn
    case incompleteAppleCredential
    case serverRejected

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Account deletion was cancelled."
        case .notSignedIn:
            return "Sign in again before deleting your account."
        case .incompleteAppleCredential:
            return "Apple didn't return the information needed to delete this account. Try again."
        case .serverRejected:
            return "Gainmap couldn't confirm that the account was deleted. Try again."
        }
    }
}

// MARK: - Google OAuth + PKCE

/// Failures produced by Gainmap's installed-app Google OAuth flow. Provider
/// payloads are deliberately collapsed to a small, safe set before display.
enum GoogleOAuthError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case cancelled
    case superseded
    case browserUnavailable
    case invalidCallback
    case stateMismatch
    case provider(String)
    case tokenExchangeFailed
    case transport

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Google sign-in is not configured."
        case .cancelled, .superseded:
            return "Google sign-in was cancelled."
        case .browserUnavailable:
            return "Google sign-in couldn't open. Try again."
        case .invalidCallback, .stateMismatch:
            return "Google sign-in returned an invalid response. Try again."
        case .provider:
            return "Google couldn't complete sign-in. Try again."
        case .tokenExchangeFailed:
            return "Google sign-in token exchange failed. Try again."
        case .transport:
            return "Google sign-in couldn't finish. Check your connection and try again."
        }
    }
}

/// Immutable values for one Google browser round-trip. Keeping state, PKCE
/// verifier, redirect URI, and generation together prevents a later attempt
/// from mutating the values an earlier callback must validate against.
struct GoogleOAuthAttempt: Equatable, Sendable {
    let generation: UInt
    let clientID: String
    let callbackScheme: String
    let redirectURI: String
    let state: String
    let verifier: String
    let authorizationURL: URL
}

struct GoogleOAuthTokens: Equatable, Sendable {
    let idToken: String
    let accessToken: String
}

private struct GoogleFirebaseCredentialResult {
    let credential: AuthCredential
    let generation: UInt
}

/// Pure construction and validation for Google's installed-app authorization
/// code flow. The browser/session and Firebase handoff remain in AuthController.
enum GoogleOAuthPKCE {
    static let callbackPath = "/oauth2redirect"
    private static let authorizationEndpoint =
        URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint =
        URL(string: "https://oauth2.googleapis.com/token")!

    static func makeAttempt(clientID: String, state: String, verifier: String,
                            generation: UInt) throws -> GoogleOAuthAttempt {
        let callbackScheme = try callbackScheme(for: clientID)
        guard state.count >= 16,
              (43...128).contains(verifier.count),
              verifier.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn:
                    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                    .contains($0)
              }) else {
            throw GoogleOAuthError.invalidConfiguration
        }
        let redirectURI = "\(callbackScheme):\(callbackPath)"
        var components = URLComponents(
            url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: codeChallenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "prompt", value: "select_account"),
        ]
        guard let authorizationURL = components.url else {
            throw GoogleOAuthError.invalidConfiguration
        }
        return GoogleOAuthAttempt(
            generation: generation,
            clientID: clientID,
            callbackScheme: callbackScheme,
            redirectURI: redirectURI,
            state: state,
            verifier: verifier,
            authorizationURL: authorizationURL)
    }

    static func callbackScheme(for clientID: String) throws -> String {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.lowercased().hasSuffix(suffix),
              clientID.count > suffix.count else {
            throw GoogleOAuthError.invalidConfiguration
        }
        let prefix = String(clientID.dropLast(suffix.count))
        guard !prefix.isEmpty,
              prefix.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
                    .contains($0)
              }) else {
            throw GoogleOAuthError.invalidConfiguration
        }
        return "com.googleusercontent.apps.\(prefix)"
    }

    static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func authorizationCode(from callback: URL,
                                  for attempt: GoogleOAuthAttempt) throws -> String {
        guard callback.scheme?.lowercased() == attempt.callbackScheme.lowercased(),
              callback.host == nil,
              callback.user == nil,
              callback.password == nil,
              callback.port == nil,
              callback.path == callbackPath,
              let items = URLComponents(
                url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw GoogleOAuthError.invalidCallback
        }
        let states = items.filter { $0.name == "state" }.compactMap(\.value)
        guard states.count == 1, states[0] == attempt.state else {
            throw GoogleOAuthError.stateMismatch
        }
        let providerErrors = items.filter { $0.name == "error" }.compactMap(\.value)
        if let providerError = providerErrors.first {
            if providerError == "access_denied" { throw GoogleOAuthError.cancelled }
            throw GoogleOAuthError.provider(providerError)
        }
        let codes = items.filter { $0.name == "code" }.compactMap(\.value)
        guard codes.count == 1, !codes[0].isEmpty else {
            throw GoogleOAuthError.invalidCallback
        }
        return codes[0]
    }

    static func tokenRequest(code: String, for attempt: GoogleOAuthAttempt) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "code", value: code),
            .init(name: "client_id", value: attempt.clientID),
            .init(name: "redirect_uri", value: attempt.redirectURI),
            .init(name: "code_verifier", value: attempt.verifier),
            .init(name: "grant_type", value: "authorization_code"),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        return request
    }

    static func tokens(data: Data, statusCode: Int) throws -> GoogleOAuthTokens {
        guard (200..<300).contains(statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = json["id_token"] as? String,
              !idToken.isEmpty else {
            throw GoogleOAuthError.tokenExchangeFailed
        }
        return GoogleOAuthTokens(
            idToken: idToken,
            accessToken: json["access_token"] as? String ?? "")
    }
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
    @Published public private(set) var cloudAccess: CloudSyncAccess?
    @Published public private(set) var cloudActionError: String?
    @Published public private(set) var isRefreshingCloudAccess = false
    @Published public private(set) var isConnectingPatreon = false
    @Published public private(set) var shouldOfferPatreonAccountSwitch = false
    /// True only after Firebase's persisted user has been inspected at launch.
    /// Empty-library onboarding must not count the controller's initial
    /// placeholder `.signedOut` value as a real signed-out launch.
    @Published public private(set) var hasRestoredAuthState = false

    private var pendingCredential: AuthCredential?
    private var currentNonce: String?
    private var accountDeletionNonce: String?
    private var cloudAccessGeneration: UInt = 0
    /// Separately invalidates in-flight OAuth-start requests and web callbacks.
    /// A cloud-access generation alone is not enough: a newly signed-in user
    /// can begin a second Patreon flow before the old callable returns.
    private var patreonConnectionGeneration: UInt = 0
    private static let callbackScheme = "gainmapauth"
    private static let pendingLocalCleanupKey =
        "gainmap.pending-account-local-cleanup-uids"
    private let patreonWebPresenter = WebAuthPresenter()
    private var patreonWebSession: ASWebAuthenticationSession?
    private let googleWebPresenter = WebAuthPresenter()
    private var googleWebSession: ASWebAuthenticationSession?
    private var googleWebContinuation: CheckedContinuation<URL, any Error>?
    private var googleOAuthGeneration: UInt = 0
    private var activeGoogleOAuthGeneration: UInt?
    #if os(macOS)
    private static let servicesID = "com.legacylab.gainmap.auth"
    private static let returnHost = "gainmap-production.firebaseapp.com"
    private static let returnPath = "/auth/apple-return/"
    private let webPresenter = WebAuthPresenter()
    private var accountDeletionWebSession: ASWebAuthenticationSession?
    private var accountDeletionWebContinuation:
        CheckedContinuation<URL, any Error>?
    #endif

    public init() {}

    /// Call once at launch (after FirebaseBootstrap.configureApp()).
    public func start() {
        if let user = Auth.auth().currentUser {
            adoptSignedIn(user)
        } else {
            state = .signedOut
        }
        hasRestoredAuthState = true
    }

    public var uid: String? {
        switch state {
        case .ready(let uid), .localOnly(let uid), .checking(let uid): return uid
        case .signedOut, .failed: return nil
        }
    }

    public var canSync: Bool {
        guard case .ready = state else { return false }
        return cloudAccess?.canSync == true
    }

    /// Durable retry queue for the narrow case where the cloud identity was
    /// deleted successfully but filesystem cleanup failed afterward.
    public static var pendingLocalCleanupUIDs: [String] {
        UserDefaults.standard.stringArray(forKey: pendingLocalCleanupKey) ?? []
    }

    public static func recordPendingLocalCleanup(uid: String) {
        var pending = pendingLocalCleanupUIDs
        guard !pending.contains(uid) else { return }
        pending.append(uid)
        UserDefaults.standard.set(pending, forKey: pendingLocalCleanupKey)
    }

    public static func completePendingLocalCleanup(uid: String) {
        let pending = pendingLocalCleanupUIDs.filter { $0 != uid }
        if pending.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingLocalCleanupKey)
        } else {
            UserDefaults.standard.set(pending, forKey: pendingLocalCleanupKey)
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
    // Both platforms use Google's installed-app authorization-code + PKCE
    // flow. Firebase's hosted iOS OAuthProvider flow depends on browser
    // sessionStorage and can fail under Safari storage partitioning.

    public func googleSignIn() {
        startGoogleSignIn()
    }

    #if os(macOS)
    /// Retains the existing Mac-facing API while sharing the implementation
    /// with iOS.
    public func googleWebSignIn() {
        startGoogleSignIn()
    }
    #endif

    private func startGoogleSignIn() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let attempt: GoogleOAuthAttempt
            do {
                attempt = try self.beginGoogleOAuthAttempt()
            } catch GoogleOAuthError.superseded {
                return
            } catch let error as GoogleOAuthError {
                self.state = .failed(error.localizedDescription)
                return
            } catch {
                self.state = .failed(
                    GoogleOAuthError.invalidConfiguration.localizedDescription)
                return
            }
            do {
                let result = try await self.googleFirebaseCredential(for: attempt)
                guard self.googleOAuthGeneration == result.generation else {
                    self.completeGoogleOAuthAttempt(generation: attempt.generation)
                    return
                }
                self.signIn(
                    with: result.credential,
                    googleGeneration: result.generation)
            } catch GoogleOAuthError.cancelled {
                // Closing the browser is not an app error and must not replace
                // the current local/auth state.
                self.completeGoogleOAuthAttempt(generation: attempt.generation)
            } catch GoogleOAuthError.superseded {
                // Closing the browser or starting a newer attempt is not an app
                // error and must not replace the current local/auth state.
                self.completeGoogleOAuthAttempt(generation: attempt.generation)
            } catch let error as GoogleOAuthError {
                self.completeGoogleOAuthAttempt(generation: attempt.generation)
                self.state = .failed(error.localizedDescription)
            } catch {
                self.completeGoogleOAuthAttempt(generation: attempt.generation)
                self.state = .failed(
                    GoogleOAuthError.transport.localizedDescription)
            }
        }
    }

    private func googleFirebaseCredential(for attempt: GoogleOAuthAttempt) async throws
        -> GoogleFirebaseCredentialResult {
        let callback = try await runGoogleWebSession(for: attempt)
        try requireCurrentGoogleAttempt(attempt)
        let code = try GoogleOAuthPKCE.authorizationCode(
            from: callback, for: attempt)
        try requireCurrentGoogleAttempt(attempt)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(
                for: GoogleOAuthPKCE.tokenRequest(code: code, for: attempt))
        } catch {
            if googleOAuthGeneration != attempt.generation {
                throw GoogleOAuthError.superseded
            }
            throw GoogleOAuthError.transport
        }
        try requireCurrentGoogleAttempt(attempt)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleOAuthError.tokenExchangeFailed
        }
        let tokens = try GoogleOAuthPKCE.tokens(
            data: data, statusCode: http.statusCode)
        try requireCurrentGoogleAttempt(attempt)
        return GoogleFirebaseCredentialResult(
            credential: GoogleAuthProvider.credential(
                withIDToken: tokens.idToken,
                accessToken: tokens.accessToken),
            generation: attempt.generation)
    }

    private func beginGoogleOAuthAttempt() throws -> GoogleOAuthAttempt {
        guard activeGoogleOAuthGeneration == nil else {
            throw GoogleOAuthError.superseded
        }
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw GoogleOAuthError.invalidConfiguration
        }
        let nextGeneration = googleOAuthGeneration &+ 1
        let attempt = try GoogleOAuthPKCE.makeAttempt(
            clientID: clientID,
            state: Self.randomNonce(),
            verifier: Self.randomNonce(length: 64),
            generation: nextGeneration)

        googleOAuthGeneration = nextGeneration
        activeGoogleOAuthGeneration = nextGeneration
        return attempt
    }

    private func runGoogleWebSession(for attempt: GoogleOAuthAttempt) async throws -> URL {
        try requireCurrentGoogleAttempt(attempt)
        return try await withCheckedThrowingContinuation { continuation in
            guard googleOAuthGeneration == attempt.generation else {
                continuation.resume(throwing: GoogleOAuthError.superseded)
                return
            }
            googleWebContinuation = continuation
            let session = ASWebAuthenticationSession(
                url: attempt.authorizationURL,
                callbackURLScheme: attempt.callbackScheme
            ) { [weak self] callback, error in
                Task { @MainActor in
                    self?.finishGoogleWebSession(
                        callback: callback,
                        error: error,
                        generation: attempt.generation)
                }
            }
            session.presentationContextProvider = googleWebPresenter
            // Keep browser accounts so `prompt=select_account` can show the
            // user's existing Google identities instead of forcing re-entry.
            session.prefersEphemeralWebBrowserSession = false
            googleWebSession = session
            guard session.start() else {
                googleWebContinuation = nil
                googleWebSession = nil
                continuation.resume(throwing: GoogleOAuthError.browserUnavailable)
                return
            }
        }
    }

    private func finishGoogleWebSession(callback: URL?, error: Error?,
                                        generation: UInt) {
        guard googleOAuthGeneration == generation,
              let continuation = googleWebContinuation else { return }
        googleWebContinuation = nil
        googleWebSession = nil
        if let error {
            let ns = error as NSError
            if ns.domain == ASWebAuthenticationSessionError.errorDomain,
               ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                continuation.resume(throwing: GoogleOAuthError.cancelled)
            } else {
                continuation.resume(throwing: GoogleOAuthError.transport)
            }
        } else if let callback {
            continuation.resume(returning: callback)
        } else {
            continuation.resume(throwing: GoogleOAuthError.invalidCallback)
        }
    }

    private func requireCurrentGoogleAttempt(_ attempt: GoogleOAuthAttempt) throws {
        guard googleOAuthGeneration == attempt.generation else {
            throw GoogleOAuthError.superseded
        }
    }

    private func cancelActiveGoogleWebSession(throwing error: GoogleOAuthError) {
        let continuation = googleWebContinuation
        let session = googleWebSession
        googleWebContinuation = nil
        googleWebSession = nil
        session?.cancel()
        continuation?.resume(throwing: error)
    }

    private func invalidateGoogleOAuth() {
        googleOAuthGeneration &+= 1
        cancelActiveGoogleWebSession(throwing: GoogleOAuthError.superseded)
    }

    private func completeGoogleOAuthAttempt(generation: UInt) {
        guard activeGoogleOAuthGeneration == generation else { return }
        activeGoogleOAuthGeneration = nil
        googleWebContinuation = nil
        googleWebSession = nil
    }

    private func reauthenticateGoogle(user: User) async throws {
        let expectedUID = user.uid
        let attempt: GoogleOAuthAttempt
        do {
            attempt = try beginGoogleOAuthAttempt()
        } catch GoogleOAuthError.superseded {
            throw AccountDeletionError.cancelled
        }
        defer { completeGoogleOAuthAttempt(generation: attempt.generation) }
        do {
            let result = try await googleFirebaseCredential(for: attempt)
            guard googleOAuthGeneration == result.generation,
                  Auth.auth().currentUser?.uid == expectedUID else {
                throw GoogleOAuthError.superseded
            }
            _ = try await user.reauthenticate(with: result.credential)
            guard googleOAuthGeneration == result.generation,
                  Auth.auth().currentUser?.uid == expectedUID else {
                throw GoogleOAuthError.superseded
            }
        } catch GoogleOAuthError.cancelled {
            throw AccountDeletionError.cancelled
        } catch GoogleOAuthError.superseded {
            throw AccountDeletionError.cancelled
        }
    }

    // ------------------------------------------------- account deletion (Mac)

    #if os(macOS)
    /// Reauthenticates with the provider already attached to this Firebase
    /// account, then calls the same server-owned purge endpoint as iOS. The
    /// caller confirms the destructive action and removes the local namespace
    /// only after this returns successfully.
    public func deleteAccountOnMac() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw AccountDeletionError.notSignedIn
        }
        if providers.contains("apple.com") {
            try await reauthenticateAppleOnMac(user: user)
        } else if providers.contains("google.com") {
            try await reauthenticateGoogle(user: user)
        } else {
            throw AccountDeletionError.notSignedIn
        }
        return try await deleteAccountFromServer()
    }

    private func reauthenticateAppleOnMac(user: User) async throws {
        let rawNonce = Self.randomNonce()
        let hashedNonce = SHA256.hash(data: Data(rawNonce.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let state = Self.randomNonce(length: 16)

        var components = URLComponents(
            string: "https://appleid.apple.com/auth/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: Self.servicesID),
            .init(name: "redirect_uri", value:
                "https://\(Self.returnHost)\(Self.returnPath)"),
            .init(name: "response_type", value: "code id_token"),
            .init(name: "response_mode", value: "form_post"),
            .init(name: "scope", value: "name email"),
            .init(name: "state", value: state),
            .init(name: "nonce", value: hashedNonce),
        ]
        let callback = try await runAccountDeletionWebSession(
            url: components.url!, callbackScheme: Self.callbackScheme)
        guard callback.scheme?.lowercased() == Self.callbackScheme,
              callback.host?.lowercased() == "callback",
              let fragment = URLComponents(
                url: callback, resolvingAgainstBaseURL: false)?.fragment
        else { throw AccountDeletionError.incompleteAppleCredential }

        var params: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let components = pair.split(separator: "=", maxSplits: 1,
                                        omittingEmptySubsequences: false)
            guard components.count == 2 else { continue }
            params[String(components[0])] =
                String(components[1]).removingPercentEncoding
                ?? String(components[1])
        }
        guard params["state"] == state,
              let idToken = params["id_token"],
              let authorizationCode = params["code"] else {
            throw AccountDeletionError.incompleteAppleCredential
        }
        let credential = OAuthProvider.appleCredential(
            withIDToken: idToken, rawNonce: rawNonce, fullName: nil)
        _ = try await user.reauthenticate(with: credential)
        try await Auth.auth().revokeToken(
            withAuthorizationCode: authorizationCode)
    }

    private func runAccountDeletionWebSession(
        url: URL, callbackScheme: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.accountDeletionWebContinuation = continuation
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: callbackScheme
            ) { [weak self] callback, error in
                Task { @MainActor in
                    guard let self,
                          let continuation = self.accountDeletionWebContinuation
                    else { return }
                    self.accountDeletionWebContinuation = nil
                    self.accountDeletionWebSession = nil
                    if let error {
                        let ns = error as NSError
                        if ns.domain == ASWebAuthenticationSessionError.errorDomain,
                           ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                            continuation.resume(throwing: AccountDeletionError.cancelled)
                        } else {
                            continuation.resume(throwing: error)
                        }
                    } else if let callback {
                        continuation.resume(returning: callback)
                    } else {
                        continuation.resume(throwing: AccountDeletionError.notSignedIn)
                    }
                }
            }
            session.presentationContextProvider = self.webPresenter
            self.accountDeletionWebSession = session
            if !session.start() {
                self.accountDeletionWebSession = nil
                self.accountDeletionWebContinuation = nil
                continuation.resume(throwing: AccountDeletionError.notSignedIn)
            }
        }
    }
    #endif

    // ------------------------------------------------- account deletion (iOS)

    #if canImport(UIKit)
    /// A destructive account deletion needs a freshly issued Apple credential.
    /// The nonce is separate from regular sign-in so overlapping system sheets
    /// can never consume each other's credential.
    public func prepareAppleAccountDeletionRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonce()
        accountDeletionNonce = nonce
        request.nonce = SHA256.hash(data: Data(nonce.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Reauthenticate, revoke the Sign in with Apple token as Apple requires,
    /// then ask the trusted backend to purge Storage, Firestore, and Firebase
    /// Authentication. The caller removes the on-device namespace before
    /// calling `finishAccountDeletion`.
    public func deleteAccount(
        withAppleAuthorization result: Result<ASAuthorization, Error>
    ) async throws -> String {
        let authorization: ASAuthorization
        switch result {
        case .failure(let error):
            let ns = error as NSError
            if ns.domain == ASAuthorizationError.errorDomain,
               ns.code == ASAuthorizationError.canceled.rawValue {
                throw AccountDeletionError.cancelled
            }
            throw error
        case .success(let value):
            authorization = value
        }

        guard let user = Auth.auth().currentUser else {
            throw AccountDeletionError.notSignedIn
        }
        guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = apple.identityToken,
              let token = String(data: tokenData, encoding: .utf8),
              let nonce = accountDeletionNonce,
              let codeData = apple.authorizationCode,
              let authorizationCode = String(data: codeData, encoding: .utf8)
        else {
            throw AccountDeletionError.incompleteAppleCredential
        }
        accountDeletionNonce = nil

        let credential = OAuthProvider.appleCredential(
            withIDToken: token, rawNonce: nonce, fullName: apple.fullName)
        _ = try await user.reauthenticate(with: credential)
        try await Auth.auth().revokeToken(withAuthorizationCode: authorizationCode)
        return try await deleteAccountFromServer()
    }

    /// The shared PKCE flow obtains a fresh Google credential, then refreshes
    /// Firebase auth_time for the server-owned deletion endpoint.
    public func deleteAccountWithGoogle() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw AccountDeletionError.notSignedIn
        }
        try await reauthenticateGoogle(user: user)
        return try await deleteAccountFromServer()
    }
    #endif

    private func deleteAccountFromServer() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw AccountDeletionError.notSignedIn
        }
        let uid = user.uid
        let result = try await Functions.functions(region: "us-central1")
            .httpsCallable("deleteAccount").call([:])
        guard let data = result.data as? [String: Any],
              data["deleted"] as? Bool == true else {
            throw AccountDeletionError.serverRejected
        }
        return uid
    }

    /// Leaves the deleted cloud identity even if best-effort local cleanup
    /// failed. Callers retain that uid in `pendingLocalCleanupUIDs` so cleanup
    /// can be retried without stranding an authenticated, already-deleted user.
    public func finishAccountDeletion(uid: String) {
        invalidateGoogleOAuth()
        cloudAccessGeneration &+= 1
        invalidatePatreonConnection()
        UserDefaults.standard.removeObject(forKey: Self.admittedKey(uid))
        try? Auth.auth().signOut()
        email = nil
        providers = []
        linkHint = nil
        cloudAccess = nil
        cloudActionError = nil
        pendingCredential = nil
        currentNonce = nil
        accountDeletionNonce = nil
        #if os(macOS)
        accountDeletionWebContinuation?.resume(
            throwing: AccountDeletionError.cancelled)
        accountDeletionWebContinuation = nil
        accountDeletionWebSession?.cancel()
        accountDeletionWebSession = nil
        #endif
        isRefreshingCloudAccess = false
        state = .signedOut
    }

    // ------------------------------------------------- Firebase + catch-and-link

    private func signIn(with credential: AuthCredential,
                        googleGeneration: UInt? = nil) {
        Auth.auth().signIn(with: credential) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let googleGeneration,
                   self.googleOAuthGeneration != googleGeneration {
                    self.completeGoogleOAuthAttempt(generation: googleGeneration)
                    // A sign-out can invalidate an in-flight Firebase request,
                    // but Firebase may still publish its result. Restore the
                    // requested signed-out state when no newer auth succeeded.
                    if case .signedOut = self.state,
                       Auth.auth().currentUser?.uid == result?.user.uid {
                        try? Auth.auth().signOut()
                    }
                    return
                }
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
                        if let googleGeneration {
                            self.completeGoogleOAuthAttempt(generation: googleGeneration)
                        }
                        return
                    }
                    self.state = .failed(error.localizedDescription)
                    if let googleGeneration {
                        self.completeGoogleOAuthAttempt(generation: googleGeneration)
                    }
                    return
                }
                guard let user = result?.user else {
                    if let googleGeneration {
                        self.completeGoogleOAuthAttempt(generation: googleGeneration)
                    }
                    return
                }
                if let pending = self.pendingCredential {
                    self.pendingCredential = nil
                    self.linkHint = nil
                    user.link(with: pending) { _, _ in
                        // Link failure is non-fatal (the account works; the
                        // second provider just isn't attached).
                        Task { @MainActor in
                            if let googleGeneration {
                                guard self.googleOAuthGeneration == googleGeneration else {
                                    self.completeGoogleOAuthAttempt(
                                        generation: googleGeneration)
                                    return
                                }
                                self.completeGoogleOAuthAttempt(
                                    generation: googleGeneration)
                            }
                            self.adoptSignedIn(user)
                        }
                    }
                } else {
                    if let googleGeneration {
                        self.completeGoogleOAuthAttempt(generation: googleGeneration)
                    }
                    self.adoptSignedIn(user)
                }
            }
        }
    }

    private func adoptSignedIn(_ user: User) {
        invalidateGoogleOAuth()
        cloudAccessGeneration &+= 1
        invalidatePatreonConnection()
        let generation = cloudAccessGeneration
        email = user.email
        providers = user.providerData.map(\.providerID)
        linkHint = nil
        cloudAccess = nil
        cloudActionError = nil
        isRefreshingCloudAccess = false
        shouldOfferPatreonAccountSwitch = false
        state = .checking(uid: user.uid)
        Task {
            await requestCloudAccess(
                uid: user.uid,
                preserveCurrentAccess: false,
                refreshPatreonFirst: false,
                generation: generation)
        }
    }

    // ------------------------------------------------- Patreon + Cloud Sync access

    /// This key predates Patreon gating. It now records only that this install
    /// has used the uid namespace, so an entitlement lapse never makes its
    /// on-device sessions appear to vanish. It does not grant cloud access.
    private static func admittedKey(_ uid: String) -> String { "gm-admitted-\(uid)" }

    public static func hasCloudNamespace(for uid: String) -> Bool {
        guard FileSessionStore.namespaceRoot(for: uid) != nil else { return false }
        return UserDefaults.standard.bool(forKey: admittedKey(uid))
            || FileSessionStore.hasStoredNamespaceData(for: uid)
    }

    private func requestCloudAccess(
        uid: String,
        preserveCurrentAccess: Bool,
        refreshPatreonFirst: Bool,
        generation: UInt
    ) async {
        guard generation == cloudAccessGeneration,
              !isRefreshingCloudAccess else { return }
        isRefreshingCloudAccess = true
        defer {
            if generation == cloudAccessGeneration {
                isRefreshingCloudAccess = false
            }
        }
        var refreshedEntitlement: PatreonEntitlement?
        do {
            if refreshPatreonFirst {
                let refreshed = try await Functions.functions(region: "us-central1")
                    .httpsCallable("refreshPatreonEntitlement").call([:])
                guard let payload = refreshed.data as? [String: Any],
                      let entitlement = PatreonEntitlement(payload: payload) else {
                    throw CloudAccessError.invalidResponse
                }
                refreshedEntitlement = entitlement
            }
            let result = try await Functions.functions(region: "us-central1")
                .httpsCallable("admitSyncUser").call([:])
            guard let data = result.data as? [String: Any],
                  let entitlement = PatreonEntitlement(payload: data) else {
                throw CloudAccessError.invalidResponse
            }
            guard generation == cloudAccessGeneration,
                  Auth.auth().currentUser?.uid == uid else { return }
            let admitted = (data["admitted"] as? Bool)
                ?? (data["syncAdmitted"] as? Bool)
                ?? ((data["status"] as? String) == "admitted")
            let reason = admitted ? nil : Self.safeAdmissionReason(data["reason"])
            let access = CloudSyncAccess(
                entitlement: entitlement,
                admitted: admitted,
                admissionReason: reason)
            cloudAccess = access
            cloudActionError = nil
            if access.canSync {
                shouldOfferPatreonAccountSwitch = false
                UserDefaults.standard.set(true, forKey: Self.admittedKey(uid))
                state = .ready(uid: uid)
            } else {
                state = .localOnly(uid: uid)
            }
        } catch {
            guard generation == cloudAccessGeneration,
                  Auth.auth().currentUser?.uid == uid else { return }
            if let refreshedEntitlement {
                // The refresh itself is authoritative even if the follow-up
                // admission request lost its connection. A confirmed lapse
                // must detach the engine immediately; confirmed effective
                // access may keep a previously admitted seat for this session.
                let access = CloudSyncAccess(
                    entitlement: refreshedEntitlement,
                    admitted: cloudAccess?.admitted == true,
                    admissionReason: cloudAccess?.admissionReason)
                cloudAccess = access
                state = access.canSync ? .ready(uid: uid) : .localOnly(uid: uid)
                cloudActionError = access.canSync ? nil
                    : "Cloud Sync access was refreshed, but setup couldn't be completed. Try again."
                return
            }
            cloudActionError = "Cloud Sync couldn't be checked. Your local library is still available."
            // A transport failure is not evidence of lost membership. During
            // a running session, retain the previous server-approved state;
            // backend rules remain authoritative for every remote operation.
            if preserveCurrentAccess, cloudAccess != nil { return }
            cloudAccess = CloudSyncAccess(entitlement: .unavailable, admitted: false)
            state = .localOnly(uid: uid)
        }
    }

    /// Refreshes status after foregrounding, a membership change, or a Patreon
    /// OAuth callback. Transport failures never manufacture an inactive state.
    public func refreshCloudAccess() {
        guard let uid, !isRefreshingCloudAccess else { return }
        let preserve = cloudAccess != nil
        let generation = cloudAccessGeneration
        if !preserve { state = .checking(uid: uid) }
        Task {
            await requestCloudAccess(
                uid: uid,
                preserveCurrentAccess: preserve,
                refreshPatreonFirst: true,
                generation: generation)
        }
    }

    /// Starts a backend-issued Patreon OAuth flow. The app receives only a
    /// safe success/error callback; Patreon tokens remain server-side.
    public func connectPatreon() {
        connectPatreon(mode: .reuseSession)
    }

    public func connectPatreon(mode: PatreonConnectionMode) {
        guard let expectedUID = Auth.auth().currentUser?.uid,
              !isConnectingPatreon else { return }
        patreonConnectionGeneration &+= 1
        let connectionGeneration = patreonConnectionGeneration
        cloudActionError = nil
        isConnectingPatreon = true
        Task {
            do {
                let result = try await Functions.functions(region: "us-central1")
                    .httpsCallable("startPatreonOAuth").call([
                        "attemptKind": mode.attemptKind,
                    ])
                guard let data = result.data as? [String: Any],
                      let rawURL = data["authorizationURL"] as? String,
                      let url = URL(string: rawURL),
                      let components = URLComponents(
                        url: url, resolvingAgainstBaseURL: false),
                      components.scheme?.lowercased() == "https",
                      components.host?.lowercased() == "www.patreon.com",
                      components.port == nil,
                      components.user == nil,
                      components.password == nil,
                      components.path == "/oauth2/authorize" else {
                    throw CloudAccessError.invalidResponse
                }
                guard connectionGeneration == patreonConnectionGeneration,
                      Auth.auth().currentUser?.uid == expectedUID else { return }
                startPatreonWebSession(
                    url: url,
                    expectedUID: expectedUID,
                    connectionGeneration: connectionGeneration,
                    mode: mode)
            } catch {
                guard connectionGeneration == patreonConnectionGeneration,
                      Auth.auth().currentUser?.uid == expectedUID else { return }
                isConnectingPatreon = false
                cloudActionError = "Couldn't open Patreon. Check your connection and try again."
            }
        }
    }

    private func startPatreonWebSession(
        url: URL,
        expectedUID: String,
        connectionGeneration: UInt,
        mode: PatreonConnectionMode
    ) {
        guard connectionGeneration == patreonConnectionGeneration,
              Auth.auth().currentUser?.uid == expectedUID else { return }
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: Self.callbackScheme
        ) { [weak self] url, error in
            Task { @MainActor in
                self?.finishPatreonWebSession(
                    url: url,
                    error: error,
                    expectedUID: expectedUID,
                    connectionGeneration: connectionGeneration)
            }
        }
        session.presentationContextProvider = patreonWebPresenter
        session.prefersEphemeralWebBrowserSession =
            mode.prefersEphemeralBrowserSession
        patreonWebSession = session
        if !session.start() {
            guard connectionGeneration == patreonConnectionGeneration else { return }
            patreonWebSession = nil
            isConnectingPatreon = false
            cloudActionError = "Couldn't open Patreon. Try again."
        }
    }

    private func finishPatreonWebSession(
        url: URL?,
        error: Error?,
        expectedUID: String,
        connectionGeneration: UInt
    ) {
        guard connectionGeneration == patreonConnectionGeneration,
              Auth.auth().currentUser?.uid == expectedUID else { return }
        patreonWebSession = nil
        isConnectingPatreon = false
        if let error {
            let ns = error as NSError
            if ns.domain == ASWebAuthenticationSessionError.errorDomain,
               ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue { return }
            cloudActionError = "Patreon couldn't be connected. Try again."
            return
        }
        guard let url,
              url.scheme?.lowercased() == Self.callbackScheme,
              url.host?.lowercased() == "patreon",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let status = components.queryItems?.first(where: { $0.name == "status" })?.value,
              status == "success" || status == "error"
        else {
            cloudActionError = "Patreon returned an invalid response. Try again."
            return
        }
        if status == "success" {
            shouldOfferPatreonAccountSwitch = false
            refreshCloudAccess()
        } else {
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value
            shouldOfferPatreonAccountSwitch = Self.patreonErrorSuggestsAccountSwitch(code)
            cloudActionError = Self.patreonCallbackMessage(code: code)
        }
    }

    private static func patreonErrorSuggestsAccountSwitch(_ code: String?) -> Bool {
        ["membership_not_found", "membership_inactive", "already_linked"].contains(code)
    }

    private static func patreonCallbackMessage(code: String?) -> String {
        switch code {
        case "authorization_denied":
            return "Patreon access wasn't approved. Nothing changed."
        case "invalid_state", "expired_state":
            return "The Patreon connection expired. Start it again."
        case "already_linked":
            return "That Patreon membership is already connected to another Gainmap account. Try another account."
        case "membership_not_found":
            return "No active Gainmap membership was found for that Patreon account. Try another account."
        case "membership_inactive":
            return "That Patreon membership isn’t active. Try another account or refresh after reactivating."
        case "campaign_not_configured":
            return "Patreon isn't configured for Gainmap yet. Try again later."
        case "token_exchange_failed", "identity_failed":
            return "Patreon couldn't finish connecting. Start it again."
        default:
            return "Patreon couldn't be connected. Try again."
        }
    }

    private static func safeAdmissionReason(_ value: Any?) -> String? {
        guard let value = value as? String,
              ["waitlist", "patreon_required"].contains(value) else { return nil }
        return value
    }

    // ------------------------------------------------- Sign in with Apple (Mac)
    // Developer ID distribution does not support the applesignin entitlement
    // (S3 finding), so the Mac runs Apple's browser OAuth flow: form_post to
    // the appleReturn Cloud Function (Hosting rewrite), which bounces the
    // fields to gainmapauth://callback where ASWebAuthenticationSession picks
    // them up. Ported verbatim from the S3 spike (proved on a notarized build).
    #if os(macOS)
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

    #endif

    // ------------------------------------------------- sign-out

    public func signOut() {
        invalidateGoogleOAuth()
        cloudAccessGeneration &+= 1
        invalidatePatreonConnection()
        #if os(macOS)
        accountDeletionWebContinuation?.resume(
            throwing: AccountDeletionError.cancelled)
        accountDeletionWebContinuation = nil
        accountDeletionWebSession?.cancel()
        accountDeletionWebSession = nil
        #endif
        try? Auth.auth().signOut()
        email = nil
        providers = []
        linkHint = nil
        cloudAccess = nil
        cloudActionError = nil
        isRefreshingCloudAccess = false
        shouldOfferPatreonAccountSwitch = false
        state = .signedOut
    }

    // ------------------------------------------------- helpers

    private func invalidatePatreonConnection() {
        patreonConnectionGeneration &+= 1
        patreonWebSession?.cancel()
        patreonWebSession = nil
        isConnectingPatreon = false
    }

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { charset[Int($0) % charset.count] })
    }
}

private enum CloudAccessError: Error {
    case invalidResponse
}

final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
            ?? ASPresentationAnchor()
        #endif
    }
}
