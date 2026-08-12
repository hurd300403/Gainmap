'use strict';

/**
 * Narrow administrative utility for finite Cloud Sync operator grants.
 *
 * Examples:
 *   node scripts/manage-sync-operator.js grant \
 *     --project gainmap-production --email owner@example.com \
 *     --days 365 --reason campaign_creator
 *   node scripts/manage-sync-operator.js revoke \
 *     --project gainmap-production --uid FIREBASE_UID
 *
 * Raw email addresses are used only to resolve an existing verified Firebase
 * user. They are never written to Firestore or printed by this utility.
 */

const { initializeApp, applicationDefault, deleteApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');
const {
  ENTITLEMENTS_COLLECTION,
  OPERATOR_GRANTS_COLLECTION,
  operatorGrantExpiry,
  operatorEntitlement,
  expiredOperatorTransition,
} = require('../lib/patreon/entitlement');

const DAY_MS = 24 * 60 * 60 * 1000;

function usage(message) {
  if (message) process.stderr.write(`ERROR: ${message}\n`);
  process.stderr.write(
    'usage: node scripts/manage-sync-operator.js <grant|revoke|status> ' +
    '--project PROJECT (--uid UID | --email EMAIL) ' +
    '[--days 1..366 --reason REASON]\n'
  );
  process.exit(2);
}

function parseArgs(argv) {
  const command = argv[0];
  if (!['grant', 'revoke', 'status'].includes(command)) usage('Unknown command.');
  const values = {};
  for (let i = 1; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key || !key.startsWith('--') || value === undefined) usage('Malformed arguments.');
    values[key.slice(2)] = value;
  }
  if (!values.project || !/^[a-z0-9][a-z0-9-]{4,62}$/.test(values.project)) {
    usage('An explicit Firebase project ID is required.');
  }
  if (Boolean(values.uid) === Boolean(values.email)) {
    usage('Specify exactly one of --uid or --email.');
  }
  if (command === 'grant') {
    const days = Number(values.days);
    if (!Number.isInteger(days) || days < 1 || days > 366) usage('--days must be 1 through 366.');
    if (!values.reason || !/^[a-z0-9_-]{3,64}$/.test(values.reason)) {
      usage('--reason must be 3–64 lowercase letters, digits, underscores, or hyphens.');
    }
  }
  return { command, values };
}

async function resolveUser(auth, values) {
  const user = values.uid
    ? await auth.getUser(values.uid)
    : await auth.getUserByEmail(String(values.email).trim().toLowerCase());
  if (!user.disabled && user.emailVerified) return user;
  throw new Error('The target Firebase user must be enabled with a verified email.');
}

async function grant({ db, user, days, reason, nowMs }) {
  const grantRef = db.doc(`${OPERATOR_GRANTS_COLLECTION}/${user.uid}`);
  const entitlementRef = db.doc(`${ENTITLEMENTS_COLLECTION}/${user.uid}`);
  const userRef = db.doc(`users/${user.uid}`);
  const expiresMs = nowMs + days * DAY_MS;
  await db.runTransaction(async (tx) => {
    const [deleted, grantSnap, entitlementSnap, userSnap] = await Promise.all([
      tx.get(db.doc(`deletedAccounts/${user.uid}`)),
      tx.get(grantRef),
      tx.get(entitlementRef),
      tx.get(userRef),
    ]);
    if (deleted.exists) throw new Error('The target Gainmap account is deleted.');
    if (entitlementSnap.exists && entitlementSnap.get('purgeLeaseId')) {
      throw new Error('Cloud library retention purge is in progress.');
    }
    const now = Timestamp.fromMillis(nowMs);
    const entitlement = operatorEntitlement(nowMs, expiresMs);
    tx.set(grantRef, {
      enabled: true,
      reason,
      expiresAt: Timestamp.fromMillis(expiresMs),
      createdAt: grantSnap.exists ? grantSnap.get('createdAt') || now : now,
      updatedAt: now,
      revokedAt: null,
    });
    tx.set(entitlementRef, entitlement, { merge: true });
    if (userSnap.exists) tx.set(userRef, { entitlement }, { merge: true });
  });
  return expiresMs;
}

async function revoke({ db, user, nowMs }) {
  const grantRef = db.doc(`${OPERATOR_GRANTS_COLLECTION}/${user.uid}`);
  const entitlementRef = db.doc(`${ENTITLEMENTS_COLLECTION}/${user.uid}`);
  const userRef = db.doc(`users/${user.uid}`);
  await db.runTransaction(async (tx) => {
    const [grantSnap, entitlementSnap, userSnap, deletedSnap] = await Promise.all([
      tx.get(grantRef),
      tx.get(entitlementRef),
      tx.get(userRef),
      tx.get(db.doc(`deletedAccounts/${user.uid}`)),
    ]);
    if (deletedSnap.exists) {
      if (grantSnap.exists) tx.delete(grantRef);
      return;
    }
    const now = Timestamp.fromMillis(nowMs);
    tx.set(grantRef, {
      enabled: false,
      updatedAt: now,
      revokedAt: now,
      ...(grantSnap.exists ? {} : { createdAt: now, reason: 'operator_revoked' }),
    }, { merge: true });
    const current = entitlementSnap.exists ? entitlementSnap.data() || {} : {};
    if (current.source === 'operator') {
      const entitlement = expiredOperatorTransition(current, nowMs);
      tx.set(entitlementRef, entitlement, { merge: true });
      if (userSnap.exists) tx.set(userRef, { entitlement }, { merge: true });
    }
  });
}

async function main() {
  const { command, values } = parseArgs(process.argv.slice(2));
  const app = initializeApp({
    credential: applicationDefault(),
    projectId: values.project,
  }, `gainmap-operator-${process.pid}`);
  try {
    const auth = getAuth(app);
    const db = getFirestore(app);
    const user = await resolveUser(auth, values);
    const nowMs = Date.now();
    if (command === 'grant') {
      const expiresMs = await grant({
        db,
        user,
        days: Number(values.days),
        reason: values.reason,
        nowMs,
      });
      process.stdout.write(JSON.stringify({
        ok: true,
        command,
        uid: user.uid,
        expiresAt: new Date(expiresMs).toISOString(),
      }) + '\n');
      return;
    }
    if (command === 'revoke') {
      await revoke({ db, user, nowMs });
      process.stdout.write(JSON.stringify({ ok: true, command, uid: user.uid }) + '\n');
      return;
    }
    const [grantSnap, entitlementSnap] = await Promise.all([
      db.doc(`${OPERATOR_GRANTS_COLLECTION}/${user.uid}`).get(),
      db.doc(`${ENTITLEMENTS_COLLECTION}/${user.uid}`).get(),
    ]);
    const grantData = grantSnap.exists ? grantSnap.data() || {} : {};
    const entitlement = entitlementSnap.exists ? entitlementSnap.data() || {} : {};
    const expiresMs = grantData.expiresAt && grantData.expiresAt.toMillis
      ? grantData.expiresAt.toMillis()
      : 0;
    const verificationExpiresMs = entitlement.verificationExpiresAt &&
      entitlement.verificationExpiresAt.toMillis
      ? entitlement.verificationExpiresAt.toMillis()
      : 0;
    process.stdout.write(JSON.stringify({
      ok: true,
      command,
      uid: user.uid,
      grantExists: grantSnap.exists,
      enabled: operatorGrantExpiry(grantData, Date.now()) > 0,
      expiresAt: expiresMs > 0 ? new Date(expiresMs).toISOString() : null,
      entitlementSource: entitlement.source || 'none',
      entitlementEffective: entitlement.effective === true && verificationExpiresMs > Date.now(),
    }) + '\n');
  } finally {
    await deleteApp(app);
  }
}

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`ERROR: ${error && error.message ? error.message : 'operator action failed'}\n`);
    process.exitCode = 1;
  });
}

module.exports = { parseArgs, resolveUser, grant, revoke };
