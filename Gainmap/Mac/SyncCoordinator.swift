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
        if let engine {
            await engine.setOnRemoteChange(nil)
            await engine.stop()
            self.engine = nil
        }
        model.onSessionPersisted = nil
        syncing = false
        currentUID = uid

        let store = FileSessionStore(uid: uid)
        if uid != "local" {
            await store.adoptLocalSessions()
        }
        await model.flushSession()              // don't lose edits made pre-switch
        await model.attachStoreAndRestore(store)

        guard withEngine else { return }
        let root = await store.root.appendingPathComponent("users/\(uid)", isDirectory: true)
        let engine = SyncEngine(uid: uid, deviceID: Self.deviceID,
                                backend: FirebaseSyncBackend(),
                                store: store, root: root)
        self.engine = engine
        await engine.setOnRemoteChange { [weak self] sessionID in
            Task { @MainActor in await self?.remoteChanged(sessionID) }
        }
        model.onSessionPersisted = { [weak self] session in
            Task { @MainActor in await self?.localPersisted(session) }
        }
        await engine.start()
        syncing = true
        Task {
            await engine.drainOnce()
            await engine.pumpTransfers()
        }
    }

    private func localPersisted(_ session: Session) async {
        guard let engine else { return }
        await engine.noteLocalSession(session)
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
