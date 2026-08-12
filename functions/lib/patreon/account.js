'use strict';

const {
  ENTITLEMENTS_COLLECTION,
  LINKS_COLLECTION,
  OPERATOR_GRANTS_COLLECTION,
} = require('./entitlement');
const {
  SUBJECT_INDEX_COLLECTION,
  MEMBER_INDEX_COLLECTION,
  OAUTH_STARTS_COLLECTION,
} = require('./oauth');

async function deletePatreonAccountData({ db, uid }) {
  const linkRef = db.doc(`${LINKS_COLLECTION}/${uid}`);
  await db.runTransaction(async (tx) => {
    const linkSnap = await tx.get(linkRef);
    const subjectHash = linkSnap.exists ? linkSnap.get('subjectHash') : '';
    const memberHash = linkSnap.exists ? linkSnap.get('memberHash') : '';
    const subjectRef = subjectHash ? db.doc(`${SUBJECT_INDEX_COLLECTION}/${subjectHash}`) : null;
    const memberRef = memberHash ? db.doc(`${MEMBER_INDEX_COLLECTION}/${memberHash}`) : null;
    const subjectSnap = subjectRef ? await tx.get(subjectRef) : null;
    const memberSnap = memberRef ? await tx.get(memberRef) : null;

    tx.delete(db.doc(`${ENTITLEMENTS_COLLECTION}/${uid}`));
    tx.delete(db.doc(`${OPERATOR_GRANTS_COLLECTION}/${uid}`));
    tx.delete(linkRef);
    tx.delete(db.doc(`${OAUTH_STARTS_COLLECTION}/${uid}`));
    if (subjectSnap && subjectSnap.exists && subjectSnap.get('uid') === uid) tx.delete(subjectRef);
    if (memberSnap && memberSnap.exists && memberSnap.get('uid') === uid) tx.delete(memberRef);
  });
}

module.exports = { deletePatreonAccountData };
