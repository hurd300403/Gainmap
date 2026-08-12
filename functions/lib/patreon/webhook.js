'use strict';

const { verifyWebhookSignature } = require('./crypto');

class WebhookError extends Error {
  constructor(code, status) {
    super(code);
    this.name = 'WebhookError';
    this.code = code;
    this.status = status;
  }
}

function authenticatedWebhookPayload({ rawBody, signature, secret }) {
  if (!Buffer.isBuffer(rawBody) || rawBody.length === 0 || rawBody.length > 1024 * 1024) {
    throw new WebhookError('invalid_payload', 400);
  }
  if (!verifyWebhookSignature(rawBody, signature, secret)) {
    throw new WebhookError('invalid_signature', 401);
  }
  let body;
  try {
    body = JSON.parse(rawBody.toString('utf8'));
  } catch {
    throw new WebhookError('invalid_payload', 400);
  }
  const data = body && body.data;
  if (!data || data.type !== 'member' || typeof data.id !== 'string' || data.id.length === 0) {
    throw new WebhookError('no_actionable_member', 200);
  }
  // No status, email, tier, or amount from this payload is trusted. The caller
  // uses only the opaque member ID to perform an authoritative creator-API GET.
  return { memberId: data.id };
}

module.exports = { WebhookError, authenticatedWebhookPayload };
