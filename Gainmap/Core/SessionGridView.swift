//
//  SessionGridView.swift
//  GainmapCore
//
//  P5: the shared session grid — cover mosaics + sync badges. Platform-
//  agnostic SwiftUI; the host supplies resolved thumb URLs (the iOS app
//  hydrates them through the SyncEngine, the Mac reads them off disk in P7).
//

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
    /// Byte-weighted completion of this session's known upload work.
    public let syncProgress: Double

    public init(id: UUID, title: String, photoCount: Int, updatedAt: Date,
                covers: [URL?], pendingSync: Bool, syncProgress: Double? = nil) {
        self.id = id
        self.title = title
        self.photoCount = photoCount
        self.updatedAt = updatedAt
        self.covers = Array(covers.prefix(4))
        self.pendingSync = pendingSync
        self.syncProgress = min(max(
            syncProgress ?? (pendingSync ? 0 : 1), 0), 1)
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
}

/// Shared Mac/iOS projection of persisted sync work into per-session
/// progress. File uploads are byte-weighted; pending metadata keeps a card
/// below 100% until the server acknowledges it.
public struct SessionSyncMetrics {
    public let pendingSessionIDs: Set<UUID>
    public let progressBySessionID: [UUID: Double]

    public static func calculate(
        sessions: [Session],
        journal: ChangeJournal?,
        transfers: TransferQueue?
    ) -> SessionSyncMetrics {
        let pendingMetadataSessionIDs = Set(
            (journal?.entries ?? []).compactMap { sessionID(for: $0.target) })
        let allTransfers = transfers?.transfers ?? []
        var pending = Set<UUID>()
        var progress: [UUID: Double] = [:]

        for session in sessions {
            let hashes = Set(session.photos.compactMap(\.contentHash))
            let related = allTransfers.filter { hashes.contains($0.contentHash) }
            let metadataIsPending = pendingMetadataSessionIDs.contains(session.id)
            let uploadsArePending = related.contains { $0.status != .done }

            guard metadataIsPending || uploadsArePending else {
                progress[session.id] = 1
                continue
            }

            pending.insert(session.id)
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
            progressBySessionID: progress)
    }

    private static func sessionID(for target: SyncTarget) -> UUID? {
        switch target {
        case .session(let id), .photo(let id, _): return id
        case .user: return nil
        }
    }
}

public struct SessionGridView: View {
    let cards: [SessionCard]
    let onOpen: (UUID) -> Void
    let onExport: ((UUID) -> Void)?
    let onRename: ((SessionCard) -> Void)?
    let onDelete: ((UUID) -> Void)?
    let syncState: ((SessionCard) -> SessionCardSyncState)?

    public init(cards: [SessionCard],
                onOpen: @escaping (UUID) -> Void,
                onExport: ((UUID) -> Void)? = nil,
                onRename: ((SessionCard) -> Void)? = nil,
                onDelete: ((UUID) -> Void)? = nil,
                syncState: ((SessionCard) -> SessionCardSyncState)? = nil) {
        self.cards = cards
        self.onOpen = onOpen
        self.onExport = onExport
        self.onRename = onRename
        self.onDelete = onDelete
        self.syncState = syncState
    }

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 260), spacing: 14)]

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(cards) { card in
                    cardButton(card)
                }
            }
            .padding(16)
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

struct SessionCardView: View {
    let card: SessionCard
    let syncState: SessionCardSyncState

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
                    Text("\(card.photoCount) photo\(card.photoCount == 1 ? "" : "s")")
                    Text("·")
                    Text(card.updatedAt, style: .relative)
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
                        : syncState.color.opacity(0.22),
                    lineWidth: 2)
            if let progress = syncState.progress, progress > 0 {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .trim(from: 0, to: progress)
                    .stroke(
                        syncState.color,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
        .shadow(
            color: syncState.color.opacity(syncState == .neutral ? 0 : 0.12),
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
