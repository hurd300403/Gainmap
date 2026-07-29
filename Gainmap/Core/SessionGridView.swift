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

    public init(id: UUID, title: String, photoCount: Int, updatedAt: Date,
                covers: [URL?], pendingSync: Bool) {
        self.id = id
        self.title = title
        self.photoCount = photoCount
        self.updatedAt = updatedAt
        self.covers = Array(covers.prefix(4))
        self.pendingSync = pendingSync
    }
}

public struct SessionGridView: View {
    let cards: [SessionCard]
    let onOpen: (UUID) -> Void

    public init(cards: [SessionCard], onOpen: @escaping (UUID) -> Void) {
        self.cards = cards
        self.onOpen = onOpen
    }

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 260), spacing: 14)]

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(cards) { card in
                    Button { onOpen(card.id) } label: {
                        SessionCardView(card: card)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }
}

struct SessionCardView: View {
    let card: SessionCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverMosaic(covers: card.covers)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if card.pendingSync {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.gold)
                            .padding(5)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title.isEmpty ? "Untitled session" : card.title)
                    .font(Theme.ui(14, .semibold)).foregroundStyle(Theme.stone)
                    .lineLimit(1)
                Text("\(card.photoCount) photo\(card.photoCount == 1 ? "" : "s")")
                    .font(Theme.mono(10)).foregroundStyle(Theme.stoneDim)
            }
        }
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

    private static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
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
