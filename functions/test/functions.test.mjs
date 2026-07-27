/**
 * Gainmap sync backend — Cloud Functions suite (P0).
 *
 * Exercises the shared cores directly against the Firestore emulator with the
 * Admin SDK. The cores are factored into functions/lib/* precisely so the logic
 * is testable without HTTP or Eventarc; index.js is a thin wiring layer.
 *
 * Storage is injected as a test double (`fakeBucket`) so object-lifecycle
 * assertions — post-deletion orphan cleanup, GC object deletion, prefix purge —
 * are deterministic and do not depend on the Storage emulator's GCS-compat API.
 */
import { test, before, beforeEach, after } from 'node:test';
import assert from 'node:assert/strict';

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || 'demo-gainmap';
process.env.FIREBASE_CONFIG =
  process.env.FIREBASE_CONFIG || JSON.stringify({ projectId: process.env.GCLOUD_PROJECT });

const { initializeApp, deleteApp } = await import('firebase-admin/app');
const { getFirestore, Timestamp } = await import('firebase-admin/firestore');

const admitMod = await import('../lib/admit.js');
const reserveMod = await import('../lib/reserve.js');
const reconcileMod = await import('../lib/reconcile.js');
const maintenanceMod = await import('../lib/maintenance.js');
const deleteMod = await import('../lib/deleteAccount.js');
const constantsMod = await import('../lib/constants.js');

const { admitSyncUserCore } = admitMod.default || admitMod;
const { reserveUploadCore } = reserveMod.default || reserveMod;
const { handleFinalize, handleDelete } = reconcileMod.default || reconcileMod;
const {
  runMaintenance,
  releaseExpiredReservations,
  purgeTombstones,
  gcPassOne,
  gcPassTwo,
  recomputeUsage,
} = maintenanceMod.default || maintenanceMod;
const { deleteAccountCore, assertRecentAuth } = deleteMod.default || deleteMod;
const { DEFAULT_QUOTA_BYTES, compareGenerations, objectName } =
  constantsMod.default || constantsMod;

const PROJECT_ID = process.env.GCLOUD_PROJECT;
const UID = 'alice';
const hashOf = (n) => n.toString(16).padStart(64, '0');
const HASH = hashOf(0xa1);

let app;
let db;

before(async () => {
  assert.ok(
    process.env.FIRESTORE_EMULATOR_HOST,
    'FIRESTORE_EMULATOR_HOST is unset — run via scripts/test-sync.sh'
  );
  app = initializeApp({ projectId: PROJECT_ID }, `test-${Date.now()}`);
  db = getFirestore(app);
});

after(async () => {
  if (app) await deleteApp(app);
});

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
async function clearFirestore() {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  const res = await fetch(
    `http://${host}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`,
    { method: 'DELETE' }
  );
  if (!res.ok) throw new Error(`clearFirestore failed: ${res.status}`);
}

beforeEach(async () => {
  await clearFirestore();
});

const now = (ms) => Timestamp.fromMillis(ms);
const NOW0 = 1_800_000_000_000; // fixed epoch for deterministic deadline math

/** Minimal Admin-Storage bucket double. */
function fakeBucket(seedFiles = []) {
  const files = new Map(seedFiles.map((f) => [f.name, { size: f.size }]));
  const deleted = [];
  return {
    files,
    deleted,
    file(name) {
      return {
        name,
        async delete() {
          if (!files.has(name)) {
            const err = new Error('No such object');
            err.code = 404;
            throw err;
          }
          files.delete(name);
          deleted.push(name);
        },
      };
    },
    async deleteFiles({ prefix }) {
      for (const name of [...files.keys()]) {
        if (name.startsWith(prefix)) {
          files.delete(name);
          deleted.push(name);
        }
      }
    },
    async getFiles({ prefix }) {
      return [
        [...files.entries()]
          .filter(([name]) => name.startsWith(prefix))
          .map(([name, meta]) => ({ name, metadata: { size: String(meta.size) } })),
      ];
    },
  };
}

async function seedFlags({ syncEnabled = true, signupsOpen = true, maxUsers = 200 } = {}) {
  await db.doc('config/flags').set({ syncEnabled, signupsOpen, maxUsers });
}
async function seedTesting(data) {
  await db.doc('config/testing').set(data);
}
async function seedUser(uid = UID, { quotaBytes = DEFAULT_QUOTA_BYTES, bytesUsed = 0, reservedBytes = 0, objectCount = 0 } = {}) {
  await db.doc(`users/${uid}`).set({
    schemaVersion: 1,
    quotaBytes,
    syncAdmitted: true,
    createdAt: now(NOW0),
  });
  await db.doc(`users/${uid}/usage/storage`).set({
    schemaVersion: 1,
    bytesUsed,
    reservedBytes,
    objectCount,
  });
}
const usage = async (uid = UID) => (await db.doc(`users/${uid}/usage/storage`).get()).data() || {};
const blob = async (hash, uid = UID) => (await db.doc(`users/${uid}/blobs/${hash}`).get()).data();

async function expectCode(promise, code) {
  try {
    await promise;
    assert.fail(`expected the call to reject with code "${code}"`);
  } catch (err) {
    assert.equal(err.code, code, `expected code "${code}", got "${err.code}": ${err.message}`);
  }
}

// ===========================================================================
// admitSyncUser
// ===========================================================================
test('admitSyncUser provisions the user doc, zeroed usage, and bumps the counter', async () => {
  await seedFlags({ maxUsers: 2 });
  const res = await admitSyncUserCore({ db, uid: UID, now: now(NOW0) });
  assert.deepEqual({ admitted: res.admitted }, { admitted: true });

  const user = (await db.doc(`users/${UID}`).get()).data();
  assert.equal(user.syncAdmitted, true);
  assert.equal(user.schemaVersion, 1);
  assert.equal(user.quotaBytes, 5 * 1024 * 1024 * 1024);

  const u = await usage();
  assert.deepEqual(
    { bytesUsed: u.bytesUsed, reservedBytes: u.reservedBytes, objectCount: u.objectCount },
    { bytesUsed: 0, reservedBytes: 0, objectCount: 0 }
  );

  const counters = (await db.doc('config/counters').get()).data();
  assert.equal(counters.admittedUsers, 1);
});

test('admitSyncUser is idempotent — a second call does not double-count the seat', async () => {
  await seedFlags({ maxUsers: 2 });
  await admitSyncUserCore({ db, uid: UID, now: now(NOW0) });
  const again = await admitSyncUserCore({ db, uid: UID, now: now(NOW0 + 1000) });
  assert.equal(again.admitted, true);
  assert.equal(again.alreadyAdmitted, true);
  assert.equal((await db.doc('config/counters').get()).get('admittedUsers'), 1);
});

test('admitSyncUser waitlists once the cap is reached, and while signups are closed', async () => {
  await seedFlags({ maxUsers: 2 });
  assert.equal((await admitSyncUserCore({ db, uid: 'u1', now: now(NOW0) })).admitted, true);
  assert.equal((await admitSyncUserCore({ db, uid: 'u2', now: now(NOW0) })).admitted, true);

  const third = await admitSyncUserCore({ db, uid: 'u3', now: now(NOW0) });
  assert.deepEqual(third, { admitted: false, reason: 'waitlist' });
  assert.equal((await db.doc('users/u3').get()).exists, false);
  assert.equal((await db.doc('config/counters').get()).get('admittedUsers'), 2);

  await seedFlags({ signupsOpen: false, maxUsers: 200 });
  const closed = await admitSyncUserCore({ db, uid: 'u4', now: now(NOW0) });
  assert.deepEqual(closed, { admitted: false, reason: 'waitlist' });
});

test('admitSyncUser rejects an empty uid (unauthenticated caller)', async () => {
  await seedFlags();
  await expectCode(admitSyncUserCore({ db, uid: '', now: now(NOW0) }), 'unauthenticated');
});

// ===========================================================================
// reserveUpload
// ===========================================================================
const reserve = (data, atMs = NOW0) =>
  reserveUploadCore({ db, uid: UID, data, now: now(atMs), projectId: PROJECT_ID });

test('reserveUpload writes both deadlines and charges reservedBytes once', async () => {
  await seedFlags();
  await seedUser();
  const r = await reserve({ contentHash: HASH, tier: 'originals', byteSize: 1000 });

  assert.equal(r.reservationId, `originals_${HASH}`);
  assert.equal(r.objectName, `users/${UID}/originals/${HASH}.jpg`);
  assert.equal(r.refreshed, false);
  assert.equal(r.startBefore, NOW0 + 30 * 60 * 1000);
  assert.equal(r.releaseAfter, r.startBefore + 8 * 24 * 3600 * 1000);
  assert.equal((await usage()).reservedBytes, 1000);
});

test('reserveUpload refresh extends BOTH deadlines and never double-counts', async () => {
  await seedFlags();
  await seedUser();
  const first = await reserve({ contentHash: HASH, tier: 'originals', byteSize: 1000 }, NOW0);
  assert.equal((await usage()).reservedBytes, 1000);

  const laterMs = NOW0 + 20 * 60 * 1000; // 20 min later, still inside the window
  const second = await reserve({ contentHash: HASH, tier: 'originals', byteSize: 1000 }, laterMs);

  assert.equal(second.refreshed, true);
  assert.ok(second.startBefore > first.startBefore, 'startBefore must move forward');
  assert.ok(second.releaseAfter > first.releaseAfter, 'releaseAfter must move forward too');
  assert.equal(second.startBefore, laterMs + 30 * 60 * 1000);
  assert.equal(second.releaseAfter, second.startBefore + 8 * 24 * 3600 * 1000);

  // the whole point: reservedBytes is unchanged
  assert.equal((await usage()).reservedBytes, 1000);

  const stored = (await db.doc(`users/${UID}/reservations/originals_${HASH}`).get()).data();
  assert.equal(stored.startBefore.toMillis(), second.startBefore);
  assert.equal(stored.releaseAfter.toMillis(), second.releaseAfter);
});

test('reserveUpload enforces the quota with a typed resource-exhausted error', async () => {
  await seedFlags();
  await seedUser(UID, { quotaBytes: 1500, bytesUsed: 1000, reservedBytes: 0 });

  await expectCode(
    reserve({ contentHash: HASH, tier: 'originals', byteSize: 600 }),
    'resource-exhausted'
  );
  assert.equal((await usage()).reservedBytes, 0, 'a rejected reservation must charge nothing');

  // exactly at the limit is allowed
  const ok = await reserve({ contentHash: HASH, tier: 'originals', byteSize: 500 });
  assert.equal(ok.byteSize, 500);
  assert.equal((await usage()).reservedBytes, 500);
});

test('reserveUpload counts concurrent reservations against the same quota', async () => {
  await seedFlags();
  await seedUser(UID, { quotaBytes: 1000 });
  await reserve({ contentHash: hashOf(1), tier: 'originals', byteSize: 700 });
  await expectCode(
    reserve({ contentHash: hashOf(2), tier: 'originals', byteSize: 700 }),
    'resource-exhausted'
  );
  assert.equal((await usage()).reservedBytes, 700);
});

test('reserveUpload refuses to issue leases while the kill switch is on', async () => {
  await seedFlags({ syncEnabled: false });
  await seedUser();
  await expectCode(
    reserve({ contentHash: HASH, tier: 'originals', byteSize: 10 }),
    'failed-precondition'
  );
  assert.equal((await usage()).reservedBytes, 0);
});

test('reserveUpload requires an admitted user and validates its arguments', async () => {
  await seedFlags();
  await db.doc(`users/${UID}`).set({ schemaVersion: 1, syncAdmitted: false });
  await expectCode(
    reserve({ contentHash: HASH, tier: 'originals', byteSize: 10 }),
    'permission-denied'
  );

  await seedUser();
  await expectCode(reserve({ contentHash: 'nope', tier: 'originals', byteSize: 10 }), 'invalid-argument');
  await expectCode(reserve({ contentHash: HASH.toUpperCase(), tier: 'originals', byteSize: 10 }), 'invalid-argument');
  await expectCode(reserve({ contentHash: HASH, tier: 'exports', byteSize: 10 }), 'invalid-argument');
  await expectCode(reserve({ contentHash: HASH, tier: 'originals', byteSize: 0 }), 'invalid-argument');
  await expectCode(
    reserve({ contentHash: HASH, tier: 'originals', byteSize: 64 * 1024 * 1024 }),
    'invalid-argument'
  );
});

test('config/testing deadline overrides apply off-production and are inert on it', async () => {
  await seedFlags();
  await seedUser();
  await seedTesting({ startWindowSec: 5, leaseSec: 60 });

  const shortened = await reserve({ contentHash: HASH, tier: 'originals', byteSize: 10 });
  assert.equal(shortened.startBefore, NOW0 + 5000);
  assert.equal(shortened.releaseAfter, NOW0 + 5000 + 60_000);

  // Same document, production project id => defaults, override ignored.
  const prod = await reserveUploadCore({
    db,
    uid: UID,
    data: { contentHash: hashOf(3), tier: 'originals', byteSize: 10 },
    now: now(NOW0),
    projectId: 'gainmap-production',
  });
  assert.equal(prod.startBefore, NOW0 + 30 * 60 * 1000);
  assert.equal(prod.releaseAfter, prod.startBefore + 8 * 24 * 3600 * 1000);
});

// ===========================================================================
// usageReconciler
// ===========================================================================
const NAME = objectName(UID, 'originals', HASH);
const GEN_BIG = '9007199254740993001'; // > 2^53: Number() would round this
const GEN_BIG_NEXT = '9007199254740993002';

test('generation comparison is BigInt-exact past 2^53', () => {
  assert.equal(compareGenerations(GEN_BIG, GEN_BIG_NEXT), -1);
  assert.equal(compareGenerations(GEN_BIG_NEXT, GEN_BIG), 1);
  assert.equal(compareGenerations(GEN_BIG, GEN_BIG), 0);
  // the trap this guards: Number() collapses these two to the same value
  assert.equal(Number(GEN_BIG), Number(GEN_BIG_NEXT));
});

test('finalize converts reserved bytes to used bytes and consumes the reservation', async () => {
  await seedFlags();
  await seedUser();
  await reserve({ contentHash: HASH, tier: 'originals', byteSize: 500 });
  assert.equal((await usage()).reservedBytes, 500);

  const bucket = fakeBucket([{ name: NAME, size: 500 }]);
  const r = await handleFinalize({
    db,
    bucket,
    name: NAME,
    generation: GEN_BIG,
    byteSize: 500,
    now: now(NOW0),
  });
  assert.equal(r.counted, true);

  const u = await usage();
  assert.deepEqual(
    { bytesUsed: u.bytesUsed, reservedBytes: u.reservedBytes, objectCount: u.objectCount },
    { bytesUsed: 500, reservedBytes: 0, objectCount: 1 }
  );
  assert.equal((await db.doc(`users/${UID}/reservations/originals_${HASH}`).get()).exists, false);

  const b = await blob(HASH);
  assert.equal(b.renditions.originals.generation, GEN_BIG);
  assert.equal(typeof b.renditions.originals.generation, 'string');
  assert.equal(b.renditions.originals.counted, true);
  assert.equal(b.renditions.originals.lastEvent, 'finalized');
});

test('duplicate finalize (at-least-once delivery) is a no-op', async () => {
  await seedFlags();
  await seedUser();
  const bucket = fakeBucket([{ name: NAME, size: 500 }]);
  const args = { db, bucket, name: NAME, generation: GEN_BIG, byteSize: 500, now: now(NOW0) };

  await handleFinalize(args);
  const second = await handleFinalize({ ...args, now: now(NOW0 + 1000) });
  assert.equal(second.skipped, 'duplicate-finalize');
  assert.equal((await usage()).bytesUsed, 500);
  assert.equal((await usage()).objectCount, 1);
});

test('delete-before-finalize: an out-of-order finalize cannot resurrect usage', async () => {
  await seedFlags();
  await seedUser();
  const bucket = fakeBucket();

  // The delete event wins the race and lands first (no finalize was ever seen).
  const d = await handleDelete({ db, name: NAME, generation: GEN_BIG, now: now(NOW0) });
  assert.equal(d.uncounted, false);
  const ledger = (await blob(HASH)).renditions.originals;
  assert.equal(ledger.lastEvent, 'deleted');
  assert.equal(ledger.generation, GEN_BIG);

  // Its own finalize arrives afterwards. It must NOT count.
  const f = await handleFinalize({
    db,
    bucket,
    name: NAME,
    generation: GEN_BIG,
    byteSize: 500,
    now: now(NOW0 + 5000),
  });
  assert.equal(f.skipped, 'already-deleted');
  assert.equal((await usage()).bytesUsed, 0);
  assert.equal((await usage()).objectCount, 0);
});

test('a stale delete for an older generation cannot uncount a newer object', async () => {
  await seedFlags();
  await seedUser();
  const bucket = fakeBucket([{ name: NAME, size: 500 }]);

  await handleFinalize({ db, bucket, name: NAME, generation: GEN_BIG_NEXT, byteSize: 500, now: now(NOW0) });
  assert.equal((await usage()).bytesUsed, 500);

  const stale = await handleDelete({ db, name: NAME, generation: GEN_BIG, now: now(NOW0 + 1000) });
  assert.equal(stale.skipped, 'stale-generation');
  assert.equal((await usage()).bytesUsed, 500);
});

test('delete after finalize decrements exactly once, and a duplicate delete is a no-op', async () => {
  await seedFlags();
  await seedUser();
  const bucket = fakeBucket([{ name: NAME, size: 500 }]);
  await handleFinalize({ db, bucket, name: NAME, generation: GEN_BIG, byteSize: 500, now: now(NOW0) });

  const first = await handleDelete({ db, name: NAME, generation: GEN_BIG, now: now(NOW0 + 10) });
  assert.equal(first.uncounted, true);
  assert.equal((await usage()).bytesUsed, 0);
  assert.equal((await usage()).objectCount, 0);

  const dup = await handleDelete({ db, name: NAME, generation: GEN_BIG, now: now(NOW0 + 20) });
  assert.equal(dup.skipped, 'duplicate-delete');
  assert.equal((await usage()).bytesUsed, 0);
});

test('bytesUsed can never go negative', async () => {
  await seedFlags();
  await seedUser(UID, { bytesUsed: 0 });
  await db.doc(`users/${UID}/blobs/${HASH}`).set({
    schemaVersion: 1,
    contentHash: HASH,
    renditions: { originals: { generation: GEN_BIG, byteSize: 5000, counted: true, lastEvent: 'finalized' } },
  });
  await handleDelete({ db, name: NAME, generation: GEN_BIG, now: now(NOW0) });
  assert.equal((await usage()).bytesUsed, 0);
});

test('post-deletion finalize DELETES the object and writes no state', async () => {
  await seedFlags();
  await seedUser();
  await db.doc(`deletedAccounts/${UID}`).set({ schemaVersion: 1, deletedAt: now(NOW0) });

  const bucket = fakeBucket([{ name: NAME, size: 500 }]);
  const r = await handleFinalize({
    db,
    bucket,
    name: NAME,
    generation: GEN_BIG,
    byteSize: 500,
    now: now(NOW0 + 1000),
  });

  assert.equal(r.orphanDeleted, true);
  assert.deepEqual(bucket.deleted, [NAME], 'the orphan object must be physically deleted');
  assert.equal(bucket.files.has(NAME), false);
  assert.equal((await db.doc(`users/${UID}/blobs/${HASH}`).get()).exists, false);
  assert.equal((await usage()).bytesUsed, 0);
});

test('finalize for a user whose doc is gone also deletes the object', async () => {
  await seedFlags();
  const bucket = fakeBucket([{ name: NAME, size: 500 }]);
  const r = await handleFinalize({
    db,
    bucket,
    name: NAME,
    generation: GEN_BIG,
    byteSize: 500,
    now: now(NOW0),
  });
  assert.equal(r.orphanDeleted, true);
  assert.equal(r.reason, 'no-user-doc');
  assert.deepEqual(bucket.deleted, [NAME]);
});

test('objects outside the synced layout are ignored', async () => {
  const bucket = fakeBucket();
  for (const name of ['exports/x.jpg', `users/${UID}/originals/not-a-hash.jpg`, `users/${UID}/weird/${HASH}.jpg`]) {
    const r = await handleFinalize({ db, bucket, name, generation: '1', byteSize: 1, now: now(NOW0) });
    assert.equal(r.skipped, 'not-a-rendition', name);
  }
  assert.deepEqual(bucket.deleted, []);
});

// ===========================================================================
// maintenance
// ===========================================================================
test('maintenance releases a lease only after releaseAfter, never at startBefore', async () => {
  await seedFlags();
  await seedUser();
  await seedTesting({ startWindowSec: 60, leaseSec: 600 });
  const r = await reserve({ contentHash: HASH, tier: 'originals', byteSize: 400 });
  assert.equal((await usage()).reservedBytes, 400);

  // Past startBefore but inside the capacity lease: the bytes stay charged.
  let out = await releaseExpiredReservations({ db, now: now(r.startBefore + 1000) });
  assert.equal(out.released, 0);
  assert.equal((await usage()).reservedBytes, 400);

  out = await releaseExpiredReservations({ db, now: now(r.releaseAfter + 1000) });
  assert.equal(out.released, 1);
  assert.equal((await usage()).reservedBytes, 0);
  assert.equal((await db.doc(`users/${UID}/reservations/originals_${HASH}`).get()).exists, false);
});

test('maintenance purges tombstones older than the retention window', async () => {
  await seedFlags();
  await seedUser();
  const RET = 30 * 24 * 3600 * 1000;
  await db.doc(`users/${UID}/sessions/old`).set({ schemaVersion: 1, deletedAt: now(NOW0 - RET - 1000) });
  await db.doc(`users/${UID}/sessions/old/photos/p`).set({ schemaVersion: 1, contentHash: HASH });
  await db.doc(`users/${UID}/sessions/recent`).set({ schemaVersion: 1, deletedAt: now(NOW0 - 1000) });
  await db.doc(`users/${UID}/sessions/live/photos/oldPhoto`).set({
    schemaVersion: 1,
    contentHash: HASH,
    deletedAt: now(NOW0 - RET - 1000),
  });

  const out = await purgeTombstones({ db, now: now(NOW0) });
  assert.equal(out.sessionsPurged, 1);
  assert.equal(out.photosPurged, 1);
  assert.equal((await db.doc(`users/${UID}/sessions/old`).get()).exists, false);
  assert.equal((await db.doc(`users/${UID}/sessions/old/photos/p`).get()).exists, false);
  assert.equal((await db.doc(`users/${UID}/sessions/recent`).get()).exists, true);
});

test('blob GC is three-state and two-pass, and respects live refs, tombstones and reservations', async () => {
  await seedFlags();
  await seedUser();
  const DAY = 24 * 3600 * 1000;

  const referenced = hashOf(0xa);
  const tombstoned = hashOf(0xb);
  const orphan = hashOf(0xc);
  const reserved = hashOf(0xd);
  for (const h of [referenced, tombstoned, orphan, reserved]) {
    await db.doc(`users/${UID}/blobs/${h}`).set({ schemaVersion: 1, contentHash: h, state: 'active' });
  }
  await db.doc(`users/${UID}/sessions/s1/photos/live`).set({ schemaVersion: 1, contentHash: referenced });
  await db.doc(`users/${UID}/sessions/s1/photos/tomb`).set({
    schemaVersion: 1,
    contentHash: tombstoned,
    deletedAt: now(NOW0 - DAY), // still inside the retention window => undo must work
  });
  await reserve({ contentHash: reserved, tier: 'originals', byteSize: 10 });

  // ---- pass 1
  const p1 = await gcPassOne({ db, uid: UID, now: now(NOW0) });
  assert.equal(p1.marked, 1);
  assert.equal((await blob(referenced)).state, 'active');
  assert.equal((await blob(tombstoned)).state, 'active');
  assert.equal((await blob(reserved)).state, 'active');
  assert.equal((await blob(orphan)).state, 'gcCandidate');

  // ---- pass 2 too early: a candidate must sit for >= 24 h
  const bucket = fakeBucket([
    { name: objectName(UID, 'originals', orphan), size: 10 },
    { name: objectName(UID, 'thumbs', orphan), size: 2 },
  ]);
  let p2 = await gcPassTwo({ db, bucket, uid: UID, now: now(NOW0 + 1000) });
  assert.equal(p2.deleted, 0);
  assert.equal((await blob(orphan)).state, 'gcCandidate');
  assert.deepEqual(bucket.deleted, []);

  // ---- pass 2 after the quiet period
  p2 = await gcPassTwo({ db, bucket, uid: UID, now: now(NOW0 + DAY + 1000) });
  assert.equal(p2.deleted, 1);
  assert.equal((await db.doc(`users/${UID}/blobs/${orphan}`).get()).exists, false);
  assert.deepEqual(
    bucket.deleted.sort(),
    [objectName(UID, 'originals', orphan), objectName(UID, 'thumbs', orphan)].sort()
  );
});

test('a gcCandidate that becomes referenced again is restored to active', async () => {
  await seedFlags();
  await seedUser();
  const h = hashOf(0xe);
  await db
    .doc(`users/${UID}/blobs/${h}`)
    .set({ schemaVersion: 1, contentHash: h, state: 'gcCandidate', gcCandidateAt: now(NOW0) });
  await db.doc(`users/${UID}/sessions/s1/photos/restored`).set({ schemaVersion: 1, contentHash: h });

  const p1 = await gcPassOne({ db, uid: UID, now: now(NOW0 + 1000) });
  assert.equal(p1.unmarked, 1);
  assert.equal((await blob(h)).state, 'active');
});

test('nightly recompute heals bytesUsed / objectCount drift from bucket reality', async () => {
  await seedFlags();
  await seedUser(UID, { bytesUsed: 999999, objectCount: 42 });
  const bucket = fakeBucket([
    { name: objectName(UID, 'originals', HASH), size: 300 },
    { name: objectName(UID, 'thumbs', HASH), size: 50 },
    { name: 'users/someoneelse/originals/x.jpg', size: 10_000 },
  ]);

  const r = await recomputeUsage({ db, bucket, uid: UID, now: now(NOW0) });
  assert.equal(r.healed, true);
  const u = await usage();
  assert.equal(u.bytesUsed, 350);
  assert.equal(u.objectCount, 2);
  assert.equal(u.reservedBytes, 0, 'recompute must not touch reservedBytes');
});

test('runMaintenance orchestrates every pass without throwing', async () => {
  await seedFlags();
  await seedUser();
  await reserve({ contentHash: HASH, tier: 'originals', byteSize: 100 });
  const bucket = fakeBucket();
  const report = await runMaintenance({ db, bucket, now: now(NOW0 + 30 * 24 * 3600 * 1000) });
  assert.deepEqual(report.errors, []);
  assert.ok(report.gc);
  assert.equal(report.reservations.released, 1);
});

// ===========================================================================
// deleteAccount
// ===========================================================================
test('assertRecentAuth requires an auth_time within 5 minutes', () => {
  const nowMs = NOW0;
  assert.equal(assertRecentAuth({ auth_time: nowMs / 1000 - 60 }, nowMs), true);
  assert.throws(() => assertRecentAuth({ auth_time: nowMs / 1000 - 600 }, nowMs), /sign in again/);
  assert.throws(() => assertRecentAuth({}, nowMs), /sign in again/);
  assert.throws(() => assertRecentAuth(null, nowMs), /sign in again/);
});

test('deleteAccount purges the tree + prefix, marks the account, and decrements once', async () => {
  await seedFlags();
  await seedUser();
  await db.doc('config/counters').set({ admittedUsers: 3 });
  await db.doc(`users/${UID}/sessions/s1`).set({ schemaVersion: 1, title: 'Iceland' });
  await db.doc(`users/${UID}/sessions/s1/photos/p1`).set({ schemaVersion: 1, contentHash: HASH });
  await db.doc(`users/${UID}/blobs/${HASH}`).set({ schemaVersion: 1, contentHash: HASH });
  await reserve({ contentHash: HASH, tier: 'originals', byteSize: 10 });

  const bucket = fakeBucket([
    { name: objectName(UID, 'originals', HASH), size: 300 },
    { name: objectName(UID, 'thumbs', HASH), size: 50 },
    { name: 'users/bob/originals/keep.jpg', size: 1 },
  ]);
  const auth = { calls: [], async deleteUser(uid) { this.calls.push(uid); } };

  const r = await deleteAccountCore({ db, bucket, auth, uid: UID, now: now(NOW0) });
  assert.equal(r.deleted, true);
  assert.equal(r.counterDecremented, true);

  assert.equal((await db.doc(`deletedAccounts/${UID}`).get()).exists, true);
  assert.equal((await db.doc(`users/${UID}`).get()).exists, false);
  assert.equal((await db.doc(`users/${UID}/sessions/s1`).get()).exists, false);
  assert.equal((await db.doc(`users/${UID}/sessions/s1/photos/p1`).get()).exists, false);
  assert.equal((await db.doc(`users/${UID}/blobs/${HASH}`).get()).exists, false);
  assert.equal((await db.doc(`users/${UID}/usage/storage`).get()).exists, false);
  assert.equal((await db.doc(`users/${UID}/reservations/originals_${HASH}`).get()).exists, false);

  assert.equal([...bucket.files.keys()].some((k) => k.startsWith(`users/${UID}/`)), false);
  assert.equal(bucket.files.has('users/bob/originals/keep.jpg'), true, 'other users are untouched');
  assert.deepEqual(auth.calls, [UID]);
  assert.equal((await db.doc('config/counters').get()).get('admittedUsers'), 2);
});

test('a retried deleteAccount never decrements the counter twice', async () => {
  await seedFlags();
  await seedUser();
  await db.doc('config/counters').set({ admittedUsers: 3 });
  const auth = { calls: [], async deleteUser(uid) { this.calls.push(uid); } };

  await deleteAccountCore({ db, bucket: fakeBucket(), auth, uid: UID, now: now(NOW0) });
  const again = await deleteAccountCore({ db, bucket: fakeBucket(), auth, uid: UID, now: now(NOW0 + 5) });
  assert.equal(again.counterDecremented, false);
  assert.equal((await db.doc('config/counters').get()).get('admittedUsers'), 2);
});

test('a late resumable upload cannot resurrect a purged account (end to end)', async () => {
  await seedFlags();
  await seedUser();
  await db.doc('config/counters').set({ admittedUsers: 1 });

  // 1. the client reserves and starts a resumable upload
  await reserve({ contentHash: HASH, tier: 'originals', byteSize: 500 });
  // 2. the account is deleted while that session is still open
  const auth = { async deleteUser() {} };
  await deleteAccountCore({ db, bucket: fakeBucket(), auth, uid: UID, now: now(NOW0) });
  // 3. the upload completes anyway
  const bucket = fakeBucket([{ name: NAME, size: 500 }]);
  const r = await handleFinalize({
    db,
    bucket,
    name: NAME,
    generation: GEN_BIG,
    byteSize: 500,
    now: now(NOW0 + 60_000),
  });

  assert.equal(r.orphanDeleted, true);
  assert.equal([...bucket.files.keys()].length, 0, 'the purged prefix must stay empty');
  const anyUserDocs = await db.collection(`users/${UID}/blobs`).get();
  assert.equal(anyUserDocs.empty, true, 'no Firestore subtree may reappear');
  assert.equal((await db.doc(`users/${UID}`).get()).exists, false);
});
