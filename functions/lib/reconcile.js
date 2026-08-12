'use strict';

const {
  SCHEMA_VERSION,
  reservationId,
  parseObjectName,
  num,
  compareGenerations,
} = require('./constants');

/**
 * usageReconciler core — the SOLE writer of rendition completion state.
 *
 * Two deployed handlers (onObjectFinalized, onObjectDeleted) share this module.
 * Eventarc delivery is at-least-once AND unordered, so every path here must be
 * idempotent and order-insensitive. The mechanism is a persisted per-tier
 * generation ledger on the blob doc:
 *
 *   blobs/{contentHash}.renditions.{tier} = {
 *     generation: "<int64 as string>",   // NEVER a Number: generations exceed 2^53
 *     byteSize, counted, lastEvent: 'finalized'|'deleted', uploadedAt|deletedAt
 *   }
 *
 * Ordering rules:
 *   finalize  skip if gen <  lastGeneration                    (stale duplicate)
 *             skip if gen == lastGeneration && lastEvent=='deleted'
 *                                                              (its own delete already won)
 *             skip if gen == lastGeneration && counted         (duplicate finalize)
 *   delete    skip if gen <  lastGeneration                    (stale duplicate)
 *             skip if gen == lastGeneration && lastEvent=='deleted'
 *
 * A delete that arrives BEFORE its finalize still writes a ledger entry, so the
 * late finalize hits the "gen == lastGeneration && deleted" rule and cannot
 * resurrect usage.
 */

function tierLedger(blobSnap, tier) {
  if (!blobSnap || !blobSnap.exists) return null;
  const renditions = blobSnap.get('renditions');
  if (!renditions || typeof renditions !== 'object') return null;
  const entry = renditions[tier];
  return entry && typeof entry === 'object' ? entry : null;
}

async function deleteObjectQuietly(bucket, name, generation) {
  if (!bucket) return false;
  try {
    // Scope cleanup to the exact object generation that emitted this event.
    // The transaction above can decide that generation N is orphaned, then a
    // reactivated user can upload generation N+1 at the same path before this
    // request reaches Storage. An unconditional name-only delete would destroy
    // that replacement. GCS evaluates ifGenerationMatch atomically.
    await bucket.file(name, {
      preconditionOpts: { ifGenerationMatch: String(generation) },
    }).delete({ ignoreNotFound: true });
    return true;
  } catch (err) {
    // 404: the event generation is already gone. 412: a newer generation now
    // occupies the name. Both are successful no-ops for this stale event.
    if (err && (err.code === 404 || err.code === 412 ||
        err.code === 'storage/object-not-found' ||
        err.code === 'storage/precondition-failed')) return false;
    throw err;
  }
}

/**
 * onObjectFinalized core.
 *
 * @param {object} a
 * @param {FirebaseFirestore.Firestore} a.db
 * @param {object} a.bucket             Admin Storage bucket (or a test double)
 * @param {string} a.name               full object name
 * @param {string} a.generation         int64 as a STRING
 * @param {number} a.byteSize
 * @param {FirebaseFirestore.Timestamp} a.now
 */
async function handleFinalize({ db, bucket, name, generation, byteSize, now }) {
  const parsed = parseObjectName(name);
  if (!parsed) return { skipped: 'not-a-rendition' };
  const { uid, tier, contentHash } = parsed;

  const gen = String(generation);
  const size = num(byteSize);

  const markerRef = db.doc(`deletedAccounts/${uid}`);
  const entitlementRef = db.doc(`patreonEntitlements/${uid}`);
  const userRef = db.doc(`users/${uid}`);
  const blobRef = db.doc(`users/${uid}/blobs/${contentHash}`);
  const usageRef = db.doc(`users/${uid}/usage/storage`);
  const resRef = db.doc(`users/${uid}/reservations/${reservationId(tier, contentHash)}`);

  const outcome = await db.runTransaction(async (tx) => {
    // ---- post-deletion upload cleanup (r6).
    // An already-authorized resumable session can complete minutes or days after
    // the account is gone. Do not merely no-op: the object must be DELETED, or the
    // purged prefix silently refills. The marker lives outside the user tree
    // precisely so recursiveDelete(users/{uid}) cannot remove its own guard.
    //
    // These two reads are deliberately INSIDE the transaction. deleteAccount
    // writes the marker in a transaction of its own before it purges, so a
    // concurrent deletion either commits before these reads (we observe the
    // marker) or after our commit (its recursiveDelete removes whatever we
    // wrote). Reading the guard outside the transaction would leave a window in
    // which both miss and an orphaned subtree survives.
    const [markerSnap, userSnap, entitlementSnap] = await Promise.all([
      tx.get(markerRef), tx.get(userRef), tx.get(entitlementRef),
    ]);
    const entitlement = entitlementSnap.exists ? entitlementSnap.data() || {} : {};
    const livePurge = Boolean(entitlement.purgeLeaseId);
    if (markerSnap.exists || !userSnap.exists || livePurge || entitlement.cloudDataPurgedAt) {
      return {
        orphan: true,
        reason: markerSnap.exists ? 'account-deleted'
          : (livePurge || entitlement.cloudDataPurgedAt ? 'retention-purge' : 'no-user-doc'),
      };
    }

    const blobSnap = await tx.get(blobRef);
    const usageSnap = await tx.get(usageRef);
    const resSnap = await tx.get(resRef);

    const ledger = tierLedger(blobSnap, tier);
    if (ledger && ledger.generation != null) {
      const cmp = compareGenerations(gen, ledger.generation);
      if (cmp < 0) return { skipped: 'stale-generation' };
      if (cmp === 0 && ledger.lastEvent === 'deleted') return { skipped: 'already-deleted' };
      if (cmp === 0 && ledger.counted === true) return { skipped: 'duplicate-finalize' };
    }

    const prevCounted = !!(ledger && ledger.counted === true);
    const prevBytes = prevCounted ? num(ledger.byteSize) : 0;

    let bytesUsed = usageSnap.exists ? num(usageSnap.get('bytesUsed')) : 0;
    let objectCount = usageSnap.exists ? num(usageSnap.get('objectCount')) : 0;
    let reservedBytes = usageSnap.exists ? num(usageSnap.get('reservedBytes')) : 0;

    bytesUsed = Math.max(0, bytesUsed - prevBytes) + size;
    if (!prevCounted) objectCount += 1;

    // Reserved -> used. A missing or already-expired reservation still counts:
    // storage reality is the truth, and the nightly recompute heals any drift.
    if (resSnap.exists) {
      reservedBytes = Math.max(0, reservedBytes - num(resSnap.get('byteSize')));
      tx.delete(resRef);
    }

    const blobPatch = {
      schemaVersion: SCHEMA_VERSION,
      contentHash,
      renditions: {
        [tier]: {
          generation: gen, // string — BigInt-safe
          byteSize: size,
          counted: true,
          lastEvent: 'finalized',
          uploadedAt: now,
        },
      },
      updatedAt: now,
    };
    // Only the create path seeds `state`; never resurrect a blob that maintenance
    // has already moved to gcCandidate/deleting — pass 2 will clean it up.
    if (!blobSnap.exists) blobPatch.state = 'active';

    tx.set(blobRef, blobPatch, { merge: true });
    tx.set(
      usageRef,
      {
        schemaVersion: SCHEMA_VERSION,
        bytesUsed,
        objectCount,
        reservedBytes,
        updatedAt: now,
      },
      { merge: true }
    );

    return { counted: true, bytesUsed, objectCount, reservedBytes };
  });

  if (outcome.orphan) {
    const deleted = await deleteObjectQuietly(bucket, name, gen);
    return deleted
      ? { orphanDeleted: true, reason: outcome.reason }
      : { orphanDeleted: false, skipped: 'already-gone-or-replaced', reason: outcome.reason };
  }
  return outcome;
}

/**
 * onObjectDeleted core. Shares the ledger with handleFinalize.
 */
async function handleDelete({ db, name, generation, now }) {
  const parsed = parseObjectName(name);
  if (!parsed) return { skipped: 'not-a-rendition' };
  const { uid, tier, contentHash } = parsed;
  const gen = String(generation);

  const markerRef = db.doc(`deletedAccounts/${uid}`);
  const entitlementRef = db.doc(`patreonEntitlements/${uid}`);
  const userRef = db.doc(`users/${uid}`);
  const blobRef = db.doc(`users/${uid}/blobs/${contentHash}`);
  const usageRef = db.doc(`users/${uid}/usage/storage`);

  return db.runTransaction(async (tx) => {
    // Same in-transaction deletion guard as handleFinalize: the whole subtree is
    // gone (or going), and writing a ledger here would resurrect it.
    const [markerSnap, userSnap, entitlementSnap] = await Promise.all([
      tx.get(markerRef), tx.get(userRef), tx.get(entitlementRef),
    ]);
    const entitlement = entitlementSnap.exists ? entitlementSnap.data() || {} : {};
    const livePurge = Boolean(entitlement.purgeLeaseId);
    if (markerSnap.exists || !userSnap.exists || livePurge || entitlement.cloudDataPurgedAt) {
      return { skipped: 'account-deleted' };
    }

    const blobSnap = await tx.get(blobRef);
    const usageSnap = await tx.get(usageRef);

    const ledger = tierLedger(blobSnap, tier);
    let wasCounted = false;
    let ledgerBytes = 0;

    if (ledger && ledger.generation != null) {
      const cmp = compareGenerations(gen, ledger.generation);
      if (cmp < 0) return { skipped: 'stale-generation' };
      if (cmp === 0 && ledger.lastEvent === 'deleted') return { skipped: 'duplicate-delete' };
      wasCounted = ledger.counted === true;
      ledgerBytes = num(ledger.byteSize);
    }

    let bytesUsed = usageSnap.exists ? num(usageSnap.get('bytesUsed')) : 0;
    let objectCount = usageSnap.exists ? num(usageSnap.get('objectCount')) : 0;
    if (wasCounted) {
      bytesUsed = Math.max(0, bytesUsed - ledgerBytes);
      objectCount = Math.max(0, objectCount - 1);
    }

    // Record the delete even when no finalize was ever seen: this is what makes a
    // later out-of-order finalize for the SAME generation a no-op.
    tx.set(
      blobRef,
      {
        schemaVersion: SCHEMA_VERSION,
        contentHash,
        renditions: {
          [tier]: {
            generation: gen,
            byteSize: ledgerBytes,
            counted: false,
            lastEvent: 'deleted',
            deletedAt: now,
          },
        },
        updatedAt: now,
      },
      { merge: true }
    );
    tx.set(
      usageRef,
      {
        schemaVersion: SCHEMA_VERSION,
        bytesUsed,
        objectCount,
        updatedAt: now,
      },
      { merge: true }
    );

    return { uncounted: wasCounted, bytesUsed, objectCount };
  });
}

module.exports = { handleFinalize, handleDelete, tierLedger, deleteObjectQuietly };
