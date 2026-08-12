'use strict';

const crypto = require('node:crypto');

function normalizeEmail(email) {
  return typeof email === 'string' ? email.trim().toLowerCase() : '';
}

function opaqueToken(bytes = 32) {
  return crypto.randomBytes(bytes).toString('base64url');
}

/**
 * Keyed hashes keep email addresses and Patreon identifiers out of Firestore
 * document IDs. A plain SHA-256 email index is vulnerable to dictionary scans.
 */
function keyedIndex(key, namespace, value) {
  if (typeof key !== 'string' || key.length < 32) {
    throw new Error('Patreon index HMAC key is missing or too short.');
  }
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error('Cannot index an empty value.');
  }
  return crypto
    .createHmac('sha256', key)
    .update(`${namespace}\0${value}`)
    .digest('hex');
}

function emailIndex(key, email) {
  const normalized = normalizeEmail(email);
  if (!normalized || !normalized.includes('@')) {
    throw new Error('Cannot index an invalid email address.');
  }
  return keyedIndex(key, 'email', normalized);
}

function subjectIndex(key, subjectId) {
  return keyedIndex(key, 'subject', String(subjectId || ''));
}

function memberIndex(key, memberId) {
  return keyedIndex(key, 'member', String(memberId || ''));
}

/**
 * Version campaign-snapshot documents without exposing the opaque sync ID or
 * keyed patron identifier in the path. Staging a new snapshot therefore never
 * mutates documents referenced by the currently-published pointer.
 */
function snapshotIndexId(syncId, keyedHash) {
  if (typeof syncId !== 'string' || !syncId || typeof keyedHash !== 'string' || !keyedHash) {
    throw new Error('Campaign snapshot index inputs are required.');
  }
  return crypto
    .createHash('sha256')
    .update(`${syncId}\0${keyedHash}`)
    .digest('hex');
}

/** Patreon currently specifies HMAC-MD5 for webhook delivery signatures. */
function verifyWebhookSignature(rawBody, suppliedSignature, secret) {
  if (!Buffer.isBuffer(rawBody)) rawBody = Buffer.from(rawBody || '');
  if (typeof suppliedSignature !== 'string' || !/^[0-9a-f]{32}$/i.test(suppliedSignature)) {
    return false;
  }
  if (typeof secret !== 'string' || secret.length === 0) return false;
  const expected = crypto.createHmac('md5', secret).update(rawBody).digest('hex');
  const supplied = Buffer.from(suppliedSignature.toLowerCase(), 'ascii');
  const wanted = Buffer.from(expected, 'ascii');
  return supplied.length === wanted.length && crypto.timingSafeEqual(supplied, wanted);
}

module.exports = {
  normalizeEmail,
  opaqueToken,
  keyedIndex,
  emailIndex,
  subjectIndex,
  memberIndex,
  snapshotIndexId,
  verifyWebhookSignature,
};
