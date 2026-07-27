'use strict';

const { Timestamp } = require('firebase-admin/firestore');
const {
  SCHEMA_VERSION,
  TIERS,
  TOMBSTONE_RETENTION_MS,
  GC_CANDIDATE_AGE_MS,
  reservationId,
  objectName,
  num,
} = require('./constants');

/**
 * Scheduled maintenance (every 24 h). Four independent passes; each is written so
 * a failure in one does not prevent the others from running.
 *
 *  1. releaseExpiredReservations — capacity leases past `releaseAfter`
 *  2. purgeTombstones            — sessions/photos deleted > 30 days ago
 *  3. blobGC                     — three-state, two-pass: active -> gcCandidate -> deleting
 *  4. recomputeUsage             — heal bytesUsed/objectCount drift from bucket reality
 */

// ---------------------------------------------------------------------------
// 1. Capacity-lease release
// ---------------------------------------------------------------------------
/**
 * Releases reservations only after `releaseAfter` (NOT `startBefore`): an upload
 * that legitimately started at the last minute of its authorization window may
 * still take the full resumable-session lifetime to finish, and its bytes must
 * stay charged until then.
 */
async function releaseExpiredReservations({ db, now }) {
  const snap = await db
    .collectionGroup('reservations')
    .where('releaseAfter', '<', now)
    .get();

  let released = 0;
  for (const doc of snap.docs) {
    const uid = doc.ref.parent.parent && doc.ref.parent.parent.id;
    if (!uid) continue;
    const usageRef = db.doc(`users/${uid}/usage/storage`);
    // eslint-disable-next-line no-await-in-loop
    const did = await db.runTransaction(async (tx) => {
      const resSnap = await tx.get(doc.ref);
      if (!resSnap.exists) return false;
      const usageSnap = await tx.get(usageRef);
      const reservedBytes = usageSnap.exists ? num(usageSnap.get('reservedBytes')) : 0;
      tx.set(
        usageRef,
        {
          schemaVersion: SCHEMA_VERSION,
          reservedBytes: Math.max(0, reservedBytes - num(resSnap.get('byteSize'))),
          updatedAt: now,
        },
        { merge: true }
      );
      tx.delete(doc.ref);
      return true;
    });
    if (did) released += 1;
  }
  return { released };
}

// ---------------------------------------------------------------------------
// 2. Tombstone purge
// ---------------------------------------------------------------------------
async function purgeTombstones({ db, now, retentionMs = TOMBSTONE_RETENTION_MS }) {
  const cutoff = Timestamp.fromMillis(now.toMillis() - retentionMs);

  const sessions = await db.collectionGroup('sessions').where('deletedAt', '<', cutoff).get();
  for (const doc of sessions.docs) {
    // recursiveDelete removes the photos subcollection too.
    // eslint-disable-next-line no-await-in-loop
    await db.recursiveDelete(doc.ref);
  }

  const photos = await db.collectionGroup('photos').where('deletedAt', '<', cutoff).get();
  let photosPurged = 0;
  for (const doc of photos.docs) {
    // eslint-disable-next-line no-await-in-loop
    await doc.ref.delete();
    photosPurged += 1;
  }

  return { sessionsPurged: sessions.size, photosPurged };
}

// ---------------------------------------------------------------------------
// 3. Blob GC — three-state, two-pass
// ---------------------------------------------------------------------------
/**
 * A blob is "referenced" if ANY of:
 *   - a live photo doc (no deletedAt) in this user's tree carries the hash
 *   - a still-retained tombstone (deletedAt within the retention window) does
 *     — undo must be able to bring the bytes back
 *   - an active reservation exists for the hash in any tier (upload in flight)
 */
async function isReferenced({ db, uid, contentHash, now, retentionMs = TOMBSTONE_RETENTION_MS }) {
  const cutoffMs = now.toMillis() - retentionMs;

  const photos = await db
    .collectionGroup('photos')
    .where('contentHash', '==', contentHash)
    .get();
  for (const doc of photos.docs) {
    if (!doc.ref.path.startsWith(`users/${uid}/`)) continue; // other users' trees
    const deletedAt = doc.get('deletedAt');
    if (deletedAt == null) return true;
    const ms = typeof deletedAt.toMillis === 'function' ? deletedAt.toMillis() : Number(deletedAt);
    if (Number.isFinite(ms) && ms >= cutoffMs) return true;
  }

  for (const tier of TIERS) {
    // eslint-disable-next-line no-await-in-loop
    const resSnap = await db
      .doc(`users/${uid}/reservations/${reservationId(tier, contentHash)}`)
      .get();
    if (resSnap.exists) return true;
  }

  return false;
}

/**
 * Pass 1 — mark unreferenced blobs as gcCandidate (and un-mark ones that became
 * referenced again, e.g. a tombstone was undone).
 */
async function gcPassOne({ db, uid, now, retentionMs }) {
  const blobs = await db.collection(`users/${uid}/blobs`).get();
  let marked = 0;
  let unmarked = 0;

  for (const doc of blobs.docs) {
    const state = doc.get('state') || 'active';
    if (state === 'deleting') continue; // pass 2 owns it
    // eslint-disable-next-line no-await-in-loop
    const referenced = await isReferenced({ db, uid, contentHash: doc.id, now, retentionMs });

    if (!referenced && state !== 'gcCandidate') {
      // eslint-disable-next-line no-await-in-loop
      await doc.ref.set({ state: 'gcCandidate', gcCandidateAt: now, updatedAt: now }, { merge: true });
      marked += 1;
    } else if (referenced && state === 'gcCandidate') {
      // eslint-disable-next-line no-await-in-loop
      await doc.ref.set({ state: 'active', gcCandidateAt: null, updatedAt: now }, { merge: true });
      unmarked += 1;
    }
  }
  return { marked, unmarked };
}

/**
 * Pass 2 — for candidates that have been quiet for >= 24 h: re-check references,
 * atomically flip to `deleting` (firestore.rules REJECTS new photo creates that
 * reference a blob in this state, which is what closes the recheck-then-reference
 * race), then physically delete the objects and the blob doc.
 *
 * Usage accounting is deliberately NOT done here: deleting the objects fires
 * onObjectDeleted, and the reconciler decrements against the still-present
 * ledger. Any event that arrives after the blob doc is gone finds no ledger,
 * so it cannot double-decrement; it may leave a stub blob doc, which the next
 * pass 1 marks and pass 2 removes (it has no counted renditions and no objects).
 * The nightly recompute is the backstop for a delete event that never arrives.
 */
async function gcPassTwo({ db, bucket, uid, now, candidateAgeMs = GC_CANDIDATE_AGE_MS, retentionMs }) {
  const threshold = Timestamp.fromMillis(now.toMillis() - candidateAgeMs);
  const candidates = await db
    .collection(`users/${uid}/blobs`)
    .where('state', '==', 'gcCandidate')
    .get();

  let deleted = 0;
  for (const doc of candidates.docs) {
    const at = doc.get('gcCandidateAt');
    if (!at || typeof at.toMillis !== 'function' || at.toMillis() > threshold.toMillis()) continue;

    // eslint-disable-next-line no-await-in-loop
    const referenced = await isReferenced({ db, uid, contentHash: doc.id, now, retentionMs });
    if (referenced) {
      // eslint-disable-next-line no-await-in-loop
      await doc.ref.set({ state: 'active', gcCandidateAt: null, updatedAt: now }, { merge: true });
      continue;
    }

    // eslint-disable-next-line no-await-in-loop
    const committed = await db.runTransaction(async (tx) => {
      const snap = await tx.get(doc.ref);
      if (!snap.exists || snap.get('state') !== 'gcCandidate') return false;
      tx.set(doc.ref, { state: 'deleting', deletingAt: now, updatedAt: now }, { merge: true });
      return true;
    });
    if (!committed) continue;

    if (bucket) {
      for (const tier of TIERS) {
        // eslint-disable-next-line no-await-in-loop
        await bucket
          .file(objectName(uid, tier, doc.id))
          .delete({ ignoreNotFound: true })
          .catch((err) => {
            if (!err || (err.code !== 404 && err.code !== 'storage/object-not-found')) throw err;
          });
      }
    }

    // eslint-disable-next-line no-await-in-loop
    await doc.ref.delete();
    deleted += 1;
  }
  return { deleted };
}

// ---------------------------------------------------------------------------
// 4. Nightly usage recompute
// ---------------------------------------------------------------------------
/**
 * Heals bytesUsed/objectCount drift by listing the bucket prefix. reservedBytes is
 * deliberately left alone — it is a promise about the future, not a fact about the
 * bucket, and releaseExpiredReservations owns it.
 */
async function recomputeUsage({ db, bucket, uid, now }) {
  if (!bucket) return { skipped: 'no-bucket' };
  const [files] = await bucket.getFiles({ prefix: `users/${uid}/` });

  let bytesUsed = 0;
  let objectCount = 0;
  for (const file of files) {
    const size = num(file.metadata && file.metadata.size);
    bytesUsed += size;
    objectCount += 1;
  }

  const usageRef = db.doc(`users/${uid}/usage/storage`);
  const snap = await usageRef.get();
  const prevBytes = snap.exists ? num(snap.get('bytesUsed')) : 0;
  const prevCount = snap.exists ? num(snap.get('objectCount')) : 0;
  if (prevBytes === bytesUsed && prevCount === objectCount) {
    return { healed: false, bytesUsed, objectCount };
  }
  await usageRef.set(
    { schemaVersion: SCHEMA_VERSION, bytesUsed, objectCount, updatedAt: now },
    { merge: true }
  );
  return { healed: true, bytesUsed, objectCount, prevBytes, prevCount };
}

// ---------------------------------------------------------------------------
// orchestrator
// ---------------------------------------------------------------------------
async function runMaintenance({
  db,
  bucket,
  now,
  retentionMs = TOMBSTONE_RETENTION_MS,
  candidateAgeMs = GC_CANDIDATE_AGE_MS,
  recompute = true,
}) {
  const report = { errors: [] };

  const step = async (name, fn) => {
    try {
      report[name] = await fn();
    } catch (err) {
      report.errors.push({ step: name, message: String((err && err.message) || err) });
    }
  };

  await step('reservations', () => releaseExpiredReservations({ db, now }));
  await step('tombstones', () => purgeTombstones({ db, now, retentionMs }));

  const users = await db.collection('users').get();
  const gc = { marked: 0, unmarked: 0, deleted: 0 };
  const usage = { healed: 0 };

  for (const userDoc of users.docs) {
    const uid = userDoc.id;
    // eslint-disable-next-line no-await-in-loop
    const marker = await db.doc(`deletedAccounts/${uid}`).get();
    if (marker.exists) continue;

    try {
      // eslint-disable-next-line no-await-in-loop
      const p1 = await gcPassOne({ db, uid, now, retentionMs });
      gc.marked += p1.marked;
      gc.unmarked += p1.unmarked;
      // eslint-disable-next-line no-await-in-loop
      const p2 = await gcPassTwo({ db, bucket, uid, now, candidateAgeMs, retentionMs });
      gc.deleted += p2.deleted;
      if (recompute) {
        // eslint-disable-next-line no-await-in-loop
        const r = await recomputeUsage({ db, bucket, uid, now });
        if (r.healed) usage.healed += 1;
      }
    } catch (err) {
      report.errors.push({ step: `user:${uid}`, message: String((err && err.message) || err) });
    }
  }

  report.gc = gc;
  report.usage = usage;
  return report;
}

module.exports = {
  runMaintenance,
  releaseExpiredReservations,
  purgeTombstones,
  isReferenced,
  gcPassOne,
  gcPassTwo,
  recomputeUsage,
};
