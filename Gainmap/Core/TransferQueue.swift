//
//  TransferQueue.swift
//  GainmapCore
//
//  P4: the upload pipeline's brain — a pure, persisted state machine. The
//  SyncEngine feeds it events (reserved, upload succeeded/failed, relaunch,
//  retry triggers) and asks it what to do next; all policy lives here where
//  it's unit-testable:
//
//    * reserve -> upload -> (server finalizes; reconciler acks via blob doc)
//    * thumbs before originals (peers show mosaics fast)
//    * skip-if-exists via the blob rendition ledger
//    * exponential backoff -> visibly parked after repeated failures
//    * quota-exceeded is a FIRST-CLASS TERMINAL state (spec r4)
//    * lease-expired-at-finalize (r7): re-reserve (idempotent refresh) and
//      start a NEW upload session — a denied finalize terminated the old one
//    * Wi-Fi gate: originals wait for an allowed network; thumbs always go
//    * relaunch restarts anything that was mid-flight (#147)
//

import Foundation

// MARK: - Transfer

public struct Transfer: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case queued          // wants a reservation
        case reserving       // reserveUpload call in flight
        case uploading       // bytes moving (or about to)
        case done
        case parked          // gave up after repeated failures; visible, retryable
        case quotaExceeded   // terminal until quota changes / user frees space
    }

    /// tier_hash — same scheme as the reservation doc id.
    public var id: String { SyncSchema.reservationId(tier: tier, contentHash: contentHash) }

    public let contentHash: String
    public let tier: String                // "thumbs" | "originals" | "proxies"
    public let byteSize: Int64
    /// Absolute path of the bytes to upload (original file or generated thumb).
    public var sourcePath: String
    public var status: Status
    public var attempts: Int
    public var lastError: String?
    /// The reservation's completion deadline (r7 single deadline).
    public var expiresAt: Date?
    public var nextRetryAt: Date?

    public init(contentHash: String, tier: String, byteSize: Int64, sourcePath: String,
                status: Status = .queued, attempts: Int = 0, lastError: String? = nil,
                expiresAt: Date? = nil, nextRetryAt: Date? = nil) {
        self.contentHash = contentHash
        self.tier = tier
        self.byteSize = byteSize
        self.sourcePath = sourcePath
        self.status = status
        self.attempts = attempts
        self.lastError = lastError
        self.expiresAt = expiresAt
        self.nextRetryAt = nextRetryAt
    }
}

// MARK: - Events + actions

public enum TransferFailure: Equatable, Sendable {
    /// Storage 403 at finalize — the lease expired mid-upload. NOT a strike:
    /// the fix is a fresh reservation + a new upload session.
    case leaseExpired
    /// reserveUpload resource-exhausted — terminal until quota changes.
    case quotaExceeded
    /// Kill switch / not admitted — parked immediately (retrying won't help
    /// until config changes; a flags listener re-triggers).
    case syncUnavailable(String)
    /// Anything retryable: offline, deadline, 5xx…
    case transient(String)
}

public enum TransferAction: Equatable, Sendable {
    /// Call reserveUpload(contentHash, tier, byteSize).
    case reserve(Transfer)
    /// Upload sourcePath to its object name (a reservation is live).
    case upload(Transfer)
}

// MARK: - Queue state machine

public struct TransferQueue: Codable, Equatable, Sendable {
    public private(set) var transfers: [Transfer]

    /// Park after this many failed attempts (backoff exhausted).
    public static let maxAttempts = 5
    /// Backoff schedule per attempt count (seconds).
    public static let backoff: [TimeInterval] = [2, 15, 60, 300, 900]

    public init(transfers: [Transfer] = []) {
        self.transfers = transfers
    }

    private func index(_ id: String) -> Int? {
        transfers.firstIndex { $0.id == id }
    }

    public func transfer(id: String) -> Transfer? {
        index(id).map { transfers[$0] }
    }

    /// Anything not done/terminal — what the UI's sync badge counts.
    public var activeCount: Int {
        transfers.filter { $0.status != .done && $0.status != .quotaExceeded }.count
    }

    public var hasParked: Bool { transfers.contains { $0.status == .parked } }
    public var isQuotaExceeded: Bool { transfers.contains { $0.status == .quotaExceeded } }

    // ---------------------------------------------------------------- intake

    /// Enqueue a rendition upload. No-ops: duplicates (same tier+hash, not
    /// failed), and anything >= the per-object cap (tooLargeToSync — those
    /// never reach the queue). Re-enqueueing a `done` transfer no-ops too
    /// (content-addressed: same bytes are already up).
    public mutating func enqueue(contentHash: String, tier: String, byteSize: Int64,
                                 sourcePath: String) {
        guard byteSize > 0, byteSize < SyncSchema.maxObjectBytes else { return }
        guard SyncSchema.isValidContentHash(contentHash) else { return }
        let id = SyncSchema.reservationId(tier: tier, contentHash: contentHash)
        if let i = index(id) {
            // Refresh the source path (file may have moved); revive parked
            // entries — a fresh enqueue is an explicit new reason to try.
            transfers[i].sourcePath = sourcePath
            if transfers[i].status == .parked {
                transfers[i].status = .queued
                transfers[i].attempts = 0
                transfers[i].nextRetryAt = nil
            }
            return
        }
        transfers.append(Transfer(contentHash: contentHash, tier: tier,
                                  byteSize: byteSize, sourcePath: sourcePath))
    }

    /// The blob ledger already shows this rendition uploaded — skip entirely.
    public mutating func markAlreadyUploaded(id: String) {
        guard let i = index(id) else { return }
        transfers[i].status = .done
        transfers[i].lastError = nil
    }

    // ---------------------------------------------------------------- planning

    /// What to do now. Thumbs first (mosaics on peers), then originals;
    /// originals additionally gated by `allowLargeTransfers` (Wi-Fi policy).
    /// Respects per-transfer backoff and a caller-chosen concurrency budget.
    public func nextActions(now: Date, allowLargeTransfers: Bool,
                            maxConcurrent: Int = 2) -> [TransferAction] {
        let inFlight = transfers.filter {
            $0.status == .reserving || $0.status == .uploading
        }.count
        guard inFlight < maxConcurrent else { return [] }

        let eligible = transfers.filter { t in
            t.status == .queued
                && (t.nextRetryAt.map { $0 <= now } ?? true)
                && (t.tier == "thumbs" || allowLargeTransfers)
        }
        let ordered = eligible.sorted {
            if ($0.tier == "thumbs") != ($1.tier == "thumbs") { return $0.tier == "thumbs" }
            return $0.byteSize < $1.byteSize
        }
        return ordered.prefix(maxConcurrent - inFlight).map { t in
            // A live, unexpired reservation can be reused (idempotent refresh
            // is cheap but a round-trip); otherwise reserve first.
            if let expires = t.expiresAt, expires > now { return .upload(t) }
            return .reserve(t)
        }
    }

    // ---------------------------------------------------------------- events

    public mutating func beganReserving(id: String) {
        guard let i = index(id) else { return }
        transfers[i].status = .reserving
    }

    public mutating func reserved(id: String, expiresAt: Date) {
        guard let i = index(id) else { return }
        transfers[i].status = .uploading
        transfers[i].expiresAt = expiresAt
        transfers[i].lastError = nil
    }

    public mutating func uploadSucceeded(id: String) {
        guard let i = index(id) else { return }
        transfers[i].status = .done
        transfers[i].lastError = nil
        transfers[i].nextRetryAt = nil
    }

    public mutating func failed(id: String, failure: TransferFailure, now: Date) {
        guard let i = index(id) else { return }
        switch failure {
        case .leaseExpired:
            // r7 contract: not a strike. Drop the dead reservation; the next
            // plan re-reserves (idempotent refresh) and re-uploads fresh.
            transfers[i].status = .queued
            transfers[i].expiresAt = nil
            transfers[i].lastError = "Upload lease expired; re-reserving."
        case .quotaExceeded:
            transfers[i].status = .quotaExceeded
            transfers[i].expiresAt = nil
            transfers[i].lastError = "Storage quota exceeded."
        case .syncUnavailable(let why):
            transfers[i].status = .parked
            transfers[i].expiresAt = nil
            transfers[i].lastError = why
        case .transient(let why):
            transfers[i].attempts += 1
            transfers[i].lastError = why
            if transfers[i].attempts >= Self.maxAttempts {
                transfers[i].status = .parked
                transfers[i].nextRetryAt = nil
            } else {
                let delay = Self.backoff[min(transfers[i].attempts - 1,
                                             Self.backoff.count - 1)]
                transfers[i].status = .queued
                transfers[i].nextRetryAt = now.addingTimeInterval(delay)
            }
        }
    }

    /// Foreground / network-change / user-tapped-retry: parked entries get a
    /// clean slate; backoff timers are cut short.
    public mutating func retryTrigger() {
        for i in transfers.indices {
            switch transfers[i].status {
            case .parked:
                transfers[i].status = .queued
                transfers[i].attempts = 0
                transfers[i].nextRetryAt = nil
            case .queued:
                transfers[i].nextRetryAt = nil
            default:
                break
            }
        }
    }

    /// Quota changed (raise, frees, deletes): terminal entries become
    /// retryable again.
    public mutating func quotaChanged() {
        for i in transfers.indices where transfers[i].status == .quotaExceeded {
            transfers[i].status = .queued
            transfers[i].attempts = 0
            transfers[i].nextRetryAt = nil
        }
    }

    /// Restart incomplete work after relaunch (#147): whatever was mid-flight
    /// goes back to queued. Reservations persist server-side; an unexpired
    /// one is reused by the next plan.
    public mutating func relaunch() {
        for i in transfers.indices {
            let s = transfers[i].status
            if s == .reserving || s == .uploading {
                transfers[i].status = .queued
            }
        }
    }

    /// Remove completed entries (housekeeping after the ledger confirms).
    public mutating func pruneDone() {
        transfers.removeAll { $0.status == .done }
    }

    /// Account teardown.
    public mutating func removeAll() {
        transfers.removeAll()
    }
}
