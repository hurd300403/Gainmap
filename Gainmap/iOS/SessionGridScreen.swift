//
//  SessionGridScreen.swift
//  Gainmap for iPhone (P5)
//
//  The home screen: shared SessionGridView + waitlist banner + account menu.
//

import SwiftUI
import PhotosUI
import GainmapCore

/// What the editor cover opens: an existing session, or a brand-new one
/// seeded with photos picked on this phone.
struct EditorRequest: Identifiable {
    let id = UUID()
    let session: Session
    let importItems: [PhotosPickerItem]
}

struct SessionGridScreen: View {
    @EnvironmentObject private var auth: AuthController
    @EnvironmentObject private var model: AppModel
    @State private var editorRequest: EditorRequest?
    @State private var pickedItems: [PhotosPickerItem] = []

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
                                    editorRequest = EditorRequest(session: session,
                                                                  importItems: [])
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Phone-native session: pick photos, land in the editor.
                    PhotosPicker(selection: $pickedItems, matching: .images,
                                 photoLibrary: .shared()) {
                        Image(systemName: "plus")
                            .foregroundStyle(Theme.gold)
                    }
                }
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
            .fullScreenCover(item: $editorRequest, onDismiss: {
                Task { await model.refresh() }
            }) { request in
                EditorScreen(session: request.session,
                             store: model.store,
                             importItems: request.importItems)
                    .environmentObject(model)
            }
            .onChange(of: pickedItems) { _, items in
                guard !items.isEmpty else { return }
                pickedItems = []
                editorRequest = EditorRequest(session: Session(), importItems: items)
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
            Text("Tap + to import photos from this phone,\nor drop them into Gainmap on your Mac —\neither way they show up everywhere.")
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

