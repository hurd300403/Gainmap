//
//  MergeModel.swift
//  Gainmap
//
//  Observable state for the bench: a QUEUE of SDR JPEGs. You step through them
//  on a filmstrip, tune the HDR look per photo, and save as you go (or Export
//  All at the end). Each photo inherits the look you last dialed (the "running
//  look") until you visit-and-leave or tweak it, after which it keeps its own.
//  Outputs land beside each original.
//

import SwiftUI

@MainActor
final class MergeModel: ObservableObject {

    enum Phase: Equatable { case idle, merging, done, error }

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
        /// The source already looks like an UltraHDR export (name suffix or an
        /// embedded gain map) — merging it again would bloom the bloom.
        var looksMerged: Bool = false
    }

    /// The live HDR-look the controls bind to. Editing it carries forward to the
    /// next untouched photo (runningLook) and is remembered on the selected item.
    @Published var bloom = AutoHDR.BloomParams() {
        didSet {
            guard !loadingSelection, bloom != oldValue else { return }
            runningLook = bloom
            // NOTE: the selected item's look is NOT written here — a slider drag
            // fires this ~60×/sec and mutating @Published items each tick churns
            // array copies + view invalidations. The live look is committed onto
            // the item when LEAVING it (commitLiveLook: navigation/merge/export).
            // A manual (advanced-slider) edit redefines the 100% anchor the
            // Intensity slider scales from — so Intensity is always RELATIVE to
            // wherever you've currently set things, not a fixed preset. But flipping
            // ONLY the GLOW-IN-SDR toggle isn't a look-strength change, so it must
            // NOT re-anchor / snap Intensity to 100%; just keep the anchor's bake in
            // sync (so a later Intensity move preserves, not reverts, the toggle).
            if !applyingIntensity {
                if onlyBakeChanged(from: oldValue) {
                    anchorLook.bakeGlowIntoSDR = bloom.bakeGlowIntoSDR
                } else {
                    anchorLook = bloom
                    intensity = 1.0
                }
            }
        }
    }

    /// True when `bloom` differs from `old` only in the GLOW-IN-SDR flag.
    private func onlyBakeChanged(from old: AutoHDR.BloomParams) -> Bool {
        guard bloom.bakeGlowIntoSDR != old.bakeGlowIntoSDR else { return false }
        var a = bloom, b = old
        a.bakeGlowIntoSDR = false; b.bakeGlowIntoSDR = false
        return a == b
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

    /// True once the user has saved their own default look (so the button offers
    /// "Restore app default" instead of "Save as default").
    @Published private(set) var hasCustomDefault = SignatureStore.hasSaved

    init() {
        // Retire the old global GLOW-IN-SDR flag (now per-photo on the look) so a
        // stale `true` from an earlier build can't override the clean default.
        UserDefaults.standard.removeObject(forKey: "gainmap.bakeGlowIntoSDR")
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

    /// Make the current dialed look the new 100% signature (persists it). The saved
    /// default never carries GLOW-IN-SDR: it's a deliberate per-photo opt-in, so new
    /// photos always start with a clean SDR base (the current photo's own bake is
    /// left untouched — only the stored default is normalized off).
    func setSignatureFromCurrent() {
        var sig = bloom
        sig.bakeGlowIntoSDR = false
        signature = sig
        anchorLook = bloom
        intensity = 1.0
        SignatureStore.save(sig)
        hasCustomDefault = true
    }

    /// Throw away the user's saved default and return to the look Gainmap shipped
    /// with (then re-anchor the current photo to it).
    func restoreBuiltInDefault() {
        SignatureStore.clear()
        signature = AutoHDR.signatureLook
        hasCustomDefault = false
        resetToDefault()
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

    /// The selected photo's file, mirrored for the preview pane.
    @Published var sdrURL: URL?

    // GLOW-IN-SDR is now a per-photo dial that lives on `bloom.bakeGlowIntoSDR`
    // (see AutoHDR.BloomParams) so it travels with each photo's look. It used to be
    // a single global persisted under UserDefaults "gainmap.bakeGlowIntoSDR"; that
    // key is retired and cleared once at launch (see init) so a stale value from an
    // older build can't linger.

    // MARK: Shared status (phase + per-merge spinner)

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

    /// Write the live bloom onto the selected item — called when LEAVING a photo
    /// (navigation, merge, export-all), not on every slider tick.
    func commitLiveLook() {
        if let i = selectedIndex { items[i].look = bloom }
    }

    /// Load a queue item into the live bench: its own look if it has one, else the
    /// running look (so a fresh photo arrives pre-dialed to your last settings).
    func select(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        commitLiveLook()   // the photo we're leaving keeps what was dialed on it
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

    /// Transient note shown when dropped files were skipped (wrong type), so a
    /// rejected drop never just silently does nothing. Cleared by the view.
    @Published var dropNotice: String?

    /// The user-facing explanation for skipped drops. nil when nothing was skipped.
    /// (nonisolated: pure String math, unit-tested off the main actor.)
    nonisolated static func dropNoticeText(tiffCount: Int, otherCount: Int) -> String? {
        guard tiffCount + otherCount > 0 else { return nil }
        if otherCount == 0 {
            return tiffCount == 1
                ? "HDR TIFF skipped — Gainmap builds the HDR from your SDR JPEG export; drop that instead."
                : "\(tiffCount) HDR TIFFs skipped — Gainmap builds the HDR from your SDR JPEG exports; drop those instead."
        }
        let n = tiffCount + otherCount
        return n == 1 ? "That file was skipped — only JPEGs can be added."
                      : "\(n) files were skipped — only JPEGs can be added."
    }

    /// Add one or more SDR JPEGs to the queue (dedup by path). Files that aren't
    /// JPEGs are skipped WITH feedback (dropNotice), never silently.
    func addFiles(_ urls: [URL]) {
        var seen = Set(items.map { $0.sdrURL.standardizedFileURL })
        var added: [BatchItem] = []
        var tiffs = 0, others = 0
        for url in urls {
            guard FileRole.role(for: url) == .sdr else {
                if FileRole.role(for: url) == .hdr { tiffs += 1 } else { others += 1 }
                continue
            }
            let std = url.standardizedFileURL
            guard !seen.contains(std) else { continue }
            seen.insert(std)
            added.append(BatchItem(id: UUID(), sdrURL: std, look: nil,
                                   looksMerged: UHDRRunner.looksLikeMergedOutput(std)))
        }
        dropNotice = Self.dropNoticeText(tiffCount: tiffs, otherCount: others)
        guard !added.isEmpty else { return }
        items.append(contentsOf: added)
        // Jump the session to the freshly-imported photo: the new file when a
        // single one is added, or the FIRST of a dragged-in / auto-selected batch.
        select(added[0].id)
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

    /// True while an Export All batch is running (drives the Stop affordance).
    @Published private(set) var isExportingAll = false
    private var exportTask: Task<Void, Never>?

    /// Kick off Export All as a RETAINED task so the user can stop it — an
    /// unowned fire-and-forget batch could only be ended by force-quitting.
    func startExportAll() {
        guard exportTask == nil else { return }
        isExportingAll = true
        exportTask = Task { [weak self] in
            await self?.exportAll()
            self?.isExportingAll = false
            self?.exportTask = nil
        }
    }

    /// Stop the batch after the in-flight photo (which also gets terminated).
    func stopExportAll() { exportTask?.cancel() }

    /// Merge every not-yet-saved photo, in order. Checks for cancellation
    /// between photos so Stop takes effect promptly.
    func exportAll() async {
        commitLiveLook()
        for id in items.filter({ $0.status != .done }).map(\.id) {
            if Task.isCancelled { break }
            await mergeItem(id)
        }
    }

    /// Synthesize + merge a single queue item, writing beside its original.
    func mergeItem(_ id: UUID) async {
        if id == selectedID { commitLiveLook() }   // merge what's on screen
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
            if Task.isCancelled {
                // Stopped, not failed: back to pending; drop the partial write.
                items[idx].status = .pending
                items[idx].error = nil
                try? FileManager.default.removeItem(at: out)
            } else {
                items[idx].status = .error
                items[idx].error = message
            }
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

    // Test seams — the real implementations render Core Image + spawn uhdrtool,
    // so the merge state machine can be unit-tested without either.
    var runTool: @Sendable (UHDRRunner.Job) async -> RunOutcome = { await UHDRRunner().run($0) }
    var synthesizeBuffer: @Sendable (URL, AutoHDR.BloomParams, Gamut) throws -> AutoHDR.RawBuffer =
        { try AutoHDR.synthesize(from: $0, params: $1, gamut: $2) }
    var synthesizeBakeInputs: @Sendable (URL, AutoHDR.BloomParams, Gamut) throws -> AutoHDR.UltraHDRInputs =
        { try AutoHDR.synthesizeInputs(from: $0, params: $1, gamut: $2) }

    /// Off-main synthesis + tool run for one auto-mode photo. With bake-glow on,
    /// the SDR primary is the bloomed look (glow shows everywhere); off, it's the
    /// original passed through pixel-for-pixel (glow lives only in the gain map).
    /// The gamut is detected PER PHOTO from the JPEG's ICC profile: libultrahdr
    /// hard-fails on a --sgamut/profile mismatch, so a fixed sRGB flag would
    /// refuse to merge Display P3 exports at all.
    private func runMerge(sdr: URL, look: AutoHDR.BloomParams, out: URL) async -> RunOutcome {
        let bake = look.bakeGlowIntoSDR
        let synthBuffer = synthesizeBuffer
        let synthInputs = synthesizeBakeInputs
        do {
            let gamut = Gamut.detect(of: sdr)
            if bake {
                let inputs = try await Task.detached(priority: .userInitiated) {
                    try synthInputs(sdr, look, gamut)
                }.value
                let job = UHDRRunner.Job(hdr: .raw(inputs.hdr.url, w: inputs.hdr.width, h: inputs.hdr.height),
                                         sdr: inputs.sdrJPEG, out: out, cgamut: gamut, sgamut: gamut)
                let outcome = await runTool(job)
                try? FileManager.default.removeItem(at: inputs.hdr.url)
                try? FileManager.default.removeItem(at: inputs.sdrJPEG)
                return outcome
            } else {
                let buf = try await Task.detached(priority: .userInitiated) {
                    try synthBuffer(sdr, look, gamut)
                }.value
                let job = UHDRRunner.Job(hdr: .raw(buf.url, w: buf.width, h: buf.height),
                                         sdr: sdr, out: out, cgamut: gamut, sgamut: gamut)
                let outcome = await runTool(job)
                try? FileManager.default.removeItem(at: buf.url)
                return outcome
            }
        } catch {
            return .failure(message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
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
    static var hasSaved: Bool { UserDefaults.standard.data(forKey: key) != nil }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
    static func save(_ p: AutoHDR.BloomParams) {
        // The saved default look never carries GLOW-IN-SDR — it's a per-photo
        // opt-in, so new photos always start from a clean SDR base.
        var q = p
        q.bakeGlowIntoSDR = false
        if let data = try? JSONEncoder().encode(q) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    static func load() -> AutoHDR.BloomParams? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AutoHDR.BloomParams.self, from: data)
    }
}
