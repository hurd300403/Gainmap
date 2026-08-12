//
//  SignInScreen.swift
//  Gainmap for iPhone
//
//  Optional Cloud Sync setup. Gainmap's editor and local library never depend
//  on this screen; Firebase identifies a private library and Patreon grants
//  access only to the cloud service.
//

import SwiftUI
import AuthenticationServices
import GainmapCore

struct SignInScreen: View {
    @EnvironmentObject private var auth: AuthController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Image(systemName: "icloud")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Theme.accent)
                        Text("Cloud Sync")
                            .font(Theme.display(32, .semibold))
                            .foregroundStyle(Theme.stone)
                        Text("Gainmap is free to use without an account. Sign in only if you want your private sessions and photos to sync between iPhone and Mac.")
                            .font(Theme.ui(14))
                            .foregroundStyle(Theme.stoneDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    switch auth.state {
                    case .signedOut, .failed:
                        signInControls
                    case .checking:
                        checkingView
                    case .ready, .localOnly:
                        signedInControls
                    }
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var signInControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1 · Create your private sync account")
                .font(Theme.mono(10, .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.gold)

            SignInWithAppleButton(.signIn) { request in
                auth.prepareAppleRequest(request)
            } onCompletion: { result in
                auth.handleAppleCompletion(result)
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button { auth.googleSignIn() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "g.circle.fill").font(.system(size: 17))
                    Text("Sign in with Google").font(Theme.ui(16, .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Theme.surface,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1))
                .foregroundStyle(Theme.stone)
            }
            .buttonStyle(.plain)

            if let hint = auth.linkHint {
                inlineMessage(hint, color: Theme.gold)
            }
            if case .failed(let message) = auth.state {
                inlineMessage(message, color: Theme.accentHot)
            }

            Text("An arbitrary email address cannot unlock Cloud Sync. A verified email that matches an active patron may receive temporary access; connecting Patreon confirms your membership.")
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.stoneFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private var checkingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            accountLabel
            HStack(spacing: 10) {
                ProgressView().tint(Theme.gold)
                Text("Checking Cloud Sync access…")
                    .font(Theme.ui(14, .medium))
                    .foregroundStyle(Theme.stoneDim)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var signedInControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            accountLabel
            entitlementCard

            if shouldOfferPatreonConnection {
                Button { auth.connectPatreon() } label: {
                    HStack(spacing: 9) {
                        if auth.isConnectingPatreon {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "link")
                        }
                        Text("Connect Patreon")
                    }
                    .font(Theme.ui(15, .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .foregroundStyle(.white)
                    .background(Theme.accent,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(auth.isConnectingPatreon)
            }

            Button {
                auth.refreshCloudAccess()
            } label: {
                HStack(spacing: 8) {
                    if auth.isRefreshingCloudAccess {
                        ProgressView().controlSize(.small)
                    }
                    Text("Check Access Again")
                }
            }
            .disabled(auth.isRefreshingCloudAccess || auth.isConnectingPatreon)

            if let error = auth.cloudActionError {
                inlineMessage(error, color: Theme.accentHot)
            }

            Divider().overlay(Theme.line)
            Button("Sign out of Cloud Sync", role: .destructive) { auth.signOut() }
                .disabled(auth.isConnectingPatreon)
        }
    }

    private var accountLabel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("SYNC ACCOUNT")
                .font(Theme.mono(9, .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.stoneFaint)
            Text(auth.email ?? "Signed in")
                .font(Theme.ui(15, .medium))
                .foregroundStyle(Theme.stone)
        }
    }

    private var entitlementCard: some View {
        let entitlement = auth.cloudAccess?.entitlement
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: entitlementIcon(entitlement?.status))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(entitlementColor(entitlement?.status))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(entitlementTitle(entitlement?.status))
                    .font(Theme.ui(15, .semibold))
                    .foregroundStyle(Theme.stone)
                Text(auth.cloudAccess?.admissionBlockMessage
                     ?? entitlement?.message
                     ?? "Cloud Sync access has not been checked yet.")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.stoneDim)
                    .fixedSize(horizontal: false, vertical: true)
                if let expiry = entitlement?.graceExpiresAt {
                    Text("Grace access ends \(expiry.formatted(date: .abbreviated, time: .shortened)).")
                        .font(Theme.mono(9.5, .medium))
                        .foregroundStyle(Theme.gold)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }

    private var shouldOfferPatreonConnection: Bool {
        guard let entitlement = auth.cloudAccess?.entitlement else { return true }
        return entitlement.linkRequired
    }

    @ViewBuilder
    private func inlineMessage(_ message: String, color: Color) -> some View {
        Text(message)
            .font(Theme.ui(12))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func entitlementTitle(_ status: PatreonEntitlementStatus?) -> String {
        if auth.cloudAccess?.isWaitlisted == true {
            return "Cloud Sync waitlist"
        }
        if auth.cloudAccess?.admissionBlockMessage != nil {
            return "Cloud Sync setup pending"
        }
        switch status {
        case .active: return "Patreon active · Cloud Sync on"
        case .grace: return "Cloud Sync in grace period"
        case .inactive: return "Patreon membership inactive"
        case .unlinked: return "Patreon not connected"
        case .error: return "Access couldn't be verified"
        case .none: return "Checking Patreon"
        }
    }

    private func entitlementIcon(_ status: PatreonEntitlementStatus?) -> String {
        if auth.cloudAccess?.admissionBlockMessage != nil {
            return auth.cloudAccess?.isWaitlisted == true
                ? "hourglass" : "exclamationmark.circle.fill"
        }
        switch status {
        case .active: return "checkmark.circle.fill"
        case .grace: return "clock.badge.exclamationmark"
        case .inactive: return "pause.circle.fill"
        case .unlinked: return "link.badge.plus"
        case .error: return "exclamationmark.triangle.fill"
        case .none: return "ellipsis.circle"
        }
    }

    private func entitlementColor(_ status: PatreonEntitlementStatus?) -> Color {
        if auth.cloudAccess?.admissionBlockMessage != nil { return Theme.gold }
        switch status {
        case .active: return Theme.syncGreen
        case .grace: return Theme.gold
        case .inactive, .unlinked, .none: return Theme.stoneDim
        case .error: return Theme.accentHot
        }
    }
}
