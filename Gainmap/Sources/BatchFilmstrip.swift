//
//  BatchFilmstrip.swift
//  Gainmap
//
//  The auto-mode queue strip: a horizontal row of photo thumbnails you step
//  through, each showing its save status (pending / merging / saved / error).
//  Tap to select; an "add" tile and a per-cell remove keep the queue editable.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BatchFilmstrip: View {
    @ObservedObject var model: MergeModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.items) { item in
                        FilmstripCell(item: item, selected: item.id == model.selectedID,
                                      onRemove: { model.remove(item.id) })
                            .id(item.id)
                            .onTapGesture { model.select(item.id) }
                    }
                    AddTile { model.addFiles($0) }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: 96)
    }
}

private let cellW: CGFloat = 96
private let cellH: CGFloat = 64

struct FilmstripCell: View {
    let item: MergeModel.BatchItem
    let selected: Bool
    var onRemove: () -> Void

    @State private var thumb: NSImage?
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                shape.fill(Theme.surfaceHi)
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: cellW, height: cellH)
            .clipShape(shape)
            .overlay(shape.stroke(selected ? Theme.accent : Theme.line,
                                  lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) { statusBadge.padding(4) }
            .overlay(alignment: .topLeading) {
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .help("Remove from queue")
                    .accessibilityLabel("Remove \(item.sdrURL.lastPathComponent) from queue")
                }
            }
            .shadow(color: .black.opacity(selected ? 0.4 : 0.25),
                    radius: selected ? 8 : 4, y: 3)

            Text(item.sdrURL.lastPathComponent)
                .font(Theme.mono(9))
                .foregroundStyle(selected ? .white : Theme.stoneDim)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: cellW)
        }
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
        .task(id: item.sdrURL) {
            let url = item.sdrURL
            let img = await Task.detached(priority: .userInitiated) {
                ImageInfo.thumbnail(of: url, maxPixel: 200)
            }.value
            thumb = img
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch item.status {
        case .pending:
            EmptyView()
        case .merging:
            ProgressView().controlSize(.small).tint(.white)
                .padding(3).background(.black.opacity(0.4), in: Circle())
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.inset, Theme.gold)
                .shadow(color: Theme.gold.opacity(0.5), radius: 4)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white, Theme.accentHot)
        }
    }
}

struct AddTile: View {
    var onPick: ([URL]) -> Void
    @State private var hovering = false
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                shape.fill(Theme.inset.opacity(0.6))
                GainmapAddEmblem(active: hovering)
                    .frame(height: cellH * 0.74)
                    .opacity(hovering ? 1 : 0.92)
            }
            .frame(width: cellW, height: cellH)
            .clipShape(shape)
            .overlay(shape.strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(hovering ? Theme.accent : Theme.line))

            Text("add").font(Theme.mono(9)).foregroundStyle(Theme.stoneDim).frame(width: cellW)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: browse)
        .onDrop(of: [.fileURL], isTargeted: $hovering, perform: handleDrop)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg]
        panel.prompt = "Add"
        panel.message = "Choose SDR JPEGs to add to the queue"
        if panel.runModal() == .OK { onPick(panel.urls) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls = [URL?](repeating: nil, count: providers.count)
        let lock = NSLock()   // loadObject callbacks land on arbitrary threads
        let group = DispatchGroup()
        for (i, p) in providers.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                lock.lock(); urls[i] = u; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { onPick(urls.compactMap { $0 }) }
        return true
    }
}
