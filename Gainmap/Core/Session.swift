//
//  Session.swift
//  GainmapCore
//
//  The persistent session model (P3): a Session is a queue of photos plus the
//  look state that travels with it — what MergeModel edits live and what
//  FileSessionStore writes to disk (and P4 will sync). Field shapes anticipate
//  the P4 cloud schema (schemaVersion 1, tolerant decoding: unknown keys are
//  ignored, missing keys get defaults, so older builds' files always load).
//

import Foundation
import CoreGraphics

/// One photo in a session.
public struct PhotoRecord: Identifiable, Equatable, Codable {

    /// Where the pixels live. `.linked` = the user's own file, referenced in
    /// place (the Mac import path); `.managed` = a copy inside the app's store
    /// (the iOS import path, P6) with a store-relative path.
    public enum Origin: Equatable, Codable {
        case linked(path: String)
        case managed(relativePath: String)

        private enum CodingKeys: String, CodingKey { case type, path }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decodeIfPresent(String.self, forKey: .type) ?? "linked"
            let path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
            self = type == "managed" ? .managed(relativePath: path) : .linked(path: path)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .linked(let path):
                try c.encode("linked", forKey: .type)
                try c.encode(path, forKey: .path)
            case .managed(let relativePath):
                try c.encode("managed", forKey: .type)
                try c.encode(relativePath, forKey: .path)
            }
        }
    }

    public let id: UUID
    public var origin: Origin
    /// SHA-256 of the source bytes — the content address the cloud store keys
    /// on (P4). Computed off-main after import; nil until hashing completes.
    public var contentHash: String?
    public var byteSize: Int64
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// > 64 MB files import and edit normally but are ENTIRELY local (r6):
    /// never journaled to the cloud, excluded from remote photoCount/covers.
    public var tooLargeToSync: Bool
    /// Import-time detection: the source already looked like an UltraHDR
    /// export (double-merge warning) — persisted so restore doesn't re-probe.
    public var looksMerged: Bool
    /// nil = inherit the session's running look (untouched photo).
    public var look: AutoHDR.BloomParams?
    /// Local export state — informational, never synced (P4: `lastExport`).
    public var done: Bool
    public var outputPath: String?
    public var readout: ClampReadout?

    public init(id: UUID = UUID(), origin: Origin, contentHash: String? = nil,
                byteSize: Int64 = 0, pixelWidth: Int? = nil, pixelHeight: Int? = nil,
                tooLargeToSync: Bool = false, looksMerged: Bool = false,
                look: AutoHDR.BloomParams? = nil,
                done: Bool = false, outputPath: String? = nil, readout: ClampReadout? = nil) {
        self.id = id
        self.origin = origin
        self.contentHash = contentHash
        self.byteSize = byteSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.tooLargeToSync = tooLargeToSync
        self.looksMerged = looksMerged
        self.look = look
        self.done = done
        self.outputPath = outputPath
        self.readout = readout
    }

    /// The absolute file URL of the source pixels, resolved against the
    /// store's managed-files root (only `.managed` needs it).
    public func sourceURL(managedRoot: URL?) -> URL {
        switch origin {
        case .linked(let path):
            return URL(fileURLWithPath: path)
        case .managed(let rel):
            return (managedRoot ?? URL(fileURLWithPath: "/")).appendingPathComponent(rel)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, origin, contentHash, byteSize, pixelWidth, pixelHeight
        case tooLargeToSync, looksMerged, look, done, outputPath, readout
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin) ?? .linked(path: "")
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        byteSize = try c.decodeIfPresent(Int64.self, forKey: .byteSize) ?? 0
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight)
        tooLargeToSync = try c.decodeIfPresent(Bool.self, forKey: .tooLargeToSync) ?? false
        looksMerged = try c.decodeIfPresent(Bool.self, forKey: .looksMerged) ?? false
        look = try c.decodeIfPresent(AutoHDR.BloomParams.self, forKey: .look)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        outputPath = try c.decodeIfPresent(String.self, forKey: .outputPath)
        readout = try c.decodeIfPresent(ClampReadout.self, forKey: .readout)
    }
}

/// A persisted editing session: the photo queue + the look state that makes it
/// resumable exactly where it was left.
public struct Session: Identifiable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    public let id: UUID
    public var schemaVersion: Int
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Session-scoped batch mode (was a UserDefaults global before P3; the
    /// global seeds the FIRST session and remains as a migration source).
    public var sameLookForAll: Bool
    /// The most-recently dialed look — what untouched photos inherit.
    public var runningLook: AutoHDR.BloomParams
    public var photos: [PhotoRecord]

    public init(id: UUID = UUID(), title: String = "",
                createdAt: Date = Date(), updatedAt: Date = Date(),
                sameLookForAll: Bool = false,
                runningLook: AutoHDR.BloomParams = AutoHDR.BloomParams(),
                photos: [PhotoRecord] = []) {
        self.id = id
        self.schemaVersion = Self.currentSchemaVersion
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sameLookForAll = sameLookForAll
        self.runningLook = runningLook
        self.photos = photos
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, title, createdAt, updatedAt
        case sameLookForAll, runningLook, photos
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        sameLookForAll = try c.decodeIfPresent(Bool.self, forKey: .sameLookForAll) ?? false
        runningLook = try c.decodeIfPresent(AutoHDR.BloomParams.self, forKey: .runningLook)
            ?? AutoHDR.BloomParams()
        photos = try c.decodeIfPresent([PhotoRecord].self, forKey: .photos) ?? []
    }
}

extension ClampReadout: Codable {
    private enum CodingKeys: String, CodingKey {
        case peakBoost, stops, maxBoost, targetNits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(peakBoost: try c.decodeIfPresent(Double.self, forKey: .peakBoost) ?? 1.0,
                  stops: try c.decodeIfPresent(Double.self, forKey: .stops) ?? 0,
                  maxBoost: try c.decodeIfPresent(Double.self, forKey: .maxBoost) ?? 1.0,
                  targetNits: try c.decodeIfPresent(Int.self, forKey: .targetNits) ?? 203)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(peakBoost, forKey: .peakBoost)
        try c.encode(stops, forKey: .stops)
        try c.encode(maxBoost, forKey: .maxBoost)
        try c.encode(targetNits, forKey: .targetNits)
    }
}
