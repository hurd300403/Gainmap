//
//  RootView.swift
//  Gainmap (Mac) — P7
//
//  The session library in front of the existing editor. A batch is no longer
//  an implicit "last queue": every import becomes a named, resumable session,
//  with the shared mosaic grid used by iPhone.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GainmapCore

extension Notification.Name {
    static let gainmapNewSession = Notification.Name("Gainmap.NewSession")
}

private enum MacRoute: Hashable {
    case editor(UUID)
}

struct MacRootView: View {
    @ObservedObject var model: MergeModel
    @EnvironmentObject private var auth: AuthController
    @EnvironmentObject private var sync: SyncCoordinator
    @State private var path: [MacRoute] = []

    private var debugSeedRequested: Bool {
        UserDefaults.standard.string(forKey: "gm-seed") != nil
    }

    var body: some View {
        Group {
            if debugSeedRequested {
                // Preserve the existing deterministic screenshot harness.
                ContentView(model: model)
            } else {
                NavigationStack(path: $path) {
                    MacSessionLibrary(
                        onOpen: openSession,
                        onStart: startSession)
                        .navigationDestination(for: MacRoute.self) { route in
                            switch route {
                            case .editor(let sessionID):
                                ContentView(
                                    model: model,
                                    onShowSessions: showLibrary,
                                    onHydrateSelected: {
                                        guard let photoID = model.selectedID else { return }
                                        await sync.hydratePhotoIfNeeded(
                                            sessionID: model.session.id,
                                            photoID: photoID)
                                    })
                                .navigationBarBackButtonHidden(true)
                                .onDisappear {
                                    Task {
                                        await model.flushSession()
                                        await sync.refresh()
                                    }
                                }
                                .id(sessionID)
                            }
                        }
                }
                .onChange(of: sync.namespaceID) {
                    path.removeAll()
                }
                .onChange(of: sync.externallyClosedSession) { _, sessionID in
                    guard let sessionID else { return }
                    if path.contains(.editor(sessionID)) {
                        path.removeAll()
                    }
                    sync.consumeExternalClose(sessionID)
                }
            }
        }
    }

    private func openSession(_ id: UUID) async -> Bool {
        guard await sync.openSession(id: id) else { return false }
        path = [.editor(id)]
        return true
    }

    private func startSession(_ urls: [URL]) async -> Bool {
        guard await sync.startSession(with: urls) else { return false }
        path = [.editor(model.session.id)]
        return true
    }

    private func showLibrary() {
        Task {
            await model.flushSession()
            await sync.refresh()
            path.removeAll()
        }
    }
}

private struct MacSessionLibrary: View {
    @EnvironmentObject private var auth: AuthController
    @EnvironmentObject private var sync: SyncCoordinator

    let onOpen: (UUID) async -> Bool
    let onStart: ([URL]) async -> Bool

    @State private var dropTargeted = false
    @State private var working = false
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    @State private var renaming: SessionCard?
    @State private var renameText = ""

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            RadialGradient(
                colors: [Theme.accent.opacity(0.10), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 520)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.line)

                Group {
                    if !sync.initialLoadDone {
                        ProgressView("Loading sessions…")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.stoneDim)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if sync.cards.isEmpty {
                        emptyState
                    } else {
                        SessionGridView(
                            cards: sync.cards,
                            onOpen: { id in open(id) },
                            onRename: beginRename,
                            onDelete: { id in
                                Task { await sync.deleteSession(id: id) }
                            },
                            syncState: cardSyncState)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let deletion = sync.recentlyDeleted {
                    undoBar(deletion)
                }
                footer
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(Theme.accent.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 18))
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }

            if working {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    ProgressView().controlSize(.large).tint(Theme.gold)
                        .padding(24)
                        .background(Theme.surface.opacity(0.96),
                                    in: RoundedRectangle(cornerRadius: 14))
                }
            }

            if let notice {
                VStack {
                    Spacer()
                    NoticeBanner(message: notice)
                        .frame(maxWidth: 500)
                        .padding(.bottom, 72)
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .task { await sync.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .gainmapNewSession)) { _ in
            browse()
        }
        .alert("Rename Session", isPresented: renameAlertPresented) {
            TextField("Session name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                guard let id = renaming?.id else { return }
                let title = renameText
                renaming = nil
                Task { await sync.renameSession(id: id, to: title) }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("This name syncs to your other devices.")
        }
        .animation(.easeOut(duration: 0.18), value: sync.recentlyDeleted)
        .animation(.easeOut(duration: 0.18), value: notice)
    }

    private var header: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SESSIONS")
                    .font(Theme.mono(11, .semibold))
                    .tracking(2)
                    .foregroundStyle(Theme.gold)
                Text("Your HDR work, ready on every screen.")
                    .font(Theme.ui(14))
                    .foregroundStyle(Theme.stoneDim)
            }
            Spacer()
            Button(action: browse) {
                Label("New Session", systemImage: "plus")
                    .font(Theme.ui(13, .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Theme.accent, in: Capsule())
            .shadow(color: Theme.accent.opacity(0.3), radius: 10, y: 4)
            .keyboardShortcut("n", modifiers: .command)

            SettingsLink {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 19))
                    .foregroundStyle(Theme.stone)
                    .frame(width: 34, height: 34)
                    .background(Theme.surface, in: Circle())
                    .overlay(Circle().stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Account & Sync Settings")

            VStack(alignment: .trailing, spacing: 0) {
                (Text("Gain").foregroundStyle(.white)
                 + Text("map").foregroundStyle(Theme.accent))
                    .font(Theme.display(28, .semibold))
            }
            SyncStatusEmblem(state: headerSyncState)
        }
        .padding(.leading, 84)
        .padding(.trailing, 38)
        .padding(.vertical, 17)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            GainmapAddEmblem(active: dropTargeted)
                .frame(width: 100, height: 78)
            Text("Start an HDR session")
                .font(Theme.ui(21, .semibold))
                .foregroundStyle(Theme.stone)
            Text("Drop a batch of SDR JPEGs anywhere in this window,\nor choose them from your Mac.")
                .font(Theme.ui(13))
                .foregroundStyle(Theme.stoneDim)
                .multilineTextAlignment(.center)
            Button("Choose JPEGs…", action: browse)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            Text("Each batch stays separate, resumes after relaunch, and syncs automatically when you sign in.")
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.stoneFaint)
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func undoBar(_ deletion: DeletedSessionNotice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .foregroundStyle(Theme.stoneDim)
            Text("Deleted “\(deletion.session.title.isEmpty ? "Untitled session" : deletion.session.title)”")
                .font(Theme.ui(12.5, .medium))
                .foregroundStyle(Theme.stone)
                .lineLimit(1)
            Spacer()
            Button("Undo") { Task { await sync.undoLastDelete() } }
                .buttonStyle(.plain)
                .font(Theme.mono(11, .semibold))
                .foregroundStyle(Theme.gold)
            Button {
                sync.dismissDeleteNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.stoneDim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(height: 42)
        .background(Theme.surfaceHi)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(sync.cards.count) session\(sync.cards.count == 1 ? "" : "s")")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.stoneFaint)
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(Theme.mono(10, .medium))
                .foregroundStyle(Theme.stoneDim)
        }
        .padding(.horizontal, 20)
        .frame(height: 38)
        .background(Theme.inset.opacity(0.96))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var statusText: String {
        switch auth.state {
        case .signedOut:
            return "On this Mac · sign in in Settings to sync"
        case .failed:
            return "On this Mac · sign-in needs attention"
        case .admitting:
            return "Setting up sync…"
        case .waitlisted:
            return auth.admissionError == nil
                ? "Saved on this Mac · sync waitlisted"
                : "Saved on this Mac · sync offline"
        case .ready:
            if sync.hasSyncIssue { return "Sync needs attention" }
            if sync.pendingWorkCount > 0 {
                return "Syncing \(sync.pendingWorkCount) item\(sync.pendingWorkCount == 1 ? "" : "s")…"
            }
            return "Up to date"
        }
    }

    private var statusColor: Color {
        switch auth.state {
        case .ready:
            return sync.hasSyncIssue ? Theme.warn
                : (sync.pendingWorkCount > 0 ? Theme.gold : Theme.syncGreen)
        case .admitting:
            return Theme.gold
        case .signedOut, .failed, .waitlisted:
            return Theme.stoneFaint
        }
    }

    private var headerSyncState: HeaderSyncState {
        switch auth.state {
        case .signedOut, .waitlisted:
            return .localOnly
        case .failed:
            return .issue
        case .admitting:
            return .connecting
        case .ready:
            if sync.hasSyncIssue { return .issue }
            if !sync.initialSyncComplete { return .connecting }
            if sync.syncPassInFlight || sync.pendingWorkCount > 0 {
                return .syncing(sync.pendingWorkCount)
            }
            return .synced
        }
    }

    private func cardSyncState(_ card: SessionCard) -> SessionCardSyncState {
        switch auth.state {
        case .signedOut, .waitlisted:
            return .neutral
        case .failed:
            return card.pendingSync ? .issue(card.syncProgress) : .neutral
        case .admitting:
            return .pending(0)
        case .ready:
            if sync.hasSyncIssue, card.pendingSync {
                return .issue(card.syncProgress)
            }
            if !sync.initialSyncComplete {
                return .pending(card.pendingSync ? card.syncProgress : 0)
            }
            if card.pendingSync { return .pending(card.syncProgress) }
            return .synced
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } })
    }

    private func beginRename(_ card: SessionCard) {
        renameText = card.title
        renaming = card
    }

    private func open(_ id: UUID) {
        guard !working else { return }
        working = true
        Task {
            let opened = await onOpen(id)
            working = false
            if !opened { showNotice("That session could not be opened.") }
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg]
        panel.prompt = "Start Session"
        panel.message = "Choose the SDR JPEGs for this HDR session"
        if panel.runModal() == .OK { start(panel.urls) }
    }

    private func start(_ urls: [URL]) {
        guard !working else { return }
        guard urls.contains(where: { FileRole.role(for: $0) == .sdr }) else {
            showNotice("Only JPEGs can start a session.")
            return
        }
        working = true
        Task {
            let started = await onStart(urls)
            working = false
            if !started { showNotice("Gainmap couldn't start that session.") }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls = [URL?](repeating: nil, count: providers.count)
        let lock = NSLock()
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                lock.lock()
                urls[index] = url
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { start(urls.compactMap { $0 }) }
        return !providers.isEmpty
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }
}

private enum HeaderSyncState: Equatable {
    case localOnly
    case connecting
    case syncing(Int)
    case synced
    case issue

    var label: String {
        switch self {
        case .localOnly: return "MAC ONLY"
        case .connecting: return "CONNECTING"
        case .syncing(let count): return count > 0 ? "SYNCING · \(count)" : "SYNCING"
        case .synced: return "SYNCED"
        case .issue: return "SYNC ISSUE"
        }
    }

    var help: String {
        switch self {
        case .localOnly:
            return "Saved on this Mac only. Sign in to make sessions available on iPhone."
        case .connecting:
            return "Connecting to sync. The iPhone may not have the latest session yet."
        case .syncing:
            return "Sending the latest images and edits. Keep Gainmap open."
        case .synced:
            return "Up to date. The latest sessions should be available on your iPhone."
        case .issue:
            return "Sync needs attention. The latest session may not be available on iPhone."
        }
    }
}

private struct SyncStatusEmblem: View {
    let state: HeaderSyncState

    private var ringColor: Color {
        switch state {
        case .localOnly: return Theme.stoneFaint
        case .connecting: return Theme.gold
        case .syncing: return Theme.accent
        case .synced: return Theme.syncGreen
        case .issue: return Theme.warn
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                GainmapEmblem()
                    .frame(width: 50, height: 50)
                    .shadow(color: .black.opacity(0.5), radius: 7, y: 4)

                Circle()
                    .stroke(Theme.line, lineWidth: 2)
                    .frame(width: 58, height: 58)

                ring
                    .frame(width: 58, height: 58)
            }
            Text(state.label)
                .font(Theme.mono(8, .semibold))
                .tracking(0.8)
                .foregroundStyle(ringColor)
                .lineLimit(1)
        }
        .frame(width: 76)
        .help(state.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sync status: \(state.label)")
        .accessibilityHint(state.help)
    }

    @ViewBuilder
    private var ring: some View {
        switch state {
        case .connecting, .syncing:
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let turn = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.35) / 1.35
                Circle()
                    .trim(from: 0.04, to: 0.72)
                    .stroke(ringColor,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
                    .shadow(color: ringColor.opacity(0.55), radius: 4)
            }
        case .synced:
            Circle()
                .stroke(ringColor.opacity(0.9), lineWidth: 2.5)
                .shadow(color: ringColor.opacity(0.35), radius: 4)
        case .issue:
            Circle()
                .stroke(ringColor,
                        style: StrokeStyle(lineWidth: 2.5, dash: [4, 3]))
        case .localOnly:
            Circle()
                .stroke(ringColor.opacity(0.75),
                        style: StrokeStyle(lineWidth: 2, dash: [2, 4]))
        }
    }
}
