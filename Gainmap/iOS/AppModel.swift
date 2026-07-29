//
//  AppModel.swift
//  Gainmap for iPhone (P5)
//
//  Per-uid app state: the session store, the sync engine's lifecycle, and
//  the grid's card list. Auth drives it: `.ready` runs the engine; `.waitlisted`
//  keeps the app fully local; sign-out tears everything down.
//

import Foundation
import SwiftUI
import GainmapCore

@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var cards: [SessionCard] = []
    @Published private(set) var syncing = false

    private(set) var store: FileSessionStore?
    private(set) var engine: SyncEngine?
    private var activeUID: String?

    /// Stable per-install device identity (the `by` in rev metadata).
    static var deviceID: String {
        let key = "gm-device-id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = "ios-\(UUID().uuidString.prefix(8))"
        UserDefaults.standard.set(fresh, forKey: key)
        return String(fresh)
    }

    // ------------------------------------------------------------- lifecycle

    func authStateChanged(_ state: AuthState) async {
        switch state {
        case .ready(let uid):
            await activate(uid: uid, syncing: true)
        case .waitlisted(let uid):
            await activate(uid: uid, syncing: false)
        case .signedOut, .failed:
            await deactivate()
        case .admitting:
            break
        }
    }

    private func activate(uid: String, syncing wantSync: Bool) async {
        if activeUID == uid, (engine != nil) == wantSync { return }
        await deactivate()
        activeUID = uid
        let store = FileSessionStore(uid: uid)
        self.store = store
        if wantSync {
            let root = await store.root.appendingPathComponent("users/\(uid)", isDirectory: true)
            let engine = SyncEngine(uid: uid, deviceID: Self.deviceID,
                                    backend: FirebaseSyncBackend(),
                                    store: store, root: root)
            self.engine = engine
            await engine.setOnRemoteChange { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            await engine.start()
            syncing = true
            Task {
                await engine.drainOnce()
                await engine.pumpTransfers()
                await self.refresh()
            }
        }
        await refresh()
    }

    private func deactivate() async {
        if let engine {
            await engine.setOnRemoteChange(nil)
            await engine.stop()
        }
        engine = nil
        store = nil
        activeUID = nil
        syncing = false
        cards = []
    }

    func appBecameActive() async {
        guard let engine else { return }
        await engine.retryTransfers()
        await engine.drainOnce()
        await refresh()
    }

    /// The editor's persist hook: journal + drain local edits.
    func sessionPersisted(_ session: Session) {
        guard let engine else { return }
        Task {
            await engine.noteLocalSession(session)
            await engine.drainOnce()
            await engine.pumpTransfers()
        }
    }

    // ------------------------------------------------------------- grid data

    func refresh() async {
        guard let store else { cards = []; return }
        let sessions = await store.loadAll()
        var newCards: [SessionCard] = []
        for session in sessions {
            let hashes = session.photos.compactMap(\.contentHash).prefix(4)
            var covers: [URL?] = []
            for hash in hashes {
                covers.append(await engine?.hydrateThumb(hash: hash))
            }
            var pending = false
            if let engine {
                let transfers = await engine.transferSnapshot
                let journal = await engine.journalSnapshot
                pending = transfers.activeCount > 0 || !journal.pendingEntries.isEmpty
            }
            newCards.append(SessionCard(
                id: session.id,
                title: session.title,
                photoCount: session.photos.count,
                updatedAt: session.updatedAt,
                covers: covers,
                pendingSync: pending))
        }
        cards = newCards
    }

    func session(id: UUID) async -> Session? {
        await store?.load(id: id)
    }
}
