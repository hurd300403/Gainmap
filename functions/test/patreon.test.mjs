import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || 'demo-gainmap';
process.env.FIREBASE_CONFIG =
  process.env.FIREBASE_CONFIG || JSON.stringify({ projectId: process.env.GCLOUD_PROJECT });

const { Timestamp } = await import('firebase-admin/firestore');
const apiMod = await import('../lib/patreon/api.js');
const cryptoMod = await import('../lib/patreon/crypto.js');
const entitlementMod = await import('../lib/patreon/entitlement.js');
const httpMod = await import('../lib/patreon/http.js');
const oauthMod = await import('../lib/patreon/oauth.js');
const syncMod = await import('../lib/patreon/sync.js');
const tokenMod = await import('../lib/patreon/tokenStore.js');
const webhookMod = await import('../lib/patreon/webhook.js');
const limiterMod = await import('../lib/patreon/rateLimiter.js');
const accountMod = await import('../lib/patreon/account.js');

const { PatreonAPI, PatreonAPIError, parseMember } = apiMod.default || apiMod;
const { PATREON_USER_AGENT } = httpMod.default || httpMod;
const {
  emailIndex,
  subjectIndex,
  memberIndex,
  snapshotIndexId,
  verifyWebhookSignature,
} = cryptoMod.default || cryptoMod;
const {
  safeEntitlement,
  activeEntitlement,
  operatorEntitlement,
  inactiveTransition,
  errorTransition,
  verifiedEmailEntitlement,
  emailLossTransition,
  preferEntitlement,
  resolveEntitlement,
} = entitlementMod.default || entitlementMod;
const {
  OAuthFlowError,
  startOAuthCore,
  consumeOAuthState,
  exchangeAuthorizationCode,
  fetchIdentity,
  identityMembership,
  verifyOAuthMembership,
  linkPatreonIdentity,
} = oauthMod.default || oauthMod;
const {
  syncCampaignCore,
  markCampaignUnavailableCore,
  reconcileMemberCore,
} = syncMod.default || syncMod;
const { PatreonTokenStore, PatreonTokenError } = tokenMod.default || tokenMod;
const { authenticatedWebhookPayload, WebhookError } = webhookMod.default || webhookMod;
const { PatreonRateLimiter } = limiterMod.default || limiterMod;
const { deletePatreonAccountData } = accountMod.default || accountMod;

const NOW = 1_800_000_000_000;
const DAY = 24 * 60 * 60 * 1000;
const HMAC_KEY = 'test-only-hmac-key-that-is-at-least-32-bytes-long';
const ts = (ms) => Timestamp.fromMillis(ms);

function clone(value) {
  if (value && typeof value.toMillis === 'function') return Timestamp.fromMillis(value.toMillis());
  if (Array.isArray(value)) return value.map(clone);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, clone(item)]));
  }
  return value;
}

class FakeSnapshot {
  constructor(ref, data) { this.ref = ref; this._data = data; this.id = ref.id; }
  get exists() { return this._data !== undefined; }
  data() { return clone(this._data); }
  get(field) { return this._data && this._data[field]; }
}

function mergeData(oldData, patch) {
  const out = clone(oldData || {});
  for (const [key, value] of Object.entries(patch || {})) {
    if (value && typeof value === 'object' && !Array.isArray(value) &&
        typeof value.toMillis !== 'function' && !(value instanceof Date)) {
      out[key] = mergeData(out[key], value);
    } else out[key] = value;
  }
  return out;
}

class FakeRef {
  constructor(db, path) { this.db = db; this.path = path; this.id = path.split('/').at(-1); }
  async get() { return new FakeSnapshot(this, this.db.docs.get(this.path)); }
  async create(data) {
    if (this.db.docs.has(this.path)) throw new Error('already exists');
    this.db.docs.set(this.path, clone(data));
  }
  async set(data, options = {}) {
    this.db.docs.set(
      this.path,
      options.merge ? mergeData(this.db.docs.get(this.path), data) : clone(data)
    );
  }
  async delete() { this.db.docs.delete(this.path); }
}

class FakeCollection {
  constructor(db, path) { this.db = db; this.path = path; }
  async get() {
    const prefix = `${this.path}/`;
    const docs = [...this.db.docs]
      .filter(([path]) => path.startsWith(prefix) && !path.slice(prefix.length).includes('/'))
      .map(([path, data]) => new FakeSnapshot(new FakeRef(this.db, path), data));
    return { docs, size: docs.length };
  }
}

class FakeDB {
  constructor(seed = {}) { this.docs = new Map(Object.entries(seed).map(([k, v]) => [k, clone(v)])); }
  doc(path) { return new FakeRef(this, path); }
  collection(path) { return new FakeCollection(this, path); }
  batch() {
    const ops = [];
    return {
      set: (ref, data, options) => ops.push(() => ref.set(data, options)),
      commit: async () => { for (const op of ops) await op(); },
    };
  }
  async runTransaction(fn) {
    const ops = [];
    const tx = {
      get: (ref) => ref.get(),
      set: (ref, data, options) => ops.push(() => ref.set(data, options)),
      create: (ref, data) => ops.push(() => ref.create(data)),
      update: (ref, data) => ops.push(() => ref.set(data, { merge: true })),
      delete: (ref) => ops.push(() => ref.delete()),
    };
    const result = await fn(tx);
    for (const op of ops) await op();
    return result;
  }
}

function memberResource({
  id = 'm1',
  userId = 'u1',
  status = 'active_patron',
  amount = 500,
  tierIds = ['t1'],
  email = 'Patron@Example.com',
  campaignId = 'campaign',
} = {}) {
  return {
    type: 'member', id,
    attributes: {
      email,
      patron_status: status,
      currently_entitled_amount_cents: amount,
      last_charge_status: status === 'active_patron' ? 'Paid' : 'Declined',
    },
    relationships: {
      user: { data: { type: 'user', id: userId } },
      campaign: { data: { type: 'campaign', id: campaignId } },
      currently_entitled_tiers: { data: tierIds.map((tierId) => ({ type: 'tier', id: tierId })) },
    },
  };
}

function jsonResponse(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: () => null },
    async json() { return clone(body); },
  };
}

test('active classifier requires active_patron and an entitled tier, including gifts/trials', () => {
  assert.equal(parseMember(memberResource()).isActiveEligible, true);
  for (const resource of [
    memberResource({ status: 'declined_patron' }),
    memberResource({ status: 'former_patron' }),
    memberResource({ tierIds: [] }),
  ]) assert.equal(parseMember(resource).isActiveEligible, false);
  assert.equal(parseMember(memberResource({ amount: 0 })).isActiveEligible, true);
  assert.equal(parseMember(memberResource({ status: null, tierIds: [] })).isActiveEligible, false);
  const absentStatus = memberResource();
  delete absentStatus.attributes.patron_status;
  assert.throws(
    () => parseMember(absentStatus),
    (error) => error instanceof PatreonAPIError && error.code === 'invalid_member_schema'
  );
  const maskedUser = memberResource({ status: null, tierIds: [] });
  maskedUser.relationships.user.data = null;
  assert.equal(parseMember(maskedUser).subjectId, '');
  const malformedUser = memberResource();
  malformedUser.relationships.user.data = 'not-json-api';
  assert.throws(() => parseMember(malformedUser), PatreonAPIError);
});

test('OAuth membership accepts the real identity shape without a nested member user relationship', () => {
  const resource = memberResource();
  delete resource.relationships.user;
  delete resource.attributes.email;
  delete resource.attributes.last_charge_status;
  delete resource.attributes.currently_entitled_amount_cents;
  const identity = {
    data: {
      type: 'user',
      id: 'identity-subject',
      relationships: { memberships: { data: [{ type: 'member', id: resource.id }] } },
    },
    included: [resource],
  };
  const member = identityMembership(identity, 'campaign');
  assert.equal(member.subjectId, 'identity-subject');
  assert.equal(member.isActiveEligible, true);
});

test('OAuth membership requires an exact campaign and prefers its active duplicate record', () => {
  const ambiguous = memberResource({ id: 'ambiguous', userId: 'identity-subject' });
  delete ambiguous.relationships.campaign;
  const otherCampaign = memberResource({
    id: 'other', userId: 'identity-subject', campaignId: 'another-campaign',
  });
  const former = memberResource({
    id: 'former', userId: 'identity-subject', status: 'former_patron', tierIds: [],
  });
  const active = memberResource({ id: 'active', userId: 'identity-subject' });
  const identity = {
    data: {
      type: 'user',
      id: 'identity-subject',
      relationships: {
        memberships: {
          data: [ambiguous, otherCampaign, former, active]
            .map((resource) => ({ type: 'member', id: resource.id })),
        },
      },
    },
    included: [ambiguous, otherCampaign, former, active],
  };

  const member = identityMembership(identity, 'campaign');
  assert.equal(member.memberId, 'active');
  assert.equal(member.subjectId, 'identity-subject');

  identity.included = [ambiguous, otherCampaign];
  assert.equal(identityMembership(identity, 'campaign'), null);
});

test('OAuth membership is reverified with configured-campaign creator credentials', async () => {
  const resource = memberResource({ id: 'member', userId: 'identity-subject' });
  const identity = {
    data: {
      type: 'user', id: 'identity-subject',
      relationships: { memberships: { data: [{ type: 'member', id: resource.id }] } },
    },
    included: [resource],
  };
  const verified = parseMember(resource);
  const member = await verifyOAuthMembership({
    identity,
    campaignId: 'campaign',
    api: { campaignId: 'campaign', getMember: async () => verified },
  });
  assert.equal(member.memberId, 'member');

  await assert.rejects(
    verifyOAuthMembership({
      identity,
      campaignId: 'campaign',
      api: {
        campaignId: 'campaign',
        getMember: async () => parseMember(memberResource({
          id: 'member', userId: 'another-subject',
        })),
      },
    }),
    (error) => error instanceof OAuthFlowError && error.code === 'membership_not_found'
  );
  await assert.rejects(
    verifyOAuthMembership({
      identity,
      campaignId: 'campaign',
      api: { campaignId: 'another-campaign', getMember: async () => verified },
    }),
    (error) => error instanceof OAuthFlowError && error.code === 'campaign_not_configured'
  );
  await assert.rejects(
    verifyOAuthMembership({
      identity,
      campaignId: 'campaign',
      api: {
        campaignId: 'campaign',
        getMember: async () => parseMember(memberResource({
          id: 'member', userId: 'identity-subject', status: 'former_patron', tierIds: [],
        })),
      },
    }),
    (error) => error instanceof OAuthFlowError && error.code === 'membership_inactive'
  );
});

test('OAuth identity asks only for own-campaign entitlement fields and no email scope', async () => {
  let requested;
  const body = { data: { type: 'user', id: 'subject' }, included: [] };
  await fetchIdentity({
    accessToken: 'opaque',
    fetchImpl: async (url) => {
      requested = new URL(url);
      return jsonResponse(body);
    },
  });
  assert.equal(
    requested.searchParams.get('include'),
    'memberships,memberships.currently_entitled_tiers,memberships.campaign'
  );
  assert.equal(requested.searchParams.get('fields[member]'), 'patron_status');
  assert.equal(requested.searchParams.has('fields[user]'), false);
});

test('every Patreon HTTP path sends the established edge-accepted User-Agent', async () => {
  const observed = [];
  const capture = (body) => async (_url, options = {}) => {
    observed.push(options.headers && options.headers['User-Agent']);
    return jsonResponse(body);
  };

  const member = memberResource();
  const api = new PatreonAPI({
    tokenStore: { getAccessToken: async () => 'access' },
    campaignId: 'campaign',
    minRequestIntervalMs: 0,
    fetchImpl: capture({ data: member, included: [] }),
  });
  await api.getMember(member.id);

  const db = new FakeDB({
    'patreonPrivate/creatorToken': {
      accessToken: 'expired', refreshToken: 'refresh', expiresAt: ts(NOW - 1),
    },
  });
  const store = new PatreonTokenStore({
    db,
    clock: () => NOW,
    randomUUID: () => 'owner',
    getClientCredentials: () => ({ clientId: 'id', clientSecret: 'secret' }),
    fetchImpl: capture({ access_token: 'new', refresh_token: 'next', expires_in: 3600 }),
  });
  await store.getAccessToken();

  await exchangeAuthorizationCode({
    code: 'code', clientId: 'id', clientSecret: 'secret', redirectURI: 'https://example.test/callback',
    fetchImpl: capture({ access_token: 'linked' }),
  });
  await fetchIdentity({
    accessToken: 'linked',
    fetchImpl: capture({ data: { type: 'user', id: 'subject' }, included: [] }),
  });

  assert.deepEqual(observed, Array(4).fill(PATREON_USER_AGENT));
});

test('entitlement transitions active to grace to inactive without extending grace on outages', () => {
  const active = activeEntitlement(NOW);
  const grace = inactiveTransition(active, NOW + DAY);
  assert.equal(safeEntitlement(grace, NOW + DAY).state, 'grace');
  assert.equal(safeEntitlement(grace, NOW + 8 * DAY).state, 'inactive');
  const outage = errorTransition(active, NOW + DAY);
  assert.equal(safeEntitlement(outage, NOW + DAY).state, 'grace');
  const repeated = errorTransition(outage, NOW + 6 * DAY);
  assert.equal(repeated.graceExpiresAt.toMillis(), outage.graceExpiresAt.toMillis());
  const expired = errorTransition(repeated, NOW + 8 * DAY);
  assert.equal(safeEntitlement(expired, NOW + 8 * DAY).state, 'error');
  assert.equal(safeEntitlement(expired, NOW + 8 * DAY).effective, false);
});

test('verified email is full active access anchored to the campaign snapshot', () => {
  const first = verifiedEmailEntitlement(NOW, NOW - DAY, 'email-hash');
  const safe = safeEntitlement(first, NOW, false);
  assert.equal(safe.state, 'active');
  assert.equal(safe.effective, true);
  assert.equal(safe.source, 'patreon_email');
  assert.equal(safe.connectionAction, 'none');
  assert.equal(safe.linkRequired, false);
  assert.equal(first.verificationExpiresAt.toMillis(), NOW + 6 * DAY);
  assert.equal(first.provisionalExpiresAt, null);

  const loss = emailLossTransition(first, NOW, 'email-hash');
  const repeated = emailLossTransition(loss, NOW + 6 * DAY, 'email-hash');
  assert.equal(loss.state, 'unlinked');
  assert.equal(loss.effective, false);
  assert.equal(loss.graceExpiresAt, null);
  assert.equal(repeated.state, 'unlinked');
  assert.equal(emailLossTransition(first, NOW, 'different-email').state, 'unlinked');
});

test('active access has an absolute verification deadline if every updater stops', () => {
  const active = activeEntitlement(NOW);
  assert.equal(safeEntitlement(active, NOW + 6 * DAY).effective, true);
  assert.equal(safeEntitlement(active, NOW + 8 * DAY).effective, false);
  assert.equal(safeEntitlement(active, NOW, true).linkRequired, false);
  assert.equal(safeEntitlement({}, NOW, false).connectionAction, 'connect');
});

test('verified email bootstrap requires a fresh completed campaign snapshot', async () => {
  const hash = emailIndex(HMAC_KEY, 'patron@example.com');
  const freshDB = new FakeDB({
    'patreonPrivate/runtime': { currentSyncId: 's1', lastCompletedAt: ts(NOW - DAY) },
    [`patreonEmailIndex/${snapshotIndexId('s1', hash)}`]: {
      lastSyncId: 's1', isActiveEligible: true, memberId: 'm1', lastVerifiedAt: ts(NOW - DAY),
    },
  });
  const fresh = await resolveEntitlement({
    db: freshDB,
    uid: 'fresh-user',
    authToken: { email: 'patron@example.com', email_verified: true },
    api: null,
    hmacKey: HMAC_KEY,
    nowMs: NOW,
  });
  assert.equal(fresh.state, 'active');
  assert.equal(fresh.effective, true);
  assert.equal(fresh.source, 'patreon_email');
  assert.equal(fresh.linkRequired, false);
  assert.equal(fresh.connectionAction, 'none');
  assert.equal(
    freshDB.docs.get('patreonEntitlements/fresh-user').verificationExpiresAt.toMillis(),
    NOW + 6 * DAY
  );
  assert.equal(freshDB.docs.get('patreonEntitlements/fresh-user').provisionalExpiresAt, null);

  const legacyDB = new FakeDB({
    'patreonPrivate/runtime': { currentSyncId: 's1', lastCompletedAt: ts(NOW - DAY) },
    [`patreonEmailIndex/${snapshotIndexId('s1', hash)}`]: {
      lastSyncId: 's1', isActiveEligible: true, memberId: 'm1', lastVerifiedAt: ts(NOW - DAY),
    },
    'patreonLinks/legacy-user': { subjectHash: 'legacy-null-link', memberId: null, memberHash: null },
    'patreonEntitlements/legacy-user': {
      state: 'grace',
      effective: true,
      source: 'patreon_email',
      lastVerifiedAt: ts(NOW - DAY),
      graceExpiresAt: ts(NOW + DAY),
      provisionalExpiresAt: ts(NOW + DAY),
    },
  });
  const migrated = await resolveEntitlement({
    db: legacyDB,
    uid: 'legacy-user',
    authToken: { email: 'patron@example.com', email_verified: true },
    api: null,
    hmacKey: HMAC_KEY,
    nowMs: NOW,
  });
  assert.equal(migrated.state, 'active');
  assert.equal(migrated.source, 'patreon_email');
  assert.equal(migrated.connectionAction, 'none');
  assert.equal(legacyDB.docs.get('patreonEntitlements/legacy-user').provisionalExpiresAt, null);

  const staleDB = new FakeDB({
    'patreonPrivate/runtime': { currentSyncId: 's1', lastCompletedAt: ts(NOW - 30 * DAY) },
    [`patreonEmailIndex/${snapshotIndexId('s1', hash)}`]: {
      lastSyncId: 's1', isActiveEligible: true, memberId: 'm1', lastVerifiedAt: ts(NOW - 30 * DAY),
    },
  });
  const stale = await resolveEntitlement({
    db: staleDB,
    uid: 'new-firebase-user',
    authToken: { email: 'patron@example.com', email_verified: true },
    api: null,
    hmacKey: HMAC_KEY,
    nowMs: NOW,
  });
  assert.deepEqual({ state: stale.state, effective: stale.effective, linkRequired: stale.linkRequired }, {
    state: 'error', effective: false, linkRequired: false,
  });
});

test('private UID operator grant is finite, mirrored, and independent of Patreon', async () => {
  const db = new FakeDB({
    'syncOperatorGrants/creator-user': {
      enabled: true,
      reason: 'campaign_creator',
      expiresAt: ts(NOW + 30 * DAY),
    },
    'users/creator-user': { schemaVersion: 1, syncAdmitted: true },
  });
  const access = await resolveEntitlement({
    db,
    uid: 'creator-user',
    authToken: {},
    api: null,
    hmacKey: HMAC_KEY,
    nowMs: NOW,
  });
  assert.equal(access.state, 'active');
  assert.equal(access.effective, true);
  assert.equal(access.source, 'operator');
  assert.equal(access.connectionAction, 'none');
  const outer = db.docs.get('patreonEntitlements/creator-user');
  assert.equal(outer.source, 'operator');
  assert.equal(outer.verificationExpiresAt.toMillis(), NOW + 7 * DAY);
  assert.equal(db.docs.get('users/creator-user').entitlement.source, 'operator');

  const shortDB = new FakeDB({
    'syncOperatorGrants/short': {
      enabled: true,
      reason: 'support',
      expiresAt: ts(NOW + 2 * DAY),
    },
  });
  await resolveEntitlement({
    db: shortDB, uid: 'short', api: null, hmacKey: HMAC_KEY, nowMs: NOW,
  });
  assert.equal(
    shortDB.docs.get('patreonEntitlements/short').verificationExpiresAt.toMillis(),
    NOW + 2 * DAY
  );
});

test('disabled, expired, or malformed operator grants fail closed immediately', async () => {
  for (const [uid, grant] of Object.entries({
    disabled: { enabled: false, reason: 'creator', expiresAt: ts(NOW + DAY) },
    expired: { enabled: true, reason: 'creator', expiresAt: ts(NOW - 1) },
    malformed: { enabled: true, expiresAt: ts(NOW + DAY) },
  })) {
    const prior = operatorEntitlement(NOW - DAY, NOW + 6 * DAY);
    const db = new FakeDB({
      [`syncOperatorGrants/${uid}`]: grant,
      [`patreonEntitlements/${uid}`]: prior,
      [`users/${uid}`]: { entitlement: prior },
      'patreonPrivate/runtime': { currentSyncId: 'fresh', lastCompletedAt: ts(NOW) },
    });
    const access = await resolveEntitlement({
      db, uid, api: null, hmacKey: HMAC_KEY, nowMs: NOW,
    });
    assert.equal(access.state, 'unlinked');
    assert.equal(access.effective, false);
    assert.equal(db.docs.get(`patreonEntitlements/${uid}`).source, 'none');
    assert.equal(db.docs.get(`users/${uid}`).entitlement.effective, false);
  }
});

test('revoked operator grant falls through to a real Patreon proof', async () => {
  const email = 'patron@example.com';
  const hash = emailIndex(HMAC_KEY, email);
  const prior = operatorEntitlement(NOW - DAY, NOW + 6 * DAY);
  const db = new FakeDB({
    'syncOperatorGrants/also-patron': {
      enabled: false,
      reason: 'campaign_creator',
      expiresAt: ts(NOW + 30 * DAY),
    },
    'patreonPrivate/runtime': { currentSyncId: 'fresh', lastCompletedAt: ts(NOW) },
    [`patreonEmailIndex/${snapshotIndexId('fresh', hash)}`]: {
      lastSyncId: 'fresh', isActiveEligible: true, memberId: 'm1', lastVerifiedAt: ts(NOW),
    },
    'patreonEntitlements/also-patron': prior,
  });
  const access = await resolveEntitlement({
    db,
    uid: 'also-patron',
    authToken: { email, email_verified: true },
    api: null,
    hmacKey: HMAC_KEY,
    nowMs: NOW,
  });
  assert.equal(access.state, 'active');
  assert.equal(access.source, 'patreon_email');
});

test('effective operator proof wins over concurrent Patreon writers', async () => {
  const operator = operatorEntitlement(NOW, NOW + 30 * DAY);
  assert.equal(preferEntitlement(operator, activeEntitlement(NOW), NOW).source, 'operator');
  assert.equal(preferEntitlement(operator, errorTransition(operator, NOW), NOW).state, 'active');

  const identity = { data: { type: 'user', id: 'patreon-subject' } };
  const member = parseMember(memberResource());
  const oauthDB = new FakeDB({
    'patreonEntitlements/creator': operator,
    'users/creator': { entitlement: operator },
  });
  await linkPatreonIdentity({
    db: oauthDB,
    uid: 'creator',
    identity,
    member,
    hmacKey: HMAC_KEY,
    nowMs: NOW + DAY,
  });
  assert.equal(oauthDB.docs.get('patreonEntitlements/creator').source, 'operator');
  assert.equal(oauthDB.docs.get('users/creator').entitlement.source, 'operator');

  const outageDB = new FakeDB({
    'patreonEntitlements/creator': operator,
    'users/creator': { entitlement: operator },
    'patreonLinks/creator': { memberId: 'member' },
  });
  await markCampaignUnavailableCore({ db: outageDB, nowMs: NOW + DAY });
  assert.equal(outageDB.docs.get('patreonEntitlements/creator').state, 'active');
  assert.equal(outageDB.docs.get('users/creator').entitlement.source, 'operator');
});

test('verified-email proof is bound to the exact current verified claim', async () => {
  const oldEmail = 'patron@example.com';
  const newEmail = 'different@example.com';
  const oldHash = emailIndex(HMAC_KEY, oldEmail);
  const active = verifiedEmailEntitlement(NOW, NOW, oldHash);

  const changedDB = new FakeDB({
    'patreonPrivate/runtime': { currentSyncId: 's2', lastCompletedAt: ts(NOW + DAY) },
    'patreonEntitlements/changed': active,
  });
  const changed = await resolveEntitlement({
    db: changedDB,
    uid: 'changed',
    authToken: { email: newEmail, email_verified: true },
    api: null,
    hmacKey: HMAC_KEY,
    nowMs: NOW + DAY,
  });
  assert.equal(changed.state, 'unlinked');
  assert.equal(changed.effective, false);
  assert.equal(
    changedDB.docs.get('patreonEntitlements/changed').emailHash,
    emailIndex(HMAC_KEY, newEmail)
  );

  const unverifiedDB = new FakeDB({
    'patreonEntitlements/unverified': active,
  });
  const unverified = await resolveEntitlement({
    db: unverifiedDB,
    uid: 'unverified',
    authToken: { email: oldEmail, email_verified: false },
    api: null,
    hmacKey: HMAC_KEY,
    nowMs: NOW + DAY,
  });
  assert.equal(unverified.state, 'unlinked');
  assert.equal(unverified.effective, false);
  assert.equal(unverifiedDB.docs.get('patreonEntitlements/unverified').emailHash, null);

  const legacy = { ...active };
  delete legacy.emailHash;
  const legacyDB = new FakeDB({
    'patreonPrivate/runtime': { currentSyncId: 's2', lastCompletedAt: ts(NOW + DAY) },
    'patreonEntitlements/legacy-mismatch': legacy,
  });
  const legacyMismatch = await resolveEntitlement({
    db: legacyDB,
    uid: 'legacy-mismatch',
    authToken: { email: oldEmail, email_verified: true },
    api: null,
    hmacKey: HMAC_KEY,
    nowMs: NOW + DAY,
  });
  assert.equal(legacyMismatch.state, 'unlinked');
  assert.equal(legacyMismatch.effective, false);
});

test('email outages preserve only an exact bound proof through its absolute deadline', async () => {
  const email = 'patron@example.com';
  const hash = emailIndex(HMAC_KEY, email);
  const active = verifiedEmailEntitlement(NOW, NOW, hash);
  const staleRuntime = {
    'patreonPrivate/runtime': {
      currentSyncId: 'stale',
      lastCompletedAt: ts(NOW - 30 * DAY),
    },
  };

  const exactDB = new FakeDB({
    ...staleRuntime,
    'patreonEntitlements/exact': active,
  });
  const exact = await resolveEntitlement({
    db: exactDB,
    uid: 'exact',
    authToken: { email, email_verified: true },
    api: null,
    hmacKey: HMAC_KEY,
    nowMs: NOW + DAY,
  });
  assert.equal(exact.state, 'grace');
  assert.equal(exact.effective, true);
  assert.equal(exact.graceExpiresAt, NOW + 7 * DAY);

  const legacy = { ...active };
  delete legacy.emailHash;
  const legacyDB = new FakeDB({
    ...staleRuntime,
    'patreonEntitlements/legacy': legacy,
  });
  const unavailableLegacy = await resolveEntitlement({
    db: legacyDB,
    uid: 'legacy',
    authToken: { email, email_verified: true },
    api: null,
    hmacKey: HMAC_KEY,
    nowMs: NOW + DAY,
  });
  assert.equal(unavailableLegacy.state, 'error');
  assert.equal(unavailableLegacy.effective, false);

  const malformedDB = new FakeDB({
    'patreonPrivate/runtime': { currentSyncId: 's2', lastCompletedAt: ts(NOW + DAY) },
    [`patreonEmailIndex/${snapshotIndexId('s2', hash)}`]: {
      lastSyncId: 'wrong-snapshot',
      isActiveEligible: true,
      lastVerifiedAt: ts(NOW + DAY),
    },
    'patreonEntitlements/malformed': active,
  });
  const malformed = await resolveEntitlement({
    db: malformedDB,
    uid: 'malformed',
    authToken: { email, email_verified: true },
    api: null,
    hmacKey: HMAC_KEY,
    nowMs: NOW + DAY,
  });
  assert.equal(malformed.state, 'grace');
  assert.equal(malformed.effective, true);
  assert.equal(malformed.graceExpiresAt, NOW + 7 * DAY);
});

test('OAuth state is opaque, single-use, and permits one immediate account switch', async () => {
  const db = new FakeDB();
  const { authorizationURL } = await startOAuthCore({
    db, uid: 'firebase-uid', clientId: 'client', redirectURI: 'https://callback', nowMs: NOW,
  });
  const state = new URL(authorizationURL).searchParams.get('state');
  assert.ok(state.length >= 32);
  assert.equal(new URL(authorizationURL).searchParams.get('scope'), 'identity');
  assert.equal(await consumeOAuthState({ db, state, nowMs: NOW + 1000 }), 'firebase-uid');
  await assert.rejects(
    consumeOAuthState({ db, state, nowMs: NOW + 2000 }),
    (error) => error instanceof OAuthFlowError && error.code === 'invalid_state'
  );

  const expired = await startOAuthCore({
    db, uid: 'other', clientId: 'client', redirectURI: 'https://callback', nowMs: NOW,
  });
  await assert.rejects(
    consumeOAuthState({
      db,
      state: new URL(expired.authorizationURL).searchParams.get('state'),
      nowMs: NOW + 11 * 60 * 1000,
    }),
    (error) => error instanceof OAuthFlowError && error.code === 'expired_state'
  );

  const switched = await startOAuthCore({
    db,
    uid: 'firebase-uid',
    clientId: 'client',
    redirectURI: 'https://callback',
    attemptKind: 'switch_account',
    nowMs: NOW + 1000,
  });
  const switchedState = new URL(switched.authorizationURL).searchParams.get('state');
  assert.equal(await consumeOAuthState({ db, state: switchedState, nowMs: NOW + 2000 }), 'firebase-uid');
  await assert.rejects(
    startOAuthCore({
      db, uid: 'firebase-uid', clientId: 'client', redirectURI: 'https://callback', nowMs: NOW + 2000,
    }),
    (error) => error instanceof OAuthFlowError && error.code === 'rate_limited'
  );

  const replacementDB = new FakeDB();
  const initial = await startOAuthCore({
    db: replacementDB, uid: 'switcher', clientId: 'client', redirectURI: 'https://callback', nowMs: NOW,
  });
  const replacement = await startOAuthCore({
    db: replacementDB, uid: 'switcher', clientId: 'client', redirectURI: 'https://callback',
    attemptKind: 'switch_account', nowMs: NOW + 1,
  });
  await assert.rejects(
    consumeOAuthState({
      db: replacementDB,
      state: new URL(initial.authorizationURL).searchParams.get('state'),
      nowMs: NOW + 2,
    }),
    (error) => error instanceof OAuthFlowError && error.code === 'invalid_state'
  );
  assert.equal(
    await consumeOAuthState({
      db: replacementDB,
      state: new URL(replacement.authorizationURL).searchParams.get('state'),
      nowMs: NOW + 2,
    }),
    'switcher'
  );
});

test('wrong or inactive Patreon OAuth attempts do not mutate an existing proof', async () => {
  const identity = { data: { type: 'user', id: 'wrong-subject' } };
  const prior = verifiedEmailEntitlement(NOW, NOW, 'email-hash');
  const db = new FakeDB({
    'patreonEntitlements/firebase-uid': prior,
    'patreonLinks/firebase-uid': {
      subjectHash: 'existing-subject', memberHash: 'existing-member', memberId: 'existing-member',
    },
  });
  await assert.rejects(
    linkPatreonIdentity({ db, uid: 'firebase-uid', identity, member: null, hmacKey: HMAC_KEY, nowMs: NOW }),
    (error) => error instanceof OAuthFlowError && error.code === 'membership_not_found'
  );
  await assert.rejects(
    linkPatreonIdentity({
      db,
      uid: 'firebase-uid',
      identity,
      member: parseMember(memberResource({ status: 'former_patron', tierIds: [] })),
      hmacKey: HMAC_KEY,
      nowMs: NOW,
    }),
    (error) => error instanceof OAuthFlowError && error.code === 'membership_inactive'
  );
  assert.equal(db.docs.get('patreonEntitlements/firebase-uid').source, 'patreon_email');
  assert.equal(db.docs.get('patreonLinks/firebase-uid').memberId, 'existing-member');
});

test('a stale OAuth link cannot suppress or inherit a verified-email proof', async () => {
  const activeEmail = verifiedEmailEntitlement(NOW, NOW, emailIndex(HMAC_KEY, 'patron@example.com'));
  const staleLink = { subjectHash: 'subject', memberHash: 'member', memberId: 'member' };
  const hash = emailIndex(HMAC_KEY, 'patron@example.com');
  const activeDB = new FakeDB({
    'patreonPrivate/runtime': { currentSyncId: 's1', lastCompletedAt: ts(NOW) },
    [`patreonEmailIndex/${snapshotIndexId('s1', hash)}`]: {
      lastSyncId: 's1', isActiveEligible: true, memberId: 'member', lastVerifiedAt: ts(NOW),
    },
    'patreonLinks/firebase-uid': staleLink,
    'patreonEntitlements/firebase-uid': activeEmail,
  });
  const verified = await resolveEntitlement({
    db: activeDB,
    uid: 'firebase-uid',
    authToken: { email: 'patron@example.com', email_verified: true },
    api: { getMember: async () => null },
    hmacKey: HMAC_KEY,
    nowMs: NOW + 1,
  });
  assert.equal(verified.state, 'active');
  assert.equal(verified.source, 'patreon_email');

  const lapsedDB = new FakeDB({
    'patreonPrivate/runtime': { currentSyncId: 's2', lastCompletedAt: ts(NOW + DAY) },
    'patreonLinks/firebase-uid': staleLink,
    'patreonEntitlements/firebase-uid': activeEmail,
  });
  const lapsed = await resolveEntitlement({
    db: lapsedDB,
    uid: 'firebase-uid',
    authToken: { email: 'patron@example.com', email_verified: true },
    api: { getMember: async () => null },
    hmacKey: HMAC_KEY,
    nowMs: NOW + DAY,
  });
  assert.equal(lapsed.state, 'inactive');
  assert.equal(lapsed.source, 'patreon_oauth');
  assert.equal(lapsed.effective, false);
  assert.equal(lapsed.connectionAction, 'switch');
  assert.equal(lapsedDB.docs.get('patreonLinks/firebase-uid').memberId, 'member');

  const oauthStillActiveDB = new FakeDB({
    'patreonPrivate/runtime': { currentSyncId: 's2', lastCompletedAt: ts(NOW + DAY) },
    'patreonLinks/firebase-uid': staleLink,
    'patreonEntitlements/firebase-uid': activeEmail,
  });
  const oauthStillActive = await resolveEntitlement({
    db: oauthStillActiveDB,
    uid: 'firebase-uid',
    authToken: { email: 'patron@example.com', email_verified: true },
    api: {
      getMember: async () => parseMember(memberResource({ id: 'member' })),
    },
    hmacKey: HMAC_KEY,
    nowMs: NOW + DAY,
  });
  assert.equal(oauthStillActive.state, 'active');
  assert.equal(oauthStillActive.source, 'patreon_oauth');
  assert.equal(oauthStillActive.effective, true);
});

test('Patreon subjects are unique across Gainmap Firebase accounts', async () => {
  const identity = { data: { type: 'user', id: 'patreon-subject' } };
  const member = parseMember(memberResource());
  const db = new FakeDB();
  await linkPatreonIdentity({ db, uid: 'one', identity, member, hmacKey: HMAC_KEY, nowMs: NOW });
  await assert.rejects(
    linkPatreonIdentity({ db, uid: 'two', identity, member, hmacKey: HMAC_KEY, nowMs: NOW }),
    (error) => error instanceof OAuthFlowError && error.code === 'already_linked'
  );
});

test('Patreon campaign member IDs are unique across Gainmap accounts', async () => {
  const identity = { data: { type: 'user', id: 'new-subject' } };
  const member = parseMember(memberResource({ id: 'shared-member' }));
  const mHash = crypto
    .createHmac('sha256', HMAC_KEY)
    .update('member\0shared-member')
    .digest('hex');
  const db = new FakeDB({ [`patreonMemberIndex/${mHash}`]: { uid: 'existing' } });
  await assert.rejects(
    linkPatreonIdentity({ db, uid: 'other', identity, member, hmacKey: HMAC_KEY, nowMs: NOW }),
    (error) => error instanceof OAuthFlowError && error.code === 'already_linked'
  );
});

test('Patreon account cleanup removes link, entitlement, operator grant, indexes, and throttle', async () => {
  const subjectHash = crypto.createHmac('sha256', HMAC_KEY)
    .update('subject\0subject').digest('hex');
  const memberHash = crypto.createHmac('sha256', HMAC_KEY)
    .update('member\0member').digest('hex');
  const db = new FakeDB({
    'patreonLinks/firebase-uid': { subjectHash, memberHash },
    'patreonEntitlements/firebase-uid': activeEntitlement(NOW),
    'syncOperatorGrants/firebase-uid': {
      enabled: true, reason: 'campaign_creator', expiresAt: ts(NOW + DAY),
    },
    'patreonOAuthStarts/firebase-uid': { lastStartedAt: ts(NOW) },
    [`patreonSubjectIndex/${subjectHash}`]: { uid: 'firebase-uid' },
    [`patreonMemberIndex/${memberHash}`]: { uid: 'firebase-uid' },
  });
  await deletePatreonAccountData({ db, uid: 'firebase-uid' });
  for (const path of [
    'patreonLinks/firebase-uid',
    'patreonEntitlements/firebase-uid',
    'syncOperatorGrants/firebase-uid',
    'patreonOAuthStarts/firebase-uid',
    `patreonSubjectIndex/${subjectHash}`,
    `patreonMemberIndex/${memberHash}`,
  ]) assert.equal(db.docs.has(path), false, path);
});

test('Firestore index config declares TTL for deletion, OAuth, and keyed snapshot data', async () => {
  const { readFile } = await import('node:fs/promises');
  const config = JSON.parse(await readFile(new URL('../../firestore.indexes.json', import.meta.url)));
  const ttl = new Set(
    config.fieldOverrides
      .filter((entry) => entry.ttl === true && entry.fieldPath === 'expiresAt')
      .map((entry) => entry.collectionGroup)
  );
  for (const collection of [
    'deletedAccounts',
    'patreonOAuthStates',
    'patreonEmailIndex',
    'patreonMemberSnapshots',
  ]) assert.equal(ttl.has(collection), true, collection);
});

test('token store bootstraps, persists rotated tokens, and reuses the fresh access token', async () => {
  const db = new FakeDB();
  let calls = 0;
  const store = new PatreonTokenStore({
    db,
    clock: () => NOW,
    randomUUID: () => 'lease-owner',
    getClientCredentials: () => ({ clientId: 'id', clientSecret: 'secret' }),
    getBootstrapCredentials: () => ({ accessToken: 'bootstrap-access', refreshToken: 'bootstrap-refresh' }),
    fetchImpl: async () => {
      calls += 1;
      return jsonResponse({ access_token: 'rotated-access', refresh_token: 'rotated-refresh', expires_in: 3600 });
    },
  });
  assert.equal(await store.getAccessToken(), 'bootstrap-access');
  assert.equal(await store.getAccessToken({ force: true }), 'rotated-access');
  assert.equal(await store.getAccessToken(), 'rotated-access');
  assert.equal(calls, 1);
  assert.equal(db.docs.get('patreonPrivate/creatorToken').refreshToken, 'rotated-refresh');
});

test('token store refuses to return a rotated token when persistence fails', async () => {
  class CommitFailDB extends FakeDB {
    async runTransaction(fn) {
      if (this.docs.get('patreonPrivate/creatorToken')?.refreshLeaseOwner) throw new Error('commit down');
      return super.runTransaction(fn);
    }
  }
  const db = new CommitFailDB({
    'patreonPrivate/creatorToken': {
      accessToken: 'old', refreshToken: 'refresh', expiresAt: ts(NOW - 1),
    },
  });
  const store = new PatreonTokenStore({
    db, clock: () => NOW, randomUUID: () => 'owner',
    getClientCredentials: () => ({ clientId: 'id', clientSecret: 'secret' }),
    fetchImpl: async () => jsonResponse({ access_token: 'new', refresh_token: 'rotated', expires_in: 3600 }),
  });
  await assert.rejects(
    store.getAccessToken(),
    (error) => error instanceof PatreonTokenError && error.code === 'creator_reauthorization_required'
  );
});

test('a forced 401 waiter accepts a newer token instead of rotating it again', async () => {
  let refreshCalls = 0;
  const db = new FakeDB({
    'patreonPrivate/creatorToken': {
      accessToken: 'winner', refreshToken: 'winner-refresh', expiresAt: ts(NOW + 60 * 60 * 1000),
    },
  });
  const store = new PatreonTokenStore({
    db,
    clock: () => NOW,
    randomUUID: () => 'late-waiter',
    getClientCredentials: () => ({ clientId: 'id', clientSecret: 'secret' }),
    fetchImpl: async () => { refreshCalls += 1; return jsonResponse({}); },
  });
  assert.equal(
    await store.getAccessToken({ force: true, rejectedAccessToken: 'rejected-old-token' }),
    'winner'
  );
  assert.equal(refreshCalls, 0);
});

test('campaign API follows every cursor and fails on a repeated/incomplete cursor', async () => {
  const tokenStore = { getAccessToken: async () => 'access' };
  const pages = [
    { data: [memberResource({ id: 'm1' })], meta: { pagination: { cursors: { next: 'c2' } } } },
    { data: [memberResource({ id: 'm2', email: 'two@example.com' })], meta: { pagination: { cursors: {} } } },
  ];
  const api = new PatreonAPI({ tokenStore, campaignId: 'campaign', fetchImpl: async () => jsonResponse(pages.shift()) });
  assert.deepEqual((await api.getAllCampaignMembers()).map((member) => member.memberId), ['m1', 'm2']);

  const looping = new PatreonAPI({
    tokenStore, campaignId: 'campaign',
    fetchImpl: async () => jsonResponse({ data: [], meta: { pagination: { cursors: { next: 'same' } } } }),
  });
  await assert.rejects(looping.getAllCampaignMembers(), PatreonAPIError);

  const incomplete = new PatreonAPI({
    tokenStore, campaignId: 'campaign', minRequestIntervalMs: 0,
    fetchImpl: async () => jsonResponse({
      data: [memberResource({ id: 'only' })],
      meta: { pagination: { total: 2, cursors: {} } },
    }),
  });
  await assert.rejects(
    incomplete.getAllCampaignMembers(),
    (error) => error instanceof PatreonAPIError && error.code === 'pagination_incomplete'
  );
});

test('Patreon API paces calls and retries one 429 using Retry-After', async () => {
  const tokenStore = { getAccessToken: async () => 'access' };
  const sleeps = [];
  let calls = 0;
  const api = new PatreonAPI({
    tokenStore,
    campaignId: 'campaign',
    minRequestIntervalMs: 0,
    sleep: async (ms) => sleeps.push(ms),
    fetchImpl: async () => {
      calls += 1;
      if (calls === 1) {
        return {
          ok: false,
          status: 429,
          headers: { get: (name) => name.toLowerCase() === 'retry-after' ? '2' : null },
        };
      }
      return jsonResponse({ data: memberResource({ id: 'm-rate' }), included: [] });
    },
  });
  assert.equal((await api.getMember('m-rate')).memberId, 'm-rate');
  assert.deepEqual(sleeps, [2000]);
  assert.equal(calls, 2);
});

test('cross-instance limiter transactionally reserves globally spaced start slots', async () => {
  const sleeps = [];
  const db = new FakeDB();
  const limiter = new PatreonRateLimiter({
    db,
    clock: () => NOW,
    minSpacingMs: 800,
    sleep: async (ms) => { sleeps.push(ms); },
  });
  await limiter.acquire();
  await limiter.acquire();
  await limiter.acquire();
  assert.deepEqual(sleeps, [800, 1600]);
  assert.equal(db.docs.get('patreonPrivate/apiRate').nextAllowedAt.toMillis(), NOW + 2400);
});

test('cross-instance limiter rejects an excessive queue without extending it', async () => {
  const db = new FakeDB({
    'patreonPrivate/apiRate': { nextAllowedAt: ts(NOW + 30_000) },
  });
  const limiter = new PatreonRateLimiter({
    db,
    clock: () => NOW,
    minSpacingMs: 800,
    maxQueueMs: 20_000,
    sleep: async () => assert.fail('rejected slots must not sleep'),
  });
  await assert.rejects(limiter.acquire(), (error) => error.code === 'rate_budget_exhausted');
  assert.equal(db.docs.get('patreonPrivate/apiRate').nextAllowedAt.toMillis(), NOW + 30_000);
});

test('webhook verification uses exact raw bytes and ignores non-member payloads', () => {
  const secret = 'webhook-secret';
  const raw = Buffer.from(JSON.stringify({ data: memberResource({ id: 'member-42' }) }));
  const signature = crypto.createHmac('md5', secret).update(raw).digest('hex');
  assert.equal(verifyWebhookSignature(raw, signature, secret), true);
  assert.deepEqual(authenticatedWebhookPayload({ rawBody: raw, signature, secret }), { memberId: 'member-42' });
  assert.throws(
    () => authenticatedWebhookPayload({ rawBody: Buffer.from(`${raw} `), signature, secret }),
    (error) => error instanceof WebhookError && error.code === 'invalid_signature'
  );
  const other = Buffer.from(JSON.stringify({ data: { type: 'campaign', id: 'c1' } }));
  const otherSig = crypto.createHmac('md5', secret).update(other).digest('hex');
  assert.throws(
    () => authenticatedWebhookPayload({ rawBody: other, signature: otherSig, secret }),
    (error) => error instanceof WebhookError && error.status === 200
  );
  assert.throws(
    () => authenticatedWebhookPayload({
      rawBody: Buffer.alloc(1024 * 1024 + 1),
      signature: '',
      secret,
    }),
    (error) => error instanceof WebhookError && error.code === 'invalid_payload'
  );
});

test('full sync publishes the snapshot only after fetch, rejects suspicious empty campaign', async () => {
  const db = new FakeDB({
    'patreonPrivate/runtime': { currentSyncId: 'old', memberCount: 1 },
    'patreonLinks/firebase-uid': { memberId: 'm1' },
    'patreonEntitlements/firebase-uid': activeEntitlement(NOW - DAY),
    'users/firebase-uid': { syncAdmitted: true },
  });
  const api = { getAllCampaignMembers: async () => [parseMember(memberResource({ id: 'm1' }))] };
  const result = await syncCampaignCore({ db, api, hmacKey: HMAC_KEY, nowMs: NOW, syncId: 'new' });
  assert.equal(result.activeMemberCount, 1);
  assert.equal(db.docs.get('patreonPrivate/runtime').currentSyncId, 'new');
  const hash = emailIndex(HMAC_KEY, 'patron@example.com');
  assert.equal(db.docs.get(`patreonEmailIndex/${snapshotIndexId('new', hash)}`).lastSyncId, 'new');
  assert.equal(db.docs.get('patreonEntitlements/firebase-uid').state, 'active');

  const formerDB = new FakeDB({ 'patreonPrivate/runtime': { currentSyncId: 'old', memberCount: 1 } });
  await syncCampaignCore({
    db: formerDB,
    api: { getAllCampaignMembers: async () => [parseMember(memberResource({
      id: 'former', status: null, tierIds: [], email: 'former@example.com',
    }))] },
    hmacKey: HMAC_KEY,
    nowMs: NOW,
    syncId: 'active-only',
  });
  assert.equal(
    formerDB.docs.has(`patreonEmailIndex/${snapshotIndexId(
      'active-only', emailIndex(HMAC_KEY, 'former@example.com')
    )}`),
    false,
    'free/former patron emails are not retained in the bootstrap index'
  );

  const emptyDB = new FakeDB({ 'patreonPrivate/runtime': { currentSyncId: 'old', memberCount: 10 } });
  await assert.rejects(
    syncCampaignCore({
      db: emptyDB, api: { getAllCampaignMembers: async () => [] },
      hmacKey: HMAC_KEY, nowMs: NOW, syncId: 'bad',
    }),
    (error) => error.code === 'suspicious_incomplete_campaign'
  );
  assert.equal(emptyDB.docs.get('patreonPrivate/runtime').currentSyncId, 'old');
});

test('full sync migrates a same-subject link to the active duplicate and removes its old index', async () => {
  const subjectId = 'returning-patron';
  const oldId = 'former-membership';
  const newId = 'active-membership';
  const oldHash = memberIndex(HMAC_KEY, oldId);
  const newHash = memberIndex(HMAC_KEY, newId);
  const sHash = subjectIndex(HMAC_KEY, subjectId);
  const before = activeEntitlement(NOW - DAY);
  const db = new FakeDB({
    'patreonPrivate/runtime': {
      currentSyncId: 'old', memberCount: 2, lastCompletedAt: ts(NOW - DAY),
    },
    'patreonLinks/firebase-uid': {
      memberId: oldId, memberHash: oldHash, subjectHash: sHash,
    },
    [`patreonMemberIndex/${oldHash}`]: { uid: 'firebase-uid', updatedAt: ts(NOW - DAY) },
    'patreonEntitlements/firebase-uid': before,
    'users/firebase-uid': { syncAdmitted: true, entitlement: before },
  });
  const former = parseMember(memberResource({
    id: oldId, userId: subjectId, status: 'former_patron', tierIds: [],
  }));
  const active = parseMember(memberResource({ id: newId, userId: subjectId }));

  await syncCampaignCore({
    db,
    api: { getAllCampaignMembers: async () => [former, active] },
    hmacKey: HMAC_KEY,
    nowMs: NOW,
    syncId: 'returning-patron-scan',
  });

  assert.equal(db.docs.get('patreonLinks/firebase-uid').memberId, newId);
  assert.equal(db.docs.get('patreonLinks/firebase-uid').memberHash, newHash);
  assert.equal(db.docs.get('patreonEntitlements/firebase-uid').state, 'active');
  assert.equal(db.docs.has(`patreonMemberIndex/${oldHash}`), false);
  assert.equal(db.docs.get(`patreonMemberIndex/${newHash}`).uid, 'firebase-uid');
});

test('failed snapshot staging never punches holes in the published email index', async () => {
  const hash = emailIndex(HMAC_KEY, 'patron@example.com');
  class FailingStageDB extends FakeDB {
    batch() {
      const batch = super.batch();
      return {
        set: batch.set,
        commit: async () => {
          await batch.commit();
          throw new Error('staging commit acknowledgement failed');
        },
      };
    }
  }
  const db = new FailingStageDB({
    'patreonPrivate/runtime': {
      currentSyncId: 'published',
      memberCount: 1,
      lastCompletedAt: ts(NOW - DAY),
    },
    [`patreonEmailIndex/${snapshotIndexId('published', hash)}`]: {
      memberId: 'm1',
      isActiveEligible: true,
      lastSyncId: 'published',
      lastVerifiedAt: ts(NOW - DAY),
    },
  });
  await assert.rejects(
    syncCampaignCore({
      db,
      api: { getAllCampaignMembers: async () => [parseMember(memberResource({ id: 'm1' }))] },
      hmacKey: HMAC_KEY,
      nowMs: NOW,
      syncId: 'failed-stage',
    }),
    /staging commit/
  );
  assert.equal(db.docs.get('patreonPrivate/runtime').currentSyncId, 'published');
  assert.equal(
    db.docs.get(`patreonEmailIndex/${snapshotIndexId('published', hash)}`).isActiveEligible,
    true
  );
});

test('full sync cannot restore an old Patreon identity after OAuth relink', async () => {
  const aMember = parseMember(memberResource({ id: 'member-a', userId: 'subject-a' }));
  const aMemberHash = crypto.createHmac('sha256', HMAC_KEY)
    .update('member\0member-a').digest('hex');
  const aSubjectHash = crypto.createHmac('sha256', HMAC_KEY)
    .update('subject\0subject-a').digest('hex');
  const bMemberHash = crypto.createHmac('sha256', HMAC_KEY)
    .update('member\0member-b').digest('hex');
  const bSubjectHash = crypto.createHmac('sha256', HMAC_KEY)
    .update('subject\0subject-b').digest('hex');
  const staleLink = {
    memberId: 'member-a', memberHash: aMemberHash, subjectHash: aSubjectHash,
  };
  class StaleLinkScanDB extends FakeDB {
    collection(path) {
      if (path !== 'patreonLinks') return super.collection(path);
      return {
        get: async () => ({
          docs: [new FakeSnapshot(new FakeRef(this, 'patreonLinks/firebase-uid'), staleLink)],
          size: 1,
        }),
      };
    }
  }
  const db = new StaleLinkScanDB({
    'patreonPrivate/runtime': { currentSyncId: 'old', memberCount: 1 },
    'patreonLinks/firebase-uid': {
      memberId: 'member-b', memberHash: bMemberHash, subjectHash: bSubjectHash,
    },
    'patreonEntitlements/firebase-uid': activeEntitlement(NOW - DAY),
    'users/firebase-uid': { syncAdmitted: true },
  });
  await syncCampaignCore({
    db,
    api: { getAllCampaignMembers: async () => [aMember] },
    hmacKey: HMAC_KEY,
    nowMs: NOW,
    syncId: 'scan-a',
  });
  assert.equal(db.docs.get('patreonLinks/firebase-uid').memberId, 'member-b');
  assert.equal(db.docs.get('patreonLinks/firebase-uid').subjectHash, bSubjectHash);
});

test('webhook email change invalidates the previous current-snapshot hash atomically', async () => {
  const oldHash = emailIndex(HMAC_KEY, 'old@example.com');
  const newHash = emailIndex(HMAC_KEY, 'new@example.com');
  const mHash = crypto
    .createHmac('sha256', HMAC_KEY)
    .update('member\0m-email')
    .digest('hex');
  const db = new FakeDB({
    'patreonPrivate/runtime': { currentSyncId: 'current', lastCompletedAt: ts(NOW - DAY) },
    [`patreonMemberSnapshots/${snapshotIndexId('current', mHash)}`]: {
      emailHash: oldHash, lastSyncId: 'current', lastVerifiedAt: ts(NOW - DAY),
    },
    [`patreonEmailIndex/${snapshotIndexId('current', oldHash)}`]: {
      memberId: 'm-email', isActiveEligible: true, lastSyncId: 'current', lastVerifiedAt: ts(NOW - DAY),
    },
  });
  await reconcileMemberCore({
    db,
    api: { getMember: async () => parseMember(memberResource({ id: 'm-email', email: 'new@example.com' })) },
    hmacKey: HMAC_KEY,
    memberId: 'm-email',
    nowMs: NOW,
  });
  assert.equal(db.docs.has(`patreonEmailIndex/${snapshotIndexId('current', oldHash)}`), false);
  assert.equal(db.docs.get(`patreonEmailIndex/${snapshotIndexId('current', newHash)}`).lastSyncId, 'current');
  assert.equal(db.docs.get(`patreonMemberSnapshots/${snapshotIndexId('current', mHash)}`).emailHash, newHash);

  await reconcileMemberCore({
    db,
    api: { getMember: async () => null },
    hmacKey: HMAC_KEY,
    memberId: 'm-email',
    nowMs: NOW + 1,
  });
  assert.equal(db.docs.has(`patreonEmailIndex/${snapshotIndexId('current', newHash)}`), false);
  assert.equal(db.docs.has(`patreonMemberSnapshots/${snapshotIndexId('current', mHash)}`), false);
});

test('stale webhook cannot overwrite a Patreon identity that was relinked', async () => {
  const aHash = crypto.createHmac('sha256', HMAC_KEY)
    .update('member\0member-a').digest('hex');
  const bHash = crypto.createHmac('sha256', HMAC_KEY)
    .update('member\0member-b').digest('hex');
  const bSubjectHash = crypto.createHmac('sha256', HMAC_KEY)
    .update('subject\0subject-b').digest('hex');
  const before = activeEntitlement(NOW - DAY);
  const db = new FakeDB({
    'patreonPrivate/runtime': { currentSyncId: 'current', lastCompletedAt: ts(NOW - DAY) },
    [`patreonMemberIndex/${aHash}`]: { uid: 'firebase-uid' },
    [`patreonMemberIndex/${bHash}`]: { uid: 'firebase-uid' },
    'patreonLinks/firebase-uid': {
      memberId: 'member-b', memberHash: bHash, subjectHash: bSubjectHash,
    },
    'patreonEntitlements/firebase-uid': before,
    'users/firebase-uid': { syncAdmitted: true, entitlement: before },
  });
  const result = await reconcileMemberCore({
    db,
    api: { getMember: async () => parseMember(memberResource({ id: 'member-a', userId: 'subject-a' })) },
    hmacKey: HMAC_KEY,
    memberId: 'member-a',
    nowMs: NOW,
  });
  assert.equal(result.reconciled, false);
  assert.equal(db.docs.get('patreonLinks/firebase-uid').memberId, 'member-b');
  assert.equal(db.docs.get('patreonLinks/firebase-uid').subjectHash, bSubjectHash);
  assert.equal(db.docs.get('patreonEntitlements/firebase-uid').lastVerifiedAt.toMillis(), NOW - DAY);
});

test('same-subject webhook keeps an eligible current member instead of reviving an old duplicate', async () => {
  const subjectId = 'same-subject';
  const oldId = 'old-member';
  const currentId = 'current-member';
  const oldHash = memberIndex(HMAC_KEY, oldId);
  const currentHash = memberIndex(HMAC_KEY, currentId);
  const sHash = subjectIndex(HMAC_KEY, subjectId);
  const before = activeEntitlement(NOW - DAY);
  const db = new FakeDB({
    'patreonPrivate/runtime': { currentSyncId: 'current', lastCompletedAt: ts(NOW - DAY) },
    [`patreonSubjectIndex/${sHash}`]: { uid: 'firebase-uid' },
    [`patreonMemberIndex/${currentHash}`]: { uid: 'firebase-uid' },
    'patreonLinks/firebase-uid': {
      memberId: currentId, memberHash: currentHash, subjectHash: sHash,
    },
    'patreonEntitlements/firebase-uid': before,
    'users/firebase-uid': { syncAdmitted: true, entitlement: before },
  });
  const members = new Map([
    [oldId, parseMember(memberResource({ id: oldId, userId: subjectId }))],
    [currentId, parseMember(memberResource({ id: currentId, userId: subjectId }))],
  ]);

  const result = await reconcileMemberCore({
    db,
    api: { getMember: async (id) => members.get(id) || null },
    hmacKey: HMAC_KEY,
    memberId: oldId,
    nowMs: NOW,
  });

  assert.equal(result.reconciled, false);
  assert.equal(result.linked, true);
  assert.equal(db.docs.get('patreonLinks/firebase-uid').memberId, currentId);
  assert.equal(db.docs.has(`patreonMemberIndex/${oldHash}`), false);
  assert.equal(db.docs.get('patreonEntitlements/firebase-uid').lastVerifiedAt.toMillis(), NOW - DAY);
});

test('same-subject webhook migrates to an active replacement and cleans the owned old index', async () => {
  const subjectId = 'returning-subject';
  const oldId = 'lapsed-member';
  const replacementId = 'replacement-member';
  const oldHash = memberIndex(HMAC_KEY, oldId);
  const replacementHash = memberIndex(HMAC_KEY, replacementId);
  const sHash = subjectIndex(HMAC_KEY, subjectId);
  const before = activeEntitlement(NOW - DAY);
  const db = new FakeDB({
    'patreonPrivate/runtime': { currentSyncId: 'current', lastCompletedAt: ts(NOW - DAY) },
    [`patreonSubjectIndex/${sHash}`]: { uid: 'firebase-uid' },
    [`patreonMemberIndex/${oldHash}`]: { uid: 'firebase-uid' },
    'patreonLinks/firebase-uid': {
      memberId: oldId, memberHash: oldHash, subjectHash: sHash,
    },
    'patreonEntitlements/firebase-uid': before,
    'users/firebase-uid': { syncAdmitted: true, entitlement: before },
  });
  const members = new Map([
    [oldId, parseMember(memberResource({
      id: oldId, userId: subjectId, status: 'former_patron', tierIds: [],
    }))],
    [replacementId, parseMember(memberResource({ id: replacementId, userId: subjectId }))],
  ]);

  const result = await reconcileMemberCore({
    db,
    api: { getMember: async (id) => members.get(id) || null },
    hmacKey: HMAC_KEY,
    memberId: replacementId,
    nowMs: NOW,
  });

  assert.equal(result.reconciled, true);
  assert.equal(result.active, true);
  assert.equal(db.docs.get('patreonLinks/firebase-uid').memberId, replacementId);
  assert.equal(db.docs.has(`patreonMemberIndex/${oldHash}`), false);
  assert.equal(db.docs.get(`patreonMemberIndex/${replacementHash}`).uid, 'firebase-uid');
});

test('webhook defers all writes while a campaign snapshot is publishing', async () => {
  const mHash = crypto.createHmac('sha256', HMAC_KEY)
    .update('member\0m-live').digest('hex');
  const before = activeEntitlement(NOW - DAY);
  const db = new FakeDB({
    'patreonPrivate/runtime': {
      currentSyncId: 'current',
      lastCompletedAt: ts(NOW - DAY),
      syncLeaseId: 'nightly',
      syncLeaseUntil: ts(NOW + 60_000),
    },
    [`patreonMemberIndex/${mHash}`]: { uid: 'firebase-uid' },
    'patreonLinks/firebase-uid': { memberId: 'm-live', memberHash: mHash },
    'patreonEntitlements/firebase-uid': before,
    'users/firebase-uid': { syncAdmitted: true, entitlement: before },
  });
  await assert.rejects(
    reconcileMemberCore({
      db,
      api: { getMember: async () => parseMember(memberResource({
        id: 'm-live', status: 'former_patron', tierIds: [], email: 'changed@example.com',
      })) },
      hmacKey: HMAC_KEY,
      memberId: 'm-live',
      nowMs: NOW,
    }),
    (error) => error.code === 'sync_in_progress'
  );
  assert.equal(db.docs.get('patreonLinks/firebase-uid').lastCheckedAt, undefined);
  assert.equal(db.docs.get('patreonEntitlements/firebase-uid').state, 'active');
});
