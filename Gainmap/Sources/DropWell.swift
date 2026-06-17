//
//  DropWell.swift
//  Gainmap
//
//  One input "plate" on the fusion bench. Accepts a file by drag-and-drop or
//  click-to-browse, shows a thumbnail + filename + pixel dimensions once filled,
//  and lights its border in accent-red on drag-over. The HDR plate renders warm
//  and luminous; the SDR plate renders the same scene muted — the visual story
//  of the merge.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import ImageIO

struct DropWell: View {
    let role: FileRole
    let url: URL?
    var onPick: (URL) -> Void = { _ in }
    /// When set, the well accepts multiple files (drop or browse) and routes them
    /// here instead of `onPick` — used to seed/extend the auto-mode queue.
    var onPickMany: (([URL]) -> Void)? = nil

    @State private var hovering = false
    @State private var thumb: NSImage?
    @State private var pixelSize: CGSize?

    private var title: String { role == .hdr ? "HDR · TIFF" : "SDR · JPEG" }
    private var emptyPrompt: String { role == .hdr ? "Drop the HDR .tif" : "Drop the SDR .jpg" }

    var body: some View {
        VStack(spacing: 0) {
            thumbArea
            metaArea
        }
        .background(
            LinearGradient(colors: [Theme.surface, Theme.surfaceHi],
                           startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(hovering ? Theme.accent : Theme.line,
                        lineWidth: hovering ? 2 : 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 10)
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .contentShape(Rectangle())
        .onTapGesture(perform: browse)
        .onDrop(of: [.fileURL], isTargeted: $hovering, perform: handleDrop)
        .onChange(of: url) { _, new in loadPreview(new) }
        .onAppear { loadPreview(url) }
        .help(emptyPrompt)
    }

    // MARK: Thumb

    private var thumbArea: some View {
        ZStack {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholderGradient
                if url == nil {
                    VStack(spacing: 10) {
                        GainmapEmblem().frame(width: 34, height: 34).opacity(0.5)
                        Text(emptyPrompt)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.stoneDim)
                    }
                }
            }
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .topLeading) { badge }
    }

    private var placeholderGradient: some View {
        Group {
            if role == .hdr {
                LinearGradient(stops: [
                    .init(color: Color(hex: 0x3A2D22), location: 0),
                    .init(color: Color(hex: 0x8A5A32), location: 0.38),
                    .init(color: Theme.gold, location: 0.70),
                    .init(color: Color(hex: 0xFFF6E6), location: 1.0),
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                LinearGradient(stops: [
                    .init(color: Color(hex: 0x2F2722), location: 0),
                    .init(color: Color(hex: 0x6B4D36), location: 0.45),
                    .init(color: Color(hex: 0xB89A72), location: 0.78),
                    .init(color: Color(hex: 0xCDBFA6), location: 1.0),
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
                .saturation(0.82)
                .brightness(-0.04)
            }
        }
    }

    private var badge: some View {
        Text(title)
            .font(Theme.mono(10, .semibold))
            .tracking(1.2)
            .foregroundStyle(role == .hdr ? .white : Theme.stone)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                (role == .hdr ? Theme.accent.opacity(0.92) : Theme.inset.opacity(0.7)),
                in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(role == .hdr ? .clear : Theme.stoneFaint, lineWidth: 1))
            .padding(10)
    }

    // MARK: Meta

    private var metaArea: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(url?.lastPathComponent ?? "—")
                .font(Theme.ui(12.5, .medium))
                .foregroundStyle(url == nil ? Theme.stoneDim : .white)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                Text(pixelSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "no file")
                    .foregroundStyle(Theme.stoneDim)
                Text(role == .hdr ? "32-bit float" : "sRGB · JPEG")
                    .foregroundStyle(Theme.goldDeep)
            }
            .font(Theme.mono(10.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.vertical, 11)
    }

    // MARK: Actions

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = onPickMany != nil
        panel.canChooseDirectories = false
        panel.allowedContentTypes = role == .hdr ? [.tiff] : [.jpeg]
        panel.prompt = "Choose"
        panel.message = role == .hdr
            ? "Choose the 32-bit float HDR TIFF"
            : (onPickMany != nil ? "Choose SDR JPEGs to add to the queue" : "Choose the SDR JPEG")
        guard panel.runModal() == .OK else { return }
        if let many = onPickMany {
            many(panel.urls)
        } else if let picked = panel.url {
            onPick(picked)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        if let many = onPickMany {
            var urls = [URL?](repeating: nil, count: providers.count)
            let group = DispatchGroup()
            for (i, p) in providers.enumerated() {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { u, _ in urls[i] = u; group.leave() }
            }
            group.notify(queue: .main) { many(urls.compactMap { $0 }) }
            return true
        }
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { onPick(url) }
        }
        return true
    }

    private func loadPreview(_ url: URL?) {
        guard let url else { thumb = nil; pixelSize = nil; return }
        pixelSize = ImageInfo.pixelSize(of: url)
        Task.detached(priority: .userInitiated) {
            let image = ImageInfo.thumbnail(of: url, maxPixel: 600)
            await MainActor.run { self.thumb = image }
        }
    }
}

// MARK: - ImageIO helpers

enum ImageInfo {
    /// Pixel dimensions without a full decode (reads the header only).
    static func pixelSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Fast downsampled thumbnail via ImageIO (handles JPEG and float TIFF).
    static func thumbnail(of url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
