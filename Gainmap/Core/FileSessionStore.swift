//
//  FileSessionStore.swift
//  GainmapCore
//
//  Atomic, uid-namespaced JSON persistence for sessions (P3). One file per
//  session under <root>/users/<uid>/sessions/<id>.json — written via
//  temp-file + atomic replace so a crash mid-write can never corrupt a
//  session (crash-safety is a P3 exit test). `users/local` is the pre-sign-in
//  namespace; P4's one-time adoption moves it under the real uid.
//
//  An actor: all file I/O is serialized off the caller's context.
//

import Foundation

public actor FileSessionStore {

    public let root: URL
    public let uid: String

    /// Default store root: Application Support/Gainmap.
    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Gainmap", isDirectory: true)
    }

    public init(root: URL = FileSessionStore.defaultRoot(), uid: String = "local") {
        self.root = root
        self.uid = uid
    }

    private var sessionsDir: URL {
        root.appendingPathComponent("users/\(uid)/sessions", isDirectory: true)
    }

    /// Store-managed photo files (iOS `.managed` origins, P6). Exposed now so
    /// PhotoRecord.sourceURL has a stable resolution root from day one.
    public var managedFilesDir: URL {
        root.appendingPathComponent("users/\(uid)/files", isDirectory: true)
    }

    private func ensureDirs() throws {
        try FileManager.default.createDirectory(at: sessionsDir,
                                                withIntermediateDirectories: true)
    }

    private func url(for id: UUID) -> URL {
        sessionsDir.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: Save / load / list / delete

    /// Atomic write: encode → temp file in the same directory → replace.
    /// A crash at ANY point leaves either the old complete file or the new
    /// complete file, never a torn one.
    public func save(_ session: Session) throws {
        try ensureDirs()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(session)
        let final = url(for: session.id)
        let tmp = sessionsDir.appendingPathComponent(".tmp-\(UUID().uuidString).json")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(final, withItemAt: tmp)
    }

    /// Load one session. Returns nil if the file is missing OR unreadable —
    /// a corrupt session must never take the app down (it is skipped, not
    /// deleted; the bytes stay on disk for post-mortem).
    public func load(id: UUID) -> Session? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return Self.decode(data)
    }

    /// All sessions, newest-updated first. Corrupt files are skipped.
    public func loadAll() -> [Session] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { (try? Data(contentsOf: $0)).flatMap(Self.decode) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The most recently updated session — what the Mac app resumes at launch
    /// (P7 replaces this with the session grid).
    public func mostRecent() -> Session? { loadAll().first }

    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private static func decode(_ data: Data) -> Session? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let s = try? dec.decode(Session.self, from: data),
              s.schemaVersion <= Session.currentSchemaVersion else { return nil }
        return s
    }

    // MARK: Signature (the saved default look) — signature.json

    /// P3 moves the saved default look from UserDefaults to a file the sync
    /// engine can watch (P4 syncs it as the user's signatureLook). Reads fall
    /// back to the old UserDefaults blob for one release; writes go to BOTH
    /// for one release so a rollback to 1.7 keeps the user's saved default.
    private var signatureURL: URL {
        root.appendingPathComponent("users/\(uid)/signature.json")
    }

    /// One-time adoption at first sign-in (P4 spec): sessions created before
    /// the account existed (uid "local") move under the real uid, so the
    /// signed-in store — and the sync engine — see them. Existing files at
    /// the destination win (never clobber synced state with pre-auth copies).
    public func adoptLocalSessions() {
        guard uid != "local" else { return }
        let fm = FileManager.default
        let localDir = root.appendingPathComponent("users/local/sessions", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: localDir,
                                                      includingPropertiesForKeys: nil) else { return }
        try? ensureDirs()
        for file in files where file.pathExtension == "json" {
            let dest = sessionsDir.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: file)      // already adopted previously
            } else {
                try? fm.moveItem(at: file, to: dest)
            }
        }
        // The signature travels too (if the signed-in namespace has none yet).
        let localSig = root.appendingPathComponent("users/local/signature.json")
        let destSig = root.appendingPathComponent("users/\(uid)/signature.json")
        if fm.fileExists(atPath: localSig.path), !fm.fileExists(atPath: destSig.path) {
            try? fm.copyItem(at: localSig, to: destSig)
        }
    }

    public func saveSignature(_ p: AutoHDR.BloomParams) {
        // The saved default never carries GLOW-IN-SDR (bake normalization —
        // same rule SignatureStore has always applied).
        var q = p
        q.bakeGlowIntoSDR = false
        try? FileManager.default.createDirectory(
            at: signatureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(q) {
            let tmp = signatureURL.deletingLastPathComponent()
                .appendingPathComponent(".tmp-sig-\(UUID().uuidString).json")
            if (try? data.write(to: tmp, options: .atomic)) != nil {
                _ = try? FileManager.default.replaceItemAt(signatureURL, withItemAt: tmp)
            }
        }
    }

    public func loadSignature() -> AutoHDR.BloomParams? {
        guard let data = try? Data(contentsOf: signatureURL) else { return nil }
        return try? JSONDecoder().decode(AutoHDR.BloomParams.self, from: data)
    }

    public func clearSignature() {
        try? FileManager.default.removeItem(at: signatureURL)
    }
}
