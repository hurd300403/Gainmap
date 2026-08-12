//
//  SignInScreen.swift
//  Gainmap for iPhone
//
//  Optional Cloud Sync setup. Local sessions and editing never depend on
//  signing in; this sheet stages identity first and Patreon only when needed.
//

import SwiftUI
import AuthenticationServices
import GainmapCore

struct SignInScreen: View {
    @EnvironmentObject private var auth: AuthController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        switch auth.state {
                        case .signedOut, .failed:
                            signInControls
                        case .checking:
                            checkingView
                        case .ready, .localOnly:
                            signedInControls
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 560, alignment: .leading)
                    .background(
                        Theme.surface,
                        in: RoundedRectangle(
                            cornerRadius: 20,
                            style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Theme.line, lineWidth: 1)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
            }
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(Theme.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Cloud Sync")
                    .font(Theme.display(27, .semibold))
                    .foregroundStyle(Theme.stone)
                Text("Optional · iPhone + Mac")
                    .font(Theme.mono(9.5, .medium))
                    .tracking(0.7)
                    .foregroundStyle(Theme.stoneDim)
            }
        }
    }

    private var signInControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(displayState.detail)
                .font(Theme.ui(13.5))
                .foregroundStyle(Theme.stoneDim)
                .fixedSize(horizontal: false, vertical: true)

            Text("SIGN IN")
                .font(Theme.mono(9.5, .bold))
                .tracking(1.15)
                .foregroundStyle(Theme.gold)

            SignInWithAppleButton(.signIn) { request in
                auth.prepareAppleRequest(request)
            } onCompletion: { result in
                auth.handleAppleCompletion(result)
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 47)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            Button { auth.googleSignIn() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "g.circle.fill")
                        .font(.system(size: 17))
                    Text("Sign in with Google")
                        .font(Theme.ui(15, .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 47)
                .background(
                    Theme.inset,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Theme.line, lineWidth: 1)
                }
                .foregroundStyle(Theme.stone)
            }
            .buttonStyle(.plain)

            if let hint = auth.linkHint {
                inlineMessage(hint, color: Theme.gold)
            }
            if case .failed(let message) = auth.state {
                inlineMessage(message, color: Theme.accentHot)
            }

            Text("Patreon member? Use the same email if you can. If it’s different, connect Patreon after signing in.")
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.stoneFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var checkingView: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountLabel
            HStack(spacing: 10) {
                ProgressView().tint(Theme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayState.title)
                        .font(Theme.ui(14, .semibold))
                        .foregroundStyle(Theme.stone)
                    Text(displayState.detail)
                        .font(Theme.ui(12.5))
                        .foregroundStyle(Theme.stoneDim)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var signedInControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountLabel
            entitlementCard

            if displayState.action == .connectPatreon
                || displayState.action == .switchPatreon {
                Text("You’ll sign in securely on Patreon.")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.stoneDim)
                    .fixedSize(horizontal: false, vertical: true)

                Button { performPatreonAction() } label: {
                    HStack(spacing: 9) {
                        if auth.isConnectingPatreon {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: displayState.action == .switchPatreon
                                  ? "arrow.triangle.2.circlepath" : "link")
                        }
                        Text(displayState.action.label ?? "Connect Patreon")
                    }
                    .font(Theme.ui(14.5, .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 47)
                    .foregroundStyle(.white)
                    .background(
                        Theme.accent,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(auth.isConnectingPatreon)
            }

            if displayState.action == .retry {
                Button(displayState.action.label ?? "Refresh Status") {
                    auth.refreshCloudAccess()
                }
                .disabled(
                    auth.isRefreshingCloudAccess
                        || auth.isConnectingPatreon)
            } else if displayState.kind == .inactive {
                Button("Refresh Status") { auth.refreshCloudAccess() }
                    .disabled(
                        auth.isRefreshingCloudAccess
                            || auth.isConnectingPatreon)
            }

            if let error = auth.cloudActionError,
               displayState.kind != .unavailable {
                inlineMessage(error, color: Theme.accentHot)
            }

            Divider().overlay(Theme.line)
            Button("Sign out", role: .destructive) { auth.signOut() }
                .disabled(auth.isConnectingPatreon)
        }
    }

    @ViewBuilder
    private var accountLabel: some View {
        if let email = auth.email, auth.uid != nil {
            VStack(alignment: .leading, spacing: 3) {
                Text("SIGNED IN AS")
                    .font(Theme.mono(9, .bold))
                    .tracking(1.1)
                    .foregroundStyle(Theme.stoneFaint)
                Text(email)
                    .font(Theme.ui(15, .medium))
                    .foregroundStyle(Theme.stone)
                    .textSelection(.enabled)
            }
        }
    }

    private var entitlementCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(displayState.title)
                    .font(Theme.ui(15, .semibold))
                    .foregroundStyle(Theme.stone)
                Text(displayState.detail)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.stoneDim)
                    .fixedSize(horizontal: false, vertical: true)
                if let expiry = displayState.graceExpiresAt {
                    Text("Grace access ends \(expiry.formatted(date: .abbreviated, time: .shortened)).")
                        .font(Theme.mono(9.5, .medium))
                        .foregroundStyle(Theme.gold)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.line, lineWidth: 1)
        }
    }

    private var displayState: CloudSyncDisplayState {
        .resolve(
            authState: auth.state,
            access: auth.cloudAccess,
            signedInEmail: auth.email,
            preferPatreonAccountSwitch: auth.shouldOfferPatreonAccountSwitch)
    }

    private var statusIcon: String {
        switch displayState.kind {
        case .enabled: return "checkmark.circle.fill"
        case .grace: return "clock.badge.exclamationmark"
        case .inactive: return "pause.circle.fill"
        case .needsPatreon: return "link.badge.plus"
        case .waitlist: return "hourglass"
        case .setupPending: return "exclamationmark.circle.fill"
        case .unavailable, .signInFailed:
            return "exclamationmark.triangle.fill"
        case .signedOut, .checking: return "ellipsis.circle"
        }
    }

    private var statusColor: Color {
        switch displayState.kind {
        case .enabled: return Theme.syncGreen
        case .grace, .waitlist, .setupPending: return Theme.gold
        case .unavailable, .signInFailed: return Theme.accentHot
        case .signedOut, .checking, .needsPatreon, .inactive:
            return Theme.stoneDim
        }
    }

    private func performPatreonAction() {
        switch displayState.action {
        case .connectPatreon:
            auth.connectPatreon(mode: .reuseSession)
        case .switchPatreon:
            auth.connectPatreon(mode: .switchAccount)
        case .none, .signIn, .retry:
            break
        }
    }

    @ViewBuilder
    private func inlineMessage(_ message: String, color: Color) -> some View {
        Text(message)
            .font(Theme.ui(12))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
