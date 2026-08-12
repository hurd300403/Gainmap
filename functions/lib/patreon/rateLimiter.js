'use strict';

const { Timestamp } = require('firebase-admin/firestore');

const RATE_PATH = 'patreonPrivate/apiRate';

/**
 * Cross-instance request spacing for Patreon's creator token.
 *
 * A fixed minute bucket can burst once at each side of a window boundary. This
 * limiter instead reserves a globally ordered future start time in Firestore.
 * At the default 800 ms spacing, every rolling minute contains at most ~75
 * starts, leaving headroom below Patreon's 100/minute creator-token budget for
 * retries and operator probes. A crashed waiter only wastes its reserved slot.
 */
class PatreonRateLimiter {
  constructor({
    db,
    clock = Date.now,
    sleep,
    minSpacingMs = 800,
    maxQueueMs = 20_000,
  }) {
    this.db = db;
    this.clock = clock;
    this.sleep = sleep || ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    this.minSpacingMs = minSpacingMs;
    this.maxQueueMs = maxQueueMs;
  }

  async acquire() {
    const ref = this.db.doc(RATE_PATH);
    const waitMs = await this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const nowMs = this.clock();
      const prior = snap.exists ? snap.get('nextAllowedAt') : null;
      const priorMs = prior && typeof prior.toMillis === 'function' ? prior.toMillis() : 0;
      const slotMs = Math.max(nowMs, priorMs);
      if (slotMs - nowMs > this.maxQueueMs) {
        return { rejected: true, waitMs: slotMs - nowMs };
      }
      tx.set(ref, {
        nextAllowedAt: Timestamp.fromMillis(slotMs + this.minSpacingMs),
        lastReservedAt: Timestamp.fromMillis(nowMs),
      }, { merge: true });
      return { rejected: false, waitMs: Math.max(0, slotMs - nowMs) };
    });
    if (waitMs.rejected) {
      const error = new Error('Patreon API request queue is full.');
      error.code = 'rate_budget_exhausted';
      throw error;
    }
    if (waitMs.waitMs > 0) await this.sleep(waitMs.waitMs);
  }
}

module.exports = { RATE_PATH, PatreonRateLimiter };
