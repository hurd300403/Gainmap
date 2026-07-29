//
//  ConflictPolicy.swift
//  GainmapCore
//
//  P4: the pure decision table a drain transaction evaluates for one pending
//  mutation against the group's current remote state. Every branch is spec'd
//  (r5 "preserve-the-loser", r6 "delete-wins with explicit exceptions") and
//  unit-tested; the SyncEngine just executes the returned decision inside a
//  Firestore transaction.
//
//  The invariant the whole protocol hangs on: rules enforce
//  `new.rev == old.rev + 1` per group, so a drain can only commit when its
//  baseRev still equals the remote rev — everything else lands here.
//

import Foundation

/// The remote side of one field group, as read inside the drain transaction.
public struct RemoteGroupState: Equatable, Sendable {
    /// False when the document is gone (purged by maintenance/deleteAccount).
    public var docExists: Bool
    /// The group's current rev (missing field == 0, same as rules).
    public var rev: Int
    /// The group's current mutationID ("" when never edited).
    public var mut: String
    /// The DOCUMENT's tombstone state (delete group), regardless of which
    /// group is draining — a remote tombstone beats any pending edit.
    public var deletedAt: Date?
    /// The delete group's current rev (undo needs it).
    public var delRev: Int

    public init(docExists: Bool = true, rev: Int = 0, mut: String = "",
                deletedAt: Date? = nil, delRev: Int = 0) {
        self.docExists = docExists
        self.rev = rev
        self.mut = mut
        self.deletedAt = deletedAt
        self.delRev = delRev
    }
}

/// What the drain should do with one pending mutation.
public enum DrainDecision: Equatable, Sendable {
    /// baseRev matches: write the update payload (rev = baseRev + 1).
    case write
    /// The remote group's mut IS our mutationID — our own earlier write
    /// landed (crash between commit and journal update). Ack, don't rewrite.
    case alreadyApplied(committedRev: Int)
    /// Nothing to do (e.g. tombstone-set but the doc is already tombstoned
    /// remotely — both-tombstoned converges silently).
    case satisfied
    /// Delete-wins: the pending tombstone rebases onto the current rev and
    /// retries — an interleaved edit does not save the record from deletion.
    case retry(newBaseRev: Int)
    /// The local value lost: adopt remote, preserve the loser as a
    /// ConflictRecord (supersededBy = the remote group's author when known).
    case conflict
    /// The document no longer exists remotely. The engine decides between
    /// "create is still queued" (drain creates first, then retry) and
    /// "record was purged" (drop the entry, adopt the purge locally).
    case targetGone
}

public enum ConflictPolicy {

    /// Decide one pending mutation against the remote group state.
    public static func decide(pending: PendingMutation,
                              remote: RemoteGroupState) -> DrainDecision {
        guard remote.docExists else { return .targetGone }

        // Self-ack FIRST: if the remote group already carries our mutationID,
        // this exact mutation committed — whatever else changed since is a
        // matter for later drains, not this one.
        if !pending.mutationID.isEmpty && remote.mut == pending.mutationID {
            return .alreadyApplied(committedRev: remote.rev)
        }

        // The signature group has no rev — deliberate whole-map commit-order
        // LWW (user-scoped, rarely contended).
        if pending.group == .userSignature { return .write }

        switch pending.value {
        case .tombstone(let deletedAt) where deletedAt != nil:
            // DELETE-WINS. Already deleted remotely → converged, nothing to
            // write. Otherwise a rev mismatch (an edit committed first) does
            // NOT lose: rebase and retry until the tombstone lands.
            if remote.deletedAt != nil { return .satisfied }
            return remote.rev == pending.baseRev ? .write : .retry(newBaseRev: remote.rev)

        case .tombstone(nil):
            // UNDO clears only the tombstone revision it observed. If the
            // deletion state moved again (re-deleted, undone elsewhere), the
            // undo is stale — surface it, never blind-clear.
            if remote.deletedAt == nil { return .satisfied }   // already undone
            return remote.rev == pending.baseRev ? .write : .conflict

        default:
            // ORDINARY EDIT. A remote tombstone beats it outright — even on a
            // matching rev, we do not decorate a deleted record; the edit is
            // preserved as a conflict record instead (r6).
            if remote.deletedAt != nil { return .conflict }
            return remote.rev == pending.baseRev ? .write : .conflict
        }
    }
}

// MARK: - Inbound merge (dirty-group overlay)

/// Applies the journal's dirty-value overlay onto an inbound remote doc:
/// clean groups adopt the snapshot, dirty groups keep the local value until
/// their drain resolves. Pure; the engine feeds it every listener event.
public enum InboundMerge {

    public static func merged(photo remote: RemotePhotoDoc,
                              overlay: [FieldGroup: GroupValue]) -> RemotePhotoDoc {
        var doc = remote
        if case .look(let params)? = overlay[.photoLook] { doc.look = params }
        if case .order(let key)? = overlay[.photoOrder] { doc.orderKey = key }
        if case .tombstone(let deletedAt)? = overlay[.delete] { doc.deletedAt = deletedAt }
        return doc
    }

    public static func merged(session remote: RemoteSessionDoc,
                              overlay: [FieldGroup: GroupValue]) -> RemoteSessionDoc {
        var doc = remote
        if case .title(let t)? = overlay[.sessionTitle] { doc.title = t }
        if case .runningLook(let look, let same)? = overlay[.sessionRunningLook] {
            doc.runningLook = look
            doc.sameLookForAll = same
        }
        if case .tombstone(let deletedAt)? = overlay[.delete] { doc.deletedAt = deletedAt }
        return doc
    }
}
