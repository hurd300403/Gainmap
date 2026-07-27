'use strict';

/**
 * Gainmap sync backend — Cloud Functions (2nd gen).
 * Spec: docs/superpowers/specs/2026-07-27-gainmap-ios-sync-design.md
 *
 * Deployed surface (5 logical functions, 6 handlers — usageReconciler ships as a
 * finalize handler and a delete handler sharing one transaction core):
 *
 *   admitSyncUser              onCall
 *   reserveUpload              onCall
 *   usageReconcilerFinalize    onObjectFinalized
 *   usageReconcilerDelete      onObjectDeleted
 *   maintenance                onSchedule (every 24 hours)
 *   deleteAccount              onCall
 *
 * Region us-central1 is irreversible for this project (Firestore location).
 */

const { initializeApp } = require('firebase-admin/app');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');
const { getStorage } = require('firebase-admin/storage');
const { getAuth } = require('firebase-admin/auth');
const { setGlobalOptions } = require('firebase-functions/v2');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { onObjectFinalized, onObjectDeleted } = require('firebase-functions/v2/storage');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const logger = require('firebase-functions/logger');

const { admitSyncUserCore } = require('./lib/admit');
const { reserveUploadCore } = require('./lib/reserve');
const { handleFinalize, handleDelete } = require('./lib/reconcile');
const { runMaintenance } = require('./lib/maintenance');
const { deleteAccountCore, assertRecentAuth } = require('./lib/deleteAccount');
const { num } = require('./lib/constants');

initializeApp();
setGlobalOptions({ region: 'us-central1', maxInstances: 20 });

const db = getFirestore();
const projectId = () => process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || '';

// ---------------------------------------------------------------------------
// admitSyncUser
// ---------------------------------------------------------------------------
exports.admitSyncUser = onCall(async (request) => {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError('unauthenticated', 'Sign in before requesting sync access.');
  }
  const result = await admitSyncUserCore({
    db,
    uid: request.auth.uid,
    now: Timestamp.now(),
  });
  logger.info('admitSyncUser', { uid: request.auth.uid, result });
  return result;
});

// ---------------------------------------------------------------------------
// reserveUpload
// ---------------------------------------------------------------------------
exports.reserveUpload = onCall(async (request) => {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError('unauthenticated', 'Sign in before uploading.');
  }
  return reserveUploadCore({
    db,
    uid: request.auth.uid,
    data: request.data || {},
    now: Timestamp.now(),
    projectId: projectId(),
  });
});

// ---------------------------------------------------------------------------
// usageReconciler — two handlers, one core
// ---------------------------------------------------------------------------
exports.usageReconcilerFinalize = onObjectFinalized(async (event) => {
  const obj = event.data;
  const result = await handleFinalize({
    db,
    bucket: getStorage().bucket(obj.bucket),
    name: obj.name,
    generation: String(obj.generation), // 64-bit: string in, BigInt compare
    byteSize: num(obj.size),
    now: Timestamp.now(),
  });
  logger.debug('usageReconciler:finalize', { name: obj.name, generation: String(obj.generation), result });
});

exports.usageReconcilerDelete = onObjectDeleted(async (event) => {
  const obj = event.data;
  const result = await handleDelete({
    db,
    name: obj.name,
    generation: String(obj.generation),
    now: Timestamp.now(),
  });
  logger.debug('usageReconciler:delete', { name: obj.name, generation: String(obj.generation), result });
});

// ---------------------------------------------------------------------------
// maintenance
// ---------------------------------------------------------------------------
exports.maintenance = onSchedule('every 24 hours', async () => {
  const report = await runMaintenance({
    db,
    bucket: getStorage().bucket(),
    now: Timestamp.now(),
  });
  logger.info('maintenance', report);
});

// ---------------------------------------------------------------------------
// deleteAccount
// ---------------------------------------------------------------------------
exports.deleteAccount = onCall(async (request) => {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError('unauthenticated', 'Sign in before deleting your account.');
  }
  // uid comes EXCLUSIVELY from the verified token — never from request.data.
  const uid = request.auth.uid;
  assertRecentAuth(request.auth.token, Date.now());

  const result = await deleteAccountCore({
    db,
    bucket: getStorage().bucket(),
    auth: getAuth(),
    uid,
    now: Timestamp.now(),
  });
  logger.info('deleteAccount', { uid, result });
  return result;
});
