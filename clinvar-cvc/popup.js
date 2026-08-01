/**
 * ClinVar POC popup logic.
 *
 * Reads 5 fields from the form and writes a single document to Firestore
 * using the Firestore REST API (no Firebase SDK — keeps the extension
 * build-free and MV3-CSP friendly). The Firestore -> BigQuery Firebase
 * Extension then streams the document into BigQuery.
 *
 * Auth model is selected by FIREBASE_CONFIG.authMode:
 *   'google'    — Google sign-in (chrome.identity.getAuthToken -> Identity
 *                 Toolkit accounts:signInWithIdp). The Firebase ID token carries
 *                 a VERIFIED email; that verified email is what gets persisted as
 *                 user_email, so a Firestore rule can enforce
 *                 user_email == request.auth.token.email.
 *   'anonymous' — Firebase Anonymous Auth (email captured but NOT verified).
 *   'none'      — no auth (open/test-mode rules only).
 */

// The email persisted with the record. In 'google' mode this is replaced by the
// verified email from sign-in; otherwise it's the Chrome profile email (a hint).
let userEmail = '';

/**
 * Resolves the signed-in Chrome profile's Google account email.
 * @returns {Promise<string>} the email, or '' if none is available.
 */
function getUserEmail() {
  return new Promise((resolve) => {
    try {
      chrome.identity.getProfileUserInfo({ accountStatus: 'ANY' }, (info) => {
        resolve((info && info.email) || '');
      });
    } catch (e) {
      resolve('');
    }
  });
}

const AUTH_STORAGE_KEY = 'poc_auth';

/** Promisified chrome.storage.local.get for a single key. */
function storageGet(key) {
  return new Promise((resolve) => {
    chrome.storage.local.get(key, (result) => resolve(result[key]));
  });
}

/** Promisified chrome.storage.local.set. */
function storageSet(obj) {
  return new Promise((resolve) => {
    chrome.storage.local.set(obj, () => resolve());
  });
}

/**
 * Authenticates according to FIREBASE_CONFIG.authMode and returns a Firebase
 * ID token to send on the Firestore write, plus the verified email when known.
 *
 * @returns {Promise<{idToken: string|null, email: string}>}
 */
async function ensureAuth() {
  const mode = FIREBASE_CONFIG.authMode || 'none';
  if (mode === 'none') return { idToken: null, email: '' };
  if (mode === 'anonymous') return { idToken: await ensureAnonymousToken(), email: '' };
  if (mode === 'google') return signInWithGoogle();
  throw new Error(`Unknown authMode "${mode}" in firebase-config.js`);
}

/**
 * Google sign-in: gets a Google OAuth token via chrome.identity, then exchanges
 * it for a Firebase credential via Identity Toolkit accounts:signInWithIdp (no
 * Firebase SDK). The returned Firebase ID token has a verified `email` claim.
 *
 * @returns {Promise<{idToken: string, email: string}>}
 */
async function signInWithGoogle() {
  const googleToken = await getGoogleAuthToken();
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
 * Gets a Google OAuth access token via chrome.identity. Requires the `oauth2`
 * block in manifest.json (client id + scopes) and, for a Chrome Extension OAuth
 * client, the client id to match this extension's id.
 *
 * @returns {Promise<string>}
 */
function getGoogleAuthToken() {
  return new Promise((resolve, reject) => {
    chrome.identity.getAuthToken({ interactive: true }, (token) => {
      if (chrome.runtime.lastError || !token) {
        reject(new Error(
          (chrome.runtime.lastError && chrome.runtime.lastError.message) ||
          'Google sign-in was cancelled or returned no token.'
        ));
        return;
      }
      resolve(token);
    });
  });
}

/**
 * Ensures we have a valid Firebase ID token for an anonymous user, using the
 * Identity Toolkit REST API. Caches the refresh token in chrome.storage.local
 * so the same anonymous identity is reused across popups.
 *
 * @returns {Promise<string>} an anonymous-user ID token.
 */
async function ensureAnonymousToken() {
  const apiKey = FIREBASE_CONFIG.apiKey;
  const cached = await storageGet(AUTH_STORAGE_KEY);

  // Reuse a still-valid cached token (60s safety margin).
  if (cached && cached.idToken && cached.expiresAt - 60000 > Date.now()) {
    return cached.idToken;
  }

  // Refresh an existing anonymous session if we have a refresh token.
  if (cached && cached.refreshToken) {
    const refreshed = await refreshIdToken(apiKey, cached.refreshToken);
    if (refreshed) return refreshed;
  }

  // Otherwise create a fresh anonymous user.
  return signUpAnonymously(apiKey);
}

async function signUpAnonymously(apiKey) {
  const resp = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${apiKey}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ returnSecureToken: true })
    }
  );
  if (!resp.ok) {
    throw new Error(await authError(resp, 'anonymous sign-in'));
  }
  const data = await resp.json();
  await cacheAuth(data.idToken, data.refreshToken, data.expiresIn);
  return data.idToken;
}

async function refreshIdToken(apiKey, refreshToken) {
  const resp = await fetch(
    `https://securetoken.googleapis.com/v1/token?key=${apiKey}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: `grant_type=refresh_token&refresh_token=${encodeURIComponent(refreshToken)}`
    }
  );
  if (!resp.ok) return null; // fall back to a fresh sign-up
  const data = await resp.json();
  await cacheAuth(data.id_token, data.refresh_token, data.expires_in);
  return data.id_token;
}

function cacheAuth(idToken, refreshToken, expiresInSeconds) {
  return storageSet({
    [AUTH_STORAGE_KEY]: {
      idToken,
      refreshToken,
      expiresAt: Date.now() + Number(expiresInSeconds) * 1000
    }
  });
}

async function authError(resp, context) {
  let detail = `HTTP ${resp.status}`;
  try {
    const body = await resp.json();
    if (body.error && body.error.message) detail = body.error.message;
  } catch (e) { /* keep status-code detail */ }
  return `${context} failed: ${detail}`;
}

/**
 * Converts a flat object of field -> value into the Firestore REST
 * document shape ({ fields: { name: { <type>Value: value } } }).
 * Empty strings are skipped so they don't create empty fields.
 */
function toFirestoreFields(obj) {
  const fields = {};
  Object.entries(obj).forEach(([key, value]) => {
    if (value === null || value === undefined || value === '') return;
    if (value instanceof Date) {
      fields[key] = { timestampValue: value.toISOString() };
    } else {
      fields[key] = { stringValue: String(value) };
    }
  });
  return { fields };
}

function setStatus(message, kind) {
  const el = document.getElementById('status');
  el.textContent = message;
  el.className = kind || '';
}

function readForm() {
  return {
    user_email: userEmail,
    variation_id: document.getElementById('variation_id').value.trim(),
    scv_id: document.getElementById('scv_id').value.trim(),
    action: document.getElementById('action').value,
    reason: document.getElementById('reason').value.trim(),
    notes: document.getElementById('notes').value.trim()
  };
}

/**
 * Same validation the real extension enforces: an SCV and an action are
 * required, and a reason is required unless the action is "No Change".
 */
function validate(data) {
  if (!data.user_email) {
    return 'No Google account detected. Sign into Chrome with a synced Google profile to submit.';
  }
  if (!data.scv_id) return 'An SCV ID is required.';
  if (!data.action) return 'An action is required.';
  if (data.action !== 'No Change' && !data.reason) {
    return `A reason is required for a '${data.action}' annotation.`;
  }
  return null;
}

function isConfigured() {
  return (
    FIREBASE_CONFIG &&
    FIREBASE_CONFIG.projectId &&
    FIREBASE_CONFIG.projectId.indexOf('PASTE_') !== 0 &&
    FIREBASE_CONFIG.apiKey &&
    FIREBASE_CONFIG.apiKey.indexOf('PASTE_') !== 0
  );
}

async function saveAnnotation(data, idToken) {
  const { projectId, apiKey, collection } = FIREBASE_CONFIG;
  const databaseId = FIREBASE_CONFIG.databaseId || '(default)';
  const url =
    `https://firestore.googleapis.com/v1/projects/${projectId}` +
    `/databases/${encodeURIComponent(databaseId)}/documents/${collection}?key=${apiKey}`;

  const payload = toFirestoreFields({
    ...data,
    created_at: new Date()
  });

  const headers = { 'Content-Type': 'application/json' };
  if (idToken) {
    headers['Authorization'] = `Bearer ${idToken}`;
  }

  const response = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify(payload)
  });

  if (!response.ok) {
    // A 403 / PERMISSION_DENIED here means the signed-in account isn't on the
    // curator allowlist (or email isn't verified). Surface a specific code so
    // the caller can show a friendly "request access" message.
    let detail = `HTTP ${response.status}`;
    try {
      const body = await response.json();
      if (body.error && body.error.message) detail = body.error.message;
    } catch (e) { /* keep the status-code detail */ }
    if (response.status === 403 || /PERMISSION_DENIED|insufficient/i.test(detail)) {
      const err = new Error(detail);
      err.notAuthorized = true;
      throw err;
    }
    throw new Error(detail);
  }

  return response.json();
}

document.addEventListener('DOMContentLoaded', async () => {
  const form = document.getElementById('poc-form');
  const saveButton = document.getElementById('save');
  const emailField = document.getElementById('user_email');

  // Show a hint of the signed-in Chrome profile email. In 'google' mode the
  // authoritative, verified email is resolved on save (via sign-in); in other
  // modes this profile email is what gets persisted.
  const mode = FIREBASE_CONFIG.authMode || 'none';
  userEmail = await getUserEmail();
  if (userEmail) {
    emailField.value = userEmail;
  } else if (mode === 'google') {
    emailField.placeholder = 'will be set from Google sign-in on save';
  } else {
    emailField.placeholder = 'no signed-in Google account detected';
    setStatus(
      'No Google account detected. Sign into Chrome with a synced Google profile to submit.',
      'err'
    );
  }

  form.addEventListener('submit', async (event) => {
    event.preventDefault();

    if (!isConfigured()) {
      setStatus(
        'Not configured. Set projectId and apiKey in firebase-config.js.',
        'err'
      );
      return;
    }

    saveButton.disabled = true;

    // Authenticate first — in 'google' mode this yields the verified email that
    // we persist (so it matches request.auth.token.email in the rules).
    let auth;
    try {
      setStatus('Authenticating...', '');
      auth = await ensureAuth();
      if (auth.email) {
        userEmail = auth.email;
        emailField.value = auth.email;
      }
    } catch (err) {
      console.error('POC auth failed:', err, new Date().toISOString());
      setStatus(`Sign-in failed: ${err.message}`, 'err');
      saveButton.disabled = false;
      return;
    }

    const data = readForm();
    const error = validate(data);
    if (error) {
      setStatus(error, 'err');
      saveButton.disabled = false;
      return;
    }

    setStatus('Saving...', '');
    try {
      const result = await saveAnnotation(data, auth.idToken);
      const docId = result.name ? result.name.split('/').pop() : '(unknown)';
      console.log('POC saved Firestore doc:', result.name, new Date().toISOString());
      setStatus(`Saved. Firestore doc id: ${docId}`, 'ok');
      form.reset();
    } catch (err) {
      console.error('POC save failed:', err, new Date().toISOString());
      if (err.notAuthorized) {
        setStatus(
          `Your Google account (${userEmail}) is not authorized to submit. ` +
          `Contact an administrator to be added to the curator allowlist.`,
          'err'
        );
      } else {
        setStatus(`Failed to save: ${err.message}`, 'err');
      }
    } finally {
      saveButton.disabled = false;
    }
  });
});
