'use strict';

const { Timestamp } = require('firebase-admin/firestore');
const { PATREON_USER_AGENT } = require('./http');
const {
  PATREON_OAUTH_STATE_TTL_MS,
  PATREON_OAUTH_START_COOLDOWN_MS,
} = require('../constants');
const { opaqueToken, subjectIndex, memberIndex } = require('./crypto');
const { relationshipId, relationshipIds, parseMember } = require('./api');
const {
  ENTITLEMENTS_COLLECTION,
  LINKS_COLLECTION,
  activeEntitlement,
  preferEntitlement,
} = require('./entitlement');

const OAUTH_STATES_COLLECTION = 'patreonOAuthStates';
const SUBJECT_INDEX_COLLECTION = 'patreonSubjectIndex';
const MEMBER_INDEX_COLLECTION = 'patreonMemberIndex';
const OAUTH_STARTS_COLLECTION = 'patreonOAuthStarts';

class OAuthFlowError extends Error {
  constructor(code, message) {
    super(message || code);
    this.name = 'OAuthFlowError';
    this.code = code;
  }
}

function safeOAuthErrorCode(value) {
  const allowed = new Set([
    'authorization_denied',
    'missing_parameters',
    'invalid_state',
    'expired_state',
    'token_exchange_failed',
    'identity_failed',
    'campaign_not_configured',
    'already_linked',
    'membership_not_found',
    'membership_inactive',
    'rate_limited',
    'internal',
  ]);
  return allowed.has(value) ? value : 'internal';
}

async function startOAuthCore({
  db,
  uid,
  clientId,
  redirectURI,
  attemptKind = 'reuse_session',
  nowMs = Date.now(),
}) {
  if (!uid) throw new OAuthFlowError('invalid_state', 'A Firebase user is required.');
  if (!clientId || !redirectURI) {
    throw new OAuthFlowError('campaign_not_configured', 'Patreon OAuth is not configured.');
  }
  if (!['reuse_session', 'switch_account'].includes(attemptKind)) {
    throw new OAuthFlowError('invalid_state', 'Unknown Patreon connection attempt.');
  }
  const state = opaqueToken(32);
  const stateRef = db.doc(`${OAUTH_STATES_COLLECTION}/${state}`);
  const throttleRef = db.doc(`${OAUTH_STARTS_COLLECTION}/${uid}`);
  await db.runTransaction(async (tx) => {
    const [deletedSnap, throttleSnap] = await Promise.all([
      tx.get(db.doc(`deletedAccounts/${uid}`)), tx.get(throttleRef),
    ]);
    if (deletedSnap.exists) throw new OAuthFlowError('invalid_state');
    const legacyLastStartedAt = throttleSnap.exists ? throttleSnap.get('lastStartedAt') : null;
    const storedWindowStartedAt = throttleSnap.exists ? throttleSnap.get('windowStartedAt') : null;
    let windowStartedMs = storedWindowStartedAt && storedWindowStartedAt.toMillis();
    let startsInWindow = throttleSnap.exists ? Number(throttleSnap.get('startsInWindow')) : 0;
    if (!Number.isFinite(windowStartedMs) && legacyLastStartedAt) {
      windowStartedMs = legacyLastStartedAt.toMillis();
      startsInWindow = 1;
    }
    if (!Number.isFinite(windowStartedMs) ||
        nowMs - windowStartedMs >= PATREON_OAUTH_START_COOLDOWN_MS) {
      windowStartedMs = nowMs;
      startsInWindow = 0;
    }
    if (startsInWindow >= 2) {
      throw new OAuthFlowError('rate_limited');
    }
    const pendingState = throttleSnap.exists ? throttleSnap.get('pendingState') : '';
    const pendingRef = pendingState
      ? db.doc(`${OAUTH_STATES_COLLECTION}/${pendingState}`)
      : null;
    const pendingSnap = pendingRef ? await tx.get(pendingRef) : null;
    if (pendingSnap && pendingSnap.exists && !pendingSnap.get('consumedAt')) {
      tx.set(pendingRef, { consumedAt: Timestamp.fromMillis(nowMs) }, { merge: true });
    }
    tx.create(stateRef, {
      uid,
      attemptKind,
      createdAt: Timestamp.fromMillis(nowMs),
      expiresAt: Timestamp.fromMillis(nowMs + PATREON_OAUTH_STATE_TTL_MS),
    });
    tx.set(throttleRef, {
      windowStartedAt: Timestamp.fromMillis(windowStartedMs),
      startsInWindow: startsInWindow + 1,
      lastStartedAt: Timestamp.fromMillis(nowMs),
      pendingState: state,
    }, { merge: true });
  });
  const url = new URL('https://www.patreon.com/oauth2/authorize');
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('client_id', clientId);
  url.searchParams.set('redirect_uri', redirectURI);
  // Request only the OAuth client's own-campaign membership. Patreon grants
  // can retain previously approved scopes, so the callback still validates an
  // exact campaign relationship instead of assuming this request narrowed an
  // older grant.
  url.searchParams.set('scope', 'identity');
  url.searchParams.set('state', state);
  return { authorizationURL: url.toString() };
}

async function consumeOAuthState({ db, state, nowMs = Date.now() }) {
  if (typeof state !== 'string' || state.length < 32 || state.length > 256) {
    throw new OAuthFlowError('invalid_state');
  }
  const ref = db.doc(`${OAUTH_STATES_COLLECTION}/${state}`);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists || snap.get('consumedAt')) throw new OAuthFlowError('invalid_state');
    const expiresAt = snap.get('expiresAt');
    if (!expiresAt || expiresAt.toMillis() <= nowMs) {
      tx.set(ref, { consumedAt: Timestamp.fromMillis(nowMs) }, { merge: true });
      throw new OAuthFlowError('expired_state');
    }
    const uid = snap.get('uid');
    if (typeof uid !== 'string' || uid.length === 0) throw new OAuthFlowError('invalid_state');
    tx.set(ref, { consumedAt: Timestamp.fromMillis(nowMs) }, { merge: true });
    return uid;
  });
}

async function exchangeAuthorizationCode({
  code,
  clientId,
  clientSecret,
  redirectURI,
  fetchImpl = fetch,
}) {
  let response;
  try {
    response = await fetchImpl('https://www.patreon.com/api/oauth2/token', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': PATREON_USER_AGENT,
      },
      body: new URLSearchParams({
        code,
        grant_type: 'authorization_code',
        client_id: clientId,
        client_secret: clientSecret,
        redirect_uri: redirectURI,
      }),
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    throw new OAuthFlowError('token_exchange_failed');
  }
  if (!response.ok) throw new OAuthFlowError('token_exchange_failed');
  try {
    const data = await response.json();
    if (!data || !data.access_token) throw new Error('missing access token');
    return data.access_token;
  } catch {
    throw new OAuthFlowError('token_exchange_failed');
  }
}

async function fetchIdentity({ accessToken, fetchImpl = fetch }) {
  const url = new URL('https://www.patreon.com/api/oauth2/v2/identity');
  // OAuth scopes are cumulative on an existing Patreon grant, so an identity
  // response may contain memberships for more than this OAuth client's
  // campaign. Include the campaign relationship and require an exact match
  // before treating any member resource as Gainmap proof.
  url.searchParams.set(
    'include',
    'memberships,memberships.currently_entitled_tiers,memberships.campaign'
  );
  url.searchParams.set(
    'fields[member]',
    'patron_status'
  );
  let response;
  try {
    response = await fetchImpl(url, {
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'User-Agent': PATREON_USER_AGENT,
        Accept: 'application/json',
      },
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    throw new OAuthFlowError('identity_failed');
  }
  if (!response.ok) throw new OAuthFlowError('identity_failed');
  try {
    const body = await response.json();
    if (!body || !body.data || body.data.type !== 'user' || !body.data.id) {
      throw new Error('invalid identity');
    }
    return body;
  } catch {
    throw new OAuthFlowError('identity_failed');
  }
}

function identityMembership(identity, campaignId) {
  if (!campaignId) throw new OAuthFlowError('campaign_not_configured');
  const membershipIds = new Set(relationshipIds(identity.data, 'memberships'));
  const included = Array.isArray(identity.included) ? identity.included : [];
  let selected = null;
  for (const resource of included) {
    if (!resource || resource.type !== 'member' || !membershipIds.has(String(resource.id))) continue;
    // Missing campaign linkage is ambiguous and therefore not proof. Never
    // infer campaign ownership from response ordering or from the OAuth app.
    const responseCampaignId = relationshipId(resource, 'campaign');
    if (responseCampaignId !== String(campaignId)) continue;
    // Patreon identity memberships do not guarantee a nested `user`
    // relationship unless explicitly included. The top-level identity is the
    // authoritative Patreon subject for every returned membership.
    const candidate = parseMember(resource, included, {
      requireUserRelationship: false,
      subjectId: String(identity.data.id),
      requireAmountField: false,
    });
    if (!selected || (candidate.isActiveEligible && !selected.isActiveEligible)) {
      selected = candidate;
    }
  }
  return selected;
}

/**
 * Converts the OAuth identity response into durable campaign proof. The OAuth
 * response selects an exact configured-campaign membership; a separate lookup
 * with the creator credential confirms that member still exists, is eligible,
 * and belongs to the exact same Patreon subject before any link is mutated.
 */
async function verifyOAuthMembership({ identity, campaignId, api }) {
  const candidate = identityMembership(identity, campaignId);
  if (!candidate) throw new OAuthFlowError('membership_not_found');
  if (!candidate.isActiveEligible) throw new OAuthFlowError('membership_inactive');

  const subjectId = identity && identity.data && String(identity.data.id || '');
  if (!subjectId || candidate.subjectId !== subjectId) {
    throw new OAuthFlowError('identity_failed');
  }
  if (!api || typeof api.getMember !== 'function' ||
      String(api.campaignId || '') !== String(campaignId)) {
    throw new OAuthFlowError('campaign_not_configured');
  }

  let verified;
  try {
    verified = await api.getMember(candidate.memberId);
  } catch {
    throw new OAuthFlowError('identity_failed');
  }
  if (!verified || verified.memberId !== candidate.memberId || verified.subjectId !== subjectId) {
    throw new OAuthFlowError('membership_not_found');
  }
  if (!verified.isActiveEligible) throw new OAuthFlowError('membership_inactive');
  return verified;
}

async function linkPatreonIdentity({ db, uid, identity, member, hmacKey, nowMs = Date.now() }) {
  // A failed/wrong-account attempt is intentionally nonmutating. Keeping the
  // previous link and entitlement lets the client immediately offer a clean
  // browser-session retry without downgrading verified-email access.
  if (!member) throw new OAuthFlowError('membership_not_found');
  if (!member.isActiveEligible) throw new OAuthFlowError('membership_inactive');
  const subjectHash = subjectIndex(hmacKey, String(identity.data.id));
  const nextMemberHash = memberIndex(hmacKey, member.memberId);
  const linkRef = db.doc(`${LINKS_COLLECTION}/${uid}`);
  const subjectRef = db.doc(`${SUBJECT_INDEX_COLLECTION}/${subjectHash}`);
  const deletedRef = db.doc(`deletedAccounts/${uid}`);
  const entitlementRef = db.doc(`${ENTITLEMENTS_COLLECTION}/${uid}`);
  const nextMemberRef = nextMemberHash
    ? db.doc(`${MEMBER_INDEX_COLLECTION}/${nextMemberHash}`)
    : null;

  let storedEntitlement;
  await db.runTransaction(async (tx) => {
    const userRef = db.doc(`users/${uid}`);
    const [linkSnap, subjectSnap, deletedSnap, entitlementSnap, userSnap, nextMemberSnap] = await Promise.all([
      tx.get(linkRef),
      tx.get(subjectRef),
      tx.get(deletedRef),
      tx.get(entitlementRef),
      tx.get(userRef),
      nextMemberRef ? tx.get(nextMemberRef) : Promise.resolve(null),
    ]);
    if (deletedSnap.exists) throw new OAuthFlowError('invalid_state');
    if (entitlementSnap.exists && entitlementSnap.get('purgeLeaseId')) {
      throw new OAuthFlowError('internal');
    }
    if (subjectSnap.exists && subjectSnap.get('uid') !== uid) {
      throw new OAuthFlowError('already_linked');
    }
    if (nextMemberSnap && nextMemberSnap.exists && nextMemberSnap.get('uid') !== uid) {
      throw new OAuthFlowError('already_linked');
    }

    const oldSubjectHash = linkSnap.exists ? linkSnap.get('subjectHash') : '';
    const oldMemberHash = linkSnap.exists ? linkSnap.get('memberHash') : '';
    const oldSubjectRef = oldSubjectHash && oldSubjectHash !== subjectHash
      ? db.doc(`${SUBJECT_INDEX_COLLECTION}/${oldSubjectHash}`)
      : null;
    const oldMemberRef = oldMemberHash && oldMemberHash !== nextMemberHash
      ? db.doc(`${MEMBER_INDEX_COLLECTION}/${oldMemberHash}`)
      : null;

    // Firestore requires reads before writes. Confirm old indexes still belong
    // to this UID before deleting them, so a damaged link cannot delete
    // somebody else's uniqueness guard.
    const oldSubjectSnap = oldSubjectRef ? await tx.get(oldSubjectRef) : null;
    const oldMemberSnap = oldMemberRef ? await tx.get(oldMemberRef) : null;

    storedEntitlement = preferEntitlement(
      entitlementSnap.exists ? entitlementSnap.data() || {} : {},
      activeEntitlement(nowMs),
      nowMs
    );

    tx.set(subjectRef, { uid, linkedAt: Timestamp.fromMillis(nowMs) }, { merge: true });
    if (nextMemberHash) {
      tx.set(nextMemberRef, {
        uid,
        updatedAt: Timestamp.fromMillis(nowMs),
      }, { merge: true });
    }
    tx.set(linkRef, {
      subjectHash,
      memberId: member.memberId,
      memberHash: nextMemberHash,
      linkedAt: linkSnap.exists ? linkSnap.get('linkedAt') || Timestamp.fromMillis(nowMs) : Timestamp.fromMillis(nowMs),
      updatedAt: Timestamp.fromMillis(nowMs),
    }, { merge: true });
    tx.set(entitlementRef, storedEntitlement, { merge: true });
    if (userSnap.exists) tx.set(userRef, { entitlement: storedEntitlement }, { merge: true });
    if (oldSubjectSnap && oldSubjectSnap.exists && oldSubjectSnap.get('uid') === uid) {
      tx.delete(oldSubjectRef);
    }
    if (oldMemberSnap && oldMemberSnap.exists && oldMemberSnap.get('uid') === uid) {
      tx.delete(oldMemberRef);
    }
  });
  return storedEntitlement;
}

module.exports = {
  OAUTH_STATES_COLLECTION,
  SUBJECT_INDEX_COLLECTION,
  MEMBER_INDEX_COLLECTION,
  OAUTH_STARTS_COLLECTION,
  OAuthFlowError,
  safeOAuthErrorCode,
  startOAuthCore,
  consumeOAuthState,
  exchangeAuthorizationCode,
  fetchIdentity,
  identityMembership,
  verifyOAuthMembership,
  linkPatreonIdentity,
};
