'use strict';

/**
 * Shared constants + path helpers for the Gainmap sync backend.
 * Spec: docs/superpowers/specs/2026-07-27-gainmap-ios-sync-design.md
 */

/** The one project where test-only deadline overrides are ignored. */
const PRODUCTION_PROJECT = 'gainmap-production';

const SCHEMA_VERSION = 1;

/** Storage tiers. Mirrored in storage.rules — keep in lockstep. */
const TIERS = ['originals', 'thumbs', 'proxies'];

/** Per-object hard cap. Mirrored in storage.rules. */
const MAX_OBJECT_BYTES = 64 * 1024 * 1024;

/** Default per-user quota: 5 GiB (spec "Locked decisions / Quota"). */
const DEFAULT_QUOTA_BYTES = 5 * 1024 * 1024 * 1024;

/** Signup cap fallback when config/flags.maxUsers is unset. */
const DEFAULT_MAX_USERS = 200;

/**
 * Two deadlines (r6):
 *  - START_WINDOW: how long the client has to BEGIN the upload. Storage rules
 *    check `request.time < startBefore` at upload start and never again.
 *  - LEASE: how long the reserved bytes stay charged against the quota.
 *    A resumable session can live ~7 days, so the lease is 7d + 1d margin,
 *    measured from startBefore (not from now).
 */
const DEFAULT_START_WINDOW_SEC = 30 * 60;
const DEFAULT_LEASE_SEC = 8 * 24 * 60 * 60;

/** Tombstones are physically purged after this long. */
const TOMBSTONE_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

/** A blob must sit in `gcCandidate` at least this long before pass 2 may delete it. */
const GC_CANDIDATE_AGE_MS = 24 * 60 * 60 * 1000;

/** deleteAccount requires a token minted within this window. */
const RECENT_AUTH_SEC = 5 * 60;

const HASH_RE = /^[0-9a-f]{64}$/;

/** users/{uid}/{tier}/{contentHash}.jpg */
const OBJECT_NAME_RE = /^users\/([^/]+)\/([^/]+)\/([0-9a-f]{64})\.jpg$/;

/**
 * RESERVATION DOC ID SCHEME — must stay in lockstep with storage.rules,
 * which derives the same id from {tier} and {fileName} alone:
 *     users/{uid}/reservations/{tier}_{contentHash}
 */
function reservationId(tier, contentHash) {
  return `${tier}_${contentHash}`;
}

function objectName(uid, tier, contentHash) {
  return `users/${uid}/${tier}/${contentHash}.jpg`;
}

/** Returns {uid, tier, contentHash} or null if the object is not a synced rendition. */
function parseObjectName(name) {
  if (typeof name !== 'string') return null;
  const m = OBJECT_NAME_RE.exec(name);
  if (!m) return null;
  const [, uid, tier, contentHash] = m;
  if (!TIERS.includes(tier)) return null;
  return { uid, tier, contentHash };
}

/** Coerce a Firestore numeric field to a finite non-negative number. */
function num(v) {
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
}

/**
 * Object generations are 64-bit and routinely exceed Number.MAX_SAFE_INTEGER.
 * They are stored and compared as strings via BigInt — NEVER as Number.
 * Returns -1 | 0 | 1.
 */
function compareGenerations(a, b) {
  const A = BigInt(String(a));
  const B = BigInt(String(b));
  if (A < B) return -1;
  if (A > B) return 1;
  return 0;
}

module.exports = {
  PRODUCTION_PROJECT,
  SCHEMA_VERSION,
  TIERS,
  MAX_OBJECT_BYTES,
  DEFAULT_QUOTA_BYTES,
  DEFAULT_MAX_USERS,
  DEFAULT_START_WINDOW_SEC,
  DEFAULT_LEASE_SEC,
  TOMBSTONE_RETENTION_MS,
  GC_CANDIDATE_AGE_MS,
  RECENT_AUTH_SEC,
  HASH_RE,
  OBJECT_NAME_RE,
  reservationId,
  objectName,
  parseObjectName,
  num,
  compareGenerations,
};
