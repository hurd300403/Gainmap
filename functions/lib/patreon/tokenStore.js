'use strict';

const { Timestamp } = require('firebase-admin/firestore');
const { PATREON_USER_AGENT } = require('./http');

const TOKEN_PATH = 'patreonPrivate/creatorToken';
const EXPIRY_SAFETY_MS = 60 * 1000;
const LEASE_MS = 60 * 1000;
const LEASE_ATTEMPTS = 6;
const COMMIT_ATTEMPTS = 3;

class PatreonTokenError extends Error {
  constructor(message, code = 'token_unavailable') {
    super(message);
    this.name = 'PatreonTokenError';
    this.code = code;
  }
}

function timestampMillis(value) {
  if (value && typeof value.toMillis === 'function') return value.toMillis();
  if (value instanceof Date) return value.getTime();
  return Number(value) || 0;
}

function isFresh(data, nowMs) {
  return Boolean(data && data.accessToken) &&
    nowMs < timestampMillis(data.expiresAt) - EXPIRY_SAFETY_MS;
}

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Patreon rotates creator refresh tokens. The mutable token pair therefore
 * lives in a server-only Firestore document, while Secret Manager supplies
 * only the OAuth client ID/secret. A short Firestore lease guarantees one
 * refresh exchange at a time across function instances.
 */
class PatreonTokenStore {
  constructor({
    db,
    fetchImpl = fetch,
    getClientCredentials,
    getBootstrapCredentials,
    clock = Date.now,
    randomUUID,
  }) {
    this.db = db;
    this.fetch = fetchImpl;
    this.getClientCredentials = getClientCredentials;
    this.getBootstrapCredentials = getBootstrapCredentials;
    this.clock = clock;
    this.randomUUID = randomUUID || require('node:crypto').randomUUID;
  }

  async getAccessToken({ force = false, rejectedAccessToken = '' } = {}) {
    const ref = this.db.doc(TOKEN_PATH);
    let initial = await ref.get();
    if (!initial.exists) initial = await this._bootstrap(ref);
    if (!force && isFresh(initial.data(), this.clock())) return initial.get('accessToken');
    return this._refreshWithLease(ref, force, rejectedAccessToken);
  }

  async _bootstrap(ref) {
    let seed;
    try {
      seed = this.getBootstrapCredentials && this.getBootstrapCredentials();
    } catch {
      seed = null;
    }
    if (!seed || !seed.accessToken || !seed.refreshToken) {
      throw new PatreonTokenError(
        'Patreon creator authorization has not been bootstrapped.',
        'creator_not_bootstrapped'
      );
    }
    await this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        tx.create(ref, {
          accessToken: seed.accessToken,
          refreshToken: seed.refreshToken,
          // Patreon developer-portal tokens do not carry an expiry alongside
          // their displayed values. Give the access token a conservative
          // window; a 401 immediately forces the rotating refresh flow.
          expiresAt: Timestamp.fromMillis(this.clock() + 30 * 60 * 1000),
          createdAt: Timestamp.fromMillis(this.clock()),
          updatedAt: Timestamp.fromMillis(this.clock()),
        });
      }
    });
    return ref.get();
  }

  async _refreshWithLease(ref, force, rejectedAccessToken) {
    const owner = this.randomUUID();
    let refreshToken;

    for (let attempt = 0; attempt < LEASE_ATTEMPTS; attempt += 1) {
      const acquired = await this.db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        if (!snap.exists) {
          throw new PatreonTokenError(
            'Patreon creator authorization has not been bootstrapped.',
            'creator_not_bootstrapped'
          );
        }
        const data = snap.data() || {};
        const nowMs = this.clock();
        // A caller retrying a 401 supplies the token Patreon rejected. If
        // another instance has already rotated it, consume that winner instead
        // of force-rotating again in a burst.
        if (isFresh(data, nowMs) &&
            (!force || (rejectedAccessToken && data.accessToken !== rejectedAccessToken))) {
          return { status: 'fresh', accessToken: data.accessToken };
        }
        const leaseLive = data.refreshLeaseOwner &&
          data.refreshLeaseOwner !== owner &&
          timestampMillis(data.refreshLeaseUntil) > nowMs;
        if (leaseLive) return { status: 'busy' };
        tx.set(ref, {
          refreshLeaseOwner: owner,
          refreshLeaseUntil: Timestamp.fromMillis(nowMs + LEASE_MS),
        }, { merge: true });
        return { status: 'acquired', refreshToken: data.refreshToken };
      });

      if (acquired.status === 'fresh') return acquired.accessToken;
      if (acquired.status === 'acquired') {
        refreshToken = acquired.refreshToken;
        break;
      }
      await delay(250 * (attempt + 1));
    }

    if (!refreshToken) {
      await this._releaseLease(ref, owner);
      throw new PatreonTokenError(
        'Patreon credential refresh is already in progress.',
        'refresh_busy'
      );
    }

    let credentials;
    try {
      credentials = this.getClientCredentials();
      if (!credentials || !credentials.clientId || !credentials.clientSecret) {
        throw new Error('missing OAuth client fields');
      }
    } catch {
      await this._releaseLease(ref, owner);
      throw new PatreonTokenError('Patreon OAuth client credentials are unavailable.');
    }

    let response;
    try {
      response = await this.fetch('https://www.patreon.com/api/oauth2/token', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent': PATREON_USER_AGENT,
        },
        body: new URLSearchParams({
          grant_type: 'refresh_token',
          refresh_token: refreshToken,
          client_id: credentials.clientId,
          client_secret: credentials.clientSecret,
        }),
        signal: AbortSignal.timeout(15_000),
      });
    } catch {
      await this._releaseLease(ref, owner);
      throw new PatreonTokenError('Patreon credential refresh could not reach Patreon.');
    }

    if (!response.ok) {
      await this._releaseLease(ref, owner);
      const code = response.status === 401 ? 'creator_reauthorization_required' : 'refresh_rejected';
      throw new PatreonTokenError(`Patreon credential refresh failed (HTTP ${response.status}).`, code);
    }

    let body;
    try {
      body = await response.json();
    } catch {
      await this._releaseLease(ref, owner);
      throw new PatreonTokenError('Patreon credential refresh returned invalid data.');
    }
    if (!body || typeof body.access_token !== 'string' || body.access_token.length === 0) {
      await this._releaseLease(ref, owner);
      throw new PatreonTokenError('Patreon credential refresh returned no access token.');
    }

    const expiresIn = Number.isFinite(Number(body.expires_in)) ? Number(body.expires_in) : 3600;
    const next = {
      accessToken: body.access_token,
      refreshToken: body.refresh_token || refreshToken,
      expiresAt: Timestamp.fromMillis(this.clock() + Math.max(60, expiresIn) * 1000),
      updatedAt: Timestamp.fromMillis(this.clock()),
    };

    let committed = false;
    for (let attempt = 0; attempt < COMMIT_ATTEMPTS; attempt += 1) {
      try {
        await this.db.runTransaction(async (tx) => {
          const snap = await tx.get(ref);
          if (!snap.exists || snap.get('refreshLeaseOwner') !== owner) {
            throw new PatreonTokenError('Patreon refresh lease was lost.', 'refresh_lease_lost');
          }
          tx.set(ref, {
            ...next,
            refreshLeaseOwner: null,
            refreshLeaseUntil: null,
          }, { merge: true });
        });
        committed = true;
        break;
      } catch (error) {
        if (error instanceof PatreonTokenError) throw error;
        if (attempt < COMMIT_ATTEMPTS - 1) await delay(250 * (2 ** attempt));
      }
    }

    if (!committed) {
      // The old rotating refresh token may already be consumed. Never pretend
      // this was healthy: operators must reauthorize instead of receiving a
      // delayed, confusing outage at the next refresh.
      throw new PatreonTokenError(
        'A refreshed Patreon credential could not be persisted; reauthorization is required.',
        'creator_reauthorization_required'
      );
    }
    return next.accessToken;
  }

  async _releaseLease(ref, owner) {
    try {
      await this.db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        if (snap.exists && snap.get('refreshLeaseOwner') === owner) {
          tx.set(ref, { refreshLeaseOwner: null, refreshLeaseUntil: null }, { merge: true });
        }
      });
    } catch {
      // The lease expires automatically; preserving the original failure is
      // more useful than replacing it with a cleanup error.
    }
  }
}

module.exports = {
  TOKEN_PATH,
  PatreonTokenError,
  PatreonTokenStore,
  isFresh,
  timestampMillis,
};
