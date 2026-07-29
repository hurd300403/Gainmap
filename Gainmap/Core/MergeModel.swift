//
//  MergeModel.swift
//  GainmapCore
//
//  Observable state for the bench: a QUEUE of SDR JPEGs. You step through them
//  on a filmstrip, tune the HDR look per photo, and save as you go (or Export
//  All at the end). Each photo inherits the look you last dialed (the "running
//  look") until you visit-and-leave or tweak it, after which it keeps its own.
//  Outputs land beside each original.
//

import SwiftUI

@MainActor
public final class MergeModel: ObservableObject {

    public enum Phase: Equatable { case idle, merging, done, error }

    /// One photo in the auto-mode queue.
    public struct BatchItem: Identifiable, Equatable {
        public enum Status: Equatable { case pending, merging, done, error }
        public let id: UUID
        public let sdrURL: URL
        public var look: AutoHDR.BloomParams?   // nil = inherit the running look (untouched)
        public var status: Status = .pending
        public var outputURL: URL?
        public var readout: ClampReadout?
        public var error: String?
        /// The source already looks like an UltraHDR export (name suffix or an
        /// embedded gain map) — merging it again would bloom the bloom.
        public var looksMerged: Bool = false
        public var byteSize: Int64 = 0
        /// > 64 MB: imports and edits normally but stays entirely local (r6) —
        /// the filmstrip badges it once sync exists.
        public var tooLargeToSync: Bool = false
    }

    /// The live HDR-look the controls bind to. Editing it carries forward to the
    /// next untouched photo (runningLook) and is remembered on the selected item.
    @Published public var bloom = AutoHDR.BloomParams() {
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
            schedulePersist()
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
    @Published public var runningLook = AutoHDR.BloomParams()

    /// 0…1 master. Scales the current look (anchorLook = 100%) down toward subtle.
    @Published public var intensity: Double = 1.0
    /// The look Intensity treats as 100% — updated by any manual edit so the macro
    /// stays relative to the current dial. Not the saved default.
    private var anchorLook = AutoHDR.signatureLook
    private var applyingIntensity = false

    /// The saved "default look" (the shared signature). Reset returns here; starts
    /// as the built-in signature, overridable via "Set as default look".
    @Published public var signature: AutoHDR.BloomParams = AutoHDR.signatureLook

    /// True once the user has saved their own default look (so the button offers
    /// "Restore app default" instead of "Save as default").
    @Published public private(set) var hasCustomDefault = SignatureStore.hasSaved

    // MARK: Same look for all (batch mode)

    /// ONE shared look for every photo in the queue. While ON, the sliders edit
    /// the shared look, navigation neither loads nor commits per-photo looks
    /// (they're KEPT and come back when turned off), and merges use the shared
    /// look for every item. Persisted across launches. private(set): all changes
    /// go through setSameLookForAll so the transition rules can't be bypassed.
    @Published public private(set) var sameLookForAll: Bool {
        didSet { UserDefaults.standard.set(sameLookForAll, forKey: Self.sameLookKey) }
    }
    static let sameLookKey = "gainmap.sameLookForAll"

    /// Flip batch mode, running the transition rules. No-ops while a batch
    /// export is running (flipping mid-run would split the batch's semantics).
    public func setSameLookForAll(_ on: Bool) {
        guard on != sameLookForAll, !isExportingAll else { return }
        if on {
            // A photo that already OWNS a look keeps its uncommitted live edits.
            // (A never-committed photo's live edits simply BECOME the shared
            // look — nothing is visually lost, and on later disable it reloads
            // runningLook, which equals that same look.)
            if selectedItem?.look != nil { commitLiveLook() }
            sameLookForAll = true
            // The shared look you're seeing reads as 100% on the Intensity dial.
            anchorLook = bloom
            intensity = 1.0
        } else {
            sameLookForAll = false
            // Restore the selected photo's OWN look, as if freshly selected —
            // otherwise the still-live shared look would commit onto it at the
            // next navigation, silently destroying its preserved look. (Can't
            // reuse select() here: its leading commitLiveLook would do exactly
            // that stamping, since the mode is already OFF.)
            if let item = selectedItem {
                loadAsAnchor(item.look ?? runningLook)
            }
        }
        schedulePersist()
    }

    /// Adopt a STORED look onto the live bench as-is: suppress the didSet
    /// re-anchoring (so runningLook isn't clobbered by the load), then make it
    /// the 100% Intensity anchor.
    private func loadAsAnchor(_ look: AutoHDR.BloomParams) {
        loadingSelection = true
        bloom = look
        loadingSelection = false
        anchorLook = bloom
        intensity = 1.0
    }

    // MARK: Persistence (P3)

    /// The persistent truth this model edits. `items` is the view-facing
    /// mirror; `syncToSession()` folds live state back into it before saves.
    public private(set) var session: Session
    private var store: FileSessionStore?
    public var outputPolicy: OutputPolicy
    private var persistTask: Task<Void, Never>?

    /// Import-time metadata (content hash + pixel dims) keyed by photo id —
    /// the source of truth `syncToSession` folds into the records. Lives
    /// OUTSIDE `session` because hashing lands async while `session.photos`
    /// is rebuilt on every flush; writing into the records directly would race
    /// the rebuild (and lose against it).
    private struct PhotoMeta {
        var hash: String?
        var pixelWidth: Int?
        var pixelHeight: Int?
        /// Durable export record (outputPath + readout). PRESERVED even when
        /// the export file is temporarily unreachable (offline volume) — only
        /// a fresh export overwrites it, absence never erases it.
        var exportPath: String?
        var exportReadout: ClampReadout?
        var exportDone = false
    }
    private var photoMeta: [UUID: PhotoMeta] = [:]

    /// Snapshot of the last persisted session CONTENT (dates ignored) — saves
    /// are skipped when nothing real changed, which both quiets the disk and
    /// keeps `updatedAt` meaningful as a version signal (an idle app must not
    /// out-rank real edits under P4's reconciliation).
    private var lastPersistedContent: Session?

    private static func contentEquals(_ a: Session, _ b: Session) -> Bool {
        a.id == b.id && a.title == b.title && a.sameLookForAll == b.sameLookForAll
            && a.runningLook == b.runningLook && a.photos == b.photos
    }

    /// `store: nil` = ephemeral (exactly the pre-P3 behavior — what most unit
    /// tests want). The Mac app attaches the real store after launch via
    /// `attachStoreAndRestore`; iOS (P5) passes one here directly.
    public init(session: Session? = nil, store: FileSessionStore? = nil,
                output: OutputPolicy = .besideOriginal) {
        // Retire the old global GLOW-IN-SDR flag (now per-photo on the look) so a
        // stale `true` from an earlier build can't override the clean default.
        UserDefaults.standard.removeObject(forKey: "gainmap.bakeGlowIntoSDR")
        self.store = store
        self.outputPolicy = output
        // Session-scoped batch mode; the old UserDefaults global seeds NEW
        // sessions (and keeps tracking the last-used mode as that seed).
        let seededSame = UserDefaults.standard.bool(forKey: Self.sameLookKey)
        let sess = session ?? Session(sameLookForAll: seededSame)
        self.session = sess
        sameLookForAll = sess.sameLookForAll
        let sig = SignatureStore.load() ?? AutoHDR.signatureLook
        signature = sig
        anchorLook = sig
        bloom = sig   // didSet seeds runningLook + anchor (intensity → 100%)
        if session != nil { restoreItemsFromSession() }
    }

    /// Mac launch path: the @StateObject is created empty, then adopts the
    /// store — loading the saved default look (signature.json, falling back to
    /// the legacy UserDefaults blob for one release) and resuming the most
    /// recently updated session. No-ops if photos were already imported
    /// (e.g. the -gm-seed dev hook ran first).
    public func attachStoreAndRestore(_ store: FileSessionStore) async {
        self.store = store
        if let sig = await store.loadSignature() {
            signature = sig
            hasCustomDefault = true
            if items.isEmpty { resetToDefault() }
        } else if let legacy = SignatureStore.load() {
            // One-time migration: the UserDefaults-era saved default becomes
            // signature.json (P4 syncs the file, not the defaults blob).
            await store.saveSignature(legacy)
        }
        if items.isEmpty, let recent = await store.mostRecent(), !recent.photos.isEmpty {
            session = recent
            restoreItemsFromSession()
        }
    }

    /// Rebuild the view-facing queue from `session.photos` (init-with-session
    /// and launch-restore). Missing source files surface as item errors —
    /// visible, never silently dropped. `done` survives only while the export
    /// file still exists.
    private func restoreItemsFromSession() {
        sameLookForAll = session.sameLookForAll
        runningLook = session.runningLook
        loadingSelection = true
        bloom = session.runningLook
        loadingSelection = false
        anchorLook = bloom
        intensity = 1.0
        photoMeta = Dictionary(session.photos.map {
            ($0.id, PhotoMeta(hash: $0.contentHash,
                              pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                              exportPath: $0.outputPath, exportReadout: $0.readout,
                              exportDone: $0.done))
        }, uniquingKeysWith: { first, _ in first })
        let fm = FileManager.default
        let managedRoot = store?.managedFilesDir
        items = session.photos.map { p in
            var src = p.sourceURL(managedRoot: managedRoot)
            // Heal records that predate portable origins: iOS rotates the app
            // container UUID on reinstall, so an absolute `.linked` path into
            // OUR OWN managed files goes stale even though iOS migrated the
            // bytes. Re-root it against the current container.
            if !fm.fileExists(atPath: src.path), let managedRoot,
               let range = src.path.range(of: "/files/") {
                let healed = managedRoot.appendingPathComponent(
                    String(src.path[range.upperBound...]))
                if fm.fileExists(atPath: healed.path) { src = healed }
            }
            var item = BatchItem(id: p.id, sdrURL: src, look: p.look,
                                 looksMerged: p.looksMerged,
                                 byteSize: p.byteSize,
                                 tooLargeToSync: p.tooLargeToSync)
            // The VIEW shows "saved" only while the export file is reachable;
            // the durable ledger (photoMeta) keeps the record either way, so
            // an offline volume at launch never erases export state.
            if p.done, let out = p.outputPath, fm.fileExists(atPath: out) {
                item.status = .done
                item.outputURL = URL(fileURLWithPath: out)
                item.readout = p.readout
            }
            if !fm.fileExists(atPath: src.path) {
                item.status = .error
                item.error = "The source file has moved or was deleted: \(src.lastPathComponent)"
            }
            return item
        }
        if let first = items.first { select(first.id) }
        // The just-loaded state IS the persisted state — restoring must not
        // trigger a save (or bump updatedAt) by itself.
        syncToSession()
        lastPersistedContent = session
        // Older records may predate hashing — fill them in.
        let unhashed = session.photos.filter { $0.contentHash == nil }.map(\.id)
        if !unhashed.isEmpty {
            Task { [weak self] in await self?.computeImportMetadata(for: unhashed) }
        }
    }

    /// Fold live state back into `session` (the view drives `items`; the
    /// session is what persists). Computed metadata (contentHash, pixel dims)
    /// is carried over from the existing records by id.
    func syncToSession() {
        // Files living inside the store's managed root persist as RELATIVE
        // paths — iOS rotates the app-container UUID on reinstall, so an
        // absolute path in there is stale by the next update.
        let managedPrefix = store.map { $0.managedFilesDir.path + "/" }
        session.photos = items.map { item in
            let origin: PhotoRecord.Origin
            if let managedPrefix, item.sdrURL.path.hasPrefix(managedPrefix) {
                origin = .managed(relativePath:
                    String(item.sdrURL.path.dropFirst(managedPrefix.count)))
            } else {
                origin = .linked(path: item.sdrURL.path)
            }
            var p = PhotoRecord(id: item.id, origin: origin)
            let meta = photoMeta[item.id]
            p.contentHash = meta?.hash
            p.pixelWidth = meta?.pixelWidth
            p.pixelHeight = meta?.pixelHeight
            p.byteSize = item.byteSize
            p.tooLargeToSync = item.tooLargeToSync
            p.looksMerged = item.looksMerged
            p.look = item.look
            // Export state: a live .done wins; otherwise the durable ledger —
            // an export that's merely unreachable right now is NOT forgotten.
            if item.status == .done {
                p.done = true
                p.outputPath = item.outputURL?.path
                p.readout = item.readout
            } else if let meta, meta.exportDone {
                p.done = true
                p.outputPath = meta.exportPath
                p.readout = meta.exportReadout
            }
            return p
        }
        session.sameLookForAll = sameLookForAll
        session.runningLook = runningLook
        // updatedAt is bumped at SAVE time, only when content actually changed.
    }

    /// Debounced persist: mutations schedule a save ~500 ms out; a burst of
    /// slider ticks collapses into one write.
    private func schedulePersist() {
        guard store != nil else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.flushSession()
        }
    }

    /// Inbound sync (P5): a peer's committed change was materialized into the
    /// session file — fold it into the LIVE model. Skips entirely while local
    /// edits are unsaved (debounce pending) or an export is running: the
    /// journal's dirty overlay protects those groups server-side, and the
    /// next inbound event after our flush catches the model up. Selection is
    /// preserved when the photo still exists.
    public func reloadFromRemote(_ remote: Session) {
        guard remote.id == session.id else { return }
        guard persistTask == nil, phase != .merging, !isExportingAll else { return }
        if let last = lastPersistedContent, Self.contentEquals(last, remote) { return }
        let selected = selectedID
        session = remote
        restoreItemsFromSession()
        if let selected, items.contains(where: { $0.id == selected }) {
            select(selected)
        }
        lastPersistedContent = remote   // inbound is persisted state, not a local edit
    }

    /// The sync bridge (P5): fired with the just-saved Session after every
    /// real save — the app hands it to SyncEngine.noteLocalSession so local
    /// edits get journaled and drained. Nil (the default) = no sync.
    public var onSessionPersisted: (@Sendable (Session) -> Void)?

    /// Commit the live look and write the session now (drains the debounce).
    /// No-ops when nothing real changed since the last save — an idle app
    /// writes nothing and never advances `updatedAt`.
    public func flushSession() async {
        guard let store else { return }
        persistTask?.cancel()
        commitLiveLook()
        syncToSession()
        guard !session.photos.isEmpty || !session.title.isEmpty else { return }
        if let last = lastPersistedContent, Self.contentEquals(last, session) { return }
        session.updatedAt = Date()
        try? await store.save(session)
        lastPersistedContent = session
        onSessionPersisted?(session)
    }

    /// Synchronous last-chance flush for app termination — willTerminate gives
    /// no async grace, so this writes the session file directly (same layout,
    /// same atomic temp-and-replace the store uses).
    public func flushNowForTermination() {
        guard let store else { return }
        persistTask?.cancel()
        commitLiveLook()
        syncToSession()
        guard !session.photos.isEmpty || !session.title.isEmpty else { return }
        if let last = lastPersistedContent, Self.contentEquals(last, session) { return }
        session.updatedAt = Date()
        let dir = store.root.appendingPathComponent("users/\(store.uid)/sessions",
                                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(session) else { return }
        let final = dir.appendingPathComponent("\(session.id.uuidString).json")
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(final, withItemAt: tmp)
        lastPersistedContent = session
        onSessionPersisted?(session)
    }

    /// Off-main metadata for freshly imported photos: SHA-256 content hash +
    /// pixel dimensions. Dedup is SAME-BATCH ONLY and keeps the earliest
    /// occurrence: identical bytes dropped twice in one gesture collapse with
    /// feedback, but a photo re-added later (or the same bytes in two shoot
    /// folders, dropped separately) is always allowed — cross-batch removal
    /// was racy and could delete an edited or exported photo (P3 review);
    /// cloud-side, P4 dedups blobs by hash regardless.
    private func computeImportMetadata(for ids: [UUID]) async {
        var batchHashes: [String: UUID] = [:]
        var duplicatesRemoved = 0
        for id in ids {
            guard let item = items.first(where: { $0.id == id }) else { continue }
            let url = item.sdrURL
            let meta = await Task.detached(priority: .utility) { () -> (String?, CGSize?) in
                (ContentHash.sha256(of: url), ImageInfo.pixelSize(of: url))
            }.value
            guard items.contains(where: { $0.id == id }) else { continue }
            if let hash = meta.0 {
                if let keeper = batchHashes[hash], items.contains(where: { $0.id == keeper }) {
                    remove(id)
                    duplicatesRemoved += 1
                    continue
                }
                batchHashes[hash] = id
            }
            var m = photoMeta[id] ?? PhotoMeta()
            m.hash = meta.0
            m.pixelWidth = meta.1.map { Int($0.width) }
            m.pixelHeight = meta.1.map { Int($0.height) }
            photoMeta[id] = m
        }
        if duplicatesRemoved > 0 {
            dropNotice = duplicatesRemoved == 1
                ? "Duplicate photo skipped — the same bytes were in this drop twice."
                : "\(duplicatesRemoved) duplicate photos skipped — the same bytes were in this drop twice."
        }
        schedulePersist()
    }


    #if DEBUG
    /// Dev hook: seed the queue from a launch argument so UI states can be
    /// screenshotted/driven without file-picker automation (SwiftUI tap
    /// gestures ignore synthesized AX clicks). Called from the view's
    /// onAppear — seeding during @StateObject init breaks scene creation.
    ///   Gainmap -gm-seed "/path/a.jpg,/path/b.jpg"
    public func applyDebugSeedIfRequested() {
        guard items.isEmpty,
              let seed = UserDefaults.standard.string(forKey: "gm-seed") else { return }
        addFiles(seed.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
    }
    #endif

    /// Drive the whole look from the single Intensity slider, RELATIVE to the
    /// current anchor (100% = the look as currently dialed).
    public func setIntensity(_ t: Double) {
        intensity = t
        applyingIntensity = true
        bloom = AutoHDR.look(intensity: t, signature: anchorLook)
        applyingIntensity = false
    }

    /// Reset to the saved default look (the shared signature / screenshot preset).
    public func resetToDefault() {
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
    public func setSignatureFromCurrent() {
        var sig = bloom
        sig.bakeGlowIntoSDR = false
        signature = sig
        anchorLook = bloom
        intensity = 1.0
        SignatureStore.save(sig)   // legacy blob kept one release (rollback safety)
        if let store { Task { await store.saveSignature(sig) } }
        hasCustomDefault = true
    }

    /// Throw away the user's saved default and return to the look Gainmap shipped
    /// with (then re-anchor the current photo to it).
    public func restoreBuiltInDefault() {
        SignatureStore.clear()
        if let store { Task { await store.clearSignature() } }
        signature = AutoHDR.signatureLook
        hasCustomDefault = false
        resetToDefault()
    }

    // MARK: Copy / paste a look between photos

    /// A copied look, ready to paste onto another photo. nil = nothing copied.
    @Published public var clipboard: AutoHDR.BloomParams?
    public var canPaste: Bool { clipboard != nil }

    /// Copy the current photo's look.
    public func copyLook() { clipboard = bloom }

    /// Paste the copied look onto the selected photo (didSet stores it + re-anchors).
    public func pasteLook() {
        guard let c = clipboard else { return }
        bloom = c
    }

    /// Paste the copied look onto every photo in the queue.
    public func pasteLookToAll() {
        guard let c = clipboard, !items.isEmpty else { return }
        for i in items.indices { items[i].look = c }
        runningLook = c
        anchorLook = c
        intensity = 1.0
        applyingIntensity = true
        bloom = c
        applyingIntensity = false
        schedulePersist()
    }

    // MARK: Auto-mode queue

    @Published public var items: [BatchItem] = []
    @Published public var selectedID: UUID?
    private var loadingSelection = false

    /// The selected photo's file, mirrored for the preview pane.
    @Published public var sdrURL: URL?

    // GLOW-IN-SDR is now a per-photo dial that lives on `bloom.bakeGlowIntoSDR`
    // (see AutoHDR.BloomParams) so it travels with each photo's look. It used to be
    // a single global persisted under UserDefaults "gainmap.bakeGlowIntoSDR"; that
    // key is retired and cleared once at launch (see init) so a stale value from an
    // older build can't linger.

    // MARK: Shared status (phase + per-merge spinner)

    @Published public var phase: Phase = .idle
    @Published public var readout: ClampReadout?
    @Published public var outputURL: URL?
    @Published public var errorMessage: String?

    // MARK: Selection

    public var selectedIndex: Int? {
        guard let id = selectedID else { return nil }
        return items.firstIndex { $0.id == id }
    }
    public var selectedItem: BatchItem? { selectedIndex.map { items[$0] } }

    public var savedCount: Int { items.filter { $0.status == .done }.count }
    public var pendingCount: Int { items.filter { $0.status != .done }.count }
    public var hasNext: Bool { selectedIndex.map { $0 < items.count - 1 } ?? false }
    public var hasPrevious: Bool { selectedIndex.map { $0 > 0 } ?? false }
    public var canSaveSelected: Bool { selectedItem != nil && phase != .merging && !isExportingAll }
    /// While SAME-LOOK is on, Export All targets EVERY photo (done ones get
    /// re-merged so the "same look for all" promise holds after look changes).
    public var canExportAll: Bool {
        sameLookForAll ? (!items.isEmpty && phase != .merging)
                       : (pendingCount > 0 && phase != .merging)
    }

    /// Write the live bloom onto the selected item — called when LEAVING a photo
    /// (navigation, merge, export-all), not on every slider tick. No-op while
    /// SAME-LOOK is on: the shared look must never stamp preserved per-photo looks.
    /// NOTE: deliberately does NOT schedulePersist — the flush paths call
    /// this, and scheduling from here re-armed the debounce from inside the
    /// flush it triggered (a self-sustaining 2 Hz write loop, P3 review).
    /// Mutation call sites schedule for themselves.
    public func commitLiveLook() {
        guard !sameLookForAll else { return }
        if let i = selectedIndex { items[i].look = bloom }
    }

    /// Load a queue item into the live bench: its own look if it has one, else the
    /// running look (so a fresh photo arrives pre-dialed to your last settings).
    /// While SAME-LOOK is on, only the selection + status mirror update — the
    /// shared look stays live (never loaded from, never committed to, the item).
    public func select(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        commitLiveLook()   // the photo we're leaving keeps what was dialed on it
        selectedID = id
        if !sameLookForAll {
            // The selected photo's own look becomes the live bench + 100% anchor.
            loadAsAnchor(item.look ?? runningLook)
        }
        sdrURL = item.sdrURL
        outputURL = item.outputURL
        readout = item.readout
        errorMessage = item.error
        if phase != .merging { phase = .idle }
        schedulePersist()
    }

    public func selectNext() { stepSelection(+1) }
    public func selectPrevious() { stepSelection(-1) }
    private func stepSelection(_ delta: Int) {
        guard let i = selectedIndex, items.indices.contains(i + delta) else { return }
        select(items[i + delta].id)
    }

    // MARK: Queue mutation

    /// Transient note shown when dropped files were skipped (wrong type), so a
    /// rejected drop never just silently does nothing. Cleared by the view.
    @Published public var dropNotice: String?

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
    public func addFiles(_ urls: [URL]) {
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
            let size = (try? FileManager.default.attributesOfItem(atPath: std.path))
                .flatMap { $0[.size] as? NSNumber }?.int64Value ?? 0
            added.append(BatchItem(id: UUID(), sdrURL: std, look: nil,
                                   looksMerged: UHDRRunner.looksLikeMergedOutput(std),
                                   byteSize: size,
                                   tooLargeToSync: SyncLimits.tooLargeToSync(byteSize: size)))
        }
        dropNotice = Self.dropNoticeText(tiffCount: tiffs, otherCount: others)
        guard !added.isEmpty else { return }
        items.append(contentsOf: added)
        // A fresh session takes its title from the first import.
        if session.title.isEmpty {
            session.title = SessionNaming.suggest(from: added.map(\.sdrURL))
        }
        // Jump the session to the freshly-imported photo: the new file when a
        // single one is added, or the FIRST of a dragged-in / auto-selected batch.
        select(added[0].id)
        schedulePersist()
        // Content hash + pixel dims compute off-main; a hash collision with an
        // existing photo removes the duplicate (contentHash dedup).
        let ids = added.map(\.id)
        Task { [weak self] in await self?.computeImportMetadata(for: ids) }
    }

    public func remove(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = id == selectedID
        items.remove(at: idx)
        // Prune the metadata ledger — a stale hash here made a removed photo
        // impossible to re-add ("duplicate" of itself, P3 review finding).
        photoMeta.removeValue(forKey: id)
        defer { schedulePersist() }
        guard wasSelected else { return }
        if let next = items[safe: idx] ?? items.last {
            select(next.id)
        } else {
            clearSelection()
        }
    }

    public func clearQueue() {
        items.removeAll()
        photoMeta.removeAll()
        clearSelection()
        schedulePersist()
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
    /// Guarded against reentry: a repeated ⌘S (or a save fired between batch
    /// items) would otherwise interleave merges and can skip a photo unsaved.
    public func saveSelectedAndAdvance() async {
        guard phase != .merging, !isExportingAll, let id = selectedID else { return }
        await mergeItem(id)
        if hasNext { selectNext() }
    }

    /// True while an Export All batch is running (drives the Stop affordance).
    @Published public private(set) var isExportingAll = false
    /// Progress for the CURRENT batch run. `pendingCount` can't describe it
    /// while SAME-LOOK is on (done items are targets too).
    @Published public private(set) var batchTotal = 0
    @Published public private(set) var batchDone = 0
    private var exportTask: Task<Void, Never>?

    /// Kick off Export All as a RETAINED task so the user can stop it — an
    /// unowned fire-and-forget batch could only be ended by force-quitting.
    public func startExportAll() {
        guard exportTask == nil else { return }
        isExportingAll = true
        exportTask = Task { [weak self] in
            await self?.exportAll()
            self?.isExportingAll = false
            self?.exportTask = nil
        }
    }

    /// Stop the batch after the in-flight photo. The in-process encoder can't
    /// be interrupted mid-flight (the CLI child could be SIGTERM'd) — a photo
    /// already encoding finishes, but its result is DISCARDED and the photo
    /// restored, so a Stop never changes any file.
    public func stopExportAll() { exportTask?.cancel() }

    /// Merge the batch, in order. SAME-LOOK on: every photo, all with the shared
    /// look; off: not-yet-saved photos with their own looks. Look AND targets are
    /// snapshotted before the first await so slider edits or queue mutations
    /// mid-batch can't split the export. Checks for cancellation between photos.
    public func exportAll() async {
        commitLiveLook()
        let batchLook: AutoHDR.BloomParams? = sameLookForAll ? bloom : nil
        let targets = sameLookForAll
            ? items.map(\.id)
            : items.filter { $0.status != .done }.map(\.id)
        batchTotal = targets.count
        batchDone = 0
        defer { batchTotal = 0; batchDone = 0 }
        for id in targets {
            if Task.isCancelled { break }
            await mergeItem(id, look: batchLook)
            batchDone += 1
        }
    }

    /// Synthesize + merge a single queue item. The finished file lands beside the
    /// original ATOMICALLY: the tool writes to a hidden temp URL and only a
    /// successful run replaces `<base>_UltraHDR.jpg` — so stopping or failing a
    /// RE-export can never destroy the previous good export.
    /// `look:` overrides the per-item look (batch snapshot); nil = resolve here.
    public func mergeItem(_ id: UUID, look overrideLook: AutoHDR.BloomParams? = nil) async {
        if id == selectedID { commitLiveLook() }   // merge what's on screen (no-op while SAME-LOOK)
        guard let item = items.first(where: { $0.id == id }) else { return }
        let look = overrideLook ?? (sameLookForAll ? bloom : (item.look ?? runningLook))
        let sdr = item.sdrURL
        let finalOut = outputPolicy.outputURL(forSource: sdr)
        let tempOut = finalOut.deletingLastPathComponent()
            .appendingPathComponent(".gm-partial-\(UUID().uuidString).jpg")
        let prior = item   // for restore if this run is stopped

        setStatus(.merging, for: id)
        phase = .merging
        let outcome = await runMerge(sdr: sdr, look: look, out: tempOut)
        phase = .idle

        guard let idx = items.firstIndex(where: { $0.id == id }) else {
            try? FileManager.default.removeItem(at: tempOut)
            return
        }
        if Task.isCancelled {
            // Stopped — whether the run failed fast OR finished anyway (the
            // in-process encoder can't be interrupted mid-flight, so a late
            // SUCCESS can arrive after Stop): discard whatever it produced and
            // restore exactly what this photo was before the run (a
            // re-exported .done keeps its previously saved file).
            try? FileManager.default.removeItem(at: tempOut)
            items[idx].status = prior.status == .merging ? .pending : prior.status
            items[idx].outputURL = prior.outputURL
            items[idx].readout = prior.readout
            items[idx].error = prior.error
        } else {
            switch outcome {
            case .success(_, let readout):
                do {
                    try Self.atomicallyPlace(tempOut, at: finalOut)
                    items[idx].status = .done
                    items[idx].outputURL = finalOut
                    items[idx].readout = readout
                    items[idx].error = nil
                    photoMeta[id, default: PhotoMeta()].exportPath = finalOut.path
                    photoMeta[id, default: PhotoMeta()].exportReadout = readout
                    photoMeta[id, default: PhotoMeta()].exportDone = true
                } catch {
                    try? FileManager.default.removeItem(at: tempOut)
                    items[idx].status = .error
                    items[idx].error = "Couldn't move the finished file into place: \(error.localizedDescription)"
                }
            case .failure(let message):
                try? FileManager.default.removeItem(at: tempOut)
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
        schedulePersist()
    }

    /// Move `temp` into `final`'s place: atomic replace when a previous export
    /// exists, plain move when it doesn't.
    private static func atomicallyPlace(_ temp: URL, at final: URL) throws {
        if FileManager.default.fileExists(atPath: final.path) {
            _ = try FileManager.default.replaceItemAt(final, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: final)
        }
    }

    private func setStatus(_ s: BatchItem.Status, for id: UUID) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = s }
    }

    // Test seams — the real implementations render Core Image + run the
    // encoder, so the merge state machine can be unit-tested without either.
    // The default routes through UHDREncoding: in-process everywhere (P2),
    // with the macOS CLI kept one release behind a rollback flag.
    var runTool: @Sendable (UHDRRunner.Job) async -> RunOutcome = { await UHDREncoding.run($0) }
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
                let job = UHDRRunner.Job(hdr: .rawBuffer(inputs.hdr),
                                         sdr: inputs.sdrJPEG, out: out, cgamut: gamut, sgamut: gamut)
                let outcome = await runTool(job)
                try? FileManager.default.removeItem(at: inputs.sdrJPEG)
                return outcome
            } else {
                let buf = try await Task.detached(priority: .userInitiated) {
                    try synthBuffer(sdr, look, gamut)
                }.value
                let job = UHDRRunner.Job(hdr: .rawBuffer(buf),
                                         sdr: sdr, out: out, cgamut: gamut, sgamut: gamut)
                return await runTool(job)
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
