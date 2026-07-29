//
//  FirebaseSyncBackend.swift
//  GainmapCore
//
//  P4: the one file that talks to Firebase. A dumb translator between the
//  SyncBackend seam (FSValue trees) and the SDK — every protocol decision
//  lives in pure code (ConflictPolicy, TransferQueue, SyncEngine); this file
//  converts types, runs the transactions, and maps SDK errors onto
//  SyncBackendError.
//

import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import FirebaseFunctions

// MARK: - FSValue <-> Firestore Any

enum FSBridge {
    static func any(_ v: FSValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .timestamp(let d): return Timestamp(date: d)
        case .array(let a): return a.map(any)
        case .map(let m): return m.mapValues(any)
        }
    }

    static func anyMap(_ m: [String: FSValue]) -> [String: Any] {
        m.mapValues(any)
    }

    static func fsValue(_ raw: Any) -> FSValue {
        switch raw {
        case is NSNull:
            return .null
        case let ts as Timestamp:
            return .timestamp(ts.dateValue())
        case let d as Date:
            return .timestamp(d)
        case let n as NSNumber:
            // Bool NSNumbers are CFBooleans; numeric ones are not.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let type = String(cString: n.objCType)
            if type == "f" || type == "d" { return .double(n.doubleValue) }
            return .int(n.int64Value)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(a.map(fsValue))
        case let m as [String: Any]:
            return .map(m.mapValues(fsValue))
        default:
            // References/geopoints/blobs are outside the schema — drop to null.
            return .null
        }
    }

    static func fsMap(_ raw: [String: Any]) -> [String: FSValue] {
        raw.mapValues(fsValue)
    }
}

// MARK: - Backend

public final class FirebaseSyncBackend: SyncBackend, @unchecked Sendable {
    private let db: Firestore
    private let storage: Storage
    private let functions: Functions

    public init() {
        self.db = Firestore.firestore()
        self.storage = Storage.storage()
        self.functions = Functions.functions(region: "us-central1")
    }

    // ------------------------------------------------------------- documents

    public func setDocument(path: String, data: [String: FSValue], merge: Bool) async throws {
        try await db.document(path).setData(FSBridge.anyMap(data), merge: merge)
    }

    public func getDocument(path: String) async throws -> [String: FSValue]? {
        let snap = try await db.document(path).getDocument()
        guard snap.exists, let raw = snap.data() else { return nil }
        return FSBridge.fsMap(raw)
    }

    public func drainMutation(docPath: String, pending: PendingMutation,
                              deviceID: String, updatedAt: Date) async throws -> DrainResult {
        let ref = db.document(docPath)
        let result = try await db.runTransaction { txn, errorPointer -> Any? in
            let snap: DocumentSnapshot
            do {
                snap = try txn.getDocument(ref)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
            let doc = snap.exists ? snap.data().map(FSBridge.fsMap) : nil
            let remote = RemoteGroupState.from(doc: doc, group: pending.group)
            let decision = ConflictPolicy.decide(pending: pending, remote: remote)

            func write(baseRev: Int) {
                let payload = SyncMutationPayload.update(
                    value: pending.value, baseRev: baseRev, deviceID: deviceID,
                    mutationID: pending.mutationID, updatedAt: updatedAt)
                txn.updateData(FSBridge.anyMap(payload), forDocument: ref)
            }

            switch decision {
            case .write:
                write(baseRev: pending.baseRev)
                return DrainResult(decision: .write, rev: pending.baseRev + 1)
            case .retry(let newBaseRev):
                // Delete-wins: rebase INSIDE the same transaction — the read
                // is consistent, so committing the tombstone on the current
                // rev right now is exactly the retry the policy asks for.
                write(baseRev: newBaseRev)
                return DrainResult(decision: .write, rev: newBaseRev + 1)
            case .alreadyApplied(let committedRev):
                return DrainResult(decision: decision, rev: committedRev)
            case .conflict:
                return DrainResult(decision: .conflict, rev: remote.rev,
                                   supersededBy: RemoteGroupState.author(
                                       doc: doc, group: pending.group))
            case .satisfied, .targetGone:
                return DrainResult(decision: decision, rev: remote.rev)
            }
        }
        guard let drain = result as? DrainResult else {
            throw NSError(domain: "com.legacylab.gainmap.sync", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Drain transaction returned no result.",
            ])
        }
        return drain
    }

    // ------------------------------------------------------------- listeners

    private final class ListenerBox: SyncListener, @unchecked Sendable {
        let registration: ListenerRegistration
        init(_ registration: ListenerRegistration) { self.registration = registration }
        func cancel() { registration.remove() }
    }

    public func listenCollection(
        path: String,
        onEvents: @escaping @Sendable ([DocEvent]) -> Void
    ) -> SyncListener {
        // includeMetadataChanges so the pending -> server-acknowledged
        // transition fires an event: the filter below suppresses unconfirmed
        // echoes, and WITHOUT metadata changes the later confirmation would
        // never be delivered at all (data is unchanged — only metadata flips).
        let reg = db.collection(path).addSnapshotListener(includeMetadataChanges: true) { snapshot, _ in
            guard let snapshot else { return }
            let changes = snapshot.documentChanges(includeMetadataChanges: true)
            let events = changes.compactMap { change -> DocEvent? in
                switch change.type {
                case .removed:
                    return DocEvent(id: change.document.documentID, data: nil)
                case .added, .modified:
                    // NEVER deliver latency-compensated echoes of our own
                    // un-acknowledged writes: if the server later rejects the
                    // write (rules), Firestore rolls it back with a .removed
                    // change — which, had we acked the echo, would read as a
                    // server-side purge and delete the user's local data
                    // (review P4-19). The server-confirmed snapshot follows
                    // and is delivered normally.
                    if change.document.metadata.hasPendingWrites { return nil }
                    return DocEvent(id: change.document.documentID,
                                    data: FSBridge.fsMap(change.document.data()))
                }
            }
            if !events.isEmpty { onEvents(events) }
        }
        return ListenerBox(reg)
    }

    // ------------------------------------------------------------- functions

    public func reserveUpload(contentHash: String, tier: String,
                              byteSize: Int64) async throws -> ReservationGrant {
        do {
            let result = try await functions.httpsCallable("reserveUpload").call([
                "contentHash": contentHash,
                "tier": tier,
                "byteSize": byteSize,
            ])
            guard let data = result.data as? [String: Any],
                  let reservationId = data["reservationId"] as? String,
                  let objectName = data["objectName"] as? String,
                  let expiresMs = (data["expiresAt"] as? NSNumber)?.doubleValue else {
                throw NSError(domain: "com.legacylab.gainmap.sync", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Malformed reserveUpload response.",
                ])
            }
            return ReservationGrant(
                reservationId: reservationId,
                objectName: objectName,
                byteSize: (data["byteSize"] as? NSNumber)?.int64Value ?? byteSize,
                expiresAt: Date(timeIntervalSince1970: expiresMs / 1000),
                refreshed: (data["refreshed"] as? Bool) ?? false)
        } catch {
            throw Self.mapCallableError(error)
        }
    }

    private static func mapCallableError(_ error: Error) -> Error {
        let ns = error as NSError
        guard ns.domain == FunctionsErrorDomain,
              let code = FunctionsErrorCode(rawValue: ns.code) else { return error }
        switch code {
        case .resourceExhausted:
            return SyncBackendError.quotaExceeded
        case .failedPrecondition, .permissionDenied:
            return SyncBackendError.syncUnavailable(ns.localizedDescription)
        case .unauthenticated:
            return SyncBackendError.notAuthenticated
        default:
            return error
        }
    }

    // ------------------------------------------------------------- storage

    public func uploadObject(objectName: String, fileURL: URL) async throws {
        let ref = storage.reference(withPath: objectName)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        metadata.cacheControl = "private, max-age=31536000, immutable"
        do {
            _ = try await ref.putFileAsync(from: fileURL, metadata: metadata)
        } catch {
            throw Self.mapStorageError(error)
        }
    }

    public func downloadObject(objectName: String, to fileURL: URL) async throws {
        let ref = storage.reference(withPath: objectName)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        _ = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<URL, Error>) in
            ref.write(toFile: fileURL) { url, error in
                if let error { cont.resume(throwing: Self.mapStorageError(error)) }
                else { cont.resume(returning: url ?? fileURL) }
            }
        }
    }

    public func objectExists(objectName: String) async throws -> Bool {
        do {
            _ = try await storage.reference(withPath: objectName).getMetadata()
            return true
        } catch {
            let ns = error as NSError
            if ns.domain == StorageErrorDomain,
               ns.code == StorageErrorCode.objectNotFound.rawValue {
                return false
            }
            throw Self.mapStorageError(error)
        }
    }

    private static func mapStorageError(_ error: Error) -> Error {
        let ns = error as NSError
        guard ns.domain == StorageErrorDomain else { return error }
        switch ns.code {
        case StorageErrorCode.unauthorized.rawValue,
             StorageErrorCode.unauthenticated.rawValue:
            // With a reservation in hand this is the r7 lease-expiry signal.
            return SyncBackendError.storageDenied
        default:
            return error
        }
    }
}

// MARK: - App configuration helpers

public enum FirebaseSetup {
    /// Configure against the LOCAL EMULATOR SUITE for integration tests.
    /// Never touches production: demo-* project IDs are emulator-only.
    public static func configureForEmulator(projectID: String = "demo-gainmap",
                                            host: String = "127.0.0.1",
                                            authPort: Int = 9099,
                                            firestorePort: Int = 8080,
                                            storagePort: Int = 9199,
                                            functionsPort: Int = 5001) {
        if FirebaseApp.app() == nil {
            let options = FirebaseOptions(googleAppID: "1:123456789:ios:abcdef",
                                          gcmSenderID: "123456789")
            options.projectID = projectID
            options.apiKey = "fake-api-key"
            options.storageBucket = "\(projectID).appspot.com"
            FirebaseApp.configure(options: options)
        }
        let settings = Firestore.firestore().settings
        settings.host = "\(host):\(firestorePort)"
        settings.isSSLEnabled = false
        settings.cacheSettings = MemoryCacheSettings()   // tests want no disk cache
        Firestore.firestore().settings = settings
        Auth.auth().useEmulator(withHost: host, port: authPort)
        Storage.storage().useEmulator(withHost: host, port: storagePort)
        Functions.functions(region: "us-central1").useEmulator(withHost: host, port: functionsPort)
    }

    /// Anonymous sign-in (Auth emulator) — returns the uid.
    public static func signInAnonymouslyForTesting() async throws -> String {
        let result = try await Auth.auth().signInAnonymously()
        return result.user.uid
    }

    public static func signOutForTesting() {
        try? Auth.auth().signOut()
    }
}
