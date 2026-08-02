/**
 * Shared silent-auth + prior-annotation history fetch for ClinVar CvC.
 *
 * Single source of truth for the token + query logic used by BOTH the popup
 * (popup.js) and the in-page-highlight background service worker
 * (background.js). Moved out of popup.js so the service worker — which can't
 * load popup.js — can `importScripts` this module directly.
 *
 * References FIREBASE_CONFIG (firebase-config.js), chrome.identity, and the
 * history.js globals (buildHistoryQuery/parseHistoryRows/sortHistoryDesc).
 */

/**
 * Exchanges a Google OAuth access token for a Firebase credential via
 * Identity Toolkit accounts:signInWithIdp (no Firebase SDK). Factored out of
 * signInWithGoogle so the silent history-auth path (silentIdToken) can reuse
 * the exact same exchange.
 *
 * @returns {Promise<{idToken: string, email: string}>}
 */
async function exchangeGoogleToken(googleToken) {
  const apiKey = FIREBASE_CONFIG.apiKey;
  // requestUri must be an authorized domain; the project's default authDomain is.
  const requestUri = `https://${FIREBASE_CONFIG.projectId}.firebaseapp.com`;

  const resp = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=${apiKey}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        postBody: `access_token=${googleToken}&providerId=google.com`,
        requestUri,
        returnSecureToken: true,
        returnIdpCredential: true
      })
    }
  );
  if (!resp.ok) {
    throw new Error(await authError(resp, 'Google sign-in'));
  }
  const data = await resp.json();
  return { idToken: data.idToken, email: data.email || '' };
}

/**
 * Like getGoogleAuthToken(), but non-interactive: resolves null (never
 * rejects) when there is no cached Google OAuth grant. Used only for the
 * best-effort history load, which must never prompt for interactive sign-in
 * just because the curator opened the popup.
 *
 * @returns {Promise<string|null>}
 */
function getGoogleAuthTokenSilent() {
  return new Promise((resolve) => {
    chrome.identity.getAuthToken({ interactive: false }, (token) => {
      if (chrome.runtime.lastError || !token) {
        resolve(null);
        return;
      }
      resolve(token);
    });
  });
}

/**
 * Best-effort Firebase ID token for the history load, obtained without ever
 * triggering an interactive sign-in prompt. Returns null whenever silent auth
 * isn't available (non-Google authMode, no cached Google grant, or any
 * failure in the token exchange) so history stays purely additive and never
 * blocks/breaks the popup.
 *
 * @returns {Promise<string|null>}
 */
async function silentIdToken() {
  if ((FIREBASE_CONFIG.authMode || 'none') !== 'google') return null;
  try {
    const googleToken = await getGoogleAuthTokenSilent();
    if (!googleToken) return null;
    const { idToken } = await exchangeGoogleToken(googleToken);
    return idToken;
  } catch (e) {
    return null;
  }
}

/**
 * Fetches prior annotations for a ClinVar variation via Firestore's REST
 * runQuery (see history.js for the query shape / response parsing), sorted
 * newest-first. Best-effort: any non-ok response — including a 403 for a
 * signed-in-but-not-allowlisted account — resolves to [] instead of
 * throwing, so a failed history fetch never blocks/breaks the popup.
 *
 * @returns {Promise<object[]>}
 */
async function fetchHistory(variationId, idToken) {
  const { projectId, collection } = FIREBASE_CONFIG;
  const databaseId = FIREBASE_CONFIG.databaseId || '(default)';
  const buildHistoryQueryFn = (typeof window !== 'undefined' && window.buildHistoryQuery) ||
    require('./history.js').buildHistoryQuery;
  const parseHistoryRowsFn = (typeof window !== 'undefined' && window.parseHistoryRows) ||
    require('./history.js').parseHistoryRows;
  const sortHistoryDescFn = (typeof window !== 'undefined' && window.sortHistoryDesc) ||
    require('./history.js').sortHistoryDesc;

  const url =
    `https://firestore.googleapis.com/v1/projects/${projectId}` +
    `/databases/${encodeURIComponent(databaseId)}/documents:runQuery`;

  const resp = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${idToken}`
    },
    body: JSON.stringify(buildHistoryQueryFn(variationId, collection))
  });

  if (!resp.ok) {
    console.info('CvC: history fetch failed —', resp.status);
    return [];
  }

  return sortHistoryDescFn(parseHistoryRowsFn(await resp.json()));
}

(function (root) {
  if (root) {
    root.getGoogleAuthTokenSilent = getGoogleAuthTokenSilent;
    root.exchangeGoogleToken = exchangeGoogleToken;
    root.silentIdToken = silentIdToken;
    root.fetchHistory = fetchHistory;
  }
})(typeof self !== 'undefined' ? self : (typeof window !== 'undefined' ? window : null));
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { getGoogleAuthTokenSilent, exchangeGoogleToken, silentIdToken, fetchHistory };
}
