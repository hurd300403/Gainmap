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

/// Session files originally used JSONEncoder's whole-second ISO-8601 dates.
/// Preserve that read compatibility, but write full-precision epoch seconds
/// so two batches created within the same second still have a deterministic
/// "most recent" order.
enum SessionJSONCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, target in
            var value = target.singleValueContainer()
            try value.encode(date.timeIntervalSince1970)
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { source in
            let value = try source.singleValueContainer()
            if let seconds = try? value.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let string = try value.decode(String.self)

            let precise = ISO8601DateFormatter()
            precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = precise.date(from: string) { return date }

            let legacy = ISO8601DateFormatter()
            legacy.formatOptions = [.withInternetDateTime]
            if let date = legacy.date(from: string) { return date }

            throw DecodingError.dataCorruptedError(
                in: value, debugDescription: "Invalid ISO-8601 session date: \(string)")
        }
        return decoder
    }
}

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

    /// Store-managed photo files (iOS `.managed` origins). Nonisolated —
    /// derived from immutable lets — so MergeModel/SyncEngine can resolve
    /// managed paths without hopping onto the actor.
    nonisolated public var managedFilesDir: URL {
        root.appendingPathComponent("users/\(uid)/files", isDirectory: true)
    }

    /// The lightweight 1024px cache shared by the session grid and editors.
    /// Keep this path calculation in the store so every surface agrees with
    /// SyncEngine's `<user>/thumbs/<content-hash>.jpg` layout.
    nonisolated public var thumbnailsDir: URL {
        root.appendingPathComponent("users/\(uid)/thumbs", isDirectory: true)
    }

    nonisolated public func thumbnailURL(forContentHash hash: String) -> URL {
        thumbnailsDir.appendingPathComponent("\(hash).jpg")
    }

    /// Resolve every filmstrip cell without downloading full originals.
    /// Locally readable originals win; otherwise an existing synced thumbnail
    /// is used, and only genuinely missing thumbnail hashes are returned for
    /// bounded hydration by the platform coordinator.
    nonisolated public func thumbnailPlan(for session: Session) -> SessionThumbnailPlan {
        let fm = FileManager.default
        var localURLs: [UUID: URL] = [:]
        var missing: [SessionThumbnailRequest] = []

        for photo in session.photos {
            let source = photo.sourceURL(managedRoot: managedFilesDir)
            if fm.fileExists(atPath: source.path) {
                localURLs[photo.id] = source
                continue
            }
            guard let hash = photo.contentHash else { continue }
            let thumbnail = thumbnailURL(forContentHash: hash)
            if fm.fileExists(atPath: thumbnail.path) {
                localURLs[photo.id] = thumbnail
            } else {
                missing.append(SessionThumbnailRequest(
                    photoID: photo.id,
                    contentHash: hash))
            }
        }

        return SessionThumbnailPlan(
            localURLsByPhotoID: localURLs,
            missing: missing)
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
        let enc = SessionJSONCoding.encoder()
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

    /// Migrates legacy iOS imports that were persisted as absolute `.linked`
    /// paths inside an older app-container UUID. The editor has always been
    /// able to find the moved bytes by their `/files/` suffix, but merely
    /// healing its in-memory BatchItem left sync-state rebuilding from the
    /// stale Session origin on every launch.
    ///
    /// This is a storage-format repair only: timestamps and user-visible
    /// content stay untouched, and the migrated origin is written once as the
    /// portable `.managed(relativePath:)` form.
    public func loadAllRepairingManagedOrigins() -> [Session] {
        let fm = FileManager.default
        var sessions = loadAll()
        for sessionIndex in sessions.indices {
            var changed = false
            for photoIndex in sessions[sessionIndex].photos.indices {
                let photo = sessions[sessionIndex].photos[photoIndex]
                guard case .linked(let oldPath) = photo.origin,
                      !fm.fileExists(atPath: oldPath),
                      let relativePath = legacyManagedRelativePath(from: oldPath)
                else { continue }
                let currentURL = managedFilesDir.appendingPathComponent(relativePath)
                guard let attrs = try? fm.attributesOfItem(atPath: currentURL.path),
                      let size = attrs[.size] as? Int64,
                      size > 0,
                      photo.byteSize == 0 || photo.byteSize == size
                else { continue }
                if let expectedHash = photo.contentHash,
                   SyncSchema.isValidContentHash(expectedHash),
                   ContentHash.sha256(of: currentURL) != expectedHash {
                    continue
                }
                sessions[sessionIndex].photos[photoIndex].origin =
                    .managed(relativePath: relativePath)
                changed = true
            }
            if changed {
                try? save(sessions[sessionIndex])
            }
        }
        return sessions
    }

    /// Only an old iOS data-container path is eligible. A disconnected Mac
    /// volume can also contain a `/files/` component; treating that as one of
    /// our managed imports could silently bind the session to unrelated bytes.
    private func legacyManagedRelativePath(from oldPath: String) -> String? {
        let containerPrefix = "/var/mobile/Containers/Data/Application/"
        let storeMarker =
            "/Library/Application Support/Gainmap/users/\(uid)/files/"
        guard oldPath.hasPrefix(containerPrefix),
              let markerRange = oldPath.range(of: storeMarker),
              markerRange.lowerBound > oldPath.startIndex else { return nil }

        let containerStart = oldPath.index(
            oldPath.startIndex, offsetBy: containerPrefix.count)
        let containerID = oldPath[containerStart..<markerRange.lowerBound]
        guard !containerID.isEmpty, !containerID.contains("/") else { return nil }

        let relativePath = String(oldPath[markerRange.upperBound...])
        let components = relativePath.split(
            separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }

        let managedRoot = managedFilesDir.standardizedFileURL
        let candidate = managedRoot
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard candidate.path.hasPrefix(managedRoot.path + "/") else { return nil }
        return relativePath
    }

    /// The most recently updated session — what the Mac app resumes at launch
    /// (P7 replaces this with the session grid).
    public func mostRecent() -> Session? { loadAll().first }

    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private static func decode(_ data: Data) -> Session? {
        let dec = SessionJSONCoding.decoder()
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
                // Collision: the same session exists in both namespaces.
                // Keep the NEWER content — blindly deleting the local copy
                // silently discarded edits made while signed out (P5 review).
                let localCopy = (try? Data(contentsOf: file)).flatMap(Self.decode)
                let destCopy = (try? Data(contentsOf: dest)).flatMap(Self.decode)
                if let localCopy, let destCopy, localCopy.updatedAt > destCopy.updatedAt {
                    _ = try? fm.replaceItemAt(dest, withItemAt: file)
                } else {
                    try? fm.removeItem(at: file)
                }
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

public struct SessionThumbnailRequest: Equatable, Sendable {
    public let photoID: UUID
    public let contentHash: String

    public init(photoID: UUID, contentHash: String) {
        self.photoID = photoID
        self.contentHash = contentHash
    }
}

public struct SessionThumbnailPlan: Equatable, Sendable {
    public let localURLsByPhotoID: [UUID: URL]
    public let missing: [SessionThumbnailRequest]

    public init(
        localURLsByPhotoID: [UUID: URL],
        missing: [SessionThumbnailRequest]
    ) {
        self.localURLsByPhotoID = localURLsByPhotoID
        self.missing = missing
    }
}
