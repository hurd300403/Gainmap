'use strict';

const { HttpsError } = require('firebase-functions/v2/https');
const {
  SCHEMA_VERSION,
  DEFAULT_QUOTA_BYTES,
  DEFAULT_MAX_USERS,
  num,
} = require('./constants');

/**
 * admitSyncUser core.
 *
 * Sync admission is deliberately separate from Auth: anyone may sign in, but only
 * an admitted user may write into the user tree (firestore.rules requires
 * users/{uid}.syncAdmitted == true on every client write). Because the client
 * CREATE rule on users/{uid} is `if false`, this function is the ONLY provisioner,
 * which is what makes the signup cap authoritative.
 *
 * Idempotent: re-calling for an already-admitted uid returns success without
 * touching the counter.
 *
 * @param {object}  a
 * @param {FirebaseFirestore.Firestore} a.db
 * @param {string}  a.uid
 * @param {FirebaseFirestore.Timestamp} a.now
 * @returns {Promise<{admitted: boolean, reason?: string, alreadyAdmitted?: boolean, quotaBytes?: number}>}
 */
async function admitSyncUserCore({ db, uid, now }) {
  if (typeof uid !== 'string' || uid.length === 0) {
    throw new HttpsError('unauthenticated', 'A signed-in user is required.');
  }

  const flagsRef = db.doc('config/flags');
  const countersRef = db.doc('config/counters');
  const userRef = db.doc(`users/${uid}`);
  const usageRef = db.doc(`users/${uid}/usage/storage`);
  const entitlementRef = db.doc(`patreonEntitlements/${uid}`);
  const deletedRef = db.doc(`deletedAccounts/${uid}`);

  return db.runTransaction(async (tx) => {
    // ---- reads (all reads must precede all writes in a Firestore transaction)
    const flagsSnap = await tx.get(flagsRef);
    const countersSnap = await tx.get(countersRef);
    const userSnap = await tx.get(userRef);
    const entitlementSnap = await tx.get(entitlementRef);
    const deletedSnap = await tx.get(deletedRef);

    // Authentication is free and the local app never reaches this function.
    // Read Patreon truth inside the same transaction that creates the seat;
    // otherwise a cancellation can race a stale pre-transaction snapshot.
    const entitlement = entitlementSnap.exists ? entitlementSnap.data() || {} : {};
    const purgeInProgress = Boolean(entitlement.purgeLeaseId);
    const migrationBypass = flagsSnap.exists &&
      flagsSnap.get('patreonEnforcementEnabled') === false;
    const graceExpiresMs = entitlement.graceExpiresAt &&
      (typeof entitlement.graceExpiresAt.toMillis === 'function'
        ? entitlement.graceExpiresAt.toMillis()
        : Number(entitlement.graceExpiresAt));
    const entitlementEffective = Boolean(
      entitlement.effective === true &&
      ((entitlement.state === 'active' && entitlement.verificationExpiresAt &&
        entitlement.verificationExpiresAt.toMillis() > now.toMillis()) ||
        (entitlement.state === 'grace' && graceExpiresMs > now.toMillis()))
    );
    if (deletedSnap.exists || purgeInProgress || (!migrationBypass && !entitlementEffective)) {
      return { admitted: false, reason: 'patreon_required' };
    }

    if (userSnap.exists && userSnap.get('syncAdmitted') === true) {
      return {
        admitted: true,
        alreadyAdmitted: true,
        quotaBytes: num(userSnap.get('quotaBytes')) || DEFAULT_QUOTA_BYTES,
      };
    }

    // Compatibility is deliberately limited to already-admitted legacy users.
    // Turning enforcement off must never let a new, unentitled signup acquire
    // a cloud seat; new admission remains Patreon-gated throughout rollout.
    if (migrationBypass && !entitlementEffective) {
      return { admitted: false, reason: 'patreon_required' };
    }

    // Fail-closed: an absent config/flags doc means "not open yet", never
    // "open to everyone". The P0 runbook seeds it explicitly.
    const signupsOpen = flagsSnap.exists && flagsSnap.get('signupsOpen') === true;
    if (!signupsOpen) {
      return { admitted: false, reason: 'waitlist' };
    }

    const rawMax = flagsSnap.get('maxUsers');
    const maxUsers = Number.isInteger(rawMax) ? rawMax : DEFAULT_MAX_USERS;
    // Losing the authoritative counter must fail closed. Treating a missing
    // document as zero could admit up to maxUsers more accounts after an
    // operational deletion.
    if (!countersSnap.exists) {
      return { admitted: false, reason: 'waitlist' };
    }
    const admittedUsers = countersSnap.exists ? num(countersSnap.get('admittedUsers')) : 0;

    // The counter is only incremented when a brand-new user doc is created, so a
    // partially-provisioned doc cannot double-count a seat.
    const acquiresSeat = !userSnap.exists || userSnap.get('syncAdmitted') !== true;
    if (acquiresSeat && admittedUsers >= maxUsers) {
      return { admitted: false, reason: 'waitlist' };
    }

    // ---- writes
    tx.set(
      userRef,
      {
        schemaVersion: SCHEMA_VERSION,
        quotaBytes: DEFAULT_QUOTA_BYTES,
        syncAdmitted: true,
        entitlement,
        createdAt: userSnap.exists ? userSnap.get('createdAt') || now : now,
      },
      { merge: true }
    );

    tx.set(
      usageRef,
      {
        schemaVersion: SCHEMA_VERSION,
        bytesUsed: 0,
        reservedBytes: 0,
        objectCount: 0,
        updatedAt: now,
      },
      { merge: true }
    );

    if (acquiresSeat) {
      tx.set(countersRef, { admittedUsers: admittedUsers + 1 }, { merge: true });
    }

    return { admitted: true, quotaBytes: DEFAULT_QUOTA_BYTES };
  });
}

module.exports = { admitSyncUserCore };
