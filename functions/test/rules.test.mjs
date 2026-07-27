/**
 * Gainmap sync backend — security rules suite (P0 exit criteria).
 *
 * Run via scripts/test-sync.sh (boots auth/firestore/storage emulators against
 * the throwaway project id `demo-gainmap`).
 *
 * Covers the P0 exit list from
 * docs/superpowers/specs/2026-07-27-gainmap-ios-sync-design.md:
 *   owner / stranger / unauthenticated; users/{uid} client create denied;
 *   server-owned field protection (quotaBytes, syncAdmitted, entitlement,
 *   usage/**, reservations/**, blobs.renditions/state/gcCandidateAt);
 *   photo create against a `deleting` blob; per-group rev == old + 1;
 *   client hard-DELETE denied everywhere; kill switch blocks creates/updates but
 *   allows tombstone-only updates; schemaVersion 2 rejected;
 *   Storage: unreserved / wrong-size / expired-lease / wrong-type / bad-tier
 *   rejected, matching reservation allowed, client delete denied.
 */
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} from '@firebase/rules-unit-testing';
import { doc, setDoc, getDoc, updateDoc, deleteDoc, Timestamp } from 'firebase/firestore';
import { ref, uploadBytes, deleteObject } from 'firebase/storage';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '../..');
const FIRESTORE_RULES = readFileSync(path.join(ROOT, 'firestore.rules'), 'utf8');
const STORAGE_RULES = readFileSync(path.join(ROOT, 'storage.rules'), 'utf8');

const PROJECT_ID = 'demo-gainmap';
const GIB = 1024 * 1024 * 1024;

/** 64 lowercase hex characters, deterministic per test. */
const hashOf = (n) => n.toString(16).padStart(64, '0');
const HASH_A = hashOf(0xa1);
const HASH_DELETING = hashOf(0xdead);
const HASH_NEW = hashOf(0xbeef);

function hostPort(envName, defaultPort) {
  const raw = process.env[envName];
  if (raw) {
    const [host, port] = raw.replace(/^https?:\/\//, '').split(':');
    return { host, port: Number(port) };
  }
  return { host: '127.0.0.1', port: defaultPort };
}
const FS_EMU = hostPort('FIRESTORE_EMULATOR_HOST', 8080);
const ST_EMU = hostPort('FIREBASE_STORAGE_EMULATOR_HOST', 9199);

/**
 * Minimal ruleset whose ONLY condition is a cross-service firestore.get().
 * If an upload under these rules is denied while config/flags.syncEnabled is
 * true, the Storage emulator is not evaluating cross-service reads and every
 * reservation-dependent expectation below is unverifiable here.
 */
const CROSS_SERVICE_PROBE_RULES = `rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /{allPaths=**} {
      allow read, write: if firestore.get(/databases/(default)/documents/config/flags).data.syncEnabled == true;
    }
  }
}`;

let testEnv;
let crossServiceSupported = false;
const XS_SKIP_REASON =
  'Storage emulator did not evaluate cross-service firestore.get(). ' +
  'Covering test: the P0 real-project reservation-lifecycle probe ' +
  '(reserve -> upload -> finalize past expiresAt -> 403) on a probe project.';

function xsSkip(t) {
  if (crossServiceSupported) return false;
  t.skip(XS_SKIP_REASON);
  return true;
}

// ---------------------------------------------------------------------------
// setup
// ---------------------------------------------------------------------------
before(async () => {
  // ---- Phase 1: cross-service capability probe.
  // Runs FIRST and in its own environment because @firebase/rules-unit-testing
  // installs Storage rules globally in the emulator; the environments must not
  // overlap in time.
  const probeEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: { rules: FIRESTORE_RULES, host: FS_EMU.host, port: FS_EMU.port },
    storage: { rules: CROSS_SERVICE_PROBE_RULES, host: ST_EMU.host, port: ST_EMU.port },
  });
  await probeEnv.clearFirestore();
  await probeEnv.clearStorage();
  await probeEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'config/flags'), { syncEnabled: true });
  });
  try {
    const st = probeEnv.authenticatedContext('probe').storage();
    await uploadBytes(ref(st, `probe/${HASH_A}.jpg`), new Uint8Array(8), {
      contentType: 'image/jpeg',
    });
    crossServiceSupported = true;
  } catch (err) {
    crossServiceSupported = false;
    console.warn(
      '\n' +
        '='.repeat(78) +
        '\n!! CROSS-SERVICE STORAGE RULES NOT EVALUATED BY THE EMULATOR !!\n' +
        `   probe error: ${err && err.code ? err.code : err}\n` +
        `   ${XS_SKIP_REASON}\n` +
        '   Storage reservation tests below are SKIPPED, not passed.\n' +
        '='.repeat(78) +
        '\n'
    );
  }
  await probeEnv.clearFirestore();
  await probeEnv.clearStorage();
  await probeEnv.cleanup();

  // ---- Phase 2: the real rules.
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: { rules: FIRESTORE_RULES, host: FS_EMU.host, port: FS_EMU.port },
    storage: { rules: STORAGE_RULES, host: ST_EMU.host, port: ST_EMU.port },
  });
});

after(async () => {
  if (testEnv) {
    await testEnv.clearFirestore();
    await testEnv.clearStorage();
    await testEnv.cleanup();
  }
});

// ---------------------------------------------------------------------------
// seeding
// ---------------------------------------------------------------------------
const T = (ms) => Timestamp.fromMillis(ms);

async function seed({ syncEnabled = true } = {}) {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'config/flags'), { syncEnabled, signupsOpen: true, maxUsers: 200 });
    await setDoc(doc(db, 'config/counters'), { admittedUsers: 2 });

    // alice: admitted
    await setDoc(doc(db, 'users/alice'), {
      schemaVersion: 1,
      quotaBytes: 5 * GIB,
      syncAdmitted: true,
      createdAt: T(1000),
      hasCustomDefault: false,
    });
    await setDoc(doc(db, 'users/alice/usage/storage'), {
      schemaVersion: 1,
      bytesUsed: 0,
      reservedBytes: 0,
      objectCount: 0,
    });
    await setDoc(doc(db, `users/alice/blobs/${HASH_A}`), {
      schemaVersion: 1,
      contentHash: HASH_A,
      byteSize: 1234,
      state: 'active',
      createdAt: T(1000),
    });
    await setDoc(doc(db, `users/alice/blobs/${HASH_DELETING}`), {
      schemaVersion: 1,
      contentHash: HASH_DELETING,
      byteSize: 99,
      state: 'deleting',
    });
    await setDoc(doc(db, 'users/alice/sessions/s1'), {
      schemaVersion: 1,
      title: 'Iceland',
      titleRev: 2,
      sameLookForAll: false,
      runningLook: null,
      rlRev: 1,
      photoCount: 1,
      createdAt: T(1000),
      updatedAt: T(1000),
    });
    await setDoc(doc(db, 'users/alice/sessions/s1/photos/p1'), {
      schemaVersion: 1,
      contentHash: HASH_A,
      look: null,
      lookRev: 3,
      orderKey: 'a0',
      orderRev: 1,
      createdAt: T(1000),
      updatedAt: T(1000),
    });

    // mallory: signed in but NOT admitted
    await setDoc(doc(db, 'users/mallory'), {
      schemaVersion: 1,
      quotaBytes: 5 * GIB,
      syncAdmitted: false,
      createdAt: T(1000),
    });

    // bob: an unrelated admitted user (the "stranger")
    await setDoc(doc(db, 'users/bob'), {
      schemaVersion: 1,
      quotaBytes: 5 * GIB,
      syncAdmitted: true,
      createdAt: T(1000),
    });

    await setDoc(doc(db, 'deletedAccounts/ghost'), { schemaVersion: 1, deletedAt: T(1000) });
  });
}

const aliceDb = () => testEnv.authenticatedContext('alice').firestore();
const bobDb = () => testEnv.authenticatedContext('bob').firestore();
const malloryDb = () => testEnv.authenticatedContext('mallory').firestore();
const anonDb = () => testEnv.unauthenticatedContext().firestore();

const PHOTO = 'users/alice/sessions/s1/photos/p1';
const SESSION = 'users/alice/sessions/s1';

// ===========================================================================
// Firestore — ownership
// ===========================================================================
test('owner can read and update their own documents', async () => {
  await seed();
  const db = aliceDb();
  await assertSucceeds(getDoc(doc(db, 'users/alice')));
  await assertSucceeds(getDoc(doc(db, SESSION)));
  await assertSucceeds(getDoc(doc(db, PHOTO)));
  await assertSucceeds(getDoc(doc(db, 'users/alice/usage/storage')));
  await assertSucceeds(
    updateDoc(doc(db, 'users/alice'), { hasCustomDefault: true, schemaVersion: 1 })
  );
  await assertSucceeds(
    updateDoc(doc(db, SESSION), { title: 'Iceland 2026', titleRev: 3, titleBy: 'mac', titleMut: 'm1' })
  );
});

test('stranger is denied on every path in another user tree', async () => {
  await seed();
  const db = bobDb();
  await assertFails(getDoc(doc(db, 'users/alice')));
  await assertFails(getDoc(doc(db, 'users/alice/usage/storage')));
  await assertFails(getDoc(doc(db, `users/alice/blobs/${HASH_A}`)));
  await assertFails(getDoc(doc(db, SESSION)));
  await assertFails(getDoc(doc(db, PHOTO)));
  await assertFails(updateDoc(doc(db, 'users/alice'), { hasCustomDefault: true }));
  await assertFails(updateDoc(doc(db, SESSION), { title: 'stolen', titleRev: 3 }));
  await assertFails(
    setDoc(doc(db, 'users/alice/sessions/s2'), { schemaVersion: 1, title: 'intrusion' })
  );
  await assertFails(deleteDoc(doc(db, PHOTO)));
});

test('unauthenticated is denied reads and writes', async () => {
  await seed();
  const db = anonDb();
  await assertFails(getDoc(doc(db, 'users/alice')));
  await assertFails(getDoc(doc(db, SESSION)));
  await assertFails(setDoc(doc(db, 'users/alice/sessions/s3'), { schemaVersion: 1 }));
  // config stays publicly readable (clients need the kill switch before sign-in).
  await assertSucceeds(getDoc(doc(db, 'config/flags')));
});

test('a signed-in but un-admitted user cannot write', async () => {
  await seed();
  const db = malloryDb();
  await assertSucceeds(getDoc(doc(db, 'users/mallory')));
  await assertFails(
    setDoc(doc(db, 'users/mallory/sessions/s1'), { schemaVersion: 1, title: 'nope' })
  );
  await assertFails(updateDoc(doc(db, 'users/mallory'), { hasCustomDefault: true }));
});

// ===========================================================================
// Firestore — provisioning + server-owned fields
// ===========================================================================
test('client CREATE of users/{uid} is denied (admitSyncUser is the only provisioner)', async () => {
  await seed();
  const db = testEnv.authenticatedContext('newcomer').firestore();
  await assertFails(
    setDoc(doc(db, 'users/newcomer'), {
      schemaVersion: 1,
      quotaBytes: 500 * GIB,
      syncAdmitted: true,
    })
  );
  await assertFails(setDoc(doc(db, 'users/newcomer'), { schemaVersion: 1 }));
});

test('server-owned user fields are client-unwritable', async () => {
  await seed();
  const db = aliceDb();
  await assertFails(updateDoc(doc(db, 'users/alice'), { quotaBytes: 500 * GIB }));
  await assertFails(updateDoc(doc(db, 'users/alice'), { syncAdmitted: false }));
  await assertFails(updateDoc(doc(db, 'users/alice'), { entitlement: 'patron' }));
  // createdAt is immutable once set
  await assertFails(updateDoc(doc(db, 'users/alice'), { createdAt: T(999999) }));
  // A full-document overwrite that drops a server-owned field is a change too.
  await assertFails(
    setDoc(doc(db, 'users/alice'), { schemaVersion: 1, hasCustomDefault: true })
  );
});

test('re-writing a server-owned field with its EXISTING value is a documented no-op', async () => {
  // The protection is diff-based (affectedKeys), which is what lets a client
  // safely round-trip a whole document it read. Writing syncAdmitted: true when
  // it is already true changes nothing and is therefore allowed; writing any
  // different value is not (asserted above). Pinning the behaviour here so it is
  // a decision rather than a surprise.
  await seed();
  const db = aliceDb();
  await assertSucceeds(
    updateDoc(doc(db, 'users/alice'), { syncAdmitted: true, hasCustomDefault: true })
  );
  await assertFails(updateDoc(doc(db, 'users/alice'), { syncAdmitted: false }));
});

test('usage/** and reservations/** are readable but never client-writable', async () => {
  await seed();
  const db = aliceDb();
  await assertSucceeds(getDoc(doc(db, 'users/alice/usage/storage')));
  await assertFails(setDoc(doc(db, 'users/alice/usage/storage'), { bytesUsed: 0 }));
  await assertFails(updateDoc(doc(db, 'users/alice/usage/storage'), { bytesUsed: 0 }));
  await assertFails(deleteDoc(doc(db, 'users/alice/usage/storage')));
  await assertFails(
    setDoc(doc(db, `users/alice/reservations/originals_${HASH_NEW}`), {
      byteSize: 10,
      expiresAt: T(Date.now() + 60000),
    })
  );
});

test('blob renditions / state / gcCandidateAt are server-only', async () => {
  await seed();
  const db = aliceDb();

  // a clean client shell is fine
  await assertSucceeds(
    setDoc(doc(db, `users/alice/blobs/${HASH_NEW}`), {
      schemaVersion: 1,
      contentHash: HASH_NEW,
      byteSize: 4096,
      createdAt: T(2000),
    })
  );
  // ...but not one that claims completion state
  await assertFails(
    setDoc(doc(db, `users/alice/blobs/${hashOf(0x11)}`), {
      schemaVersion: 1,
      contentHash: hashOf(0x11),
      byteSize: 4096,
      renditions: { originals: { counted: true, byteSize: 4096, generation: '1' } },
    })
  );
  await assertFails(
    setDoc(doc(db, `users/alice/blobs/${hashOf(0x12)}`), {
      schemaVersion: 1,
      contentHash: hashOf(0x12),
      byteSize: 1,
      state: 'active',
    })
  );
  // ...and updates cannot forge them either
  await assertFails(
    updateDoc(doc(db, `users/alice/blobs/${HASH_A}`), {
      renditions: { originals: { counted: true, byteSize: 1234, generation: '7' } },
    })
  );
  await assertFails(
    updateDoc(doc(db, `users/alice/blobs/${HASH_A}`), { state: 'gcCandidate' })
  );
  await assertFails(
    updateDoc(doc(db, `users/alice/blobs/${HASH_A}`), { gcCandidateAt: T(5000) })
  );
  // contentHash is immutable once set
  await assertFails(
    updateDoc(doc(db, `users/alice/blobs/${HASH_A}`), { contentHash: HASH_NEW })
  );
});

test('config/** and deletedAccounts/** are not client-writable', async () => {
  await seed();
  const db = aliceDb();
  await assertSucceeds(getDoc(doc(db, 'config/flags')));
  await assertFails(setDoc(doc(db, 'config/flags'), { syncEnabled: true, maxUsers: 1e9 }));
  await assertFails(updateDoc(doc(db, 'config/counters'), { admittedUsers: 0 }));
  await assertFails(getDoc(doc(db, 'deletedAccounts/ghost')));
  await assertFails(setDoc(doc(db, 'deletedAccounts/alice'), { deletedAt: T(1) }));
});

// ===========================================================================
// Firestore — photo/blob shape invariants
// ===========================================================================
test('photo create referencing a blob in state=deleting is rejected', async () => {
  await seed();
  const db = aliceDb();

  // referencing a healthy blob is fine
  await assertSucceeds(
    setDoc(doc(db, 'users/alice/sessions/s1/photos/pOK'), {
      schemaVersion: 1,
      contentHash: HASH_A,
      look: null,
      orderKey: 'a1',
      createdAt: T(3000),
    })
  );
  // referencing one the GC has committed to deleting is not
  await assertFails(
    setDoc(doc(db, 'users/alice/sessions/s1/photos/pBad'), {
      schemaVersion: 1,
      contentHash: HASH_DELETING,
      look: null,
      orderKey: 'a2',
      createdAt: T(3000),
    })
  );
  // a hash with no blob doc yet is allowed (client creates the shell first or races)
  await assertSucceeds(
    setDoc(doc(db, 'users/alice/sessions/s1/photos/pFresh'), {
      schemaVersion: 1,
      contentHash: hashOf(0x77),
      look: null,
      orderKey: 'a3',
      createdAt: T(3000),
    })
  );
});

test('look must be a map or literal null', async () => {
  await seed();
  const db = aliceDb();
  await assertSucceeds(
    updateDoc(doc(db, PHOTO), { look: { bloom: 0.4 }, lookRev: 4, lookBy: 'mac', lookMut: 'm1' })
  );
  await seed();
  const db2 = aliceDb();
  await assertSucceeds(
    updateDoc(doc(db2, PHOTO), { look: null, lookRev: 4, lookBy: 'mac', lookMut: 'm2' })
  );
  await seed();
  const db3 = aliceDb();
  await assertFails(
    updateDoc(doc(db3, PHOTO), { look: 'vivid', lookRev: 4, lookBy: 'mac', lookMut: 'm3' })
  );
});

test('schemaVersion 2 is rejected everywhere', async () => {
  await seed();
  const db = aliceDb();
  await assertFails(updateDoc(doc(db, PHOTO), { schemaVersion: 2 }));
  await assertFails(updateDoc(doc(db, SESSION), { schemaVersion: 2 }));
  await assertFails(updateDoc(doc(db, 'users/alice'), { schemaVersion: 2 }));
  await assertFails(
    setDoc(doc(db, 'users/alice/sessions/s9'), { schemaVersion: 2, title: 'future' })
  );
  await assertFails(
    setDoc(doc(db, 'users/alice/sessions/s9'), { title: 'no version at all' })
  );
});

// ===========================================================================
// Firestore — per-group revision invariant
// ===========================================================================
test('photo look group: rev must be exactly old + 1', async () => {
  await seed();
  await assertSucceeds(
    updateDoc(doc(aliceDb(), PHOTO), { look: { bloom: 1 }, lookRev: 4, lookBy: 'ios', lookMut: 'm1' })
  );

  await seed();
  await assertFails(
    updateDoc(doc(aliceDb(), PHOTO), { look: { bloom: 1 }, lookRev: 3 }) // unchanged
  );
  await seed();
  await assertFails(
    updateDoc(doc(aliceDb(), PHOTO), { look: { bloom: 1 }, lookRev: 5 }) // skipped ahead
  );
  await seed();
  await assertFails(
    updateDoc(doc(aliceDb(), PHOTO), { look: { bloom: 1 } }) // rev not bumped at all
  );
  await seed();
  await assertFails(
    updateDoc(doc(aliceDb(), PHOTO), { lookRev: 9 }) // metadata-only jump
  );
});

test('photo order group and session groups enforce their own revs independently', async () => {
  await seed();
  await assertSucceeds(
    updateDoc(doc(aliceDb(), PHOTO), { orderKey: 'b0', orderRev: 2, orderBy: 'mac', orderMut: 'm2' })
  );
  await seed();
  await assertFails(updateDoc(doc(aliceDb(), PHOTO), { orderKey: 'b0', orderRev: 4 }));

  await seed();
  await assertSucceeds(
    updateDoc(doc(aliceDb(), SESSION), { title: 'Iceland II', titleRev: 3, titleBy: 'mac' })
  );
  await seed();
  await assertFails(updateDoc(doc(aliceDb(), SESSION), { title: 'Iceland II', titleRev: 2 }));

  await seed();
  await assertSucceeds(
    updateDoc(doc(aliceDb(), SESSION), {
      runningLook: { bloom: 0.2 },
      sameLookForAll: true,
      rlRev: 2,
      rlBy: 'ios',
    })
  );
  await seed();
  await assertFails(
    updateDoc(doc(aliceDb(), SESSION), { sameLookForAll: true, rlRev: 7 })
  );
});

test('tombstone group: setting deletedAt bumps delRev from an absent (=0) base', async () => {
  await seed();
  await assertSucceeds(
    updateDoc(doc(aliceDb(), PHOTO), {
      deletedAt: T(5000),
      delRev: 1,
      delBy: 'mac',
      delMut: 'd1',
      updatedAt: T(5000),
    })
  );
  await seed();
  await assertFails(
    updateDoc(doc(aliceDb(), PHOTO), { deletedAt: T(5000), delRev: 2 })
  );
  await seed();
  await assertFails(updateDoc(doc(aliceDb(), PHOTO), { deletedAt: T(5000) }));
});

// ===========================================================================
// Firestore — no client hard-deletes
// ===========================================================================
test('client hard-DELETE is denied on every client-facing document', async () => {
  await seed();
  const db = aliceDb();
  await assertFails(deleteDoc(doc(db, PHOTO)));
  await assertFails(deleteDoc(doc(db, SESSION)));
  await assertFails(deleteDoc(doc(db, `users/alice/blobs/${HASH_A}`)));
  await assertFails(deleteDoc(doc(db, 'users/alice/usage/storage')));
  await assertFails(deleteDoc(doc(db, 'users/alice')));
  await assertFails(deleteDoc(doc(db, 'config/flags')));
});

test('Admin SDK (maintenance / deleteAccount) can hard-delete', async () => {
  await seed();
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await assertSucceeds(deleteDoc(doc(db, PHOTO)));
    await assertSucceeds(deleteDoc(doc(db, SESSION)));
    await assertSucceeds(deleteDoc(doc(db, `users/alice/blobs/${HASH_A}`)));
  });
});

// ===========================================================================
// Firestore — kill switch
// ===========================================================================
test('kill switch blocks creates and ordinary updates', async () => {
  await seed({ syncEnabled: false });
  const db = aliceDb();
  await assertFails(
    setDoc(doc(db, 'users/alice/sessions/s2'), { schemaVersion: 1, title: 'blocked' })
  );
  await assertFails(
    setDoc(doc(db, `users/alice/blobs/${HASH_NEW}`), {
      schemaVersion: 1,
      contentHash: HASH_NEW,
      byteSize: 1,
    })
  );
  await assertFails(
    updateDoc(doc(db, PHOTO), { look: { bloom: 1 }, lookRev: 4, lookBy: 'mac' })
  );
  await assertFails(
    updateDoc(doc(db, SESSION), { title: 'blocked', titleRev: 3 })
  );
  await assertFails(updateDoc(doc(db, 'users/alice'), { hasCustomDefault: true }));
});

test('kill switch still allows tombstone-only updates (always able to delete / leave)', async () => {
  await seed({ syncEnabled: false });
  await assertSucceeds(
    updateDoc(doc(aliceDb(), PHOTO), {
      deletedAt: T(6000),
      delRev: 1,
      delBy: 'mac',
      delMut: 'd1',
      updatedAt: T(6000),
    })
  );

  await seed({ syncEnabled: false });
  await assertSucceeds(
    updateDoc(doc(aliceDb(), SESSION), {
      deletedAt: T(6000),
      delRev: 1,
      delBy: 'mac',
      delMut: 'd1',
      updatedAt: T(6000),
    })
  );

  // ...but a tombstone smuggling another field along is not tombstone-only
  await seed({ syncEnabled: false });
  await assertFails(
    updateDoc(aliceDb() && doc(aliceDb(), PHOTO), {
      deletedAt: T(6000),
      delRev: 1,
      orderKey: 'zz',
      orderRev: 2,
    })
  );
});

// ===========================================================================
// Storage
// ===========================================================================
const aliceStorage = () => testEnv.authenticatedContext('alice').storage();

async function seedReservation({ tier = 'originals', hash, byteSize, expiresAtMs }) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, `users/alice/reservations/${tier}_${hash}`), {
      schemaVersion: 1,
      contentHash: hash,
      tier,
      byteSize,
      createdAt: Timestamp.now(),
      expiresAt: Timestamp.fromMillis(expiresAtMs),
    });
  });
}

const bytes = (n) => new Uint8Array(n).fill(7);
const JPEG = { contentType: 'image/jpeg' };

test('Storage: upload with a matching, unexpired reservation is allowed', async (t) => {
  if (xsSkip(t)) return;
  await seed();
  await testEnv.clearStorage();
  const hash = hashOf(0x101);
  await seedReservation({ hash, byteSize: 16, expiresAtMs: Date.now() + 600_000 });
  await assertSucceeds(
    uploadBytes(ref(aliceStorage(), `users/alice/originals/${hash}.jpg`), bytes(16), JPEG)
  );
});

test('Storage: upload with NO reservation is rejected', async (t) => {
  if (xsSkip(t)) return;
  await seed();
  await testEnv.clearStorage();
  const hash = hashOf(0x102);
  await assertFails(
    uploadBytes(ref(aliceStorage(), `users/alice/originals/${hash}.jpg`), bytes(16), JPEG)
  );
});

test('Storage: reservation byteSize must match the object exactly', async (t) => {
  if (xsSkip(t)) return;
  await seed();
  await testEnv.clearStorage();
  const hash = hashOf(0x103);
  await seedReservation({ hash, byteSize: 16, expiresAtMs: Date.now() + 600_000 });
  await assertFails(
    uploadBytes(ref(aliceStorage(), `users/alice/originals/${hash}.jpg`), bytes(32), JPEG)
  );
});

test('Storage: an expired lease is rejected at finalize', async (t) => {
  if (xsSkip(t)) return;
  await seed();
  await testEnv.clearStorage();
  const hash = hashOf(0x104);
  // expiresAt in the past — rules evaluate at finalize, so this upload fails.
  await seedReservation({ hash, byteSize: 16, expiresAtMs: Date.now() - 5_000 });
  await assertFails(
    uploadBytes(ref(aliceStorage(), `users/alice/originals/${hash}.jpg`), bytes(16), JPEG)
  );
});

test('Storage: reservations are scoped per tier', async (t) => {
  if (xsSkip(t)) return;
  await seed();
  await testEnv.clearStorage();
  const hash = hashOf(0x105);
  await seedReservation({ tier: 'thumbs', hash, byteSize: 16, expiresAtMs: Date.now() + 600_000 });
  await assertSucceeds(
    uploadBytes(ref(aliceStorage(), `users/alice/thumbs/${hash}.jpg`), bytes(16), JPEG)
  );
  await assertFails(
    uploadBytes(ref(aliceStorage(), `users/alice/originals/${hash}.jpg`), bytes(16), JPEG)
  );
});

test('Storage: wrong contentType is rejected', async (t) => {
  if (xsSkip(t)) return;
  await seed();
  await testEnv.clearStorage();
  const hash = hashOf(0x106);
  await seedReservation({ hash, byteSize: 16, expiresAtMs: Date.now() + 600_000 });
  await assertFails(
    uploadBytes(ref(aliceStorage(), `users/alice/originals/${hash}.jpg`), bytes(16), {
      contentType: 'image/heic',
    })
  );
});

test('Storage: tier allowlist and file-name shape are enforced', async (t) => {
  if (xsSkip(t)) return;
  await seed();
  await testEnv.clearStorage();
  const hash = hashOf(0x107);
  await seedReservation({ tier: 'exports', hash, byteSize: 16, expiresAtMs: Date.now() + 600_000 });
  await assertFails(
    uploadBytes(ref(aliceStorage(), `users/alice/exports/${hash}.jpg`), bytes(16), JPEG)
  );
  await seedReservation({ hash: 'notahash', byteSize: 16, expiresAtMs: Date.now() + 600_000 });
  await assertFails(
    uploadBytes(ref(aliceStorage(), 'users/alice/originals/notahash.jpg'), bytes(16), JPEG)
  );
});

test('Storage: the kill switch blocks uploads even with a valid reservation', async (t) => {
  if (xsSkip(t)) return;
  await seed({ syncEnabled: false });
  await testEnv.clearStorage();
  const hash = hashOf(0x108);
  await seedReservation({ hash, byteSize: 16, expiresAtMs: Date.now() + 600_000 });
  await assertFails(
    uploadBytes(ref(aliceStorage(), `users/alice/originals/${hash}.jpg`), bytes(16), JPEG)
  );
});

test('Storage: a stranger cannot upload into or read another user prefix', async (t) => {
  if (xsSkip(t)) return;
  await seed();
  await testEnv.clearStorage();
  const hash = hashOf(0x109);
  await seedReservation({ hash, byteSize: 16, expiresAtMs: Date.now() + 600_000 });
  const bobSt = testEnv.authenticatedContext('bob').storage();
  await assertFails(
    uploadBytes(ref(bobSt, `users/alice/originals/${hash}.jpg`), bytes(16), JPEG)
  );
});

test('Storage: client DELETE is denied (no client GC)', async () => {
  // Deliberately NOT gated on cross-service support: `allow delete: if false`
  // needs no firestore.get(), so this assertion is meaningful either way.
  await seed();
  await testEnv.clearStorage();
  const hash = hashOf(0x10a);
  const objectPath = `users/alice/originals/${hash}.jpg`;
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await uploadBytes(ref(ctx.storage(), objectPath), bytes(16), JPEG);
  });
  await assertFails(deleteObject(ref(aliceStorage(), objectPath)));
  // ...and the owner can still read it
  await assertSucceeds(
    (async () => {
      const { getMetadata } = await import('firebase/storage');
      return getMetadata(ref(aliceStorage(), objectPath));
    })()
  );
});

test('Storage: the 64 MB cap and CREATE-only posture are expressed in the ruleset', () => {
  // Uploading a 64 MB body through the emulator on every run is not worth the
  // wall-clock; the guard is asserted structurally instead (and enforced a second
  // time server-side by reserveUpload, which is exercised in functions.test.mjs).
  assert.match(STORAGE_RULES, /request\.resource\.size\s*<\s*64\s*\*\s*1024\s*\*\s*1024/);
  assert.match(STORAGE_RULES, /allow update:\s*if false/);
  assert.match(STORAGE_RULES, /allow delete:\s*if false/);
  assert.match(STORAGE_RULES, /request\.resource\.contentType\s*==\s*'image\/jpeg'/);
  // exactly two cross-service reads in the ACTIVE ruleset (comments excluded)
  const active = STORAGE_RULES.split('\n')
    .filter((line) => !line.trim().startsWith('//'))
    .join('\n');
  assert.equal(
    (active.match(/firestore\.get\(/g) || []).length,
    2,
    'Storage rules may make at most two cross-service Firestore reads'
  );
});

test('cross-service support was probed, not assumed', () => {
  if (!crossServiceSupported) {
    console.warn(`\n[SKIPPED-COVERAGE] ${XS_SKIP_REASON}\n`);
  }
  assert.equal(typeof crossServiceSupported, 'boolean');
});
