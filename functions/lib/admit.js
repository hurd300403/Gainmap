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

  return db.runTransaction(async (tx) => {
    // ---- reads (all reads must precede all writes in a Firestore transaction)
    const flagsSnap = await tx.get(flagsRef);
    const countersSnap = await tx.get(countersRef);
    const userSnap = await tx.get(userRef);

    if (userSnap.exists && userSnap.get('syncAdmitted') === true) {
      return {
        admitted: true,
        alreadyAdmitted: true,
        quotaBytes: num(userSnap.get('quotaBytes')) || DEFAULT_QUOTA_BYTES,
      };
    }

    // Fail-closed: an absent config/flags doc means "not open yet", never
    // "open to everyone". The P0 runbook seeds it explicitly.
    const signupsOpen = flagsSnap.exists && flagsSnap.get('signupsOpen') === true;
    if (!signupsOpen) {
      return { admitted: false, reason: 'waitlist' };
    }

    const rawMax = flagsSnap.get('maxUsers');
    const maxUsers = Number.isInteger(rawMax) ? rawMax : DEFAULT_MAX_USERS;
    const admittedUsers = countersSnap.exists ? num(countersSnap.get('admittedUsers')) : 0;

    // The counter is only incremented when a brand-new user doc is created, so a
    // partially-provisioned doc cannot double-count a seat.
    const isNewSeat = !userSnap.exists;
    if (isNewSeat && admittedUsers >= maxUsers) {
      return { admitted: false, reason: 'waitlist' };
    }

    // ---- writes
    tx.set(
      userRef,
      {
        schemaVersion: SCHEMA_VERSION,
        quotaBytes: DEFAULT_QUOTA_BYTES,
        syncAdmitted: true,
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

    if (isNewSeat) {
      tx.set(countersRef, { admittedUsers: admittedUsers + 1 }, { merge: true });
    }

    return { admitted: true, quotaBytes: DEFAULT_QUOTA_BYTES };
  });
}

module.exports = { admitSyncUserCore };
