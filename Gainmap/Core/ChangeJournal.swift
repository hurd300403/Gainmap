//
//  ChangeJournal.swift
//  GainmapCore
//
//  P4: the outbound half of the sync protocol. Every local edit records ONE
//  coalesced pending mutation per (target, field group): the latest local
//  VALUE (not field names — the drain and the conflict record both need the
//  value), the remote rev it branched from (baseRev), and a mutationID that
//  doubles as the self-ack marker (a remote snapshot whose group `mut` equals
//  our mutationID is our own write landing, never a conflict).
//
//  Persistence contract: the journal is flushed in the SAME debounce cycle as
//  the session file (MergeModel.flushSession writes both back-to-back), so a
//  crash leaves the pair consistent — either both reflect the edit or neither
//  does; both orders converge after the next drain + inbound snapshot.
//

import Foundation

// MARK: - Pending mutation

/// One coalesced outbound mutation for a (target, group).
public struct PendingMutation: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case pending       // waiting for a drain
        case inFlight      // a drain transaction is running with this value
    }

    public var id: String { PendingMutation.key(target: target, group: group) }

    public let target: SyncTarget
    public let group: FieldGroup
    /// The remote rev this mutation was made on top of. Stays put while
    /// coalescing (inbound never overwrites a dirty group, so the local branch
    /// point doesn't move); advances only when our own prior commit re-arms a
    /// queued `next` value.
    public var baseRev: Int
    public var mutationID: String
    public let deviceID: String
    public var value: GroupValue
    /// An edit that landed while `value` was in flight — becomes the next
    /// pending mutation when the flight resolves.
    public var next: GroupValue?
    public var state: State
    public var createdAt: Date

    public static func key(target: SyncTarget, group: FieldGroup) -> String {
        let t: String
        switch target {
        case .user: t = "user"
        case .session(let s): t = "s/\(s.uuidString)"
        case .photo(let s, let p): t = "s/\(s.uuidString)/p/\(p.uuidString)"
        }
        return "\(t)#\(group.rawValue)"
    }

    /// The latest local value — what the UI overlay shows and what a conflict
    /// record preserves.
    public var latestValue: GroupValue { next ?? value }
}

// MARK: - Conflict record (the preserved loser)

/// A local value that lost a conflict — adopted remote won, but the user's
/// work is recoverable: "Your edit was superseded by your other device —
/// Restore?" Restore re-applies `localValue` as a NEW mutation on the current
/// rev (the engine records a fresh journal entry; nothing is rewound).
public struct ConflictRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let target: SyncTarget
    public let group: FieldGroup
    public let localValue: GroupValue
    /// deviceID of the remote writer that superseded us ("" when unknown).
    public let supersededBy: String
    public let occurredAt: Date

    public init(id: UUID = UUID(), target: SyncTarget, group: FieldGroup,
                localValue: GroupValue, supersededBy: String, occurredAt: Date = Date()) {
        self.id = id
        self.target = target
        self.group = group
        self.localValue = localValue
        self.supersededBy = supersededBy
        self.occurredAt = occurredAt
    }
}

// MARK: - Journal

/// Value-semantic journal state: an index of pending mutations plus the
/// conflict log. The SyncEngine owns one, persists it alongside the session
/// files, and drains it when online.
public struct ChangeJournal: Codable, Equatable, Sendable {
    public private(set) var entries: [PendingMutation]
    public private(set) var conflicts: [ConflictRecord]

    public init(entries: [PendingMutation] = [], conflicts: [ConflictRecord] = []) {
        self.entries = entries
        self.conflicts = conflicts
    }

    private func index(target: SyncTarget, group: FieldGroup) -> Int? {
        let key = PendingMutation.key(target: target, group: group)
        return entries.firstIndex { $0.id == key }
    }

    public func entry(target: SyncTarget, group: FieldGroup) -> PendingMutation? {
        index(target: target, group: group).map { entries[$0] }
    }

    /// True when the group has local changes the server hasn't acked —
    /// "inbound snapshots never overwrite dirty field groups".
    public func isDirty(target: SyncTarget, group: FieldGroup) -> Bool {
        entry(target: target, group: group) != nil
    }

    /// The dirty-value overlay the UI (and inbound merge) reads.
    public func overlay(for target: SyncTarget) -> [FieldGroup: GroupValue] {
        var out: [FieldGroup: GroupValue] = [:]
        for e in entries where e.target == target {
            out[e.group] = e.latestValue
        }
        return out
    }

    // ------------------------------------------------------------------ record

    /// Record a local edit. Coalesces into an existing pending entry (latest
    /// value wins, branch point and mutationID kept — nothing with that ID has
    /// been written yet); parks as `next` when the current value is in flight.
    /// `baseRev` is the group's CURRENT remote rev as known locally — used
    /// only when this creates a fresh entry.
    public mutating func record(target: SyncTarget, value: GroupValue,
                                baseRev: Int, deviceID: String, now: Date = Date()) {
        let group = value.group
        precondition(FieldGroup.groups(for: target).contains(group),
                     "group \(group) is not valid for \(target)")
        if let i = index(target: target, group: group) {
            switch entries[i].state {
            case .pending:
                entries[i].value = value
                entries[i].next = nil
            case .inFlight:
                entries[i].next = value
            }
        } else {
            entries.append(PendingMutation(
                target: target, group: group, baseRev: baseRev,
                mutationID: UUID().uuidString, deviceID: deviceID,
                value: value, next: nil, state: .pending, createdAt: now))
        }
    }

    // ------------------------------------------------------------------ drain

    /// Entries a drain should attempt now (snapshot; caller marks in-flight).
    public var pendingEntries: [PendingMutation] {
        entries.filter { $0.state == .pending }
    }

    /// Entries stuck in flight from a previous process (crash mid-drain).
    /// On relaunch these go back to pending; the drain's ConflictPolicy
    /// self-acks via mutationID if the write actually landed.
    public mutating func requeueInFlightAfterRelaunch() {
        for i in entries.indices where entries[i].state == .inFlight {
            entries[i].state = .pending
        }
    }

    public mutating func markInFlight(target: SyncTarget, group: FieldGroup) {
        guard let i = index(target: target, group: group) else { return }
        entries[i].state = .inFlight
    }

    /// Our write committed at `committedRev` (or was found already applied /
    /// already satisfied). If an edit queued up mid-flight, it re-arms as the
    /// next pending mutation branched from the committed rev, with a FRESH
    /// mutationID (the old ID is now on the server).
    public mutating func completeCommit(target: SyncTarget, group: FieldGroup,
                                        committedRev: Int, now: Date = Date()) {
        guard let i = index(target: target, group: group) else { return }
        if let queued = entries[i].next {
            entries[i].value = queued
            entries[i].next = nil
            entries[i].baseRev = committedRev
            entries[i].mutationID = UUID().uuidString
            entries[i].state = .pending
            entries[i].createdAt = now
        } else {
            entries.remove(at: i)
        }
    }

    /// Transient failure (offline, deadline, transaction abort): back to
    /// pending, everything else intact — the next drain retries.
    public mutating func completeFailure(target: SyncTarget, group: FieldGroup) {
        guard let i = index(target: target, group: group) else { return }
        entries[i].state = .pending
    }

    /// Delete-wins retry: the pending tombstone reloads onto the current rev
    /// and stays pending (the delete still wins; it just needed the new rev).
    public mutating func rebase(target: SyncTarget, group: FieldGroup, to newBaseRev: Int) {
        guard let i = index(target: target, group: group) else { return }
        entries[i].baseRev = newBaseRev
        entries[i].state = .pending
    }

    /// The entry lost (remote adopted): remove it and preserve the LATEST
    /// local value as a recoverable conflict record.
    @discardableResult
    public mutating func resolveConflict(target: SyncTarget, group: FieldGroup,
                                         supersededBy: String,
                                         now: Date = Date()) -> ConflictRecord? {
        guard let i = index(target: target, group: group) else { return nil }
        let e = entries.remove(at: i)
        let record = ConflictRecord(target: target, group: group,
                                    localValue: e.latestValue,
                                    supersededBy: supersededBy, occurredAt: now)
        conflicts.append(record)
        return record
    }

    /// Drop an entry with no conflict record (target purged remotely and
    /// acked, or already satisfied with no queued follow-up).
    public mutating func drop(target: SyncTarget, group: FieldGroup) {
        guard let i = index(target: target, group: group) else { return }
        entries.remove(at: i)
    }

    /// Drop every entry for a target (used when adopting a remote tombstone
    /// purge locally).
    public mutating func dropAll(for target: SyncTarget) {
        entries.removeAll { $0.target == target }
    }

    // ------------------------------------------------------------------ conflicts

    /// Restore pops the record; the caller re-applies `localValue` as a brand
    /// new local mutation (record → journal → drain on the current rev).
    public mutating func popConflict(id: UUID) -> ConflictRecord? {
        guard let i = conflicts.firstIndex(where: { $0.id == id }) else { return nil }
        return conflicts.remove(at: i)
    }

    public mutating func dismissConflict(id: UUID) {
        conflicts.removeAll { $0.id == id }
    }
}

// MARK: - Ack ledger (reconcile's memory)

/// Per-record "has the server ever acknowledged this record" — the bit that
/// makes the >30-days-offline reconcile safe: acked-but-absent means the
/// record was purged remotely (adopt the purge); never-acked means the server
/// never saw it (preserve and upload). Keyed by SyncTarget.
public struct AckLedger: Codable, Equatable, Sendable {
    private var acked: Set<String>

    public init(acked: Set<String> = []) {
        self.acked = acked
    }

    private static func key(_ target: SyncTarget) -> String {
        PendingMutation.key(target: target, group: .delete)   // group irrelevant; reuse keying
    }

    public mutating func markAcked(_ target: SyncTarget) {
        acked.insert(Self.key(target))
    }

    public func everAcked(_ target: SyncTarget) -> Bool {
        acked.contains(Self.key(target))
    }

    /// Account teardown / uid switch.
    public mutating func removeAll() {
        acked.removeAll()
    }

    public mutating func remove(_ target: SyncTarget) {
        acked.remove(Self.key(target))
    }
}
