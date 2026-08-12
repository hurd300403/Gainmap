'use strict';

const { HttpsError } = require('firebase-functions/v2/https');
const {
  SCHEMA_VERSION,
  RECENT_AUTH_SEC,
  DELETED_ACCOUNT_MARKER_TTL_MS,
  num,
} = require('./constants');
const { Timestamp } = require('firebase-admin/firestore');

/**
 * Server-side recent-auth enforcement (spec 5.1.1(v)). A destructive, irreversible
 * operation must not be reachable with a token minted days ago; the client is
 * expected to re-authenticate immediately before calling.
 *
 * @param {object} token  decoded auth token (request.auth.token)
 * @param {number} nowMs
 */
function assertRecentAuth(token, nowMs) {
  const authTime = token && token.auth_time;
  if (!Number.isFinite(authTime)) {
    throw new HttpsError('failed-precondition', 'Please sign in again to delete your account.');
  }
  const ageSec = nowMs / 1000 - authTime;
  if (!(ageSec <= RECENT_AUTH_SEC)) {
    throw new HttpsError('failed-precondition', 'Please sign in again to delete your account.');
  }
  return true;
}

/**
 * deleteAccount core.
 *
 * Order matters:
 *  1. Write deletedAccounts/{uid} FIRST, in the same transaction that decrements
 *     the admission counter. The marker lives OUTSIDE the user tree so the
 *     recursive delete below cannot remove its own guard, and it is what makes
 *     usageReconciler delete (not merely ignore) objects finalized by an
 *     already-authorized resumable session that completes after the purge.
 *     TTL: apply the Firestore TTL policy to `expiresAt` (not `deletedAt`).
 *     `expiresAt` is written 30 days in the future, longer than the maximum
 *     resumable-upload session lifetime plus event-delivery margin.
 *  2. The counter decrements EXACTLY ONCE: it is guarded on the marker not
 *     already existing, so a retried call is a no-op.
 *  3. Firestore subtree and Storage prefix. The caller performs any adjacent
 *     identity cleanup (Patreon indexes) and deletes Auth LAST, so a cleanup
 *     failure remains retryable by the still-authenticated user.
 */
async function deleteAccountCore({ db, bucket, auth, uid, now }) {
  if (typeof uid !== 'string' || uid.length === 0) {
    throw new HttpsError('unauthenticated', 'A signed-in user is required.');
  }

  const markerRef = db.doc(`deletedAccounts/${uid}`);
  const countersRef = db.doc('config/counters');

  const counterDecremented = await db.runTransaction(async (tx) => {
    const markerSnap = await tx.get(markerRef);
    const countersSnap = await tx.get(countersRef);
    const userSnap = await tx.get(db.doc(`users/${uid}`));
    if (markerSnap.exists) {
      return false; // already deleted (or a retry) — never decrement twice
    }
    const admittedUsers = countersSnap.exists ? num(countersSnap.get('admittedUsers')) : 0;
    const occupiedSeat = userSnap.exists && userSnap.get('syncAdmitted') === true;
    if (occupiedSeat && !countersSnap.exists) {
      throw new HttpsError(
        'failed-precondition',
        'Cloud Sync account counters require administrator repair before deletion.'
      );
    }
    tx.create(markerRef, {
      schemaVersion: SCHEMA_VERSION,
      deletedAt: now,
      expiresAt: Timestamp.fromMillis(now.toMillis() + DELETED_ACCOUNT_MARKER_TTL_MS),
    });
    if (occupiedSeat) {
      tx.set(countersRef, { admittedUsers: Math.max(0, admittedUsers - 1) }, { merge: true });
    }
    return occupiedSeat;
  });

  await db.recursiveDelete(db.doc(`users/${uid}`));

  if (bucket) {
    await bucket.deleteFiles({ prefix: `users/${uid}/`, force: true });
  }

  return { deleted: true, counterDecremented };
}

module.exports = { deleteAccountCore, assertRecentAuth };
