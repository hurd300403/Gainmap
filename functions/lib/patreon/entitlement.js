'use strict';

const { Timestamp } = require('firebase-admin/firestore');
const {
  PATREON_GRACE_MS,
  PATREON_EMAIL_PROVISIONAL_MS,
  PATREON_RETENTION_MS,
  PATREON_REFRESH_COOLDOWN_MS,
} = require('../constants');
const { emailIndex, snapshotIndexId } = require('./crypto');
const { timestampMillis } = require('./tokenStore');

const ENTITLEMENTS_COLLECTION = 'patreonEntitlements';
const LINKS_COLLECTION = 'patreonLinks';
const EMAIL_INDEX_COLLECTION = 'patreonEmailIndex';
const RUNTIME_PATH = 'patreonPrivate/runtime';

function valueMillis(value) {
  return timestampMillis(value);
}

function toTimestamp(ms) {
  return Number.isFinite(ms) && ms > 0 ? Timestamp.fromMillis(ms) : null;
}

function isEffectiveAt(entitlement, nowMs) {
  if (!entitlement || entitlement.effective !== true) return false;
  if (entitlement.state === 'active') {
    return valueMillis(entitlement.verificationExpiresAt) > nowMs;
  }
  return entitlement.state === 'grace' && valueMillis(entitlement.graceExpiresAt) > nowMs;
}

function safeEntitlement(entitlement, nowMs = Date.now(), linked) {
  const source = entitlement || {};
  let state = ['active', 'grace', 'inactive', 'unlinked', 'error'].includes(source.state)
    ? source.state
    : 'unlinked';
  const effective = isEffectiveAt(source, nowMs);
  if (state === 'active' && !effective) state = 'error';
  if (state === 'grace' && !effective) {
    state = source.source === 'patreon_email' ? 'unlinked' : 'inactive';
  }
  const response = {
    state,
    effective,
    // This is deliberately a boolean, not an inference the client has to make
    // from human copy. OAuth-linked inactive/grace users must not be prompted
    // to connect a second Patreon identity.
    linkRequired: typeof linked === 'boolean'
      ? !linked
      : source.source !== 'patreon_oauth',
    message: messageFor(state, source.source),
  };
  const graceExpiresAt = valueMillis(source.graceExpiresAt);
  const lastVerifiedAt = valueMillis(source.lastVerifiedAt);
  if (graceExpiresAt > 0) response.graceExpiresAt = graceExpiresAt;
  if (lastVerifiedAt > 0) response.lastVerifiedAt = lastVerifiedAt;
  return response;
}

function messageFor(state, source) {
  switch (state) {
    case 'active':
      return 'Cloud Sync is enabled by your active Patreon membership.';
    case 'grace':
      return source === 'patreon_email'
        ? 'Patreon email matched. Connect Patreon before temporary Cloud Sync access expires.'
        : 'Cloud Sync remains available during the Patreon grace period.';
    case 'inactive':
      return 'An active Patreon membership is required for Cloud Sync.';
    case 'error':
      return 'Patreon verification is temporarily unavailable. Try again later.';
    case 'unlinked':
    default:
      return 'Connect Patreon to use Cloud Sync.';
  }
}

function activeEntitlement(nowMs, source = 'patreon_oauth') {
  return {
    state: 'active',
    effective: true,
    source,
    lastVerifiedAt: toTimestamp(nowMs),
    // This is also the maximum fail-open duration if every scheduled check and
    // webhook stops running. Successful direct verification rolls it forward.
    verificationExpiresAt: toTimestamp(nowMs + PATREON_GRACE_MS),
    graceExpiresAt: null,
    inactiveSince: null,
    retentionExpiresAt: null,
    cloudDataPurgedAt: null,
    updatedAt: toTimestamp(nowMs),
  };
}

function inactiveTransition(previous, nowMs) {
  const prior = previous || {};
  if (isEffectiveAt(prior, nowMs)) {
    const existingExpiry = valueMillis(prior.graceExpiresAt);
    const inactiveSince = valueMillis(prior.inactiveSince) || nowMs;
    const graceExpiresAt = existingExpiry > nowMs ? existingExpiry : nowMs + PATREON_GRACE_MS;
    return {
      ...prior,
      state: 'grace',
      effective: true,
      source: prior.source === 'patreon_email' ? 'patreon_email' : 'patreon_oauth',
      lastVerifiedAt: toTimestamp(nowMs),
      inactiveSince: toTimestamp(inactiveSince),
      graceExpiresAt: toTimestamp(graceExpiresAt),
      retentionExpiresAt: toTimestamp(inactiveSince + PATREON_RETENTION_MS),
      updatedAt: toTimestamp(nowMs),
    };
  }
  const inactiveSince = valueMillis(prior.inactiveSince) || nowMs;
  return {
    ...prior,
    state: 'inactive',
    effective: false,
    source: prior.source || 'patreon_oauth',
    lastVerifiedAt: toTimestamp(nowMs),
    graceExpiresAt: null,
    inactiveSince: toTimestamp(inactiveSince),
    retentionExpiresAt: toTimestamp(inactiveSince + PATREON_RETENTION_MS),
    updatedAt: toTimestamp(nowMs),
  };
}

function errorTransition(previous, nowMs) {
  const prior = previous || {};
  if (prior.state === 'grace' && isEffectiveAt(prior, nowMs)) {
    return { ...prior, updatedAt: toTimestamp(nowMs) };
  }
  if (prior.state === 'active' && prior.effective === true) {
    const verified = valueMillis(prior.lastVerifiedAt);
    const expiry = verified > 0 ? verified + PATREON_GRACE_MS : 0;
    if (expiry > nowMs) {
      return {
        ...prior,
        state: 'grace',
        effective: true,
        graceExpiresAt: toTimestamp(expiry),
        updatedAt: toTimestamp(nowMs),
      };
    }
  }
  return {
    ...prior,
    state: 'error',
    effective: false,
    updatedAt: toTimestamp(nowMs),
  };
}

function provisionalEntitlement(previous, nowMs, snapshotVerifiedMs) {
  const prior = previous || {};
  // `provisionalExpiresAt` is immutable once issued and is deliberately kept
  // after expiry. Clearing it would let the next launch mint another seven-day
  // email-only window indefinitely.
  const existingExpiry = valueMillis(prior.provisionalExpiresAt) ||
    (prior.source === 'patreon_email' ? valueMillis(prior.graceExpiresAt) : 0);
  const expiry = existingExpiry || nowMs + PATREON_EMAIL_PROVISIONAL_MS;
  if (expiry <= nowMs) {
    const inactiveSince = valueMillis(prior.inactiveSince) || expiry;
    return {
      ...prior,
      state: 'unlinked',
      effective: false,
      source: 'patreon_email',
      graceExpiresAt: null,
      provisionalExpiresAt: toTimestamp(expiry),
      inactiveSince: toTimestamp(inactiveSince),
      retentionExpiresAt: toTimestamp(inactiveSince + PATREON_RETENTION_MS),
      updatedAt: toTimestamp(nowMs),
    };
  }
  return {
    ...prior,
    state: 'grace',
    effective: true,
    source: 'patreon_email',
    lastVerifiedAt: toTimestamp(snapshotVerifiedMs || nowMs),
    graceExpiresAt: toTimestamp(expiry),
    provisionalExpiresAt: toTimestamp(expiry),
    updatedAt: toTimestamp(nowMs),
  };
}

function unlinkedEntitlement(previous, nowMs) {
  const prior = previous || {};
  const wasProvisional = prior.source === 'patreon_email';
  const inactiveSince = wasProvisional
    ? valueMillis(prior.inactiveSince) || valueMillis(prior.provisionalExpiresAt) || nowMs
    : 0;
  return {
    ...prior,
    state: 'unlinked',
    effective: false,
    source: prior.source === 'patreon_email' ? 'patreon_email' : 'none',
    graceExpiresAt: null,
    inactiveSince: inactiveSince ? toTimestamp(inactiveSince) : prior.inactiveSince || null,
    retentionExpiresAt: inactiveSince
      ? toTimestamp(inactiveSince + PATREON_RETENTION_MS)
      : prior.retentionExpiresAt || null,
    updatedAt: toTimestamp(nowMs),
  };
}

async function persistEntitlement({
  db,
  uid,
  entitlement,
  nowMs = Date.now(),
  requireUnlinked = false,
}) {
  const entitlementRef = db.doc(`${ENTITLEMENTS_COLLECTION}/${uid}`);
  const userRef = db.doc(`users/${uid}`);
  const deletedRef = db.doc(`deletedAccounts/${uid}`);
  const linkRef = db.doc(`${LINKS_COLLECTION}/${uid}`);
  return db.runTransaction(async (tx) => {
    const [deletedSnap, userSnap, currentSnap, linkSnap] = await Promise.all([
      tx.get(deletedRef),
      tx.get(userRef),
      tx.get(entitlementRef),
      tx.get(linkRef),
    ]);
    const current = currentSnap.exists ? currentSnap.data() || {} : {};
    if (deletedSnap.exists || (requireUnlinked && linkSnap.exists)) {
      return { entitlement: current, linked: linkSnap.exists };
    }
    if (currentSnap.exists && currentSnap.get('purgeLeaseId')) {
      throw new Error('Cloud library retention purge is in progress.');
    }
    if (currentSnap.exists &&
        valueMillis(currentSnap.get('lastVerifiedAt')) > valueMillis(entitlement.lastVerifiedAt)) {
      return { entitlement: current, linked: linkSnap.exists };
    }
    tx.set(entitlementRef, entitlement, { merge: true });
    if (userSnap.exists) tx.set(userRef, { entitlement }, { merge: true });
    return { entitlement, linked: linkSnap.exists };
  });
}

/**
 * Atomically claim the per-user refresh cooldown before making a creator API
 * request. Reading the deletion marker and link in the same transaction keeps
 * a refresh that straddles account deletion from recreating an orphan link.
 */
async function claimLinkedRefresh({ db, uid, nowMs, force }) {
  const linkRef = db.doc(`${LINKS_COLLECTION}/${uid}`);
  const entitlementRef = db.doc(`${ENTITLEMENTS_COLLECTION}/${uid}`);
  return db.runTransaction(async (tx) => {
    const [deletedSnap, linkSnap, entitlementSnap] = await Promise.all([
      tx.get(db.doc(`deletedAccounts/${uid}`)),
      tx.get(linkRef),
      tx.get(entitlementRef),
    ]);
    const entitlement = entitlementSnap.exists ? entitlementSnap.data() || {} : {};
    if (deletedSnap.exists || !linkSnap.exists) {
      return { proceed: false, linked: false, entitlement, link: null };
    }
    if (entitlement.purgeLeaseId) {
      return { proceed: false, linked: true, entitlement, link: linkSnap.data() || {} };
    }
    const link = linkSnap.data() || {};
    const lastAttemptMs = valueMillis(link.lastCheckAttemptAt);
    const lastCheckMs = valueMillis(link.lastCheckedAt);
    // A forced user retry may bypass a recent successful check, but never a
    // recent attempt. This bounds manual retry traffic during outages.
    if ((lastAttemptMs > 0 && nowMs - lastAttemptMs < PATREON_REFRESH_COOLDOWN_MS) ||
        (!force && nowMs - Math.max(lastAttemptMs, lastCheckMs) < PATREON_REFRESH_COOLDOWN_MS)) {
      return { proceed: false, linked: true, entitlement, link };
    }
    tx.set(linkRef, { lastCheckAttemptAt: toTimestamp(nowMs) }, { merge: true });
    return { proceed: true, linked: true, entitlement, link };
  });
}

function sameLinkIdentity(current, expected) {
  const a = current || {};
  const b = expected || {};
  return a.memberId === b.memberId &&
    a.memberHash === b.memberHash &&
    a.subjectHash === b.subjectHash;
}

/**
 * Publish a linked creator-API result, link freshness, outer entitlement and
 * rules-facing mirror as one transaction. The identity equality guard closes
 * the refresh-versus-OAuth-relink race.
 */
async function persistLinkedResult({
  db,
  uid,
  expectedLink,
  entitlement,
  nowMs,
  memberActive,
  markChecked,
}) {
  const linkRef = db.doc(`${LINKS_COLLECTION}/${uid}`);
  const entitlementRef = db.doc(`${ENTITLEMENTS_COLLECTION}/${uid}`);
  return db.runTransaction(async (tx) => {
    const userRef = db.doc(`users/${uid}`);
    const [deletedSnap, linkSnap, entitlementSnap, userSnap] = await Promise.all([
      tx.get(db.doc(`deletedAccounts/${uid}`)),
      tx.get(linkRef),
      tx.get(entitlementRef),
      tx.get(userRef),
    ]);
    const current = entitlementSnap.exists ? entitlementSnap.data() || {} : {};
    if (deletedSnap.exists || !linkSnap.exists ||
        !sameLinkIdentity(linkSnap.data() || {}, expectedLink)) {
      return { entitlement: current, linked: linkSnap.exists, applied: false };
    }
    if (entitlementSnap.exists && entitlementSnap.get('purgeLeaseId')) {
      return { entitlement: current, linked: true, applied: false };
    }
    if (valueMillis(entitlementSnap.exists && entitlementSnap.get('lastVerifiedAt')) >= nowMs ||
        (markChecked && valueMillis(linkSnap.get('lastCheckedAt')) >= nowMs)) {
      return { entitlement: current, linked: true, applied: false };
    }
    tx.set(entitlementRef, entitlement, { merge: true });
    if (userSnap.exists) tx.set(userRef, { entitlement }, { merge: true });
    if (markChecked) {
      tx.set(linkRef, {
        lastCheckedAt: toTimestamp(nowMs),
        lastKnownMemberState: memberActive ? 'active' : 'inactive',
        updatedAt: toTimestamp(nowMs),
      }, { merge: true });
    }
    return { entitlement, linked: true, applied: true };
  });
}

async function currentEntitlement(db, uid) {
  const snap = await db.doc(`${ENTITLEMENTS_COLLECTION}/${uid}`).get();
  return snap.exists ? snap.data() || {} : {};
}

async function resolveEntitlement({
  db,
  uid,
  authToken = {},
  api,
  hmacKey,
  nowMs = Date.now(),
  force = false,
  persist = true,
}) {
  const [entitlementSnap, linkSnap] = await Promise.all([
    db.doc(`${ENTITLEMENTS_COLLECTION}/${uid}`).get(),
    db.doc(`${LINKS_COLLECTION}/${uid}`).get(),
  ]);
  const previous = entitlementSnap.exists ? entitlementSnap.data() || {} : {};
  const link = linkSnap.exists ? linkSnap.data() || {} : null;
  let next;

  if (link) {
    const lastCheckMs = Math.max(
      valueMillis(link.lastCheckedAt),
      valueMillis(link.lastCheckAttemptAt)
    );
    if (!link.memberId) {
      next = inactiveTransition(previous, nowMs);
      const stored = await persistLinkedResult({
        db,
        uid,
        expectedLink: link,
        entitlement: next,
        nowMs,
        memberActive: false,
        markChecked: false,
      });
      return safeEntitlement(stored.entitlement, nowMs, stored.linked);
    } else if (!force &&
               nowMs - lastCheckMs < PATREON_REFRESH_COOLDOWN_MS) {
      return safeEntitlement(previous, nowMs, true);
    } else {
      const claim = await claimLinkedRefresh({ db, uid, nowMs, force });
      if (!claim.proceed) return safeEntitlement(claim.entitlement, nowMs, claim.linked);
      let member;
      try {
        member = await api.getMember(claim.link.memberId);
      } catch {
        next = errorTransition(claim.entitlement, nowMs);
        const stored = await persistLinkedResult({
          db,
          uid,
          expectedLink: claim.link,
          entitlement: next,
          nowMs,
          memberActive: false,
          markChecked: false,
        });
        return safeEntitlement(stored.entitlement, nowMs, stored.linked);
      }
      next = member && member.isActiveEligible
        ? activeEntitlement(nowMs)
        : inactiveTransition(claim.entitlement, nowMs);
      const stored = await persistLinkedResult({
        db,
        uid,
        expectedLink: claim.link,
        entitlement: next,
        nowMs,
        memberActive: Boolean(member && member.isActiveEligible),
        markChecked: true,
      });
      return safeEntitlement(stored.entitlement, nowMs, stored.linked);
    }
  } else {
    const normalizedEmail = typeof authToken.email === 'string'
      ? authToken.email.trim().toLowerCase()
      : '';
    const emailVerified = authToken.email_verified === true || authToken.email_verified === 'true';
    if (normalizedEmail && emailVerified) {
      const hash = emailIndex(hmacKey, normalizedEmail);
      const runtimeSnap = await db.doc(RUNTIME_PATH).get();
      const runtime = runtimeSnap.exists ? runtimeSnap.data() || {} : {};
      const indexSnap = runtime.currentSyncId
        ? await db.doc(`${EMAIL_INDEX_COLLECTION}/${snapshotIndexId(runtime.currentSyncId, hash)}`).get()
        : null;
      const indexed = indexSnap && indexSnap.exists ? indexSnap.data() || {} : {};
      // An old pointer is not current merely because its ID still matches. A
      // fresh Firebase UID must not bootstrap provisional access months after
      // campaign verification stopped.
      const snapshotVerifiedAt = valueMillis(runtime.lastCompletedAt);
      const indexVerifiedAt = valueMillis(indexed.lastVerifiedAt);
      const currentSnapshot = runtime.currentSyncId &&
        indexed.lastSyncId === runtime.currentSyncId &&
        snapshotVerifiedAt > 0 &&
        nowMs - snapshotVerifiedAt <= PATREON_GRACE_MS &&
        indexVerifiedAt > 0 &&
        nowMs - indexVerifiedAt <= PATREON_GRACE_MS;
      if (currentSnapshot && indexed.isActiveEligible === true) {
        next = provisionalEntitlement(previous, nowMs, valueMillis(runtime.lastCompletedAt));
      } else if (currentSnapshot && indexed.memberId) {
        next = inactiveTransition(previous, nowMs);
      } else {
        next = unlinkedEntitlement(previous, nowMs);
      }
    } else {
      next = unlinkedEntitlement(previous, nowMs);
    }
  }

  const stored = persist
    ? await persistEntitlement({
      db,
      uid,
      entitlement: next,
      nowMs,
      requireUnlinked: true,
    })
    : { entitlement: next, linked: Boolean(link) };
  return safeEntitlement(stored.entitlement, nowMs, stored.linked);
}

module.exports = {
  ENTITLEMENTS_COLLECTION,
  LINKS_COLLECTION,
  EMAIL_INDEX_COLLECTION,
  RUNTIME_PATH,
  valueMillis,
  isEffectiveAt,
  safeEntitlement,
  messageFor,
  activeEntitlement,
  inactiveTransition,
  errorTransition,
  provisionalEntitlement,
  unlinkedEntitlement,
  persistEntitlement,
  claimLinkedRefresh,
  sameLinkIdentity,
  persistLinkedResult,
  currentEntitlement,
  resolveEntitlement,
};
