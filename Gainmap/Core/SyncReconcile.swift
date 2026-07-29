//
//  SyncReconcile.swift
//  GainmapCore
//
//  P4: the ack-aware full reconcile (r4/r5) — what runs when listeners have
//  settled and local + remote record sets can be compared. The ack bit is
//  what makes >30-days-offline safe:
//
//    * remote has a record local lacks            -> adopt it locally
//    * local has a record remote lacks, EVER ACKED -> it was purged remotely
//                                                     (tombstone retention ran
//                                                     out); adopt the purge
//    * local has a record remote lacks, NEVER ACKED -> the server never saw it
//                                                     (offline-created);
//                                                     preserve and upload
//
//  Pure set arithmetic over SyncTargets; the engine executes the actions.
//

import Foundation

public enum ReconcileAction: Equatable, Hashable, Sendable {
    /// Remote record missing locally: materialize it (listeners deliver the
    /// field data; this marks the record itself).
    case adoptRemote(SyncTarget)
    /// Local record was acked once and is gone remotely: purge the local copy
    /// (never the Mac's original files — only the session record).
    case purgeLocal(SyncTarget)
    /// Local record the server never acknowledged: push it as a create
    /// (the offline-created-session case).
    case pushLocalCreate(SyncTarget)
}

public enum SyncReconcile {

    /// Compare one record space (sessions, or one session's photos).
    /// `local` excludes records that are local-only BY DESIGN (a photo whose
    /// every rendition is tooLargeToSync is never journaled remotely and must
    /// not be pushed or purged) — the caller filters those before calling.
    public static func actions(local: Set<SyncTarget>, remote: Set<SyncTarget>,
                               acks: AckLedger) -> [ReconcileAction] {
        var out: [ReconcileAction] = []
        for t in remote.subtracting(local) {
            out.append(.adoptRemote(t))
        }
        for t in local.subtracting(remote) {
            out.append(acks.everAcked(t) ? .purgeLocal(t) : .pushLocalCreate(t))
        }
        // Deterministic order: adoptions first, then pushes, then purges —
        // and stable within each class (tests + reproducible logs).
        func rank(_ a: ReconcileAction) -> Int {
            switch a {
            case .adoptRemote: return 0
            case .pushLocalCreate: return 1
            case .purgeLocal: return 2
            }
        }
        func key(_ a: ReconcileAction) -> String {
            switch a {
            case .adoptRemote(let t), .purgeLocal(let t), .pushLocalCreate(let t):
                return t.path(uid: "-")
            }
        }
        return out.sorted { (rank($0), key($0)) < (rank($1), key($1)) }
    }
}
