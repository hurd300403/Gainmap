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

public enum PatreonEntitlementStatus: String, Equatable, Sendable {
    case active
    case grace
    case inactive
    case unlinked
    case error
}

/// Safe, displayable entitlement data returned by Gainmap's trusted backend.
/// Patreon tokens and membership payloads never enter the app.
public struct PatreonEntitlement: Equatable, Sendable {
    public let status: PatreonEntitlementStatus
    public let effective: Bool
    /// True when this access came from a verified Patreon-email match or no
    /// Patreon identity is linked yet. Linked grace/inactive states are false.
    public let linkRequired: Bool
    public let graceExpiresAt: Date?
    public let lastVerifiedAt: Date?
    public let message: String

    public init(status: PatreonEntitlementStatus, effective: Bool,
                linkRequired: Bool? = nil,
                graceExpiresAt: Date? = nil, lastVerifiedAt: Date? = nil,
                message: String) {
        self.status = status
        self.effective = effective
        self.linkRequired = linkRequired ?? (status == .unlinked)
        self.graceExpiresAt = graceExpiresAt
        self.lastVerifiedAt = lastVerifiedAt
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
        self.linkRequired = Self.bool(payload["linkRequired"])
            ?? (status == .unlinked)
        self.graceExpiresAt = Self.date(payload["graceExpiresAt"])
        self.lastVerifiedAt = Self.date(payload["lastVerifiedAt"])
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
            try await reauthenticateGoogleOnMac(user: user)
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

    private func reauthenticateGoogleOnMac(user: User) async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw AccountDeletionError.notSignedIn
        }
        let reversed = clientID.split(separator: ".").reversed().joined(separator: ".")
        let redirectURI = "\(reversed):/oauth2redirect"
        let verifier = Self.randomNonce(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let state = Self.randomNonce(length: 16)

        var components = URLComponents(
            string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "prompt", value: "select_account"),
        ]
        let callback = try await runAccountDeletionWebSession(
            url: components.url!, callbackScheme: String(reversed))
        guard callback.scheme?.lowercased() == reversed.lowercased(),
              callback.path == "/oauth2redirect",
              let items = URLComponents(
                url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value
        else { throw AccountDeletionError.notSignedIn }

        var request = URLRequest(
            url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
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
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = json["id_token"] as? String else {
            throw AccountDeletionError.notSignedIn
        }
        let accessToken = json["access_token"] as? String ?? ""
        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken, accessToken: accessToken)
        _ = try await user.reauthenticate(with: credential)
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

    /// Firebase's provider flow presents the Google sheet, then refreshes the
    /// Firebase auth_time that the deletion endpoint verifies server-side.
    public func deleteAccountWithGoogle() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw AccountDeletionError.notSignedIn
        }
        let provider = OAuthProvider(providerID: "google.com")
        provider.scopes = ["email", "profile"]
        do {
            _ = try await user.reauthenticate(with: provider, uiDelegate: nil)
        } catch {
            let ns = error as NSError
            if ns.code == AuthErrorCode.webContextCancelled.rawValue {
                throw AccountDeletionError.cancelled
            }
            throw error
        }
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
        cloudAccessGeneration &+= 1
        invalidatePatreonConnection()
        let generation = cloudAccessGeneration
        email = user.email
        providers = user.providerData.map(\.providerID)
        linkHint = nil
        cloudAccess = nil
        cloudActionError = nil
        isRefreshingCloudAccess = false
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
        guard let expectedUID = Auth.auth().currentUser?.uid,
              !isConnectingPatreon else { return }
        patreonConnectionGeneration &+= 1
        let connectionGeneration = patreonConnectionGeneration
        cloudActionError = nil
        isConnectingPatreon = true
        Task {
            do {
                let result = try await Functions.functions(region: "us-central1")
                    .httpsCallable("startPatreonOAuth").call([:])
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
                    connectionGeneration: connectionGeneration)
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
        connectionGeneration: UInt
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
        session.prefersEphemeralWebBrowserSession = false
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
            refreshCloudAccess()
        } else {
            cloudActionError = Self.patreonCallbackMessage(
                code: components.queryItems?.first(where: { $0.name == "code" })?.value)
        }
    }

    private static func patreonCallbackMessage(code: String?) -> String {
        switch code {
        case "authorization_denied":
            return "Patreon access wasn't approved. Nothing changed."
        case "invalid_state", "expired_state":
            return "The Patreon connection expired. Start it again."
        case "already_linked":
            return "That Patreon membership is already connected to another Gainmap account."
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
