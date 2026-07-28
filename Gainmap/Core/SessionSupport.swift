//
//  SessionSupport.swift
//  GainmapCore
//
//  P3 helpers around the session model: content hashing (the cloud's content
//  address), output-location policy, session auto-naming, and the >64 MB
//  sync-size limit.
//

import Foundation
import CryptoKit

// MARK: - Content hash

public enum ContentHash {
    /// SHA-256 of a file's bytes, streamed in 1 MB chunks (a 50 MB JPEG never
    /// lands in memory whole). Hex-encoded lowercase — the object key the
    /// cloud store uses (P4). Call off the main thread.
    public static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Sync size limit

public enum SyncLimits {
    /// Cloud Storage rules reject objects ≥ 64 MB (r6): larger photos import
    /// and edit normally but stay entirely local, with a visible badge.
    public static let maxSyncableBytes: Int64 = 64 * 1024 * 1024

    public static func tooLargeToSync(byteSize: Int64) -> Bool {
        byteSize >= maxSyncableBytes
    }
}

// MARK: - Output policy

/// Where finished exports land. The Mac writes beside the original (the
/// behavior Gainmap has always had); iOS (P6) uses a managed directory and
/// hands files to Photos/share sheet from there.
public enum OutputPolicy: Equatable, Sendable {
    case besideOriginal
    case managedDirectory(URL)

    public func outputURL(forSource source: URL) -> URL {
        switch self {
        case .besideOriginal:
            return UHDRRunner.defaultOutputURL(forSDR: source)
        case .managedDirectory(let dir):
            let base = source.deletingPathExtension().lastPathComponent
            return dir.appendingPathComponent("\(base)_UltraHDR.jpg")
        }
    }
}

// MARK: - Session naming

public enum SessionNaming {
    /// Suggest a human title for a fresh session from its first photos: the
    /// photos' common parent-folder name when it reads like a shoot folder
    /// ("Smith Wedding" → "Smith Wedding"), else a date title ("July 27
    /// Session"). Pure and unit-tested.
    public static func suggest(from urls: [URL], date: Date = Date(),
                               calendar: Calendar = .current) -> String {
        if let folder = commonParentName(of: urls), isMeaningful(folder) {
            return folder
        }
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.dateFormat = "MMMM d"
        return "\(fmt.string(from: date)) Session"
    }

    private static func commonParentName(of urls: [URL]) -> String? {
        let parents = Set(urls.map { $0.deletingLastPathComponent().path })
        guard parents.count == 1, let parent = parents.first, !parent.isEmpty else { return nil }
        return URL(fileURLWithPath: parent).lastPathComponent
    }

    /// Generic containers ("Desktop", "Downloads", volume roots…) make bad
    /// titles; a real shoot folder name does not appear in this list.
    private static func isMeaningful(_ name: String) -> Bool {
        let generic: Set<String> = [
            "", "/", "desktop", "downloads", "documents", "pictures", "photos",
            "images", "tmp", "temp", "untitled", "export", "exports", "jpeg",
            "jpegs", "jpg", "output", "processed", "finals", "full",
        ]
        return !generic.contains(name.lowercased())
    }
}
