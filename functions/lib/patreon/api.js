'use strict';

const { PATREON_USER_AGENT } = require('./http');

class PatreonAPIError extends Error {
  constructor(message, { code = 'upstream_error', status = 0 } = {}) {
    super(message);
    this.name = 'PatreonAPIError';
    this.code = code;
    this.status = status;
  }
}

function relationshipId(resource, name) {
  const data = resource && resource.relationships && resource.relationships[name] &&
    resource.relationships[name].data;
  return data && !Array.isArray(data) ? String(data.id || '') : '';
}

function relationshipIds(resource, name) {
  const data = resource && resource.relationships && resource.relationships[name] &&
    resource.relationships[name].data;
  return Array.isArray(data) ? data.map((item) => String(item && item.id || '')).filter(Boolean) : [];
}

function parseMember(resource, included = [], {
  requireUserRelationship = true,
  subjectId = '',
  requireAmountField = true,
} = {}) {
  if (!resource || resource.type !== 'member' || !resource.id) {
    throw new PatreonAPIError('Patreon returned a malformed member resource.', {
      code: 'invalid_member_schema',
    });
  }
  const attrs = resource.attributes || {};
  const hasPatronStatus = Object.prototype.hasOwnProperty.call(attrs, 'patron_status');
  const validPatronStatus = attrs.patron_status === null ||
    typeof attrs.patron_status === 'string';
  if (!hasPatronStatus || !validPatronStatus ||
      (requireAmountField &&
        !Object.prototype.hasOwnProperty.call(attrs, 'currently_entitled_amount_cents')) ||
      !resource.relationships ||
      (requireUserRelationship && !resource.relationships.user) ||
      !resource.relationships.currently_entitled_tiers ||
      !Array.isArray(resource.relationships.currently_entitled_tiers.data)) {
    throw new PatreonAPIError('Patreon member fields/scopes are incomplete.', {
      code: 'invalid_member_schema',
    });
  }
  const relatedUserId = relationshipId(resource, 'user');
  if (requireUserRelationship) {
    const userData = resource.relationships.user.data;
    const validUserData = userData === null ||
      (userData && !Array.isArray(userData) && userData.type === 'user' && userData.id);
    if (!validUserData) {
      throw new PatreonAPIError('Patreon member user relationship is malformed.', {
        code: 'invalid_member_schema',
      });
    }
  }
  const userId = relatedUserId || String(subjectId || '');
  let email = typeof attrs.email === 'string' ? attrs.email.trim().toLowerCase() : '';
  if (!email && userId) {
    const user = included.find((item) => item && item.type === 'user' && String(item.id) === userId);
    email = user && user.attributes && typeof user.attributes.email === 'string'
      ? user.attributes.email.trim().toLowerCase()
      : '';
  }
  const tierIds = relationshipIds(resource, 'currently_entitled_tiers');
  const amountCents = Number(attrs.currently_entitled_amount_cents) || 0;
  const patronStatus = typeof attrs.patron_status === 'string' ? attrs.patron_status : '';
  return {
    memberId: String(resource.id),
    subjectId: userId,
    email,
    patronStatus,
    amountCents,
    tierIds,
    lastChargeStatus: String(attrs.last_charge_status || ''),
    // Patreon gift and trial entitlements may carry $0. The benefit boundary
    // is active_patron plus an actually-entitled tier, per Patreon guidance.
    isActiveEligible: patronStatus === 'active_patron' && tierIds.length > 0,
  };
}

function cursorFrom(data) {
  const metaCursor = data && data.meta && data.meta.pagination &&
    data.meta.pagination.cursors && data.meta.pagination.cursors.next;
  if (metaCursor) return String(metaCursor);
  const nextURL = data && data.links && data.links.next;
  if (!nextURL) return '';
  try {
    return new URL(nextURL).searchParams.get('page[cursor]') || '';
  } catch {
    throw new PatreonAPIError('Patreon returned an invalid pagination URL.');
  }
}

class PatreonAPI {
  constructor({
    tokenStore,
    fetchImpl = fetch,
    campaignId,
    minRequestIntervalMs = 800,
    sleep,
    beforeRequest,
  }) {
    this.tokenStore = tokenStore;
    this.fetch = fetchImpl;
    this.campaignId = campaignId;
    this.baseURL = 'https://www.patreon.com/api/oauth2/v2';
    this.minRequestIntervalMs = minRequestIntervalMs;
    this.sleep = sleep || ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    this.lastRequestStartedAt = 0;
    this.beforeRequest = beforeRequest;
    this.lastRateSlotAt = 0;
  }

  async _pace() {
    if (!(this.minRequestIntervalMs > 0)) return;
    const elapsed = Date.now() - this.lastRequestStartedAt;
    if (this.lastRequestStartedAt > 0 && elapsed < this.minRequestIntervalMs) {
      await this.sleep(this.minRequestIntervalMs - elapsed);
    }
    this.lastRequestStartedAt = Date.now();
  }

  async _request(path, params = {}, { allowNotFound = false } = {}) {
    let token;
    try {
      token = await this.tokenStore.getAccessToken();
    } catch (error) {
      throw new PatreonAPIError('Patreon creator credentials are unavailable.', {
        code: error && error.code || 'token_unavailable',
      });
    }

    const url = new URL(`${this.baseURL}${path}`);
    for (const [key, value] of Object.entries(params)) {
      if (value !== undefined && value !== null && value !== '') url.searchParams.set(key, String(value));
    }

    const makeCall = async (accessToken) => {
      await this._pace();
      const nowMs = Date.now();
      if (this.beforeRequest &&
          (!this.lastRateSlotAt || nowMs - this.lastRateSlotAt >= this.minRequestIntervalMs)) {
        await this.beforeRequest();
        this.lastRateSlotAt = Date.now();
      }
      try {
        return await this.fetch(url, {
          headers: {
            Authorization: `Bearer ${accessToken}`,
            'User-Agent': PATREON_USER_AGENT,
            Accept: 'application/json',
          },
          signal: AbortSignal.timeout(20_000),
        });
      } catch {
        throw new PatreonAPIError('Patreon could not be reached.', { code: 'network_error' });
      }
    };

    let response = await makeCall(token);
    if (response.status === 401) {
      try {
        token = await this.tokenStore.getAccessToken({
          force: true,
          rejectedAccessToken: token,
        });
      } catch (error) {
        throw new PatreonAPIError('Patreon creator authorization must be renewed.', {
          code: error && error.code || 'token_unavailable',
          status: 401,
        });
      }
      response = await makeCall(token);
    }
    // Patreon currently budgets this creator token at 100 requests/minute.
    // The normal 800ms page pacing stays below that limit with headroom;
    // Retry-After is a
    // second line of defense for a shared rolling window or a temporary clamp.
    if (response.status === 429) {
      const rawRetry = response.headers && response.headers.get
        ? response.headers.get('retry-after')
        : '';
      const retrySeconds = Number(rawRetry);
      const retryMs = Number.isFinite(retrySeconds) && retrySeconds >= 0
        ? Math.min(60_000, retrySeconds * 1000)
        : 5_000;
      await this.sleep(retryMs);
      response = await makeCall(token);
    }
    if (allowNotFound && response.status === 404) return null;
    if (!response.ok) {
      throw new PatreonAPIError(`Patreon request failed (HTTP ${response.status}).`, {
        code: response.status === 429 ? 'rate_limited' : 'upstream_error',
        status: response.status,
      });
    }
    try {
      return await response.json();
    } catch {
      throw new PatreonAPIError('Patreon returned invalid JSON.');
    }
  }

  async getMember(memberId) {
    if (!memberId) throw new PatreonAPIError('A Patreon member ID is required.', { code: 'invalid_member' });
    const data = await this._request(`/members/${encodeURIComponent(memberId)}`, {
      include: 'user,currently_entitled_tiers',
      'fields[member]': 'patron_status,email,last_charge_status,last_charge_date,currently_entitled_amount_cents',
      'fields[user]': 'email',
    }, { allowNotFound: true });
    if (data === null) return null;
    const member = parseMember(data.data, data.included || []);
    if (!member) throw new PatreonAPIError('Patreon returned an invalid member record.');
    return member;
  }

  async getAllCampaignMembers() {
    if (!this.campaignId) {
      throw new PatreonAPIError('The Gainmap Patreon campaign is not configured.', {
        code: 'campaign_not_configured',
      });
    }
    const members = [];
    const seenCursors = new Set();
    let cursor = '';

    for (let page = 0; page < 1000; page += 1) {
      const data = await this._request(
        `/campaigns/${encodeURIComponent(this.campaignId)}/members`,
        {
          include: 'user,currently_entitled_tiers',
          'fields[member]': 'patron_status,email,last_charge_status,last_charge_date,currently_entitled_amount_cents',
          'fields[user]': 'email',
          // Patreon supports 1000 when pledge-event history is not included.
          // This campaign is ~9.2k members, cutting a census from ~92 calls to
          // ~10 and leaving ample room in the 100-request/min creator budget.
          'page[count]': 1000,
          'page[cursor]': cursor,
        }
      );
      if (!Array.isArray(data.data)) {
        throw new PatreonAPIError('Patreon returned an invalid campaign member page.');
      }
      for (const resource of data.data) {
        members.push(parseMember(resource, data.included || []));
      }
      const next = cursorFrom(data);
      if (!next) {
        const reportedTotal = Number(
          data && data.meta && data.meta.pagination && data.meta.pagination.total
        );
        if (Number.isFinite(reportedTotal) && reportedTotal >= 0 && members.length < reportedTotal) {
          throw new PatreonAPIError('Patreon pagination ended before the reported total.', {
            code: 'pagination_incomplete',
          });
        }
        return members;
      }
      if (seenCursors.has(next)) {
        throw new PatreonAPIError('Patreon pagination repeated a cursor.');
      }
      seenCursors.add(next);
      cursor = next;
    }
    throw new PatreonAPIError('Patreon pagination exceeded the safety limit.');
  }
}

module.exports = {
  PatreonAPI,
  PatreonAPIError,
  parseMember,
  cursorFrom,
  relationshipId,
  relationshipIds,
};
