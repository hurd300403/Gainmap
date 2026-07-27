'use strict';

const { HttpsError } = require('firebase-functions/v2/https');
const { Timestamp } = require('firebase-admin/firestore');
const {
  PRODUCTION_PROJECT,
  SCHEMA_VERSION,
  TIERS,
  MAX_OBJECT_BYTES,
  DEFAULT_QUOTA_BYTES,
  DEFAULT_LEASE_SEC,
  HASH_RE,
  reservationId,
  objectName,
  num,
} = require('./constants');

/**
 * Resolve the reservation lease (the single deadline: expiresAt = now + lease).
 *
 * The override lives in config/testing {leaseSec} and is honoured ONLY when the
 * runtime project is not gainmap-production. Rationale: the P0 real-project
 * reservation-lifecycle probe and CI both need to watch a lease expire without
 * literally waiting 8 days, but a client-reachable knob that shortens (or
 * lengthens) capacity leases in production would be a quota-evasion lever. The
 * document is server-owned (firestore.rules denies all client writes to
 * config/**) *and* inert in production — belt and braces.
 */
function resolveLeaseSec(testingData, projectId) {
  const isProd = projectId === PRODUCTION_PROJECT;
  const t = (!isProd && testingData) || {};
  return Number.isFinite(t.leaseSec) && t.leaseSec > 0 ? t.leaseSec : DEFAULT_LEASE_SEC;
}

function validate(data) {
  const contentHash = data && data.contentHash;
  const tier = data && data.tier;
  const byteSize = data && data.byteSize;

  if (typeof contentHash !== 'string' || !HASH_RE.test(contentHash)) {
    throw new HttpsError('invalid-argument', 'contentHash must be 64 lowercase hex characters.');
  }
  if (typeof tier !== 'string' || !TIERS.includes(tier)) {
    throw new HttpsError('invalid-argument', `tier must be one of ${TIERS.join(', ')}.`);
  }
  if (!Number.isInteger(byteSize) || byteSize <= 0 || byteSize >= MAX_OBJECT_BYTES) {
    throw new HttpsError(
      'invalid-argument',
      `byteSize must be an integer in (0, ${MAX_OBJECT_BYTES}).`
    );
  }
  return { contentHash, tier, byteSize };
}

/**
 * reserveUpload core — the ONLY place quota arithmetic happens.
 *
 * Storage rules check only "a matching, unexpired reservation exists" — and
 * they check it at FINALIZE (probe-proven; P0-PROBE-RESULTS.md), so expiresAt
 * is a COMPLETION deadline. The capacity accounting is here, inside a
 * transaction, so concurrent uploads cannot race past the quota.
 *
 * Idempotency: re-reserving the same (contentHash, tier, byteSize) atomically
 * refreshes expiresAt = now + LEASE and never double-counts reservedBytes.
 *
 * CLIENT CONTRACT: a 403 at finalize means the lease expired mid-upload. The
 * client re-reserves (this refresh even revives a still-open resumable
 * session — probe E2) and retries the upload.
 *
 * @returns {Promise<{reservationId, objectName, byteSize, expiresAt:number,
 *                    refreshed:boolean}>}
 */
async function reserveUploadCore({ db, uid, data, now, projectId }) {
  if (typeof uid !== 'string' || uid.length === 0) {
    throw new HttpsError('unauthenticated', 'A signed-in user is required.');
  }
  const { contentHash, tier, byteSize } = validate(data);

  const resId = reservationId(tier, contentHash);
  const flagsRef = db.doc('config/flags');
  const testingRef = db.doc('config/testing');
  const userRef = db.doc(`users/${uid}`);
  const usageRef = db.doc(`users/${uid}/usage/storage`);
  const resRef = db.doc(`users/${uid}/reservations/${resId}`);

  return db.runTransaction(async (tx) => {
    // ---- reads
    const flagsSnap = await tx.get(flagsRef);
    const userSnap = await tx.get(userRef);
    const usageSnap = await tx.get(usageRef);
    const resSnap = await tx.get(resRef);
    const testingSnap =
      projectId === PRODUCTION_PROJECT ? null : await tx.get(testingRef);

    // Kill switch: a disabled sync must not accumulate week-long capacity leases.
    if (!flagsSnap.exists || flagsSnap.get('syncEnabled') !== true) {
      throw new HttpsError('failed-precondition', 'Sync is temporarily disabled.');
    }
    if (!userSnap.exists || userSnap.get('syncAdmitted') !== true) {
      throw new HttpsError('permission-denied', 'This account is not admitted to sync.');
    }

    const leaseSec = resolveLeaseSec(
      testingSnap && testingSnap.exists ? testingSnap.data() : null,
      projectId
    );

    const expiresAtMs = now.toMillis() + leaseSec * 1000;

    const quotaBytes = num(userSnap.get('quotaBytes')) || DEFAULT_QUOTA_BYTES;
    const bytesUsed = usageSnap.exists ? num(usageSnap.get('bytesUsed')) : 0;
    const reservedBytes = usageSnap.exists ? num(usageSnap.get('reservedBytes')) : 0;

    const priorBytes = resSnap.exists ? num(resSnap.get('byteSize')) : 0;
    const refreshed = resSnap.exists && priorBytes === byteSize;
    // On a refresh the delta is exactly 0 — the bytes are already reserved.
    const delta = byteSize - priorBytes;

    if (!refreshed && bytesUsed + reservedBytes + delta > quotaBytes) {
      throw new HttpsError(
        'resource-exhausted',
        'Storage quota exceeded. Free space or remove downloads to continue syncing.',
        { bytesUsed, reservedBytes, byteSize, quotaBytes }
      );
    }

    // ---- writes
    tx.set(
      resRef,
      {
        schemaVersion: SCHEMA_VERSION,
        contentHash,
        tier,
        byteSize,
        createdAt: resSnap.exists ? resSnap.get('createdAt') || now : now,
        expiresAt: Timestamp.fromMillis(expiresAtMs),
      },
      { merge: true }
    );

    if (delta !== 0) {
      tx.set(
        usageRef,
        {
          schemaVersion: SCHEMA_VERSION,
          reservedBytes: Math.max(0, reservedBytes + delta),
          updatedAt: now,
        },
        { merge: true }
      );
    }

    return {
      reservationId: resId,
      objectName: objectName(uid, tier, contentHash),
      byteSize,
      expiresAt: expiresAtMs,
      refreshed,
    };
  });
}

module.exports = { reserveUploadCore, resolveLeaseSec, validate };
