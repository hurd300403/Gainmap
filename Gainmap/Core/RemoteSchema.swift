//
//  RemoteSchema.swift
//  GainmapCore
//
//  P4: the frozen cloud schema (schemaVersion 1) — Swift mirrors of the
//  Firestore documents, kept deliberately SDK-free. Documents encode to and
//  decode from `FSValue` trees; the Firebase adapter (SyncBackend) is the only
//  place that converts FSValue <-> FirebaseFirestore types. That keeps every
//  schema/protocol rule unit-testable on both platforms with no emulator.
//
//  FIELD NAMES ARE LOAD-BEARING: the per-group revision invariant in
//  firestore.rules names these exact keys (PHOTO_LOOK_FIELDS() etc.). Any
//  rename here without a rules change bricks sync. See firestore.rules and
//  docs/superpowers/specs/2026-07-27-gainmap-ios-sync-design.md.
//

import Foundation

// MARK: - FSValue — a Firestore field value, SDK-free

/// The subset of Firestore field types the Gainmap schema uses. Decoding is
/// tolerant the same way the local store is: accessors coerce int <-> double,
/// unknown keys in maps are ignored by the document decoders.
public indirect enum FSValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case timestamp(Date)
    case array([FSValue])
    case map([String: FSValue])

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    public var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d == d.rounded() && abs(d) < 9e15: return Int64(d)
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var dateValue: Date? {
        if case .timestamp(let d) = self { return d }
        return nil
    }
    public var arrayValue: [FSValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    public var mapValue: [String: FSValue]? {
        if case .map(let m) = self { return m }
        return nil
    }
    public var isNull: Bool { self == .null }
}

// MARK: - Schema constants + paths

public enum SyncSchema {
    /// Bumping this is a breaking protocol change (rules reject anything
    /// above their MAX_SCHEMA_VERSION). Decoders skip docs from the future.
    public static let schemaVersion = 1

    /// Storage tiers — mirrored in storage.rules + functions/lib/constants.js.
    public static let tiers = ["originals", "thumbs", "proxies"]

    /// Per-object hard cap (storage.rules `payloadOK`); >= this stays local.
    public static let maxObjectBytes: Int64 = 64 * 1024 * 1024

    /// Session cover mosaics carry at most this many entries.
    public static let maxCovers = 4

    /// RESERVATION DOC ID SCHEME — lockstep with storage.rules (which derives
    /// the id from {tier} and {fileName} alone) and functions/lib/constants.js.
    public static func reservationId(tier: String, contentHash: String) -> String {
        "\(tier)_\(contentHash)"
    }

    /// users/{uid}/{tier}/{contentHash}.jpg — the immutable object name.
    public static func objectName(uid: String, tier: String, contentHash: String) -> String {
        "users/\(uid)/\(tier)/\(contentHash).jpg"
    }

    public static func isValidContentHash(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// Which document a mutation targets. Firestore doc IDs are the local UUIDs'
/// `uuidString` — stable across devices because IDs are minted once at import.
public enum SyncTarget: Equatable, Hashable, Codable, Sendable {
    case user
    case session(UUID)
    case photo(session: UUID, photo: UUID)

    /// Firestore path relative to users/{uid}. `.user` is the user doc itself.
    public func path(uid: String) -> String {
        switch self {
        case .user:
            return "users/\(uid)"
        case .session(let s):
            return "users/\(uid)/sessions/\(s.uuidString)"
        case .photo(let s, let p):
            return "users/\(uid)/sessions/\(s.uuidString)/photos/\(p.uuidString)"
        }
    }
}

// MARK: - Field groups + revision metadata

/// Per-group revision metadata: `rev` enforced by rules (new == old + 1),
/// `by` = deviceID, `mut` = mutationID (the self-ack marker).
public struct RevMeta: Equatable, Codable, Sendable {
    public var rev: Int
    public var by: String
    public var mut: String

    public init(rev: Int = 0, by: String = "", mut: String = "") {
        self.rev = rev
        self.by = by
        self.mut = mut
    }

    /// Groups start life implicit: a created doc carries no rev fields, rules
    /// treat a missing old rev as 0, so the first edit writes rev 1.
    public static let initial = RevMeta()
}

/// The mutable field groups of the protocol. `keys` lists EVERY field the
/// group owns — including its rev/by/mut metadata — exactly as firestore.rules
/// spells them; an update payload for a group touches exactly these keys
/// (+ updatedAt).
public enum FieldGroup: String, Equatable, Hashable, Codable, Sendable, CaseIterable {
    case photoLook
    case photoOrder
    case sessionTitle
    case sessionRunningLook
    case delete            // shared tombstone group (photos AND sessions)
    case userSignature     // whole-map LWW, no rev group (user-scoped)

    /// firestore.rules: *_FIELDS() lists.
    public var keys: [String] {
        switch self {
        case .photoLook:          return ["look", "lookRev", "lookBy", "lookMut"]
        case .photoOrder:         return ["orderKey", "orderRev", "orderBy", "orderMut"]
        case .sessionTitle:       return ["title", "titleRev", "titleBy", "titleMut"]
        case .sessionRunningLook: return ["runningLook", "sameLookForAll", "rlRev", "rlBy", "rlMut"]
        case .delete:             return ["deletedAt", "delRev", "delBy", "delMut"]
        case .userSignature:      return ["signatureLook", "hasCustomDefault"]
        }
    }

    /// The rev field rules gate on; nil for the LWW-only signature group.
    public var revField: String? {
        switch self {
        case .photoLook:          return "lookRev"
        case .photoOrder:         return "orderRev"
        case .sessionTitle:       return "titleRev"
        case .sessionRunningLook: return "rlRev"
        case .delete:             return "delRev"
        case .userSignature:      return nil
        }
    }

    /// firestore.rules TOMBSTONE_ONLY_KEYS() — the exact key set a tombstone
    /// update may touch (allowed even under the kill switch).
    public static let tombstoneOnlyKeys: Set<String> =
        ["deletedAt", "delRev", "delBy", "delMut", "updatedAt"]

    /// Which groups a target supports (drives journal validation).
    public static func groups(for target: SyncTarget) -> Set<FieldGroup> {
        switch target {
        case .user:    return [.userSignature]
        case .session: return [.sessionTitle, .sessionRunningLook, .delete]
        case .photo:   return [.photoLook, .photoOrder, .delete]
        }
    }
}

// MARK: - Group values (the coalesced local VALUE a journal entry carries)

/// The typed value of one field group — what the journal persists and what an
/// update payload writes. `look(nil)` means "inherit" and encodes literal null.
public enum GroupValue: Equatable, Codable, Sendable {
    case look(AutoHDR.BloomParams?)
    case order(Double)
    case title(String)
    case runningLook(AutoHDR.BloomParams, sameLookForAll: Bool)
    case tombstone(Date?)          // set (deletedAt) or clear (undo)
    case signature(AutoHDR.BloomParams?, hasCustomDefault: Bool)

    public var group: FieldGroup {
        switch self {
        case .look:        return .photoLook
        case .order:       return .photoOrder
        case .title:       return .sessionTitle
        case .runningLook: return .sessionRunningLook
        case .tombstone:   return .delete
        case .signature:   return .userSignature
        }
    }
}

// MARK: - BloomParams <-> FSValue

extension AutoHDR.BloomParams {
    /// Legacy dial names stay frozen; optional new keys are tolerant schema-v1
    /// additions that older clients ignore.
    public func fsMap() -> FSValue {
        // As with local Codable, OFF keeps the legacy fields neutral so clients
        // predating the switch cannot accidentally apply the preserved look.
        var wire = self
        if !hdrLookEnabled {
            wire = AutoHDR.BloomParams()
            wire.glow = 0
            wire.punch = 0
            wire.headroom = 1
            wire.bakeGlowIntoSDR = false
        }
        var map: [String: FSValue] = [
            "hdrLookEnabled": .bool(hdrLookEnabled),
            "glow": .double(wire.glow),
            "threshold": .double(wire.threshold),
            "spread": .double(wire.spread),
            "punch": .double(wire.punch),
            "peak": .double(wire.peak),
            "falloff": .double(wire.falloff),
            "saturation": .double(wire.saturation),
            "tint": .double(wire.tint),
            "headroom": .double(wire.headroom),
            "bakeGlowIntoSDR": .bool(wire.bakeGlowIntoSDR),
        ]
        if !hdrLookEnabled {
            map["preservedLook"] = .map([
                "glow": .double(glow),
                "threshold": .double(threshold),
                "spread": .double(spread),
                "punch": .double(punch),
                "peak": .double(peak),
                "falloff": .double(falloff),
                "saturation": .double(saturation),
                "tint": .double(tint),
                "headroom": .double(headroom),
                "bakeGlowIntoSDR": .bool(bakeGlowIntoSDR),
            ])
        }
        return .map(map)
    }

    /// Tolerant: missing keys keep defaults, unknown keys ignored.
    public init?(fsValue: FSValue) {
        guard let m = fsValue.mapValue else { return nil }
        self.init()
        let enabled = m["hdrLookEnabled"]?.boolValue ?? true
        let values = (!enabled ? m["preservedLook"]?.mapValue : nil) ?? m
        if let v = values["glow"]?.doubleValue { glow = v }
        if let v = values["threshold"]?.doubleValue { threshold = v }
        if let v = values["spread"]?.doubleValue { spread = v }
        if let v = values["punch"]?.doubleValue { punch = v }
        if let v = values["peak"]?.doubleValue { peak = v }
        if let v = values["falloff"]?.doubleValue { falloff = v }
        if let v = values["saturation"]?.doubleValue { saturation = v }
        if let v = values["tint"]?.doubleValue { tint = v }
        if let v = values["headroom"]?.doubleValue { headroom = v }
        if let v = values["bakeGlowIntoSDR"]?.boolValue { bakeGlowIntoSDR = v }
        hdrLookEnabled = enabled
    }
}

// MARK: - Decode helpers

private func revMeta(from m: [String: FSValue], _ revKey: String, _ byKey: String,
                     _ mutKey: String) -> RevMeta {
    RevMeta(rev: m[revKey]?.intValue.map(Int.init) ?? 0,
            by: m[byKey]?.stringValue ?? "",
            mut: m[mutKey]?.stringValue ?? "")
}

private func encodeRevMeta(_ meta: RevMeta, into m: inout [String: FSValue],
                           _ revKey: String, _ byKey: String, _ mutKey: String) {
    // A never-edited group stays implicit (rev 0 == absent, per rules).
    guard meta.rev > 0 else { return }
    m[revKey] = .int(Int64(meta.rev))
    m[byKey] = .string(meta.by)
    m[mutKey] = .string(meta.mut)
}

/// Shared future-schema gate: docs written by a NEWER protocol are skipped,
/// exactly like FileSessionStore does for local files.
private func schemaOK(_ m: [String: FSValue]) -> Bool {
    let v = m["schemaVersion"]?.intValue.map(Int.init) ?? SyncSchema.schemaVersion
    return v >= 1 && v <= SyncSchema.schemaVersion
}

// MARK: - RemotePhotoDoc

/// users/{uid}/sessions/{sessionId}/photos/{photoId}
public struct RemotePhotoDoc: Equatable, Sendable {
    public var id: UUID
    public var contentHash: String           // immutable once set
    public var look: AutoHDR.BloomParams?    // nil = inherit (literal null remotely)
    public var lookMeta: RevMeta
    public var orderKey: Double
    public var orderMeta: RevMeta
    public var gamut: String?                // "srgb" | "p3" when known
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var looksMerged: Bool
    public var lastExport: [String: FSValue]?  // informational, opaque
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var delMeta: RevMeta

    public init(id: UUID, contentHash: String, look: AutoHDR.BloomParams? = nil,
                lookMeta: RevMeta = .initial, orderKey: Double = 0,
                orderMeta: RevMeta = .initial, gamut: String? = nil,
                pixelWidth: Int? = nil, pixelHeight: Int? = nil,
                looksMerged: Bool = false, lastExport: [String: FSValue]? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(),
                deletedAt: Date? = nil, delMeta: RevMeta = .initial) {
        self.id = id
        self.contentHash = contentHash
        self.look = look
        self.lookMeta = lookMeta
        self.orderKey = orderKey
        self.orderMeta = orderMeta
        self.gamut = gamut
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.looksMerged = looksMerged
        self.lastExport = lastExport
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.delMeta = delMeta
    }

    /// Full-document encode (CREATE payload). Rev groups a fresh doc has never
    /// edited stay implicit. `look == nil` encodes LITERAL NULL — "inherit" is
    /// a stated value, not an omission (rules: map or null).
    public func fsMap() -> [String: FSValue] {
        var m: [String: FSValue] = [
            "schemaVersion": .int(Int64(SyncSchema.schemaVersion)),
            "contentHash": .string(contentHash),
            "look": look.map { $0.fsMap() } ?? .null,
            "orderKey": .double(orderKey),
            "looksMerged": .bool(looksMerged),
            "createdAt": .timestamp(createdAt),
            "updatedAt": .timestamp(updatedAt),
        ]
        if let g = gamut { m["gamut"] = .string(g) }
        if let w = pixelWidth { m["pixelWidth"] = .int(Int64(w)) }
        if let h = pixelHeight { m["pixelHeight"] = .int(Int64(h)) }
        if let e = lastExport { m["lastExport"] = .map(e) }
        if let d = deletedAt { m["deletedAt"] = .timestamp(d) }
        encodeRevMeta(lookMeta, into: &m, "lookRev", "lookBy", "lookMut")
        encodeRevMeta(orderMeta, into: &m, "orderRev", "orderBy", "orderMut")
        encodeRevMeta(delMeta, into: &m, "delRev", "delBy", "delMut")
        return m
    }

    /// Tolerant decode; nil when the doc is unusable (bad hash, future schema).
    public init?(id: UUID, fsMap m: [String: FSValue]) {
        guard schemaOK(m),
              let hash = m["contentHash"]?.stringValue,
              SyncSchema.isValidContentHash(hash) else { return nil }
        self.id = id
        self.contentHash = hash
        // Missing AND literal null both mean "inherit" (spec).
        self.look = m["look"].flatMap { AutoHDR.BloomParams(fsValue: $0) }
        self.lookMeta = revMeta(from: m, "lookRev", "lookBy", "lookMut")
        self.orderKey = m["orderKey"]?.doubleValue ?? 0
        self.orderMeta = revMeta(from: m, "orderRev", "orderBy", "orderMut")
        self.gamut = m["gamut"]?.stringValue
        self.pixelWidth = m["pixelWidth"]?.intValue.map(Int.init)
        self.pixelHeight = m["pixelHeight"]?.intValue.map(Int.init)
        self.looksMerged = m["looksMerged"]?.boolValue ?? false
        self.lastExport = m["lastExport"]?.mapValue
        self.createdAt = m["createdAt"]?.dateValue ?? Date(timeIntervalSince1970: 0)
        self.updatedAt = m["updatedAt"]?.dateValue ?? Date(timeIntervalSince1970: 0)
        self.deletedAt = m["deletedAt"]?.dateValue
        self.delMeta = revMeta(from: m, "delRev", "delBy", "delMut")
    }

    /// Remote ordering contract: (orderKey, createdAt, photoId) — the tiebreak
    /// makes concurrent same-key inserts deterministic on every device.
    public static func ordered(_ photos: [RemotePhotoDoc]) -> [RemotePhotoDoc] {
        photos.sorted {
            if $0.orderKey != $1.orderKey { return $0.orderKey < $1.orderKey }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

// MARK: - RemoteSessionDoc

/// users/{uid}/sessions/{sessionId}
public struct RemoteSessionDoc: Equatable, Sendable {
    public struct Cover: Equatable, Sendable {
        public var photoId: UUID
        public var contentHash: String
        public init(photoId: UUID, contentHash: String) {
            self.photoId = photoId
            self.contentHash = contentHash
        }
    }

    public var id: UUID
    public var title: String
    public var titleMeta: RevMeta
    public var sameLookForAll: Bool
    public var runningLook: AutoHDR.BloomParams
    public var rlMeta: RevMeta
    public var covers: [Cover]               // <= 4; derived, LWW
    public var photoCount: Int               // UI-only; derived, LWW
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var delMeta: RevMeta

    public init(id: UUID, title: String = "", titleMeta: RevMeta = .initial,
                sameLookForAll: Bool = false,
                runningLook: AutoHDR.BloomParams = AutoHDR.BloomParams(),
                rlMeta: RevMeta = .initial, covers: [Cover] = [], photoCount: Int = 0,
                createdAt: Date = Date(), updatedAt: Date = Date(),
                deletedAt: Date? = nil, delMeta: RevMeta = .initial) {
        self.id = id
        self.title = title
        self.titleMeta = titleMeta
        self.sameLookForAll = sameLookForAll
        self.runningLook = runningLook
        self.rlMeta = rlMeta
        self.covers = Array(covers.prefix(SyncSchema.maxCovers))
        self.photoCount = photoCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.delMeta = delMeta
    }

    public func fsMap() -> [String: FSValue] {
        var m: [String: FSValue] = [
            "schemaVersion": .int(Int64(SyncSchema.schemaVersion)),
            "title": .string(title),
            "sameLookForAll": .bool(sameLookForAll),
            "runningLook": runningLook.fsMap(),
            "covers": .array(covers.prefix(SyncSchema.maxCovers).map {
                .map(["photoId": .string($0.photoId.uuidString),
                      "contentHash": .string($0.contentHash)])
            }),
            "photoCount": .int(Int64(photoCount)),
            "createdAt": .timestamp(createdAt),
            "updatedAt": .timestamp(updatedAt),
        ]
        if let d = deletedAt { m["deletedAt"] = .timestamp(d) }
        encodeRevMeta(titleMeta, into: &m, "titleRev", "titleBy", "titleMut")
        encodeRevMeta(rlMeta, into: &m, "rlRev", "rlBy", "rlMut")
        encodeRevMeta(delMeta, into: &m, "delRev", "delBy", "delMut")
        return m
    }

    public init?(id: UUID, fsMap m: [String: FSValue]) {
        guard schemaOK(m) else { return nil }
        self.id = id
        self.title = m["title"]?.stringValue ?? ""
        self.titleMeta = revMeta(from: m, "titleRev", "titleBy", "titleMut")
        self.sameLookForAll = m["sameLookForAll"]?.boolValue ?? false
        self.runningLook = m["runningLook"].flatMap { AutoHDR.BloomParams(fsValue: $0) }
            ?? AutoHDR.BloomParams()
        self.rlMeta = revMeta(from: m, "rlRev", "rlBy", "rlMut")
        self.covers = (m["covers"]?.arrayValue ?? []).compactMap { entry in
            guard let em = entry.mapValue,
                  let idString = em["photoId"]?.stringValue,
                  let pid = UUID(uuidString: idString),
                  let hash = em["contentHash"]?.stringValue else { return nil }
            return Cover(photoId: pid, contentHash: hash)
        }
        self.photoCount = m["photoCount"]?.intValue.map(Int.init) ?? 0
        self.createdAt = m["createdAt"]?.dateValue ?? Date(timeIntervalSince1970: 0)
        self.updatedAt = m["updatedAt"]?.dateValue ?? Date(timeIntervalSince1970: 0)
        self.deletedAt = m["deletedAt"]?.dateValue
        self.delMeta = revMeta(from: m, "delRev", "delBy", "delMut")
    }
}

// MARK: - RemoteBlobDoc

/// users/{uid}/blobs/{contentHash}. The client creates a shell; renditions.*,
/// state and gcCandidateAt are server-owned (usageReconciler / maintenance) —
/// modeled decode-only, and shellFSMap() deliberately cannot emit them.
public struct RemoteBlobDoc: Equatable, Sendable {
    public struct Rendition: Equatable, Sendable {
        /// GCS generation — 64-bit, kept as String (never a Double round-trip).
        public var generation: String
        public var byteSize: Int64
        public var counted: Bool
        public var uploadedAt: Date?

        public init(generation: String, byteSize: Int64, counted: Bool, uploadedAt: Date?) {
            self.generation = generation
            self.byteSize = byteSize
            self.counted = counted
            self.uploadedAt = uploadedAt
        }
    }

    public enum State: String, Sendable {
        case active, gcCandidate, deleting
    }

    public var contentHash: String
    public var byteSize: Int64
    public var createdAt: Date
    // Server-owned:
    public var renditions: [String: Rendition]   // keyed by tier
    public var state: State

    public init(contentHash: String, byteSize: Int64, createdAt: Date = Date(),
                renditions: [String: Rendition] = [:], state: State = .active) {
        self.contentHash = contentHash
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.renditions = renditions
        self.state = state
    }

    /// The CREATE shell — the only blob write a client may perform. Emitting
    /// any server-owned key here would be rejected by rules.
    public func shellFSMap() -> [String: FSValue] {
        [
            "schemaVersion": .int(Int64(SyncSchema.schemaVersion)),
            "contentHash": .string(contentHash),
            "byteSize": .int(byteSize),
            "createdAt": .timestamp(createdAt),
        ]
    }

    public init?(contentHash: String, fsMap m: [String: FSValue]) {
        guard schemaOK(m), SyncSchema.isValidContentHash(contentHash) else { return nil }
        self.contentHash = contentHash
        self.byteSize = m["byteSize"]?.intValue ?? 0
        self.createdAt = m["createdAt"]?.dateValue ?? Date(timeIntervalSince1970: 0)
        var rends: [String: Rendition] = [:]
        if let rm = m["renditions"]?.mapValue {
            for (tier, v) in rm {
                guard let tm = v.mapValue else { continue }
                // Generations can be written as int or string; normalize to String.
                let gen = tm["generation"]?.stringValue
                    ?? tm["generation"]?.intValue.map(String.init) ?? ""
                rends[tier] = Rendition(
                    generation: gen,
                    byteSize: tm["byteSize"]?.intValue ?? 0,
                    counted: tm["counted"]?.boolValue ?? false,
                    uploadedAt: tm["uploadedAt"]?.dateValue)
            }
        }
        self.renditions = rends
        self.state = (m["state"]?.stringValue).flatMap(State.init(rawValue:)) ?? .active
    }

    /// The completion signal the client trusts but never writes.
    public func isUploaded(tier: String) -> Bool {
        renditions[tier]?.uploadedAt != nil
    }
}

// MARK: - RemoteUserDoc / usage / reservation (decode-mostly)

/// users/{uid}. Provisioned by admitSyncUser; the client may update only the
/// signature group (whole-map LWW) — quotaBytes/syncAdmitted/entitlement are
/// server-owned.
public struct RemoteUserDoc: Equatable, Sendable {
    public var signatureLook: AutoHDR.BloomParams?
    public var hasCustomDefault: Bool
    public var quotaBytes: Int64
    public var syncAdmitted: Bool
    public var createdAt: Date?

    public init(signatureLook: AutoHDR.BloomParams? = nil, hasCustomDefault: Bool = false,
                quotaBytes: Int64 = 0, syncAdmitted: Bool = false, createdAt: Date? = nil) {
        self.signatureLook = signatureLook
        self.hasCustomDefault = hasCustomDefault
        self.quotaBytes = quotaBytes
        self.syncAdmitted = syncAdmitted
        self.createdAt = createdAt
    }

    public init?(fsMap m: [String: FSValue]) {
        guard schemaOK(m) else { return nil }
        self.signatureLook = m["signatureLook"].flatMap { AutoHDR.BloomParams(fsValue: $0) }
        self.hasCustomDefault = m["hasCustomDefault"]?.boolValue ?? false
        self.quotaBytes = m["quotaBytes"]?.intValue ?? 0
        self.syncAdmitted = m["syncAdmitted"]?.boolValue ?? false
        self.createdAt = m["createdAt"]?.dateValue
    }
}

/// users/{uid}/usage/storage — CF-owned ledger, read-only for clients.
public struct RemoteUsageDoc: Equatable, Sendable {
    public var bytesUsed: Int64
    public var reservedBytes: Int64

    public init(bytesUsed: Int64 = 0, reservedBytes: Int64 = 0) {
        self.bytesUsed = bytesUsed
        self.reservedBytes = reservedBytes
    }

    public init?(fsMap m: [String: FSValue]) {
        guard schemaOK(m) else { return nil }
        self.bytesUsed = m["bytesUsed"]?.intValue ?? 0
        self.reservedBytes = m["reservedBytes"]?.intValue ?? 0
    }
}

/// users/{uid}/reservations/{tier}_{hash} — written by reserveUpload only.
/// The client reads expiresAt to know its completion deadline (r7: single
/// deadline; a finalize-time 403 means the lease expired mid-upload).
public struct RemoteReservationDoc: Equatable, Sendable {
    public var contentHash: String
    public var tier: String
    public var byteSize: Int64
    public var expiresAt: Date

    public init(contentHash: String, tier: String, byteSize: Int64, expiresAt: Date) {
        self.contentHash = contentHash
        self.tier = tier
        self.byteSize = byteSize
        self.expiresAt = expiresAt
    }

    public init?(fsMap m: [String: FSValue]) {
        guard schemaOK(m),
              let hash = m["contentHash"]?.stringValue,
              let tier = m["tier"]?.stringValue,
              let expires = m["expiresAt"]?.dateValue else { return nil }
        self.contentHash = hash
        self.tier = tier
        self.byteSize = m["byteSize"]?.intValue ?? 0
        self.expiresAt = expires
    }
}

// MARK: - Update payload builders

/// Builds the exact merge payloads a journal drain writes. Central so the
/// "touches exactly the group's keys (+ updatedAt)" invariant — what the rules
/// enforce — is authored once and unit-tested against FieldGroup.keys.
public enum SyncMutationPayload {

    /// Update payload for one group: the group's value fields + its rev/by/mut
    /// (rev = baseRev + 1) + updatedAt. For `.userSignature` there is no rev
    /// group — the payload is just the two signature fields + updatedAt.
    public static func update(value: GroupValue, baseRev: Int, deviceID: String,
                              mutationID: String, updatedAt: Date) -> [String: FSValue] {
        var m: [String: FSValue] = ["updatedAt": .timestamp(updatedAt)]
        switch value {
        case .look(let params):
            m["look"] = params.map { $0.fsMap() } ?? .null
            m["lookRev"] = .int(Int64(baseRev + 1))
            m["lookBy"] = .string(deviceID)
            m["lookMut"] = .string(mutationID)
        case .order(let key):
            m["orderKey"] = .double(key)
            m["orderRev"] = .int(Int64(baseRev + 1))
            m["orderBy"] = .string(deviceID)
            m["orderMut"] = .string(mutationID)
        case .title(let title):
            m["title"] = .string(title)
            m["titleRev"] = .int(Int64(baseRev + 1))
            m["titleBy"] = .string(deviceID)
            m["titleMut"] = .string(mutationID)
        case .runningLook(let params, let same):
            m["runningLook"] = params.fsMap()
            m["sameLookForAll"] = .bool(same)
            m["rlRev"] = .int(Int64(baseRev + 1))
            m["rlBy"] = .string(deviceID)
            m["rlMut"] = .string(mutationID)
        case .tombstone(let deletedAt):
            m["deletedAt"] = deletedAt.map { .timestamp($0) } ?? .null
            m["delRev"] = .int(Int64(baseRev + 1))
            m["delBy"] = .string(deviceID)
            m["delMut"] = .string(mutationID)
        case .signature(let params, let hasCustom):
            m["signatureLook"] = params.map { $0.fsMap() } ?? .null
            m["hasCustomDefault"] = .bool(hasCustom)
        }
        return m
    }

    /// True iff a payload could pass the kill switch's tombstone-only gate.
    public static func isTombstoneOnly(_ payload: [String: FSValue]) -> Bool {
        Set(payload.keys).isSubset(of: FieldGroup.tombstoneOnlyKeys)
    }
}
