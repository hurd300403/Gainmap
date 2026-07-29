//
//  SessionGridScreen.swift
//  Gainmap for iPhone (P5)
//
//  The home screen: shared SessionGridView + waitlist banner + account menu.
//

import SwiftUI
import GainmapCore

struct SessionGridScreen: View {
    @EnvironmentObject private var auth: AuthController
    @EnvironmentObject private var model: AppModel
    @State private var openSession: Session?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    if case .waitlisted = auth.state {
                        waitlistBanner
                    }
                    if model.cards.isEmpty {
                        emptyState
                    } else {
                        SessionGridView(cards: model.cards) { id in
                            Task {
                                if let session = await model.session(id: id) {
                                    openSession = session
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let email = auth.email {
                            Text(email)
                        }
                        Button("Sign out", role: .destructive) { auth.signOut() }
                    } label: {
                        Image(systemName: "person.circle")
                            .foregroundStyle(Theme.stoneDim)
                    }
                }
            }
            .fullScreenCover(item: $openSession) { session in
                EditorScreen(session: session)
                    .environmentObject(model)
            }
            .task { await model.refresh() }
            .refreshable { await model.refresh() }
        }
    }

    private var waitlistBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hourglass").font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync is full right now — you're on the waitlist.")
                    .font(Theme.ui(12, .medium)).foregroundStyle(Theme.stone)
                Text("Everything works offline; sessions sync once a spot opens.")
                    .font(Theme.mono(9)).foregroundStyle(Theme.stoneDim)
            }
            Spacer()
            Button("Re-check") { auth.retryAdmission() }
                .font(Theme.mono(10, .semibold)).foregroundStyle(Theme.gold)
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(Theme.surface.opacity(0.6))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line),
                 alignment: .bottom)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 40)).foregroundStyle(Theme.stoneFaint)
            Text("No sessions yet")
                .font(Theme.ui(16, .semibold)).foregroundStyle(Theme.stone)
            Text("Drop photos into Gainmap on your Mac —\nthe session shows up here, ready to tune.")
                .font(Theme.ui(13)).foregroundStyle(Theme.stoneDim)
                .multilineTextAlignment(.center)
            if model.syncing {
                ProgressView().tint(Theme.stoneDim).padding(.top, 8)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

