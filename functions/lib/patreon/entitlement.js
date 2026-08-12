'use strict';

const { Timestamp } = require('firebase-admin/firestore');
const {
  PATREON_GRACE_MS,
  PATREON_EMAIL_VERIFICATION_MS,
  PATREON_RETENTION_MS,
  PATREON_REFRESH_COOLDOWN_MS,
} = require('../constants');
const { emailIndex, snapshotIndexId } = require('./crypto');
const { timestampMillis } = require('./tokenStore');

const ENTITLEMENTS_COLLECTION = 'patreonEntitlements';
const LINKS_COLLECTION = 'patreonLinks';
const EMAIL_INDEX_COLLECTION = 'patreonEmailIndex';
const OPERATOR_GRANTS_COLLECTION = 'syncOperatorGrants';
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
  const normalizedSource = ['patreon_email', 'patreon_oauth', 'operator'].includes(source.source)
    ? source.source
    : 'none';
  let connectionAction = 'none';
  if (!effective && state !== 'error') {
    connectionAction = linked ? 'switch' : 'connect';
  }
  const response = {
    state,
    effective,
    source: normalizedSource,
    connectionAction,
    // Kept for build-11 compatibility. New clients use connectionAction.
    linkRequired: connectionAction === 'connect',
    message: messageFor(state, normalizedSource),
  };
  const graceExpiresAt = valueMillis(source.graceExpiresAt);
  const lastVerifiedAt = valueMillis(source.lastVerifiedAt);
  const verificationExpiresAt = valueMillis(source.verificationExpiresAt);
  if (graceExpiresAt > 0) response.graceExpiresAt = graceExpiresAt;
  if (lastVerifiedAt > 0) response.lastVerifiedAt = lastVerifiedAt;
  if (verificationExpiresAt > 0) response.verificationExpiresAt = verificationExpiresAt;
  return response;
}

function messageFor(state, source) {
  switch (state) {
    case 'active':
      return source === 'operator'
        ? 'Cloud Sync access is verified.'
        : source === 'patreon_email'
          ? 'Patreon access is verified with your signed-in email.'
          : 'Patreon is connected and Cloud Sync is on.';
    case 'grace':
      return 'Cloud Sync is temporarily available during the Patreon grace period.';
    case 'inactive':
      return 'An active Patreon membership is required for Cloud Sync.';
    case 'error':
      return 'Patreon verification is temporarily unavailable. Try again later.';
    case 'unlinked':
    default:
      return 'Connect Patreon to use Cloud Sync.';
  }
}

function activeEntitlement(nowMs, source = 'patreon_oauth', verifiedAtMs = nowMs, proof = {}) {
  const verifiedMs = Number.isFinite(verifiedAtMs) && verifiedAtMs > 0 ? verifiedAtMs : nowMs;
  return {
    ...proof,
    emailHash: source === 'patreon_email' ? proof.emailHash || null : null,
    state: 'active',
    effective: true,
    source,
    lastVerifiedAt: toTimestamp(verifiedMs),
    // This is also the maximum fail-open duration if every scheduled check and
    // webhook stops running. Successful direct verification rolls it forward.
    verificationExpiresAt: toTimestamp(verifiedMs + PATREON_GRACE_MS),
    graceExpiresAt: null,
    provisionalExpiresAt: null,
    inactiveSince: null,
    retentionExpiresAt: null,
    cloudDataPurgedAt: null,
    updatedAt: toTimestamp(nowMs),
  };
}

function inactiveTransition(previous, nowMs, source = 'patreon_oauth', proof = {}) {
  const prior = previous || {};
  if (prior.source === source && isEffectiveAt(prior, nowMs)) {
    const existingExpiry = valueMillis(prior.graceExpiresAt);
    const inactiveSince = valueMillis(prior.inactiveSince) || nowMs;
    const graceExpiresAt = existingExpiry > nowMs ? existingExpiry : nowMs + PATREON_GRACE_MS;
    return {
      ...prior,
      ...proof,
      emailHash: source === 'patreon_email'
        ? proof.emailHash || prior.emailHash || null
        : null,
      state: 'grace',
      effective: true,
      source,
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
    ...proof,
    emailHash: source === 'patreon_email'
      ? proof.emailHash || prior.emailHash || null
      : null,
    state: 'inactive',
    effective: false,
    source,
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
    const absoluteVerificationExpiry = valueMillis(prior.verificationExpiresAt);
    const expiry = absoluteVerificationExpiry > 0
      ? absoluteVerificationExpiry
      : (verified > 0 ? verified + PATREON_GRACE_MS : 0);
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

function verifiedEmailEntitlement(nowMs, snapshotVerifiedMs, emailHash) {
  return activeEntitlement(
    nowMs,
    'patreon_email',
    snapshotVerifiedMs,
    { emailHash: emailHash || null }
  );
}

function operatorEntitlement(nowMs, grantExpiresMs) {
  const verificationExpiresMs = Math.min(grantExpiresMs, nowMs + PATREON_GRACE_MS);
  return {
    emailHash: null,
    state: 'active',
    effective: true,
    source: 'operator',
    lastVerifiedAt: toTimestamp(nowMs),
    verificationExpiresAt: toTimestamp(verificationExpiresMs),
    graceExpiresAt: null,
    provisionalExpiresAt: null,
    inactiveSince: null,
    retentionExpiresAt: null,
    cloudDataPurgedAt: null,
    updatedAt: toTimestamp(nowMs),
  };
}

function expiredOperatorTransition(previous, nowMs) {
  const prior = previous || {};
  const inactiveSince = valueMillis(prior.inactiveSince) || nowMs;
  return {
    ...prior,
    emailHash: null,
    state: 'inactive',
    effective: false,
    source: 'operator',
    verificationExpiresAt: null,
    graceExpiresAt: null,
    provisionalExpiresAt: null,
    inactiveSince: toTimestamp(inactiveSince),
    retentionExpiresAt: toTimestamp(inactiveSince + PATREON_RETENTION_MS),
    updatedAt: toTimestamp(nowMs),
  };
}

function emailLossTransition(previous, nowMs, emailHash, verifiedAtMs = nowMs) {
  // A completed campaign snapshot with no exact hash match is conclusive. It
  // is not an outage and must not mint a new grace window at client refresh
  // time. Grace is reserved for a previously bound hash whose campaign
  // snapshot is temporarily unavailable.
  return unlinkedEntitlement(previous, nowMs, emailHash, verifiedAtMs);
}

function unlinkedEntitlement(previous, nowMs, emailHash, verifiedAtMs = nowMs) {
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
    emailHash: emailHash || null,
    lastVerifiedAt: toTimestamp(verifiedAtMs),
    verificationExpiresAt: null,
    graceExpiresAt: null,
    provisionalExpiresAt: null,
    inactiveSince: inactiveSince ? toTimestamp(inactiveSince) : prior.inactiveSince || null,
    retentionExpiresAt: inactiveSince
      ? toTimestamp(inactiveSince + PATREON_RETENTION_MS)
      : prior.retentionExpiresAt || null,
    updatedAt: toTimestamp(nowMs),
  };
}

function preferEntitlement(current, candidate, nowMs = Date.now()) {
  const prior = current || {};
  const next = candidate || {};
  // An explicit operator grant is independent of Patreon and must not be
  // downgraded by a concurrent campaign scan, webhook, or OAuth refresh.
  // Its absolute deadline still fails closed if the grant is never checked.
  if (prior.source === 'operator' && isEffectiveAt(prior, nowMs) &&
      !(next.source === 'operator' && next.state === 'active' && isEffectiveAt(next, nowMs))) {
    return prior;
  }
  // Email and OAuth are independent proofs. A failed linked-account refresh
  // must not suppress a still-valid verified-email entitlement.
  if (prior.source === 'patreon_email' && next.source === 'patreon_oauth' &&
      isEffectiveAt(prior, nowMs) &&
      !isEffectiveAt(next, nowMs)) {
    return prior;
  }
  return next;
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
    const sameProof = current.source === entitlement.source &&
      (current.source !== 'patreon_email' ||
       (current.emailHash && current.emailHash === entitlement.emailHash));
    if (currentSnap.exists && sameProof &&
        valueMillis(currentSnap.get('lastVerifiedAt')) > valueMillis(entitlement.lastVerifiedAt)) {
      return { entitlement: current, linked: linkSnap.exists };
    }
    const selected = preferEntitlement(current, entitlement, nowMs);
    tx.set(entitlementRef, selected, { merge: true });
    if (userSnap.exists) tx.set(userRef, { entitlement: selected }, { merge: true });
    return { entitlement: selected, linked: linkSnap.exists };
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
    const sameSource = current.source === entitlement.source;
    if ((sameSource &&
         valueMillis(entitlementSnap.exists && entitlementSnap.get('lastVerifiedAt')) >= nowMs) ||
        (markChecked && valueMillis(linkSnap.get('lastCheckedAt')) >= nowMs)) {
      return { entitlement: current, linked: true, applied: false };
    }
    const selected = preferEntitlement(current, entitlement, nowMs);
    tx.set(entitlementRef, selected, { merge: true });
    if (userSnap.exists) tx.set(userRef, { entitlement: selected }, { merge: true });
    if (markChecked) {
      tx.set(linkRef, {
        lastCheckedAt: toTimestamp(nowMs),
        lastKnownMemberState: memberActive ? 'active' : 'inactive',
        updatedAt: toTimestamp(nowMs),
      }, { merge: true });
    }
    return { entitlement: selected, linked: true, applied: true };
  });
}

async function currentEntitlement(db, uid) {
  const snap = await db.doc(`${ENTITLEMENTS_COLLECTION}/${uid}`).get();
  return snap.exists ? snap.data() || {} : {};
}

function operatorGrantExpiry(grant, nowMs) {
  const source = grant || {};
  const reason = typeof source.reason === 'string' ? source.reason.trim() : '';
  const expiresAt = valueMillis(source.expiresAt);
  return source.enabled === true && reason && expiresAt > nowMs ? expiresAt : 0;
}

/**
 * Re-read the private grant in the same transaction that mints (or revokes)
 * its rules-facing entitlement. Disabling a grant therefore cannot race a
 * final seven-day renewal.
 */
async function persistOperatorProof({ db, uid, nowMs }) {
  const grantRef = db.doc(`${OPERATOR_GRANTS_COLLECTION}/${uid}`);
  const entitlementRef = db.doc(`${ENTITLEMENTS_COLLECTION}/${uid}`);
  const userRef = db.doc(`users/${uid}`);
  const linkRef = db.doc(`${LINKS_COLLECTION}/${uid}`);
  return db.runTransaction(async (tx) => {
    const [grantSnap, entitlementSnap, userSnap, linkSnap, deletedSnap] = await Promise.all([
      tx.get(grantRef),
      tx.get(entitlementRef),
      tx.get(userRef),
      tx.get(linkRef),
      tx.get(db.doc(`deletedAccounts/${uid}`)),
    ]);
    const current = entitlementSnap.exists ? entitlementSnap.data() || {} : {};
    const linked = linkSnap.exists;
    if (deletedSnap.exists) return { valid: false, entitlement: current, linked };

    const grantExpiry = operatorGrantExpiry(grantSnap.exists ? grantSnap.data() : null, nowMs);
    if (grantExpiry > 0) {
      if (entitlementSnap.exists && entitlementSnap.get('purgeLeaseId')) {
        throw new Error('Cloud library retention purge is in progress.');
      }
      const entitlement = operatorEntitlement(nowMs, grantExpiry);
      tx.set(entitlementRef, entitlement, { merge: true });
      if (userSnap.exists) tx.set(userRef, { entitlement }, { merge: true });
      return { valid: true, entitlement, linked };
    }

    if (current.source === 'operator') {
      const entitlement = expiredOperatorTransition(current, nowMs);
      tx.set(entitlementRef, entitlement, { merge: true });
      if (userSnap.exists) tx.set(userRef, { entitlement }, { merge: true });
      return { valid: false, entitlement, linked };
    }
    return { valid: false, entitlement: current, linked };
  });
}

async function resolveEmailProof({ db, authToken, hmacKey, previous, nowMs }) {
  const normalizedEmail = typeof authToken.email === 'string'
    ? authToken.email.trim().toLowerCase()
    : '';
  const emailVerified = authToken.email_verified === true || authToken.email_verified === 'true';
  if (!normalizedEmail || !emailVerified) {
    if (previous.source !== 'patreon_email') {
      return { kind: 'none', entitlement: null };
    }
    // A Firebase email proof cannot survive removal of the verified email
    // claim. A separately linked Patreon identity is evaluated below.
    return {
      kind: 'invalid',
      entitlement: unlinkedEntitlement(previous, nowMs, '', nowMs),
      hash: '',
    };
  }

  const hash = emailIndex(hmacKey, normalizedEmail);
  const runtimeSnap = await db.doc(RUNTIME_PATH).get();
  const runtime = runtimeSnap.exists ? runtimeSnap.data() || {} : {};
  const snapshotVerifiedAt = valueMillis(runtime.lastCompletedAt);
  const runtimeFresh = Boolean(
    runtime.currentSyncId &&
    snapshotVerifiedAt > 0 &&
    nowMs - snapshotVerifiedAt <= PATREON_EMAIL_VERIFICATION_MS
  );
  if (!runtimeFresh) {
    const priorSameEmail = previous.source === 'patreon_email' &&
      previous.emailHash === hash;
    const unavailable = priorSameEmail
      ? errorTransition(previous, nowMs)
      : {
        ...unlinkedEntitlement(previous, nowMs, hash, nowMs),
        state: 'error',
        updatedAt: toTimestamp(nowMs),
      };
    return { kind: 'unavailable', entitlement: unavailable, hash };
  }

  const indexSnap = await db.doc(
    `${EMAIL_INDEX_COLLECTION}/${snapshotIndexId(runtime.currentSyncId, hash)}`
  ).get();
  const indexed = indexSnap.exists ? indexSnap.data() || {} : {};
  const indexVerifiedAt = valueMillis(indexed.lastVerifiedAt);
  if (indexSnap.exists &&
      (indexed.lastSyncId !== runtime.currentSyncId ||
       indexVerifiedAt <= 0 ||
       nowMs - indexVerifiedAt > PATREON_EMAIL_VERIFICATION_MS)) {
    const priorSameEmail = previous.source === 'patreon_email' &&
      previous.emailHash === hash;
    return {
      kind: 'unavailable',
      entitlement: priorSameEmail
        ? errorTransition(previous, nowMs)
        : {
          ...unlinkedEntitlement(previous, nowMs, hash, nowMs),
          state: 'error',
          updatedAt: toTimestamp(nowMs),
        },
      hash,
    };
  }
  if (indexSnap.exists && indexed.isActiveEligible === true) {
    const verifiedAt = Math.min(snapshotVerifiedAt, indexVerifiedAt || snapshotVerifiedAt);
    return {
      kind: 'active',
      entitlement: verifiedEmailEntitlement(nowMs, verifiedAt, hash),
      hash,
    };
  }
  return {
    kind: 'mismatch',
    entitlement: emailLossTransition(previous, nowMs, hash, snapshotVerifiedAt),
    hash,
  };
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
  const [entitlementSnap, linkSnap, grantSnap] = await Promise.all([
    db.doc(`${ENTITLEMENTS_COLLECTION}/${uid}`).get(),
    db.doc(`${LINKS_COLLECTION}/${uid}`).get(),
    db.doc(`${OPERATOR_GRANTS_COLLECTION}/${uid}`).get(),
  ]);
  let previous = entitlementSnap.exists ? entitlementSnap.data() || {} : {};
  let link = linkSnap.exists ? linkSnap.data() || {} : null;
  const grantExpiry = operatorGrantExpiry(grantSnap.exists ? grantSnap.data() : null, nowMs);
  if (grantExpiry > 0 || previous.source === 'operator') {
    const stored = persist
      ? await persistOperatorProof({ db, uid, nowMs })
      : {
        valid: grantExpiry > 0,
        entitlement: grantExpiry > 0
          ? operatorEntitlement(nowMs, grantExpiry)
          : expiredOperatorTransition(previous, nowMs),
        linked: Boolean(link),
      };
    if (stored.valid) return safeEntitlement(stored.entitlement, nowMs, stored.linked);
    previous = stored.entitlement;
    if (!stored.linked) link = null;
  }
  const emailProof = await resolveEmailProof({
    db,
    authToken,
    hmacKey,
    previous,
    nowMs,
  });
  let baseline = previous;
  let next;

  // A verified email match is a complete Patreon proof. It is deliberately
  // evaluated even when a stale/inactive OAuth link exists, so the two proofs
  // behave as an OR rather than allowing a bad link to suppress valid access.
  if (emailProof.kind === 'active') {
    const stored = persist
      ? await persistEntitlement({
        db,
        uid,
        entitlement: emailProof.entitlement,
        nowMs,
        requireUnlinked: false,
      })
      : { entitlement: emailProof.entitlement, linked: Boolean(link) };
    return safeEntitlement(stored.entitlement, nowMs, stored.linked);
  }

  if (link && previous.source === 'patreon_email' && emailProof.entitlement) {
    const storedEmailTransition = persist
      ? await persistEntitlement({
        db,
        uid,
        entitlement: emailProof.entitlement,
        nowMs,
        requireUnlinked: false,
      })
      : { entitlement: emailProof.entitlement };
    baseline = storedEmailTransition.entitlement;
  }

  if (link && link.memberId) {
    const lastCheckMs = Math.max(
      valueMillis(link.lastCheckedAt),
      valueMillis(link.lastCheckAttemptAt)
    );
    // An email proof can overwrite the single public entitlement document
    // while an OAuth link remains valid. If that email proof is later lost,
    // bypass a prior successful-check cooldown once so the independent OAuth
    // proof is evaluated instead of being accidentally suppressed.
    const forceLinkedProof = force || previous.source === 'patreon_email';
    if (!forceLinkedProof &&
               nowMs - lastCheckMs < PATREON_REFRESH_COOLDOWN_MS) {
      return safeEntitlement(baseline, nowMs, true);
    } else {
      const claim = await claimLinkedRefresh({
        db,
        uid,
        nowMs,
        force: forceLinkedProof,
      });
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
    if (emailProof.entitlement) {
      next = emailProof.entitlement;
    } else if (link) {
      next = preferEntitlement(previous, inactiveTransition(previous, nowMs), nowMs);
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
      requireUnlinked: !link,
    })
    : { entitlement: next, linked: Boolean(link) };
  return safeEntitlement(stored.entitlement, nowMs, stored.linked);
}

module.exports = {
  ENTITLEMENTS_COLLECTION,
  LINKS_COLLECTION,
  EMAIL_INDEX_COLLECTION,
  OPERATOR_GRANTS_COLLECTION,
  RUNTIME_PATH,
  valueMillis,
  isEffectiveAt,
  safeEntitlement,
  messageFor,
  activeEntitlement,
  inactiveTransition,
  errorTransition,
  verifiedEmailEntitlement,
  operatorEntitlement,
  expiredOperatorTransition,
  emailLossTransition,
  unlinkedEntitlement,
  preferEntitlement,
  persistEntitlement,
  claimLinkedRefresh,
  sameLinkIdentity,
  persistLinkedResult,
  currentEntitlement,
  operatorGrantExpiry,
  persistOperatorProof,
  resolveEmailProof,
  resolveEntitlement,
};
