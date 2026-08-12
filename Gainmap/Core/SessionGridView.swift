//
//  SessionGridView.swift
//  GainmapCore
//
//  P5: the shared session grid — cover mosaics + sync badges. Platform-
//  agnostic SwiftUI; the host supplies resolved thumb URLs (the iOS app
//  hydrates them through the SyncEngine, the Mac reads them off disk in P7).
//

import Foundation
import SwiftUI

/// One tile of the grid — a display model the host derives from Session (+
/// engine state), so the view stays dumb and shareable.
public struct SessionCard: Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let photoCount: Int
    public let updatedAt: Date
    /// Up to 4 local thumb file URLs (already hydrated; nil slots = no thumb).
    public let covers: [URL?]
    /// True while local edits/uploads for this session haven't fully synced.
    public let pendingSync: Bool
    /// True when this session owns parked/quota work or a recoverable conflict.
    public let syncIssue: Bool
    /// Byte-weighted completion of this session's known upload work.
    public let syncProgress: Double
    /// Persisted converged metadata plus server-owned blob ledgers prove this
    /// exact local state reached the cloud. This lets a cold launch restore
    /// its last truthful green state before the first network reply.
    public let knownSynced: Bool

    public init(id: UUID, title: String, photoCount: Int, updatedAt: Date,
                covers: [URL?], pendingSync: Bool, syncIssue: Bool = false,
                syncProgress: Double? = nil, knownSynced: Bool = false) {
        self.id = id
        self.title = title
        self.photoCount = photoCount
        self.updatedAt = updatedAt
        self.covers = Array(covers.prefix(4))
        self.pendingSync = pendingSync
        self.syncIssue = syncIssue
        self.syncProgress = min(max(
            syncProgress ?? (pendingSync ? 0 : 1), 0), 1)
        self.knownSynced = knownSynced
    }
}

/// Truthful, per-session status used by both editors. The platform owns auth
/// state, while this shared projection keeps Mac and iPhone from disagreeing
/// about what a card's persisted sync evidence means.
public enum SessionEditorSyncState: Equatable {
    case localOnly
    case connecting
    case pending(Double)
    case synced
    case issue(Double)
    case unavailable

    public static func resolve(
        card: SessionCard?,
        localOnly: Bool,
        unavailable: Bool,
        initialSyncComplete: Bool,
        hasUnflushedChanges: Bool
    ) -> SessionEditorSyncState {
        if localOnly { return .localOnly }
        if unavailable { return .unavailable }
        if hasUnflushedChanges { return .pending(0) }
        if let card {
            if card.syncIssue { return .issue(card.syncProgress) }
            if card.pendingSync { return .pending(card.syncProgress) }
            // Persisted acknowledgement proof survives a cold launch, so do
            // not flash a previously synced session back to "connecting".
            if card.knownSynced { return .synced }
        }
        return initialSyncComplete ? .pending(0) : .connecting
    }

    public var label: String {
        switch self {
        case .localOnly: return "LOCAL ONLY"
        case .connecting: return "CONNECTING"
        case .pending(let progress):
            let percent = Int((Self.clamp(progress) * 100).rounded())
            return percent > 0 ? "SYNCING \(percent)%" : "NOT SYNCED"
        case .synced: return "SYNCED"
        case .issue: return "SYNC ISSUE"
        case .unavailable: return "SYNC UNAVAILABLE"
        }
    }

    public var accessibilityDescription: String {
        switch self {
        case .localOnly:
            return "Saved on this device only."
        case .connecting:
            return "Connecting to sync."
        case .pending(let progress):
            let percent = Int((Self.clamp(progress) * 100).rounded())
            return percent > 0
                ? "Syncing this session, \(percent) percent complete."
                : "This session has not synced yet."
        case .synced:
            return "This session is up to date."
        case .issue:
            return "This session needs sync attention."
        case .unavailable:
            return "Sync is currently unavailable."
        }
    }

    fileprivate var clampedProgress: Double? {
        switch self {
        case .pending(let progress), .issue(let progress):
            return Self.clamp(progress)
        case .synced:
            return 1
        case .localOnly, .connecting, .unavailable:
            return nil
        }
    }

    fileprivate static func clamp(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }
}

/// Compact perimeter trace for an editor emblem or toolbar control. Pending
/// states are determinate and use the same warm-to-green history as session
/// cards; only a genuine connection handshake is indeterminate.
public struct SessionSyncRing: View {
    public let state: SessionEditorSyncState
    public let lineWidth: CGFloat

    public init(
        state: SessionEditorSyncState,
        lineWidth: CGFloat = 2.5
    ) {
        self.state = state
        self.lineWidth = lineWidth
    }

    private var progressSpectrum: AngularGradient {
        AngularGradient(
            stops: [
                .init(color: Theme.accent, location: 0.00),
                .init(color: Theme.accentHot, location: 0.10),
                .init(color: Theme.gold, location: 0.24),
                .init(color: Theme.gold, location: 0.32),
                .init(color: Theme.syncGreen, location: 0.42),
                .init(color: Theme.syncGreen, location: 0.88),
                .init(color: Theme.accent, location: 1.00),
            ],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270))
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.line, lineWidth: max(1, lineWidth - 0.5))
            trace
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trace: some View {
        switch state {
        case .connecting:
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let turn = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.35) / 1.35
                Circle()
                    .trim(from: 0.03, to: 0.36)
                    .stroke(
                        Theme.gold,
                        style: StrokeStyle(
                            lineWidth: lineWidth,
                            lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
        case .pending(let rawProgress):
            let progress = SessionEditorSyncState.clamp(rawProgress)
            Circle()
                .trim(from: 0, to: max(progress, 0.025))
                .stroke(
                    progressSpectrum,
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round))
                .rotationEffect(.degrees(90))
        case .synced:
            Circle()
                .stroke(progressSpectrum, lineWidth: lineWidth)
                .rotationEffect(.degrees(90))
        case .issue(let rawProgress):
            Circle()
                .stroke(
                    Color.red.opacity(0.68),
                    style: StrokeStyle(
                        lineWidth: max(1, lineWidth - 0.5),
                        dash: [3, 3]))
            let progress = SessionEditorSyncState.clamp(rawProgress)
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color.red,
                        style: StrokeStyle(
                            lineWidth: lineWidth,
                            lineCap: .round))
                    .rotationEffect(.degrees(90))
            }
        case .localOnly:
            Circle()
                .stroke(
                    Theme.stoneFaint,
                    style: StrokeStyle(
                        lineWidth: max(1, lineWidth - 0.5),
                        dash: [2, 4]))
        case .unavailable:
            Circle()
                .stroke(
                    Theme.warn,
                    style: StrokeStyle(
                        lineWidth: max(1, lineWidth - 0.5),
                        dash: [4, 3]))
        }
    }
}

public enum SessionCardSyncState: Equatable {
    case neutral
    case synced
    case pending(Double)
    case issue(Double)

    fileprivate var progress: Double? {
        switch self {
        case .neutral: return nil
        case .synced: return 1
        case .pending(let progress), .issue(let progress):
            return min(max(progress, 0), 1)
        }
    }

    fileprivate var color: Color {
        switch self {
        case .neutral: return Theme.line
        case .synced: return Theme.syncGreen
        case .pending: return Theme.gold
        case .issue: return .red
        }
    }

    fileprivate var usesProgressSpectrum: Bool {
        switch self {
        case .synced, .pending: return true
        case .neutral, .issue: return false
        }
    }

    fileprivate var cardLabel: String? {
        switch self {
        case .neutral:
            return "LOCAL ONLY"
        case .synced:
            return nil
        case .pending(let progress):
            let clamped = min(max(progress, 0), 1)
            guard clamped > 0.005 else { return "NOT SYNCED" }
            return "SYNCING \(Int((clamped * 100).rounded()))%"
        case .issue:
            return "SYNC ISSUE"
        }
    }

    fileprivate var labelColor: Color {
        switch self {
        case .neutral: return Theme.stoneDim
        case .synced: return Theme.syncGreen
        case .pending: return Theme.gold
        case .issue: return .red
        }
    }

    fileprivate var accessibilityStatus: String {
        switch self {
        case .neutral:
            return "Local only, not synced"
        case .synced:
            return "Synced"
        case .pending(let progress):
            let percent = Int((min(max(progress, 0), 1) * 100).rounded())
            return percent > 0 ? "Syncing, \(percent) percent" : "Not synced"
        case .issue:
            return "Sync needs attention"
        }
    }
}

/// Shared Mac/iOS projection of persisted sync work into per-session
/// progress. File uploads are byte-weighted; pending metadata keeps a card
/// below 100% until the server acknowledges it.
public struct SessionSyncMetrics {
    public let pendingSessionIDs: Set<UUID>
    public let issueSessionIDs: Set<UUID>
    public let progressBySessionID: [UUID: Double]
    public let knownSyncedSessionIDs: Set<UUID>

    public static func calculate(
        sessions: [Session],
        journal: ChangeJournal?,
        transfers: TransferQueue?,
        persistedSyncedSessionIDs: Set<UUID> = []
    ) -> SessionSyncMetrics {
        let pendingMetadataSessionIDs = Set(
            (journal?.entries ?? []).compactMap { sessionID(for: $0.target) })
        let conflictedSessionIDs = Set(
            (journal?.conflicts ?? []).compactMap { sessionID(for: $0.target) })
        let allTransfers = transfers?.transfers ?? []
        var pending = Set<UUID>()
        var issues = Set<UUID>()
        var progress: [UUID: Double] = [:]
        var knownSynced = Set<UUID>()

        for session in sessions {
            let hashes = Set(session.photos.compactMap(\.contentHash))
            let related = allTransfers.filter { hashes.contains($0.contentHash) }
            let metadataIsPending = pendingMetadataSessionIDs.contains(session.id)
            let uploadsArePending = related.contains { $0.status != .done }
            let conflictNeedsAttention = conflictedSessionIDs.contains(session.id)
            let uploadNeedsAttention = related.contains {
                $0.status == .parked || $0.status == .quotaExceeded
            }
            let needsAttention = conflictNeedsAttention || uploadNeedsAttention

            guard metadataIsPending || uploadsArePending || needsAttention else {
                progress[session.id] = 1
                if persistedSyncedSessionIDs.contains(session.id) {
                    knownSynced.insert(session.id)
                }
                continue
            }

            pending.insert(session.id)
            if needsAttention { issues.insert(session.id) }
            if conflictNeedsAttention && !metadataIsPending && !uploadsArePending {
                progress[session.id] = 0
                continue
            }
            let totalBytes = related.reduce(Int64(0)) { $0 + max($1.byteSize, 0) }
            let completedBytes = related.reduce(Int64(0)) { sum, transfer in
                sum + (transfer.status == .done
                       ? max(transfer.byteSize, 0)
                       : min(max(transfer.bytesTransferred, 0),
                             max(transfer.byteSize, 0)))
            }
            var fraction = totalBytes > 0
                ? Double(completedBytes) / Double(totalBytes)
                : 0
            if metadataIsPending {
                fraction = min(fraction, 0.99)
            }
            progress[session.id] = min(max(fraction, 0), 1)
        }

        return SessionSyncMetrics(
            pendingSessionIDs: pending,
            issueSessionIDs: issues,
            progressBySessionID: progress,
            knownSyncedSessionIDs: knownSynced)
    }

    private static func sessionID(for target: SyncTarget) -> UUID? {
        switch target {
        case .session(let id), .photo(let id, _): return id
        case .user: return nil
        }
    }
}

// MARK: - Cloud Sync presentation

/// A single, platform-neutral vocabulary for Cloud Sync. Both apps project
/// the auth/backend model through this type so an entitlement can never read
/// as both "on" and "not connected" in different parts of the UI.
public enum CloudSyncDisplayKind: Equatable, Sendable {
    case signedOut
    case signInFailed
    case checking
    case enabled
    case needsPatreon
    case inactive
    case grace
    case waitlist
    case setupPending
    case unavailable
}

public enum CloudSyncDisplayAction: Equatable, Sendable {
    case none
    case signIn
    case connectPatreon
    case switchPatreon
    case retry

    public var label: String? {
        switch self {
        case .none: return nil
        case .signIn: return "Set Up Cloud Sync"
        case .connectPatreon: return "Connect Patreon"
        case .switchPatreon: return "Try Another Patreon Account"
        case .retry: return "Refresh Status"
        }
    }
}

public struct CloudSyncDisplayState: Equatable, Sendable {
    public let kind: CloudSyncDisplayKind
    public let title: String
    public let detail: String
    public let action: CloudSyncDisplayAction
    public let graceExpiresAt: Date?

    public init(
        kind: CloudSyncDisplayKind,
        title: String,
        detail: String,
        action: CloudSyncDisplayAction,
        graceExpiresAt: Date? = nil
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.action = action
        self.graceExpiresAt = graceExpiresAt
    }

    public static func resolve(
        authState: AuthState,
        access: CloudSyncAccess?,
        signedInEmail: String? = nil,
        preferPatreonAccountSwitch: Bool = false
    ) -> CloudSyncDisplayState {
        switch authState {
        case .signedOut:
            return .init(
                kind: .signedOut,
                title: "Set up Cloud Sync",
                detail: "Sign in to sync sessions and photos between iPhone and Mac.",
                action: .signIn)
        case .failed:
            return .init(
                kind: .signInFailed,
                title: "Sign-in failed",
                detail: "Try Apple or Google again.",
                action: .signIn)
        case .checking:
            return .init(
                kind: .checking,
                title: "Checking Patreon…",
                detail: "Verifying Cloud Sync access.",
                action: .none)
        case .ready, .localOnly:
            break
        }

        guard let access else {
            return .init(
                kind: .unavailable,
                title: "Couldn’t check access",
                detail: "Your local sessions are safe. Try again.",
                action: .retry)
        }

        if access.canSync {
            if access.entitlement.status == .grace {
                return .init(
                    kind: .grace,
                    title: "Cloud Sync is temporarily on",
                    detail: "Patreon access is being rechecked.",
                    action: .none,
                    graceExpiresAt: access.entitlement.graceExpiresAt)
            }
            switch access.entitlement.source {
            case .patreonEmail:
                let email = signedInEmail?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                return .init(
                    kind: .enabled,
                    title: "Membership verified",
                    detail: email.map { "Cloud Sync is on for \($0)." }
                        ?? "Cloud Sync is on.",
                    action: .none)
            case .patreonOAuth:
                return .init(
                    kind: .enabled,
                    title: "Patreon connected",
                    detail: "Cloud Sync is on.",
                    action: .none)
            case .none:
                return .init(
                    kind: .enabled,
                    title: "Cloud Sync is on",
                    detail: "Patreon access verified.",
                    action: .none)
            }
        }

        if access.isWaitlisted {
            return .init(
                kind: .waitlist,
                title: "Patreon verified",
                detail: "Cloud Sync is full right now. You’re on the waitlist.",
                action: .retry)
        }

        if access.entitlement.effective {
            return .init(
                kind: .setupPending,
                title: "Patreon verified",
                detail: "Cloud Sync setup didn’t finish. Try again.",
                action: .retry)
        }

        switch access.entitlement.status {
        case .unlinked:
            let action: CloudSyncDisplayAction
            if preferPatreonAccountSwitch {
                action = .switchPatreon
            } else {
                switch access.entitlement.connectionAction {
                case .switchAccount: action = .switchPatreon
                case .connect, .none: action = .connectPatreon
                }
            }
            return .init(
                kind: .needsPatreon,
                title: action == .switchPatreon
                    ? "Try another Patreon account" : "Connect Patreon",
                detail: action == .switchPatreon
                    ? "Use a different Patreon account, or refresh after reactivating."
                    : "No active membership matched this sign-in. Your Patreon email can be different.",
                action: action)
        case .inactive:
            return .init(
                kind: .inactive,
                title: "Membership not active",
                detail: "Try another Patreon account or check again after reactivating.",
                action: .switchPatreon)
        case .active, .grace, .error:
            return .init(
                kind: .unavailable,
                title: "Couldn’t check access",
                detail: "Your local sessions are safe. Try again.",
                action: .retry)
        }
    }
}

// MARK: - Empty-library coachmark

/// Pure rules for the versioned, deliberately short-lived onboarding nudge.
/// A future copy/design revision can use a new key without conflating its two
/// eligible launches with this version's impressions.
public enum EmptyLibraryCloudCoachmarkPolicy {
    public static let impressionsKey =
        "gainmap.empty-library-cloud-coachmark.impressions.v1"
    public static let maximumImpressions = 2

    public static func isEligible(
        libraryIsEmpty: Bool,
        signedOut: Bool,
        impressionCount: Int
    ) -> Bool {
        libraryIsEmpty
            && signedOut
            && max(0, impressionCount) < maximumImpressions
    }
}

/// Process-level claim around the pure policy. SwiftUI may rebuild a root view
/// many times, but an eligible app launch consumes at most one impression.
/// Observing any real session exhausts this version permanently, so deleting a
/// library later cannot make first-run coaching return.
@MainActor
public enum EmptyLibraryCloudCoachmarkGate {
    private static var launchDecision: Bool?

    public static func visibility(
        libraryIsEmpty: Bool,
        signedOut: Bool,
        authStateRestored: Bool = true,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard authStateRestored else { return false }
        guard libraryIsEmpty else {
            complete(defaults: defaults)
            return false
        }
        guard signedOut else {
            // Once shown, an auth attempt suppresses the nudge for the rest of
            // this process even if the user signs out again immediately.
            if launchDecision != nil { launchDecision = false }
            return false
        }
        if let launchDecision { return launchDecision }

        let count = defaults.integer(
            forKey: EmptyLibraryCloudCoachmarkPolicy.impressionsKey)
        let shouldShow = EmptyLibraryCloudCoachmarkPolicy.isEligible(
            libraryIsEmpty: true,
            signedOut: true,
            impressionCount: count)
        if shouldShow {
            defaults.set(
                min(count + 1,
                    EmptyLibraryCloudCoachmarkPolicy.maximumImpressions),
                forKey: EmptyLibraryCloudCoachmarkPolicy.impressionsKey)
        }
        launchDecision = shouldShow
        return shouldShow
    }

    public static func complete(defaults: UserDefaults = .standard) {
        defaults.set(
            EmptyLibraryCloudCoachmarkPolicy.maximumImpressions,
            forKey: EmptyLibraryCloudCoachmarkPolicy.impressionsKey)
        launchDecision = false
    }

    static func resetForTesting() {
        launchDecision = nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public struct SessionGridView: View {
    let cards: [SessionCard]
    let onCreate: (() -> Void)?
    let onOpen: (UUID) -> Void
    let onExport: ((UUID) -> Void)?
    let onRename: ((SessionCard) -> Void)?
    let onDelete: ((UUID) -> Void)?
    let syncState: ((SessionCard) -> SessionCardSyncState)?
    let showsCloudSyncCoachmark: Bool
    let onSetUpCloudSync: (() -> Void)?

    public init(cards: [SessionCard],
                onCreate: (() -> Void)? = nil,
                onOpen: @escaping (UUID) -> Void,
                onExport: ((UUID) -> Void)? = nil,
                onRename: ((SessionCard) -> Void)? = nil,
                onDelete: ((UUID) -> Void)? = nil,
                syncState: ((SessionCard) -> SessionCardSyncState)? = nil,
                showsCloudSyncCoachmark: Bool = false,
                onSetUpCloudSync: (() -> Void)? = nil) {
        self.cards = cards
        self.onCreate = onCreate
        self.onOpen = onOpen
        self.onExport = onExport
        self.onRename = onRename
        self.onDelete = onDelete
        self.syncState = syncState
        self.showsCloudSyncCoachmark = showsCloudSyncCoachmark
        self.onSetUpCloudSync = onSetUpCloudSync
    }

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 260), spacing: 14)]

    public var body: some View {
        GeometryReader { geometry in
            ScrollView {
                ZStack(alignment: .top) {
                    if cards.isEmpty {
                        EmptyLibraryBackdrop(
                            showsCloudSyncCoachmark: showsCloudSyncCoachmark,
                            onSetUpCloudSync: onSetUpCloudSync)
                            .frame(maxWidth: .infinity)
                            .frame(height: max(geometry.size.height, 460))
                    }

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(cards) { card in
                            cardButton(card)
                        }
                        if let onCreate {
                            Button(action: onCreate) {
                                NewSessionCardView()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("New Session")
                            .accessibilityHint("Choose photos to start a new session")
                        }
                    }
                    .padding(16)
                }
                .frame(width: geometry.size.width)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
    }

    @ViewBuilder
    private func cardButton(_ card: SessionCard) -> some View {
        let button = Button { onOpen(card.id) } label: {
            SessionCardView(
                card: card,
                syncState: syncState?(card)
                    ?? (card.pendingSync
                        ? .pending(card.syncProgress)
                        : .neutral))
        }
        .buttonStyle(.plain)

        if onExport != nil || onRename != nil || onDelete != nil {
            button.contextMenu {
                if let onExport {
                    Button("Export All…", systemImage: "square.and.arrow.up.on.square") {
                        onExport(card.id)
                    }
                }
                if let onRename {
                    Button("Rename…", systemImage: "pencil") { onRename(card) }
                }
                if onDelete != nil && (onExport != nil || onRename != nil) {
                    Divider()
                }
                if let onDelete {
                    Button("Delete Session", systemImage: "trash", role: .destructive) {
                        onDelete(card.id)
                    }
                }
            }
        } else {
            button
        }
    }
}

private struct EmptyLibraryBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let showsCloudSyncCoachmark: Bool
    let onSetUpCloudSync: (() -> Void)?
    @State private var pulse = false

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Theme.accent.opacity(0.09), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 270)
                .accessibilityHidden(true)

            VStack(spacing: 24) {
                Spacer(minLength: 175)
                GainmapEmblem()
                    .frame(maxWidth: 280)
                    .padding(.horizontal, 58)
                    .opacity(0.12)
                    .saturation(0.72)
                    .shadow(color: Theme.accent.opacity(0.18), radius: 30)
                    .accessibilityHidden(true)

                if showsCloudSyncCoachmark, let onSetUpCloudSync {
                    Button(action: onSetUpCloudSync) {
                        HStack(spacing: 10) {
                            Image(systemName: "icloud")
                                .font(.system(size: 15, weight: .semibold))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Set Up Cloud Sync")
                                    .font(Theme.ui(13, .semibold))
                                Text("OPTIONAL")
                                    .font(Theme.mono(8, .bold))
                                    .tracking(1)
                                    .foregroundStyle(Theme.stoneDim)
                            }
                        }
                        .foregroundStyle(Theme.stone)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(
                            Theme.surface.opacity(0.96),
                            in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(
                                    Theme.accent.opacity(
                                        reduceMotion ? 0.72
                                            : (pulse ? 0.9 : 0.35)),
                                    lineWidth: reduceMotion ? 2 : 1.5)
                        }
                        .shadow(
                            color: Theme.accent.opacity(
                                reduceMotion ? 0.12 : (pulse ? 0.28 : 0.08)),
                            radius: pulse && !reduceMotion ? 14 : 5)
                        .scaleEffect(
                            reduceMotion ? 1 : (pulse ? 1.025 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(
                        "Sign in to sync sessions and photos between iPhone and Mac")
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(
                            .easeInOut(duration: 1.15)
                                .repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
                    .onChange(of: reduceMotion) { _, reduced in
                        if reduced { pulse = false }
                    }
                }
                Spacer(minLength: 36)
            }
        }
    }
}

private struct NewSessionCardView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Theme.inset
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.gold)
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("New Session")
                    .font(Theme.ui(14, .semibold))
                    .foregroundStyle(Theme.stone)
                    .lineLimit(1)
                Text("CHOOSE PHOTOS")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.stoneDim)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.surface.opacity(0.24),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.line, lineWidth: 2)
        }
    }
}

/// A rounded perimeter whose trim origin is the bottom-left corner. SwiftUI's
/// built-in RoundedRectangle path begins elsewhere, which made partial sync
/// traces appear to start arbitrarily along the top edge.
private struct BottomLeftRoundedRectangle: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(
            cornerRadius,
            max(0, min(rect.width, rect.height) / 2))
        var path = Path()
        path.move(to: CGPoint(
            x: rect.minX + radius,
            y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY),
            radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY),
            radius: radius)
        path.closeSubpath()
        return path
    }
}

struct SessionCardView: View {
    let card: SessionCard
    let syncState: SessionCardSyncState

    /// A completed trace keeps its warm starting history, then resolves into
    /// the calmer sync green. Pending cards reveal the same spectrum
    /// progressively; issues remain unambiguously red.
    private var progressSpectrum: AngularGradient {
        AngularGradient(
            stops: [
                .init(color: Theme.accent, location: 0.00),
                .init(color: Theme.accentHot, location: 0.10),
                .init(color: Theme.gold, location: 0.24),
                .init(color: Theme.gold, location: 0.32),
                .init(color: Theme.syncGreen, location: 0.42),
                .init(color: Theme.syncGreen, location: 0.88),
                // Match the first stop at the angular wrap, giving the green
                // a soft return to coral instead of a hard seam.
                .init(color: Theme.accent, location: 1.00),
            ],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverMosaic(covers: card.covers)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title.isEmpty ? "Untitled session" : card.title)
                    .font(Theme.ui(14, .semibold)).foregroundStyle(Theme.stone)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    HStack(spacing: 5) {
                        Text("\(card.photoCount) photo\(card.photoCount == 1 ? "" : "s")")
                        Text("·")
                        Text(card.updatedAt, style: .relative)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    if let label = syncState.cardLabel {
                        Text(label)
                            .font(Theme.mono(8, .bold))
                            .tracking(0.35)
                            .foregroundStyle(syncState.labelColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                syncState.labelColor.opacity(0.14),
                                in: Capsule())
                            .accessibilityLabel(syncState.accessibilityStatus)
                    }
                }
                .font(Theme.mono(10)).foregroundStyle(Theme.stoneDim)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.24),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    syncState == .neutral
                        ? Theme.line
                        : (syncState == .synced
                           ? Theme.line
                           : syncState.color.opacity(0.22)),
                    lineWidth: 2)
            if let progress = syncState.progress, progress > 0 {
                if syncState.usesProgressSpectrum {
                    BottomLeftRoundedRectangle(cornerRadius: 16)
                        .trim(from: 0, to: progress)
                        .stroke(
                            progressSpectrum,
                            style: StrokeStyle(
                                lineWidth: 2.5, lineCap: .round))
                } else {
                    BottomLeftRoundedRectangle(cornerRadius: 16)
                        .trim(from: 0, to: progress)
                        .stroke(
                            syncState.color,
                            style: StrokeStyle(
                                lineWidth: 2.5, lineCap: .round))
                }
            }
        }
        .shadow(
            color: syncState.color.opacity(
                syncState == .neutral ? 0
                    : (syncState == .synced ? 0.05 : 0.12)),
            radius: 5)
    }
}

/// 2x2 mosaic (1 photo = full bleed, 2 = split, 3 = one tall + two, 4 = quad).
struct CoverMosaic: View {
    let covers: [URL?]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, gap: CGFloat = 2
            ZStack {
                Theme.inset
                switch covers.count {
                case 0:
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.stoneFaint)
                case 1:
                    tile(covers[0], CGSize(width: w, height: h))
                case 2:
                    HStack(spacing: gap) {
                        tile(covers[0], CGSize(width: (w - gap) / 2, height: h))
                        tile(covers[1], CGSize(width: (w - gap) / 2, height: h))
                    }
                case 3:
                    HStack(spacing: gap) {
                        tile(covers[0], CGSize(width: (w - gap) / 2, height: h))
                        VStack(spacing: gap) {
                            tile(covers[1], CGSize(width: (w - gap) / 2, height: (h - gap) / 2))
                            tile(covers[2], CGSize(width: (w - gap) / 2, height: (h - gap) / 2))
                        }
                    }
                default:
                    VStack(spacing: gap) {
                        HStack(spacing: gap) {
                            tile(covers[0], CGSize(width: (w - gap) / 2, height: (h - gap) / 2))
                            tile(covers[1], CGSize(width: (w - gap) / 2, height: (h - gap) / 2))
                        }
                        HStack(spacing: gap) {
                            tile(covers[2], CGSize(width: (w - gap) / 2, height: (h - gap) / 2))
                            tile(covers[3], CGSize(width: (w - gap) / 2, height: (h - gap) / 2))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tile(_ url: URL?, _ size: CGSize) -> some View {
        CoverTile(url: url)
            .frame(width: size.width, height: size.height)
            .clipped()
    }
}

/// One mosaic cell: decodes OFF the main thread with a small shared cache.
/// Decoding synchronously inside `body` blocked the main thread for up to
/// four JPEG decodes per card per layout pass (P5 review).
struct CoverTile: View {
    let url: URL?

    @State private var image: CGImage?

    /// Decoded-tile cache shared across the grid; NSCache evicts under
    /// memory pressure on its own.
    private static let cache = NSCache<NSURL, CGImage>()

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.inset
                Image(systemName: "photo")
                    .font(.system(size: 14)).foregroundStyle(Theme.stoneFaint)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = Self.cache.object(forKey: url as NSURL) {
                image = hit
                return
            }
            let decoded = await Task.detached(priority: .utility) {
                Self.decode(url, maxPixel: 400)
            }.value
            if let decoded {
                Self.cache.setObject(decoded, forKey: url as NSURL)
                image = decoded
            }
        }
    }

    nonisolated private static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
