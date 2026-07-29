//
//  SyncCoordinator.swift
//  Gainmap (Mac) — P5
//
//  Owns the Mac's per-uid store + sync engine lifecycle, driven by auth
//  state. Signed out: the classic local store (uid "local"), no engine.
//  Signed in + admitted: one-time adoption of pre-auth sessions, the store
//  switches to the real uid, the engine starts, and MergeModel's persist
//  hook feeds local edits into the journal while inbound changes fold back
//  into the live model.
//

import Foundation
import SwiftUI
import GainmapCore

@MainActor
final class SyncCoordinator: ObservableObject {

    @Published private(set) var syncing = false

    private var engine: SyncEngine?
    private var model: MergeModel?
    private var currentUID: String?

    /// Stable per-install device identity (the `by` in rev metadata).
    static var deviceID: String {
        let key = "gm-device-id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = "mac-\(UUID().uuidString.prefix(8))"
        UserDefaults.standard.set(fresh, forKey: key)
        return String(fresh)
    }

    /// True in dev/test launches that must not touch stores or Firebase.
    static var isEphemeralLaunch: Bool {
        UserDefaults.standard.string(forKey: "gm-seed") != nil
            || UserDefaults.standard.bool(forKey: "gm-no-store")
    }

    /// Called once at launch and again on every auth-state change.
    func apply(authState: AuthState, model: MergeModel) async {
        guard !Self.isEphemeralLaunch else { return }
        self.model = model
        switch authState {
        case .ready(let uid):
            await activate(uid: uid, withEngine: true, model: model)
        case .waitlisted(let uid):
            await activate(uid: uid, withEngine: false, model: model)
        case .signedOut, .failed:
            await activate(uid: "local", withEngine: false, model: model)
        case .admitting:
            break   // keep whatever is attached; .ready/.waitlisted follows
        }
    }

    private func activate(uid: String, withEngine: Bool, model: MergeModel) async {
        if currentUID == uid, (engine != nil) == withEngine { return }
        let switchingUID = currentUID != uid

        // Order matters (P5 review, critical):
        // 1. FLUSH FIRST — into the OLD namespace, while the outgoing
        //    engine's persist hook is still armed (so the edit journals).
        //    Flushing after adoption re-created the just-swept users/local
        //    file and stranded the newest edits in a dead namespace.
        await model.flushSession()
        if let engine {
            await engine.setOnRemoteChange(nil)
            await engine.stop()
            self.engine = nil
        }
        model.onSessionPersisted = nil
        syncing = false
        currentUID = uid

        // 2. ADOPT — users/local moves under the real uid (newest copy wins).
        let store = FileSessionStore(uid: uid)
        if uid != "local" {
            await store.adoptLocalSessions()
        }
        // 3. ATTACH — resetting the model whenever the namespace changed:
        //    keeping the old account's session live over the new store wrote
        //    A's photos into whatever namespace came next (sign-out leak).
        await model.attachStoreAndRestore(store, reset: switchingUID)

        guard withEngine else { return }
        let root = await store.root.appendingPathComponent("users/\(uid)", isDirectory: true)
        let engine = SyncEngine(uid: uid, deviceID: Self.deviceID,
                                backend: FirebaseSyncBackend(),
                                store: store, root: root)
        self.engine = engine
        await engine.setOnRemoteChange { [weak self] sessionID in
            Task { @MainActor in await self?.remoteChanged(sessionID) }
        }
        model.onSessionPersisted = { [weak self] session, before in
            Task { @MainActor in await self?.localPersisted(session, before: before) }
        }
        await engine.start()
        syncing = true
        Task {
            await engine.drainOnce()
            await engine.pumpTransfers()
        }
    }

    private func localPersisted(_ session: Session, before: Session?) async {
        guard let engine else { return }
        await engine.noteLocalSession(session, before: before)
        await engine.drainOnce()
        await engine.pumpTransfers()
    }

    private func remoteChanged(_ sessionID: UUID) async {
        guard let model, let engine else { return }
        guard model.session.id == sessionID else { return }   // grid handles others (P7)
        let uid = await engine.uid
        let store = FileSessionStore(uid: uid)
        if let fresh = await store.load(id: sessionID) {
            model.reloadFromRemote(fresh)
        }
    }

    /// Foreground hook: retry parked transfers + drain anything pending.
    func appBecameActive() async {
        guard let engine else { return }
        await engine.retryTransfers()
        await engine.drainOnce()
    }
}
