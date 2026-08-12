'use strict';

// Patreon requires a descriptive User-Agent and may drop requests with a 403
// when it cannot classify one. Keep this truthful, stable label on every API
// and OAuth token request made by Gain Map Cloud Sync.
const PATREON_USER_AGENT = 'Gain Map - Cloud Sync';

module.exports = { PATREON_USER_AGENT };
