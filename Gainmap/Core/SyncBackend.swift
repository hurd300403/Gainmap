//
//  SyncBackend.swift
//  GainmapCore
//
//  P4: the seam between the SyncEngine (pure protocol logic) and Firebase.
//  Everything crosses this boundary as FSValue trees and small value types,
//  so the engine stays unit-testable with an in-memory fake and the Firebase
//  adapter stays a dumb translator.
//

import Foundation

/// One document change delivered by a collection listener.
/// `data == nil` means the document was removed.
public struct DocEvent: Sendable {
    public let id: String
    public let data: [String: FSValue]?

    public init(id: String, data: [String: FSValue]?) {
        self.id = id
        self.data = data
    }
}

/// Cancelable listener registration.
public protocol SyncListener: Sendable {
    func cancel()
}

/// Result of reserveUpload (mirrors the callable's payload).
public struct ReservationGrant: Sendable, Equatable {
    public let reservationId: String
    public let objectName: String
    public let byteSize: Int64
    public let expiresAt: Date
    public let refreshed: Bool

    public init(reservationId: String, objectName: String, byteSize: Int64,
                expiresAt: Date, refreshed: Bool) {
        self.reservationId = reservationId
        self.objectName = objectName
        self.byteSize = byteSize
        self.expiresAt = expiresAt
        self.refreshed = refreshed
    }
}

/// Backend failures the engine's policy layer cares about; everything else
/// stays a thrown error and counts as transient.
public enum SyncBackendError: Error, Equatable, Sendable {
    /// reserveUpload: resource-exhausted (quota).
    case quotaExceeded
    /// Kill switch / not admitted / signups closed.
    case syncUnavailable(String)
    /// Storage denied the object create — with a live reservation this means
    /// the lease expired mid-upload (r7).
    case storageDenied
    /// Not signed in / uid mismatch.
    case notAuthenticated
}

/// What a drain transaction did (the executed DrainDecision + the rev it
/// left the group at, for journal bookkeeping).
public struct DrainResult: Sendable, Equatable {
    public let decision: DrainDecision
    /// Group rev after the transaction (committed rev on .write/.alreadyApplied;
    /// current remote rev otherwise).
    public let rev: Int
    /// The remote group author when the decision is .conflict ("" unknown).
    public let supersededBy: String

    public init(decision: DrainDecision, rev: Int, supersededBy: String = "") {
        self.decision = decision
        self.rev = rev
        self.supersededBy = supersededBy
    }
}

/// The full backend surface the engine needs. Paths are Firestore-style
/// ("users/u1/sessions/ABC"), object names are Storage-style
/// ("users/u1/thumbs/<hash>.jpg").
public protocol SyncBackend: Sendable {

    // ------------------------------------------------------------- documents

    /// Plain write (create or merge). Used for creates, covers/photoCount
    /// refreshes and the LWW signature group — never for rev-gated groups.
    func setDocument(path: String, data: [String: FSValue], merge: Bool) async throws

    func getDocument(path: String) async throws -> [String: FSValue]?

    /// Drain one pending mutation transactionally: read the doc, evaluate
    /// ConflictPolicy against the group's current state, apply the update
    /// payload iff the decision is .write (or the delete-wins .retry rebase
    /// re-evaluated inside the SAME transaction), and report what happened.
    func drainMutation(docPath: String, pending: PendingMutation,
                       deviceID: String, updatedAt: Date) async throws -> DrainResult

    // ------------------------------------------------------------- listeners

    /// Listen to a collection; fires with the full current set first, then
    /// incremental changes.
    func listenCollection(path: String,
                          onEvents: @escaping @Sendable ([DocEvent]) -> Void) -> SyncListener

    // ------------------------------------------------------------- functions

    func reserveUpload(contentHash: String, tier: String,
                       byteSize: Int64) async throws -> ReservationGrant

    // ------------------------------------------------------------- storage

    /// Upload a local file to its content-addressed object. Throws
    /// SyncBackendError.storageDenied on a rules 403 (lease expired).
    func uploadObject(
        objectName: String,
        fileURL: URL,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws

    /// Download an object to a local file (thumbs/originals hydration).
    func downloadObject(objectName: String, to fileURL: URL) async throws

    /// Fast existence probe (skip-if-exists belt alongside the blob ledger).
    func objectExists(objectName: String) async throws -> Bool
}
