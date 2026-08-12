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
 * Single deadline (r7 — probe-proven): Cloud Storage evaluates rules at
 * FINALIZE, not at resumable-session start, so a reservation carries one
 * COMPLETION deadline: `expiresAt = now + LEASE`. A resumable session can
 * live ~7 days, so the lease is 7d + 1d margin. Storage rules check
 * `request.time < expiresAt`; a finalize-time 403 means the lease expired
 * mid-upload and the client re-reserves (idempotent refresh) and retries.
 * Evidence: Gainmap/scripts/spike/P0-PROBE-RESULTS.md.
 */
const DEFAULT_LEASE_SEC = 8 * 24 * 60 * 60;

/**
 * maintenance releases a reservation's capacity only this long AFTER
 * `expiresAt` — margin for a finalize that squeaks in at the deadline and
 * whose reconciler event is still in flight.
 */
const RESERVATION_RELEASE_GRACE_MS = 60 * 60 * 1000;

/** Tombstones are physically purged after this long. */
const TOMBSTONE_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

/** A blob must sit in `gcCandidate` at least this long before pass 2 may delete it. */
const GC_CANDIDATE_AGE_MS = 24 * 60 * 60 * 1000;

/** deleteAccount requires a token minted within this window. */
const RECENT_AUTH_SEC = 5 * 60;

/**
 * Account-deletion race marker lifetime. This outlives resumable uploads and
 * delayed Storage events without retaining a deleted account identifier
 * forever. Firestore TTL is configured on deletedAccounts.expiresAt.
 */
const DELETED_ACCOUNT_MARKER_TTL_MS = 30 * 24 * 60 * 60 * 1000;

/** Patreon access survives a conclusive lapse or upstream outage for 7 days. */
const PATREON_GRACE_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * A verified Firebase email is a full proof while its active Patreon campaign
 * snapshot remains inside this absolute verification window. A new completed
 * campaign snapshot rolls the window forward; a client refresh cannot.
 */
const PATREON_EMAIL_VERIFICATION_MS = 7 * 24 * 60 * 60 * 1000;

/** Cloud data is retained after entitlement expiry for recovery/reactivation. */
const PATREON_RETENTION_MS = 90 * 24 * 60 * 60 * 1000;

/** Superseded keyed campaign snapshots live long enough for rollback/debugging. */
const PATREON_INDEX_TTL_MS = 14 * 24 * 60 * 60 * 1000;

/** OAuth state is opaque, single-use, and deliberately short lived. */
const PATREON_OAUTH_STATE_TTL_MS = 10 * 60 * 1000;

/** Per-Firebase-account OAuth rolling window; at most two starts are allowed. */
const PATREON_OAUTH_START_COOLDOWN_MS = 60 * 1000;

/** Avoid turning a client refresh loop into Patreon API traffic. */
const PATREON_REFRESH_COOLDOWN_MS = 5 * 60 * 1000;

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
  DEFAULT_LEASE_SEC,
  RESERVATION_RELEASE_GRACE_MS,
  TOMBSTONE_RETENTION_MS,
  GC_CANDIDATE_AGE_MS,
  RECENT_AUTH_SEC,
  DELETED_ACCOUNT_MARKER_TTL_MS,
  PATREON_GRACE_MS,
  PATREON_EMAIL_VERIFICATION_MS,
  PATREON_RETENTION_MS,
  PATREON_INDEX_TTL_MS,
  PATREON_OAUTH_STATE_TTL_MS,
  PATREON_OAUTH_START_COOLDOWN_MS,
  PATREON_REFRESH_COOLDOWN_MS,
  HASH_RE,
  OBJECT_NAME_RE,
  reservationId,
  objectName,
  parseObjectName,
  num,
  compareGenerations,
};
