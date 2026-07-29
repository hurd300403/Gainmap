//
//  SignInScreen.swift
//  Gainmap for iPhone (P5)
//
//  Auth gate: Sign in with Apple (native), Google, catch-and-link hint.
//  Waitlist state renders inside the main app (the app is fully usable
//  without sync) — this screen is only for the signed-out state.
//

import SwiftUI
import AuthenticationServices
import GainmapCore

struct SignInScreen: View {
    @EnvironmentObject private var auth: AuthController

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                (Text("Gain").foregroundStyle(Color.white)
                 + Text("map").foregroundStyle(Theme.accent))
                    .font(Theme.display(40, .semibold))
                Text("Your HDR sessions, on every screen.")
                    .font(Theme.ui(15)).foregroundStyle(Theme.stoneDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)

            Spacer()

            VStack(spacing: 12) {
                SignInWithAppleButton(.signIn) { request in
                    auth.prepareAppleRequest(request)
                } onCompletion: { result in
                    auth.handleAppleCompletion(result)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    auth.googleSignIn()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "g.circle.fill").font(.system(size: 17))
                        Text("Sign in with Google").font(Theme.ui(16, .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.line, lineWidth: 1))
                    .foregroundStyle(Theme.stone)
                }
                .buttonStyle(.plain)

                if let hint = auth.linkHint {
                    Text(hint)
                        .font(Theme.ui(12)).foregroundStyle(Theme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .background(Theme.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                if case .failed(let message) = auth.state {
                    Text(message)
                        .font(Theme.ui(12)).foregroundStyle(Theme.accentHot)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Sessions you start on your Mac appear here — tuned looks sync both ways. Photos upload to your private library only.")
                    .font(Theme.mono(9.5)).foregroundStyle(Theme.stoneFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
    }
}
