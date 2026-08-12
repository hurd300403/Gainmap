'use strict';

const crypto = require('node:crypto');
const { Timestamp } = require('firebase-admin/firestore');
const {
  PATREON_INDEX_TTL_MS,
} = require('../constants');
const {
  emailIndex,
  subjectIndex,
  memberIndex,
  snapshotIndexId,
} = require('./crypto');
const {
  ENTITLEMENTS_COLLECTION,
  LINKS_COLLECTION,
  EMAIL_INDEX_COLLECTION,
  RUNTIME_PATH,
  activeEntitlement,
  inactiveTransition,
  errorTransition,
  preferEntitlement,
  valueMillis,
} = require('./entitlement');
const {
  SUBJECT_INDEX_COLLECTION,
  MEMBER_INDEX_COLLECTION,
} = require('./oauth');

const MEMBER_SNAPSHOTS_COLLECTION = 'patreonMemberSnapshots';
const CAMPAIGN_SYNC_LEASE_MS = 11 * 60 * 1000;

async function claimCampaignSync({ db, syncId, nowMs }) {
  const ref = db.doc(RUNTIME_PATH);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data = snap.exists ? snap.data() || {} : {};
    const leaseUntil = valueMillis(data.syncLeaseUntil);
    if (data.syncLeaseId && data.syncLeaseId !== syncId && leaseUntil > nowMs) {
      const error = new Error('A Patreon campaign sync is already in progress.');
      error.code = 'sync_in_progress';
      throw error;
    }
    tx.set(ref, {
      syncLeaseId: syncId,
      syncLeaseUntil: Timestamp.fromMillis(nowMs + CAMPAIGN_SYNC_LEASE_MS),
      syncStartedAt: Timestamp.fromMillis(nowMs),
    }, { merge: true });
    return data;
  });
}

async function releaseCampaignSync({ db, syncId, nowMs }) {
  const ref = db.doc(RUNTIME_PATH);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists || snap.get('syncLeaseId') !== syncId) return;
    tx.set(ref, {
      syncLeaseId: null,
      syncLeaseUntil: null,
      syncFinishedAt: Timestamp.fromMillis(nowMs),
    }, { merge: true });
  });
}

async function commitSets(db, writes, chunkSize = 400) {
  for (let offset = 0; offset < writes.length; offset += chunkSize) {
    const batch = db.batch();
    for (const write of writes.slice(offset, offset + chunkSize)) {
      batch.set(write.ref, write.data, { merge: write.merge !== false });
    }
    await batch.commit();
  }
}

function preferMember(existing, candidate) {
  if (!existing) return candidate;
  if (!candidate) return existing;
  if (candidate.isActiveEligible && !existing.isActiveEligible) return candidate;
  return existing;
}

/**
 * Full campaign reconciliation. No Firestore state changes until every Patreon
 * page has been fetched successfully. Email lookups require the runtime's
 * `currentSyncId`, so partially-written snapshots can never grant access.
 */
async function syncCampaignWithLease({ db, api, hmacKey, nowMs, id, priorRuntime }) {
  const members = await api.getAllCampaignMembers();
  const priorCount = Number(priorRuntime && priorRuntime.memberCount) || 0;
  if (members.length === 0 ||
      (priorCount > 0 && members.length < Math.floor(priorCount * 0.8))) {
    // A suddenly empty but nominally successful page is much more likely to be
    // an upstream/scoping anomaly than every campaign member disappearing at
    // once. Treat it as unavailable; never mass-revoke on that response.
    const error = new Error('Patreon campaign returned a suspiciously incomplete census.');
    error.code = 'suspicious_incomplete_campaign';
    throw error;
  }
  const verifiedAt = Timestamp.fromMillis(nowMs);
  const expiresAt = Timestamp.fromMillis(nowMs + PATREON_INDEX_TTL_MS);
  const byEmailHash = new Map();
  const byMemberId = new Map();
  const bySubjectHash = new Map();

  for (const member of members) {
    byMemberId.set(member.memberId, preferMember(byMemberId.get(member.memberId), member));
    if (member.subjectId) {
      const hash = subjectIndex(hmacKey, member.subjectId);
      bySubjectHash.set(hash, preferMember(bySubjectHash.get(hash), member));
    }
    // Verified email is a complete proof only for currently eligible patrons.
    // Do not retain campaign-wide hashes for free/former members; linked
    // inactive users are reconciled through their link.
    if (member.isActiveEligible && member.email) {
      const hash = emailIndex(hmacKey, member.email);
      byEmailHash.set(hash, preferMember(byEmailHash.get(hash), member));
    }
  }

  const indexWrites = [];
  for (const [hash, member] of byEmailHash) {
    const mHash = memberIndex(hmacKey, member.memberId);
    indexWrites.push({
      ref: db.doc(`${EMAIL_INDEX_COLLECTION}/${snapshotIndexId(id, hash)}`),
      data: {
        memberId: member.memberId,
        memberHash: mHash,
        isActiveEligible: member.isActiveEligible,
        lastSyncId: id,
        lastVerifiedAt: verifiedAt,
        expiresAt,
      },
    });
  }
  // Keep each member's current email hash, including duplicate-email
  // memberships. Webhook reconciliation uses this to invalidate the prior hash
  // immediately when Patreon reports an address change.
  for (const member of members) {
    if (!member.isActiveEligible || !member.email) continue;
    const mHash = memberIndex(hmacKey, member.memberId);
    indexWrites.push({
      ref: db.doc(`${MEMBER_SNAPSHOTS_COLLECTION}/${snapshotIndexId(id, mHash)}`),
      data: {
        emailHash: emailIndex(hmacKey, member.email),
        lastSyncId: id,
        lastVerifiedAt: verifiedAt,
        expiresAt,
      },
    });
  }
  await commitSets(db, indexWrites);

  // Publishing the pointer is the atomic snapshot boundary. Old email-index
  // documents remain harmless because their lastSyncId no longer matches.
  await db.runTransaction(async (tx) => {
    const runtime = await tx.get(db.doc(RUNTIME_PATH));
    if (!runtime.exists || runtime.get('syncLeaseId') !== id) {
      const error = new Error('Patreon campaign sync lease was lost before publish.');
      error.code = 'sync_lease_lost';
      throw error;
    }
    if (valueMillis(runtime.get('lastCompletedAt')) > nowMs) {
      const error = new Error('A newer Patreon campaign snapshot is already published.');
      error.code = 'stale_campaign_sync';
      throw error;
    }
    tx.set(db.doc(RUNTIME_PATH), {
      currentSyncId: id,
      lastCompletedAt: verifiedAt,
      memberCount: members.length,
      activeMemberCount: members.filter((member) => member.isActiveEligible).length,
    }, { merge: true });
  });

  const [linksSnap, entitlementsSnap] = await Promise.all([
    db.collection(LINKS_COLLECTION).get(),
    db.collection(ENTITLEMENTS_COLLECTION).get(),
  ]);
  const entitlements = new Map(entitlementsSnap.docs.map((doc) => [doc.id, doc.data() || {}]));
  let linkedActive = 0;
  let linkedGraceOrInactive = 0;

  for (const linkDoc of linksSnap.docs) {
    const uid = linkDoc.id;
    const link = linkDoc.data() || {};
    // eslint-disable-next-line no-await-in-loop
    const deletedSnap = await db.doc(`deletedAccounts/${uid}`).get();
    if (deletedSnap.exists) continue;
    // Patreon can issue a new member resource when the same patron leaves and
    // later rejoins. Prefer the active record for the linked subject instead
    // of letting an older inactive member ID force an unnecessary downgrade.
    const member = preferMember(
      byMemberId.get(link.memberId),
      bySubjectHash.get(link.subjectHash)
    ) || null;
    // The outer entitlement and rules-facing mirror are one atomic unit. A
    // partial batch failure must never let callable state disagree with rules.
    // Link freshness and the member uniqueness index are committed with that
    // same unit, so an older full scan cannot follow a newer webhook.
    const mHash = member ? memberIndex(hmacKey, member.memberId) : '';
    const memberRef = mHash ? db.doc(`${MEMBER_INDEX_COLLECTION}/${mHash}`) : null;
    const oldMemberRef = mHash && link.memberHash && link.memberHash !== mHash
      ? db.doc(`${MEMBER_INDEX_COLLECTION}/${link.memberHash}`)
      : null;
    // eslint-disable-next-line no-await-in-loop
    const entitlement = await db.runTransaction(async (tx) => {
      const [deleted, user, current, currentLink, indexedMember, oldIndexedMember] = await Promise.all([
        tx.get(db.doc(`deletedAccounts/${uid}`)),
        tx.get(db.doc(`users/${uid}`)),
        tx.get(db.doc(`${ENTITLEMENTS_COLLECTION}/${uid}`)),
        tx.get(db.doc(`${LINKS_COLLECTION}/${uid}`)),
        memberRef ? tx.get(memberRef) : Promise.resolve(null),
        oldMemberRef ? tx.get(oldMemberRef) : Promise.resolve(null),
      ]);
      if (deleted.exists || !currentLink.exists) return null;
      if (current.exists && current.get('purgeLeaseId')) return null;
      // A link may be replaced while a scan is in flight. Never let a result
      // selected from the outer snapshot restore the old Patreon identity.
      if (currentLink.get('memberId') !== link.memberId ||
          currentLink.get('memberHash') !== link.memberHash ||
          currentLink.get('subjectHash') !== link.subjectHash) return null;
      if (current.exists && valueMillis(current.get('lastVerifiedAt')) >= nowMs) {
        return current.data() || null;
      }
      if (valueMillis(currentLink.get('lastCheckedAt')) >= nowMs) {
        return current.exists ? current.data() || null : null;
      }
      if (indexedMember && indexedMember.exists && indexedMember.get('uid') !== uid) return null;
      const prior = current.exists ? current.data() || {} : entitlements.get(uid) || {};
      const linkedCandidate = member && member.isActiveEligible
        ? activeEntitlement(nowMs)
        : inactiveTransition(prior, nowMs);
      const next = preferEntitlement(prior, linkedCandidate, nowMs);
      tx.set(db.doc(`${ENTITLEMENTS_COLLECTION}/${uid}`), next, { merge: true });
      if (user.exists) tx.set(db.doc(`users/${uid}`), { entitlement: next }, { merge: true });
      tx.set(db.doc(`${LINKS_COLLECTION}/${uid}`), {
        lastCheckedAt: verifiedAt,
        lastKnownMemberState: member && member.isActiveEligible ? 'active' : 'inactive',
        updatedAt: verifiedAt,
        ...(member ? {
          memberId: member.memberId,
          memberHash: mHash,
        } : {}),
      }, { merge: true });
      if (memberRef) tx.set(memberRef, { uid, updatedAt: verifiedAt }, { merge: true });
      if (oldIndexedMember && oldIndexedMember.exists && oldIndexedMember.get('uid') === uid) {
        tx.delete(oldMemberRef);
      }
      return next;
    });
    if (!entitlement) continue;
    if (entitlement.state === 'active') linkedActive += 1;
    else linkedGraceOrInactive += 1;
  }

  return {
    syncId: id,
    memberCount: members.length,
    activeMemberCount: members.filter((member) => member.isActiveEligible).length,
    linkedActive,
    linkedGraceOrInactive,
  };
}

async function syncCampaignCore({ db, api, hmacKey, nowMs = Date.now(), syncId }) {
  const id = syncId || `${nowMs}-${crypto.randomUUID()}`;
  const priorRuntime = await claimCampaignSync({ db, syncId: id, nowMs });
  try {
    return await syncCampaignWithLease({ db, api, hmacKey, nowMs, id, priorRuntime });
  } finally {
    await releaseCampaignSync({ db, syncId: id, nowMs: Date.now() }).catch(() => {});
  }
}

async function markCampaignUnavailableCore({ db, nowMs = Date.now() }) {
  const [linksSnap, entitlementsSnap] = await Promise.all([
    db.collection(LINKS_COLLECTION).get(),
    db.collection(ENTITLEMENTS_COLLECTION).get(),
  ]);
  const linkedUIDs = new Set(linksSnap.docs.map((doc) => doc.id));
  for (const doc of entitlementsSnap.docs) {
    if (!linkedUIDs.has(doc.id)) continue;
    const entitlement = errorTransition(doc.data() || {}, nowMs);
    // eslint-disable-next-line no-await-in-loop
    await db.runTransaction(async (tx) => {
      const [deleted, user, current] = await Promise.all([
        tx.get(db.doc(`deletedAccounts/${doc.id}`)),
        tx.get(db.doc(`users/${doc.id}`)),
        tx.get(doc.ref),
      ]);
      if (deleted.exists) return;
      if (current.exists && current.get('purgeLeaseId')) return;
      if (current.exists && valueMillis(current.get('lastVerifiedAt')) > nowMs) return;
      tx.set(doc.ref, entitlement, { merge: true });
      if (user.exists) tx.set(user.ref, { entitlement }, { merge: true });
    });
  }
  return { linkedUsers: linkedUIDs.size };
}

async function reconcileMemberCore({ db, api, hmacKey, memberId, nowMs = Date.now() }) {
  const mHash = memberIndex(hmacKey, memberId);
  const [member, memberIndexSnap] = await Promise.all([
    api.getMember(memberId),
    db.doc(`${MEMBER_INDEX_COLLECTION}/${mHash}`).get(),
  ]);
  if (member && member.memberId !== String(memberId)) {
    const error = new Error('Patreon returned a different member than requested.');
    error.code = 'invalid_member_schema';
    throw error;
  }
  let uid = memberIndexSnap.exists ? memberIndexSnap.get('uid') : '';
  let resolvedBySubject = false;
  let resolvedSubjectHash = '';

  if (member && member.subjectId && !uid) {
    resolvedSubjectHash = subjectIndex(hmacKey, member.subjectId);
    const subjectSnap = await db.doc(`${SUBJECT_INDEX_COLLECTION}/${resolvedSubjectHash}`).get();
    uid = subjectSnap.exists ? subjectSnap.get('uid') : '';
    resolvedBySubject = Boolean(uid);
  }

  // A subject can legitimately acquire a new Patreon member ID after
  // leaving/rejoining. Before allowing that fallback to migrate the link,
  // compare both records with the creator credential. Keeping the current
  // record on an eligibility tie prevents a delayed webhook for an old member
  // from stealing the link back; an active replacement can still supersede an
  // inactive or deleted record.
  let expectedSubjectLink = null;
  let oldMemberRef = null;
  if (resolvedBySubject) {
    const expectedLinkSnap = await db.doc(`${LINKS_COLLECTION}/${uid}`).get();
    if (!expectedLinkSnap.exists ||
        expectedLinkSnap.get('subjectHash') !== resolvedSubjectHash) {
      return { reconciled: false, linked: false, active: false };
    }
    expectedSubjectLink = {
      memberId: expectedLinkSnap.get('memberId') || '',
      memberHash: expectedLinkSnap.get('memberHash') || '',
      subjectHash: expectedLinkSnap.get('subjectHash') || '',
    };
    if (expectedSubjectLink.memberHash && expectedSubjectLink.memberHash !== mHash) {
      const currentMember = expectedSubjectLink.memberId
        ? await api.getMember(expectedSubjectLink.memberId)
        : null;
      if (currentMember &&
          (currentMember.memberId !== expectedSubjectLink.memberId ||
           currentMember.subjectId !== member.subjectId)) {
        return { reconciled: false, linked: true, active: false };
      }
      if (preferMember(currentMember, member) !== member) {
        return {
          reconciled: false,
          linked: true,
          active: Boolean(currentMember && currentMember.isActiveEligible),
        };
      }
      oldMemberRef = db.doc(`${MEMBER_INDEX_COLLECTION}/${expectedSubjectLink.memberHash}`);
    }
  }

  const verifiedAt = Timestamp.fromMillis(nowMs);
  const runtimeRef = db.doc(RUNTIME_PATH);
  const nextEmailHash = member && member.isActiveEligible && member.email
    ? emailIndex(hmacKey, member.email)
    : '';

  if (!uid) {
    // No Gainmap UID is involved, but the old/new email index still changes as
    // one transaction so a Patreon address change never makes both addresses
    // current. Only active-eligible patrons are indexed.
    await db.runTransaction(async (tx) => {
      const runtimeSnap = await tx.get(runtimeRef);
      const currentSyncId = runtimeSnap.exists ? runtimeSnap.get('currentSyncId') : '';
      if (!currentSyncId) return;
      const snapshotRef = db.doc(
        `${MEMBER_SNAPSHOTS_COLLECTION}/${snapshotIndexId(currentSyncId, mHash)}`
      );
      const snapshotSnap = await tx.get(snapshotRef);
      if (runtimeSnap.get('syncLeaseId') &&
          valueMillis(runtimeSnap.get('syncLeaseUntil')) > nowMs) {
        const error = new Error('Campaign snapshot publish is in progress.');
        error.code = 'sync_in_progress';
        throw error;
      }
      const priorEmailHash = snapshotSnap.exists ? snapshotSnap.get('emailHash') : '';
      const priorEmailRef = priorEmailHash
        ? db.doc(`${EMAIL_INDEX_COLLECTION}/${snapshotIndexId(currentSyncId, priorEmailHash)}`)
        : null;
      const nextEmailRef = nextEmailHash
        ? db.doc(`${EMAIL_INDEX_COLLECTION}/${snapshotIndexId(currentSyncId, nextEmailHash)}`)
        : null;
      const [priorEmailSnap, nextEmailSnap] = await Promise.all([
        priorEmailRef ? tx.get(priorEmailRef) : Promise.resolve(null),
        nextEmailRef && (!priorEmailRef || nextEmailRef.path !== priorEmailRef.path)
          ? tx.get(nextEmailRef) : Promise.resolve(null),
      ]);
      if (valueMillis(snapshotSnap.exists && snapshotSnap.get('lastVerifiedAt')) > nowMs ||
          valueMillis(priorEmailSnap && priorEmailSnap.exists && priorEmailSnap.get('lastVerifiedAt')) > nowMs ||
          valueMillis(nextEmailSnap && nextEmailSnap.exists && nextEmailSnap.get('lastVerifiedAt')) > nowMs) return;
      // If a newer full census was published after this webhook began, do not
      // attach the older result to its snapshot.
      if (valueMillis(runtimeSnap.get('lastCompletedAt')) > nowMs) return;
      if (priorEmailRef && priorEmailHash !== nextEmailHash) {
        tx.delete(priorEmailRef);
      }
      if (nextEmailRef) {
        tx.set(nextEmailRef, {
          memberId: member.memberId,
          memberHash: mHash,
          isActiveEligible: true,
          lastSyncId: currentSyncId,
          lastVerifiedAt: verifiedAt,
          expiresAt: Timestamp.fromMillis(nowMs + PATREON_INDEX_TTL_MS),
        }, { merge: true });
        tx.set(snapshotRef, {
          emailHash: nextEmailHash,
          lastSyncId: currentSyncId,
          lastVerifiedAt: verifiedAt,
          expiresAt: Timestamp.fromMillis(nowMs + PATREON_INDEX_TTL_MS),
        }, { merge: true });
      } else if (snapshotSnap.exists) {
        tx.delete(snapshotRef);
      }
    });
    return { reconciled: false, linked: false, active: Boolean(member && member.isActiveEligible) };
  }

  const transactionResult = await db.runTransaction(async (tx) => {
    const entitlementRef = db.doc(`${ENTITLEMENTS_COLLECTION}/${uid}`);
    const userRef = db.doc(`users/${uid}`);
    const linkRef = db.doc(`${LINKS_COLLECTION}/${uid}`);
    const memberRef = db.doc(`${MEMBER_INDEX_COLLECTION}/${mHash}`);
    const [deleted, user, current, currentLink, memberIndexCurrent, oldMemberIndex, runtimeSnap] =
      await Promise.all([
        tx.get(db.doc(`deletedAccounts/${uid}`)),
        tx.get(userRef),
        tx.get(entitlementRef),
        tx.get(linkRef),
        tx.get(memberRef),
        oldMemberRef ? tx.get(oldMemberRef) : Promise.resolve(null),
        tx.get(runtimeRef),
      ]);
    if (deleted.exists || !currentLink.exists) return { applied: false, deleted: deleted.exists };
    if (current.exists && current.get('purgeLeaseId')) return { applied: false };
    if (valueMillis(current.exists && current.get('lastVerifiedAt')) >= nowMs ||
        valueMillis(currentLink.get('lastCheckedAt')) >= nowMs) return { applied: false };
    // The index/link used to resolve uid can change while the creator request
    // is in flight (OAuth relink or member recreation). Require the current
    // identity to still be the one that authorized this reconciliation.
    if (resolvedBySubject) {
      if (currentLink.get('subjectHash') !== expectedSubjectLink.subjectHash ||
          currentLink.get('memberId') !== expectedSubjectLink.memberId ||
          currentLink.get('memberHash') !== expectedSubjectLink.memberHash ||
          (memberIndexCurrent.exists && memberIndexCurrent.get('uid') !== uid) ||
          (oldMemberIndex && oldMemberIndex.exists && oldMemberIndex.get('uid') !== uid)) {
        return { applied: false };
      }
    } else if (!memberIndexCurrent.exists ||
               memberIndexCurrent.get('uid') !== uid ||
               currentLink.get('memberHash') !== mHash) {
      return { applied: false };
    }

    const currentSyncId = runtimeSnap.exists ? runtimeSnap.get('currentSyncId') : '';
    const emailMutationDeferred = runtimeSnap.exists && runtimeSnap.get('syncLeaseId') &&
      valueMillis(runtimeSnap.get('syncLeaseUntil')) > nowMs;
    if (emailMutationDeferred) {
      // Fail the whole reconciliation before any writes. Patreon retries the
      // signed webhook after the census publishes, ensuring a cancellation or
      // address change cannot be acknowledged while its email-index mutation
      // was deferred forever.
      const error = new Error('Campaign snapshot publish is in progress.');
      error.code = 'sync_in_progress';
      throw error;
    }
    const snapshotRef = currentSyncId
      ? db.doc(`${MEMBER_SNAPSHOTS_COLLECTION}/${snapshotIndexId(currentSyncId, mHash)}`)
      : null;
    const snapshotSnap = snapshotRef ? await tx.get(snapshotRef) : null;
    const priorEmailHash = snapshotSnap && snapshotSnap.exists ? snapshotSnap.get('emailHash') : '';
    const priorEmailRef = priorEmailHash
      ? db.doc(`${EMAIL_INDEX_COLLECTION}/${snapshotIndexId(currentSyncId, priorEmailHash)}`)
      : null;
    const nextEmailRef = nextEmailHash && currentSyncId
      ? db.doc(`${EMAIL_INDEX_COLLECTION}/${snapshotIndexId(currentSyncId, nextEmailHash)}`)
      : null;
    const [priorEmailSnap, nextEmailSnap] = await Promise.all([
      priorEmailRef ? tx.get(priorEmailRef) : Promise.resolve(null),
      nextEmailRef && (!priorEmailRef || nextEmailRef.path !== priorEmailRef.path)
        ? tx.get(nextEmailRef) : Promise.resolve(null),
    ]);
    if (valueMillis(runtimeSnap.exists && runtimeSnap.get('lastCompletedAt')) > nowMs ||
        valueMillis(snapshotSnap && snapshotSnap.exists && snapshotSnap.get('lastVerifiedAt')) > nowMs ||
        valueMillis(priorEmailSnap && priorEmailSnap.exists && priorEmailSnap.get('lastVerifiedAt')) > nowMs ||
        valueMillis(nextEmailSnap && nextEmailSnap.exists && nextEmailSnap.get('lastVerifiedAt')) > nowMs) {
      return { applied: false };
    }

    const prior = current.exists ? current.data() || {} : {};
    const linkedCandidate = member && member.isActiveEligible
      ? activeEntitlement(nowMs)
      : inactiveTransition(prior, nowMs);
    const entitlement = preferEntitlement(prior, linkedCandidate, nowMs);
    tx.set(entitlementRef, entitlement, { merge: true });
    if (user.exists) tx.set(userRef, { entitlement }, { merge: true });
    tx.set(linkRef, {
      memberId: member ? member.memberId : currentLink.get('memberId'),
      memberHash: mHash,
      lastCheckedAt: verifiedAt,
      lastKnownMemberState: member && member.isActiveEligible ? 'active' : 'inactive',
      updatedAt: verifiedAt,
    }, { merge: true });
    tx.set(memberRef, { uid, updatedAt: verifiedAt }, { merge: true });
    if (oldMemberIndex && oldMemberIndex.exists && oldMemberIndex.get('uid') === uid) {
      tx.delete(oldMemberRef);
    }

    if (currentSyncId) {
      if (priorEmailRef && priorEmailHash !== nextEmailHash) {
        tx.delete(priorEmailRef);
      }
      if (nextEmailRef) {
        tx.set(nextEmailRef, {
          memberId: member.memberId,
          memberHash: mHash,
          isActiveEligible: true,
          lastSyncId: currentSyncId,
          lastVerifiedAt: verifiedAt,
          expiresAt: Timestamp.fromMillis(nowMs + PATREON_INDEX_TTL_MS),
        }, { merge: true });
        tx.set(snapshotRef, {
          emailHash: nextEmailHash,
          lastSyncId: currentSyncId,
          lastVerifiedAt: verifiedAt,
          expiresAt: Timestamp.fromMillis(nowMs + PATREON_INDEX_TTL_MS),
        }, { merge: true });
      } else if (snapshotSnap && snapshotSnap.exists) {
        tx.delete(snapshotRef);
      }
    }
    return { applied: true, entitlement };
  });
  if (!transactionResult.applied) {
    return {
      reconciled: false,
      linked: !transactionResult.deleted,
      deleted: Boolean(transactionResult.deleted),
      active: false,
    };
  }
  const entitlement = transactionResult.entitlement;
  return {
    reconciled: true,
    linked: true,
    active: entitlement.state === 'active',
    state: entitlement.state,
  };
}

module.exports = {
  MEMBER_SNAPSHOTS_COLLECTION,
  commitSets,
  preferMember,
  syncCampaignCore,
  markCampaignUnavailableCore,
  reconcileMemberCore,
};
