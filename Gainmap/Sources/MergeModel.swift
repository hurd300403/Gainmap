//
//  MergeModel.swift
//  Gainmap
//
//  Observable state for the bench. Two modes:
//
//  • Auto — a QUEUE of SDR JPEGs. You step through them on a filmstrip, tune the
//    HDR look per photo, and save as you go (or Export All at the end). Each photo
//    inherits the look you last dialed (the "running look") until you tweak it,
//    after which it keeps its own. Outputs land beside each original.
//
//  • Advanced — one real HDR edit (float TIFF) fused with its SDR JPEG. Single
//    shot, unchanged from before.
//

import SwiftUI

@MainActor
final class MergeModel: ObservableObject {

    enum Phase: Equatable { case idle, merging, done, error }

    /// Auto = a queue of SDR JPEGs, highlights auto-popped (default).
    /// Advanced = a real HDR edit (float TIFF) fused with the SDR JPEG.
    enum Mode: Equatable { case auto, advanced }

    /// One photo in the auto-mode queue.
    struct BatchItem: Identifiable, Equatable {
        enum Status: Equatable { case pending, merging, done, error }
        let id: UUID
        let sdrURL: URL
        var look: AutoHDR.BloomParams?   // nil = inherit the running look (untouched)
        var status: Status = .pending
        var outputURL: URL?
        var readout: ClampReadout?
        var error: String?
    }

    @Published var mode: Mode = .auto

    /// The live HDR-look the controls bind to. Editing it carries forward to the
    /// next untouched photo (runningLook) and is remembered on the selected item.
    @Published var bloom = AutoHDR.BloomParams() {
        didSet {
            guard !loadingSelection, bloom != oldValue else { return }
            runningLook = bloom
            if let i = selectedIndex { items[i].look = bloom }
            // A manual (advanced-slider) edit redefines the 100% anchor the
            // Intensity slider scales from — so Intensity is always RELATIVE to
            // wherever you've currently set things, not a fixed preset.
            if !applyingIntensity {
                anchorLook = bloom
                intensity = 1.0
            }
        }
    }
    /// The most-recently dialed look, inherited by the next photo you arrive at.
    @Published var runningLook = AutoHDR.BloomParams()

    /// 0…1 master. Scales the current look (anchorLook = 100%) down toward subtle.
    @Published var intensity: Double = 1.0
    /// The look Intensity treats as 100% — updated by any manual edit so the macro
    /// stays relative to the current dial. Not the saved default.
    private var anchorLook = AutoHDR.signatureLook
    private var applyingIntensity = false

    /// The saved "default look" (the shared signature). Reset returns here; starts
    /// as the built-in signature, overridable via "Set as default look".
    @Published var signature: AutoHDR.BloomParams = AutoHDR.signatureLook

    init() {
        let sig = SignatureStore.load() ?? AutoHDR.signatureLook
        signature = sig
        anchorLook = sig
        bloom = sig   // didSet seeds runningLook + anchor (intensity → 100%)
    }

    /// Drive the whole look from the single Intensity slider, RELATIVE to the
    /// current anchor (100% = the look as currently dialed).
    func setIntensity(_ t: Double) {
        intensity = t
        applyingIntensity = true
        bloom = AutoHDR.look(intensity: t, signature: anchorLook)
        applyingIntensity = false
    }

    /// Reset to the saved default look (the shared signature / screenshot preset).
    func resetToDefault() {
        anchorLook = signature
        applyingIntensity = true
        bloom = signature
        applyingIntensity = false
        intensity = 1.0
    }

    /// Make the current dialed look the new 100% signature (persists it).
    func setSignatureFromCurrent() {
        signature = bloom
        anchorLook = bloom
        intensity = 1.0
        SignatureStore.save(bloom)
    }

    // MARK: Copy / paste a look between photos

    /// A copied look, ready to paste onto another photo. nil = nothing copied.
    @Published var clipboard: AutoHDR.BloomParams?
    var canPaste: Bool { clipboard != nil }

    /// Copy the current photo's look.
    func copyLook() { clipboard = bloom }

    /// Paste the copied look onto the selected photo (didSet stores it + re-anchors).
    func pasteLook() {
        guard let c = clipboard else { return }
        bloom = c
    }

    /// Paste the copied look onto every photo in the queue.
    func pasteLookToAll() {
        guard let c = clipboard, !items.isEmpty else { return }
        for i in items.indices { items[i].look = c }
        runningLook = c
        anchorLook = c
        intensity = 1.0
        applyingIntensity = true
        bloom = c
        applyingIntensity = false
    }

    // MARK: Auto-mode queue

    @Published var items: [BatchItem] = []
    @Published var selectedID: UUID?
    private var loadingSelection = false

    // MARK: Advanced-mode inputs

    @Published var hdrURL: URL?
    @Published var sdrURL: URL?
    @Published var customOutputURL: URL?
    @Published var cgamut: Gamut = .rec709
    @Published var sgamut: Gamut = .rec709

    /// When true (default), the soft bloom is baked into the SDR base so the glow
    /// shows on every display (the SDR fallback is the bloomed look, not the
    /// original). When false, the SDR fallback is the original JPEG passed through
    /// pixel-for-pixel and the glow lives only in the gain map (HDR-only).
    @Published var bakeGlowIntoSDR: Bool = UserDefaults.standard.object(forKey: "gainmap.bakeGlowIntoSDR") as? Bool ?? false {
        didSet { UserDefaults.standard.set(bakeGlowIntoSDR, forKey: "gainmap.bakeGlowIntoSDR") }
    }

    // MARK: Shared status (advanced phase + per-merge spinner)

    @Published var phase: Phase = .idle
    @Published var readout: ClampReadout?
    @Published var outputURL: URL?
    @Published var errorMessage: String?

    // MARK: Selection

    var selectedIndex: Int? {
        guard let id = selectedID else { return nil }
        return items.firstIndex { $0.id == id }
    }
    var selectedItem: BatchItem? { selectedIndex.map { items[$0] } }

    var savedCount: Int { items.filter { $0.status == .done }.count }
    var pendingCount: Int { items.filter { $0.status != .done }.count }
    var hasNext: Bool { selectedIndex.map { $0 < items.count - 1 } ?? false }
    var hasPrevious: Bool { selectedIndex.map { $0 > 0 } ?? false }
    var canSaveSelected: Bool { selectedItem != nil && phase != .merging }
    var canExportAll: Bool { pendingCount > 0 && phase != .merging }

    /// Load a queue item into the live bench: its own look if it has one, else the
    /// running look (so a fresh photo arrives pre-dialed to your last settings).
    func select(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        selectedID = id
        loadingSelection = true
        bloom = item.look ?? runningLook
        sdrURL = item.sdrURL
        loadingSelection = false
        // The selected photo's current look becomes the Intensity anchor (100%).
        anchorLook = bloom
        intensity = 1.0
        outputURL = item.outputURL
        readout = item.readout
        errorMessage = item.error
        if phase != .merging { phase = .idle }
    }

    func selectNext() { stepSelection(+1) }
    func selectPrevious() { stepSelection(-1) }
    private func stepSelection(_ delta: Int) {
        guard let i = selectedIndex, items.indices.contains(i + delta) else { return }
        select(items[i + delta].id)
    }

    // MARK: Queue mutation

    /// Add one or more SDR JPEGs to the queue (dedup by path). Non-JPEGs ignored.
    func addFiles(_ urls: [URL]) {
        var seen = Set(items.map { $0.sdrURL.standardizedFileURL })
        var added: [BatchItem] = []
        for url in urls where FileRole.role(for: url) == .sdr {
            let std = url.standardizedFileURL
            guard !seen.contains(std) else { continue }
            seen.insert(std)
            added.append(BatchItem(id: UUID(), sdrURL: std, look: nil))
        }
        guard !added.isEmpty else { return }
        items.append(contentsOf: added)
        if selectedID == nil { select(added[0].id) }
    }

    func remove(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = id == selectedID
        items.remove(at: idx)
        guard wasSelected else { return }
        if let next = items[safe: idx] ?? items.last {
            select(next.id)
        } else {
            clearSelection()
        }
    }

    func clearQueue() {
        items.removeAll()
        clearSelection()
    }

    private func clearSelection() {
        selectedID = nil
        sdrURL = nil
        outputURL = nil
        readout = nil
        errorMessage = nil
        phase = .idle
    }

    // MARK: Saving (auto mode)

    /// Merge the selected photo, then advance to the next (save-as-you-go).
    func saveSelectedAndAdvance() async {
        guard let id = selectedID else { return }
        await mergeItem(id)
        if hasNext { selectNext() }
    }

    /// Merge every not-yet-saved photo, in order.
    func exportAll() async {
        for id in items.filter({ $0.status != .done }).map(\.id) {
            await mergeItem(id)
        }
    }

    /// Synthesize + merge a single queue item, writing beside its original.
    func mergeItem(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let look = item.look ?? runningLook
        let sdr = item.sdrURL
        let out = UHDRRunner.defaultOutputURL(forSDR: sdr)

        setStatus(.merging, for: id)
        phase = .merging
        let outcome = await runMerge(sdr: sdr, look: look, out: out)
        phase = .idle

        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .success(let output, let readout):
            items[idx].status = .done
            items[idx].outputURL = output
            items[idx].readout = readout
            items[idx].error = nil
        case .failure(let message):
            items[idx].status = .error
            items[idx].error = message
        }
        // Mirror onto the live bench if this is the photo on screen.
        if id == selectedID, let updated = items[safe: idx] {
            outputURL = updated.outputURL
            readout = updated.readout
            errorMessage = updated.error
        }
    }

    private func setStatus(_ s: BatchItem.Status, for id: UUID) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = s }
    }

    /// Off-main synthesis + tool run for one auto-mode photo. With bake-glow on,
    /// the SDR primary is the bloomed look (glow shows everywhere); off, it's the
    /// original passed through pixel-for-pixel (glow lives only in the gain map).
    private func runMerge(sdr: URL, look: AutoHDR.BloomParams, out: URL) async -> RunOutcome {
        let bake = bakeGlowIntoSDR
        do {
            if bake {
                let inputs = try await Task.detached(priority: .userInitiated) {
                    try AutoHDR.synthesizeInputs(from: sdr, params: look)
                }.value
                let job = UHDRRunner.Job(hdr: .raw(inputs.hdr.url, w: inputs.hdr.width, h: inputs.hdr.height),
                                         sdr: inputs.sdrJPEG, out: out, cgamut: cgamut, sgamut: sgamut)
                let outcome = await UHDRRunner().run(job)
                try? FileManager.default.removeItem(at: inputs.hdr.url)
                try? FileManager.default.removeItem(at: inputs.sdrJPEG)
                return outcome
            } else {
                let buf = try await Task.detached(priority: .userInitiated) {
                    try AutoHDR.synthesize(from: sdr, params: look)
                }.value
                let job = UHDRRunner.Job(hdr: .raw(buf.url, w: buf.width, h: buf.height),
                                         sdr: sdr, out: out, cgamut: cgamut, sgamut: sgamut)
                let outcome = await UHDRRunner().run(job)
                try? FileManager.default.removeItem(at: buf.url)
                return outcome
            }
        } catch {
            return .failure(message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    // MARK: Advanced mode (two files, single shot)

    var canMergeAdvanced: Bool {
        phase != .merging && hdrURL != nil && sdrURL != nil
    }

    /// Where the advanced merge writes: explicit choice, else `<sdr>_UltraHDR.jpg`.
    var resolvedOutputURL: URL? {
        if let custom = customOutputURL { return custom }
        if let sdr = sdrURL { return UHDRRunner.defaultOutputURL(forSDR: sdr) }
        return nil
    }

    /// Route a dropped/opened file to the right advanced slot by type.
    func accept(_ url: URL) {
        switch FileRole.role(for: url) {
        case .hdr: hdrURL = url
        case .sdr: sdrURL = url
        case .none: break
        }
        if phase == .error { phase = .idle; errorMessage = nil }
    }

    func mergeAdvanced() async {
        guard let sdr = sdrURL, let hdr = hdrURL, let out = resolvedOutputURL else { return }
        phase = .merging
        errorMessage = nil
        let job = UHDRRunner.Job(hdr: .tiff(hdr), sdr: sdr, out: out, cgamut: cgamut, sgamut: sgamut)
        switch await UHDRRunner().run(job) {
        case .success(let output, let r):
            outputURL = output
            readout = r
            phase = .done
        case .failure(let message):
            errorMessage = message
            phase = .error
        }
    }

    /// Reset the advanced bench for the next two-file merge.
    func reset() {
        hdrURL = nil
        sdrURL = nil
        customOutputURL = nil
        outputURL = nil
        readout = nil
        errorMessage = nil
        phase = .idle
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Persists the user's "default look" (signature) across launches.
enum SignatureStore {
    private static let key = "gainmap.signatureLook"
    static func save(_ p: AutoHDR.BloomParams) {
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    static func load() -> AutoHDR.BloomParams? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AutoHDR.BloomParams.self, from: data)
    }
}
