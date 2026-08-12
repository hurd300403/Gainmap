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
const { onCall, onRequest, HttpsError } = require('firebase-functions/v2/https');
const { onObjectFinalized, onObjectDeleted } = require('firebase-functions/v2/storage');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { defineSecret } = require('firebase-functions/params');
const logger = require('firebase-functions/logger');

const { admitSyncUserCore } = require('./lib/admit');
const { reserveUploadCore } = require('./lib/reserve');
const { handleFinalize, handleDelete } = require('./lib/reconcile');
const { runMaintenance } = require('./lib/maintenance');
const { deleteAccountCore, assertRecentAuth } = require('./lib/deleteAccount');
const { num } = require('./lib/constants');
const { PatreonTokenStore } = require('./lib/patreon/tokenStore');
const { PatreonAPI } = require('./lib/patreon/api');
const { PatreonRateLimiter } = require('./lib/patreon/rateLimiter');
const {
  resolveEntitlement,
} = require('./lib/patreon/entitlement');
const {
  OAuthFlowError,
  safeOAuthErrorCode,
  startOAuthCore,
  consumeOAuthState,
  exchangeAuthorizationCode,
  fetchIdentity,
  verifyOAuthMembership,
  linkPatreonIdentity,
} = require('./lib/patreon/oauth');
const {
  syncCampaignCore,
  markCampaignUnavailableCore,
  reconcileMemberCore,
} = require('./lib/patreon/sync');
const { WebhookError, authenticatedWebhookPayload } = require('./lib/patreon/webhook');
const { deletePatreonAccountData } = require('./lib/patreon/account');

initializeApp();
setGlobalOptions({ region: 'us-central1', maxInstances: 20 });

const db = getFirestore();
const projectId = () => process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || '';
const PATREON_SERVICE_ACCOUNT = 'gainmap-patreon@gainmap-production.iam.gserviceaccount.com';

// Each value is a dedicated Gainmap secret. The creator token pair has already
// been bootstrapped and is now rotated atomically in the server-only
// patreonPrivate/creatorToken document; runtime functions intentionally cannot
// read the retired bootstrap seed.
const patreonClientId = defineSecret('PATREON_CLIENT_ID');
const patreonClientSecret = defineSecret('PATREON_CLIENT_SECRET');
const patreonWebhookSecret = defineSecret('PATREON_WEBHOOK_SECRET');
const patreonIndexHmacKey = defineSecret('PATREON_INDEX_HMAC_KEY');
const patreonCampaignId = defineSecret('PATREON_CAMPAIGN_ID');

const CREATOR_SECRET_SET = [
  patreonClientId,
  patreonClientSecret,
  patreonIndexHmacKey,
  patreonCampaignId,
];

function patreonRedirectURI() {
  return `https://us-central1-${projectId()}.cloudfunctions.net/patreonOAuthCallback`;
}

function patreonAPI() {
  const tokenStore = new PatreonTokenStore({
    db,
    getClientCredentials: () => ({
      clientId: patreonClientId.value(),
      clientSecret: patreonClientSecret.value(),
    }),
    // A missing token document is an operator-visible, fail-closed condition.
    // Never silently reseed a stale or already-consumed rotating token pair.
    getBootstrapCredentials: () => null,
  });
  return new PatreonAPI({
    tokenStore,
    campaignId: patreonCampaignId.value(),
    beforeRequest: () => new PatreonRateLimiter({ db }).acquire(),
  });
}

// ---------------------------------------------------------------------------
// admitSyncUser
// ---------------------------------------------------------------------------
exports.admitSyncUser = onCall({
  secrets: CREATOR_SECRET_SET,
  serviceAccount: PATREON_SERVICE_ACCOUNT,
}, async (request) => {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError('unauthenticated', 'Sign in before requesting sync access.');
  }
  const now = Timestamp.now();
  const publicEntitlement = await resolveEntitlement({
    db,
    uid: request.auth.uid,
    authToken: request.auth.token || {},
    api: patreonAPI(),
    hmacKey: patreonIndexHmacKey.value(),
    nowMs: now.toMillis(),
  });
  const result = await admitSyncUserCore({
    db,
    uid: request.auth.uid,
    now,
  });
  const response = { ...result, ...publicEntitlement };
  if (result.admitted === false && result.reason === 'waitlist') {
    response.message = 'Cloud Sync is currently full. Gainmap remains fully available offline.';
  } else if (result.admitted === false && result.reason === 'patreon_required') {
    response.message = publicEntitlement.message;
  }
  logger.info('admitSyncUser', {
    uid: request.auth.uid,
    admitted: response.admitted,
    entitlementState: response.state,
  });
  return response;
});

// ---------------------------------------------------------------------------
// Patreon OAuth + entitlement
// ---------------------------------------------------------------------------
exports.startPatreonOAuth = onCall({
  secrets: [patreonClientId],
  serviceAccount: PATREON_SERVICE_ACCOUNT,
}, async (request) => {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError('unauthenticated', 'Sign in before connecting Patreon.');
  }
  try {
    return await startOAuthCore({
      db,
      uid: request.auth.uid,
      clientId: patreonClientId.value(),
      redirectURI: patreonRedirectURI(),
      attemptKind: request.data && request.data.attemptKind || 'reuse_session',
    });
  } catch (error) {
    logger.error('startPatreonOAuth failed', { code: safeOAuthErrorCode(error && error.code) });
    throw new HttpsError('failed-precondition', 'Patreon sign-in is temporarily unavailable.');
  }
});

exports.patreonOAuthCallback = onRequest(
  {
    secrets: [patreonClientId, patreonClientSecret, patreonIndexHmacKey, patreonCampaignId],
    serviceAccount: PATREON_SERVICE_ACCOUNT,
  },
  async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const finish = (status, code) => {
      const url = new URL('gainmapauth://patreon');
      url.searchParams.set('status', status);
      if (code) url.searchParams.set('code', safeOAuthErrorCode(code));
      res.redirect(303, url.toString());
    };
    if (req.method !== 'GET') {
      res.status(405).set('Allow', 'GET').send('Method not allowed');
      return;
    }

    try {
      const state = typeof req.query.state === 'string' ? req.query.state : '';
      const uid = await consumeOAuthState({ db, state });
      if (req.query.error) throw new OAuthFlowError('authorization_denied');
      const code = typeof req.query.code === 'string' ? req.query.code : '';
      if (!code) throw new OAuthFlowError('missing_parameters');

      const accessToken = await exchangeAuthorizationCode({
        code,
        clientId: patreonClientId.value(),
        clientSecret: patreonClientSecret.value(),
        redirectURI: patreonRedirectURI(),
      });
      const identity = await fetchIdentity({ accessToken });
      const member = await verifyOAuthMembership({
        identity,
        campaignId: patreonCampaignId.value(),
        api: patreonAPI(),
      });
      await linkPatreonIdentity({
        db,
        uid,
        identity,
        member,
        hmacKey: patreonIndexHmacKey.value(),
      });
      logger.info('Patreon OAuth linked', { uid, hasCampaignMembership: Boolean(member) });
      finish('success');
    } catch (error) {
      const code = safeOAuthErrorCode(error && error.code);
      logger.warn('Patreon OAuth callback rejected', { code });
      finish('error', code);
    }
  }
);

exports.refreshPatreonEntitlement = onCall(
  { secrets: CREATOR_SECRET_SET, serviceAccount: PATREON_SERVICE_ACCOUNT },
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError('unauthenticated', 'Sign in before refreshing Patreon access.');
    }
    const result = await resolveEntitlement({
      db,
      uid: request.auth.uid,
      authToken: request.auth.token || {},
      api: patreonAPI(),
      hmacKey: patreonIndexHmacKey.value(),
    });
    logger.info('refreshPatreonEntitlement', {
      uid: request.auth.uid,
      entitlementState: result.state,
      effective: result.effective,
    });
    return result;
  }
);

exports.patreonCampaignSync = onSchedule(
  {
    schedule: '15 3 * * *',
    timeZone: 'America/New_York',
    timeoutSeconds: 540,
    memory: '512MiB',
    secrets: CREATOR_SECRET_SET,
    serviceAccount: PATREON_SERVICE_ACCOUNT,
  },
  async () => {
    try {
      const result = await syncCampaignCore({
        db,
        api: patreonAPI(),
        hmacKey: patreonIndexHmacKey.value(),
      });
      logger.info('patreonCampaignSync complete', result);
    } catch (error) {
      // Scheduler delivery can overlap a still-running invocation. The lease
      // holder is already verifying the campaign; overlap is not an outage and
      // must never move every linked user into grace.
      if (error && error.code === 'sync_in_progress') {
        logger.info('patreonCampaignSync skipped: another invocation is active');
        return;
      }
      const report = await markCampaignUnavailableCore({ db });
      logger.error('patreonCampaignSync unavailable', {
        code: error && error.code || 'upstream_error',
        ...report,
      });
      throw error;
    }
  }
);

exports.patreonWebhook = onRequest(
  {
    secrets: [...CREATOR_SECRET_SET, patreonWebhookSecret],
    timeoutSeconds: 60,
    invoker: 'public',
    serviceAccount: PATREON_SERVICE_ACCOUNT,
  },
  async (req, res) => {
    if (req.method !== 'POST') {
      res.status(405).set('Allow', 'POST').json({ error: 'method_not_allowed' });
      return;
    }
    try {
      const payload = authenticatedWebhookPayload({
        rawBody: req.rawBody,
        signature: req.get('X-Patreon-Signature') || '',
        secret: patreonWebhookSecret.value(),
      });
      const result = await reconcileMemberCore({
        db,
        api: patreonAPI(),
        hmacKey: patreonIndexHmacKey.value(),
        memberId: payload.memberId,
      });
      logger.info('patreonWebhook reconciled', {
        eventType: String(req.get('X-Patreon-Event') || 'unknown').slice(0, 80),
        linked: result.linked,
        active: result.active,
      });
      res.status(200).json({ status: 'ok' });
    } catch (error) {
      if (error instanceof WebhookError) {
        if (error.status === 200) res.status(200).json({ status: 'ignored' });
        else res.status(error.status).json({ error: error.code });
        return;
      }
      logger.error('patreonWebhook reconciliation failed', {
        code: error && error.code || 'internal',
      });
      // A 5xx asks Patreon to retry; no entitlement is downgraded on failure.
      res.status(503).json({ error: 'reconciliation_unavailable' });
    }
  }
);

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
exports.maintenance = onSchedule({
  schedule: '15 4 * * *',
  timeZone: 'America/New_York',
  timeoutSeconds: 540,
  memory: '512MiB',
}, async () => {
  const report = await runMaintenance({
    db,
    bucket: getStorage().bucket(),
    now: Timestamp.now(),
  });
  logger.info('maintenance', report);
});

// ---------------------------------------------------------------------------
// appleReturn — Sign-in-with-Apple return endpoint for the DESKTOP app
// ---------------------------------------------------------------------------
// Developer ID Mac builds cannot use native SIWA (S3 finding), so the Mac app
// runs a browser flow. Requesting the email scope forces Apple to form_post
// the response, which a static page cannot read — this endpoint receives the
// POST (behind the Hosting rewrite at /auth/apple-return) and bounces the
// fields to the app's custom scheme, where ASWebAuthenticationSession picks
// them up. Deliberately: no auth, no state, no logging of token material.
exports.appleReturn = onRequest((req, res) => {
  const p = req.method === 'POST' ? req.body || {} : req.query || {};
  const frag = ['code', 'id_token', 'state', 'user', 'error']
    .filter((k) => typeof p[k] === 'string' && p[k].length > 0 && p[k].length < 8192)
    .map((k) => `${k}=${encodeURIComponent(p[k])}`)
    .join('&');
  res.set('Cache-Control', 'no-store');
  res.redirect(303, `gainmapauth://callback#${frag || 'error=empty_response'}`);
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
  // deleteAccountCore writes deletedAccounts/{uid} before purging. Every
  // Patreon writer checks that marker; cleanup after the purge therefore wins
  // against any reconciliation that began before deletion.
  await deletePatreonAccountData({ db, uid });
  try {
    await getAuth().deleteUser(uid);
  } catch (error) {
    if (!error || error.code !== 'auth/user-not-found') throw error;
  }
  logger.info('deleteAccount', { uid, result });
  return result;
});
