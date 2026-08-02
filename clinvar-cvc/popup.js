/**
 * ClinVar CvC popup logic.
 *
 * Scrapes the active ClinVar variation tab (via content.js), lets the curator
 * pick an SCV and an action/reason, then writes a single v4 annotation
 * document to Firestore using the Firestore REST API (no Firebase SDK —
 * keeps the extension build-free and MV3-CSP friendly). The Firestore ->
 * BigQuery Firebase Extension then streams the document into BigQuery.
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

/**
 * Asks the active tab's content script (content.js) to scrape the current
 * ClinVar variation page. Resolves to the scraped data, or null if there is
 * no active tab / no content script response (e.g. not on a ClinVar page).
 *
 * @returns {Promise<object|null>}
 */
async function requestClinVarData() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) return null;
  return new Promise((resolve) => {
    chrome.tabs.sendMessage(
      tab.id,
      { from: 'popup', subject: 'initializePopup' },
      (response) => {
        if (chrome.runtime.lastError) {
          console.error(
            'CvC initializePopup failed:', chrome.runtime.lastError.message, new Date().toISOString()
          );
          resolve(null);
          return;
        }
        resolve(response || null);
      }
    );
  });
}

/** Clears all <option>/<optgroup> children of a <select>, keeping none. */
function clearOptions(select) {
  while (select.firstChild) select.removeChild(select.firstChild);
}

function addChooseOption(select) {
  const opt = document.createElement('option');
  opt.value = '';
  opt.textContent = 'Choose...';
  opt.selected = true;
  select.appendChild(opt);
}

document.addEventListener('DOMContentLoaded', async () => {
  if ((FIREBASE_CONFIG.env || 'prod') !== 'prod') {
    const b = document.getElementById('env-banner');
    if (b) { b.textContent = `DEV — ${FIREBASE_CONFIG.projectId}`; b.style.display = 'block'; }
  }

  const saveButton = document.getElementById('save');
  const scvSelect = document.getElementById('scvselect');
  const actionSelect = document.getElementById('action');
  const reasonSelect = document.getElementById('reason');
  const notesField = document.getElementById('notes');
  const vcvIdEl = document.getElementById('vcvid');
  const variantNameEl = document.getElementById('variant_name');

  const readOnlyIds = ['interp_ro', 'review_ro', 'eval_date_ro', 'submitter_ro', 'origin_ro', 'method_ro'];

  let clinvarData = null;

  function resetScvDisplay() {
    readOnlyIds.forEach((id) => { document.getElementById(id).textContent = ''; });
  }

  function populateScvDisplay(scvRow) {
    document.getElementById('interp_ro').textContent = scvRow.interp || '';
    document.getElementById('review_ro').textContent = scvRow.review || '';
    document.getElementById('eval_date_ro').textContent = scvRow.eval_date || '';
    document.getElementById('submitter_ro').textContent = scvRow.submitter || '';
    document.getElementById('origin_ro').textContent = scvRow.origin || '';
    document.getElementById('method_ro').textContent = scvRow.method || '';
  }

  function populateVcvDisplay(data) {
    document.getElementById('vcv_interp_ro').textContent = data.vcv_interp || '';
    document.getElementById('vcv_review_ro').textContent = data.vcv_review || '';
    document.getElementById('vcv_eval_date_ro').textContent = data.vcv_eval_date || '';
  }

  // Scrape the active ClinVar tab and populate the header + SCV picker.
  clinvarData = await requestClinVarData();
  if (clinvarData) {
    vcvIdEl.textContent = clinvarData.vcv || '';
    variantNameEl.textContent = clinvarData.name || '';
    populateVcvDisplay(clinvarData);

    clearOptions(scvSelect);
    addChooseOption(scvSelect);
    (clinvarData.row || []).forEach((row, index) => {
      const opt = document.createElement('option');
      opt.value = String(index);
      opt.textContent = scvOptionLabel(row);
      scvSelect.appendChild(opt);
    });
  } else {
    setStatus(
      'Could not read this ClinVar page. Open a ClinVar variation page and reopen the popup.',
      'err'
    );
  }

  scvSelect.addEventListener('change', () => {
    const selectedVal = scvSelect.value;
    if (!selectedVal || !clinvarData) {
      resetScvDisplay();
      actionSelect.disabled = true;
      actionSelect.value = '';
      reasonSelect.disabled = true;
      clearOptions(reasonSelect);
      addChooseOption(reasonSelect);
      return;
    }
    const scvRow = clinvarData.row[Number(selectedVal)];
    populateScvDisplay(scvRow);
    actionSelect.disabled = false;
  });

  actionSelect.addEventListener('change', () => {
    const action = actionSelect.value;

    clearOptions(reasonSelect);
    addChooseOption(reasonSelect);
    reasonOptionGroups(action).forEach((group) => {
      if (group.label) {
        const optgroup = document.createElement('optgroup');
        optgroup.label = group.label;
        group.options.forEach((text) => {
          const opt = document.createElement('option');
          opt.value = text;
          opt.textContent = text;
          optgroup.appendChild(opt);
        });
        reasonSelect.appendChild(optgroup);
      } else {
        group.options.forEach((text) => {
          const opt = document.createElement('option');
          opt.value = text;
          opt.textContent = text;
          reasonSelect.appendChild(opt);
        });
      }
    });

    reasonSelect.disabled = !action;
    reasonSelect.value = '';
  });

  saveButton.addEventListener('click', async (event) => {
    event.preventDefault();

    if (!isConfigured()) {
      setStatus(
        'Not configured. Set projectId and apiKey in firebase-config.js.',
        'err'
      );
      return;
    }

    const selectedVal = scvSelect.value;
    const scvRow = selectedVal && clinvarData ? clinvarData.row[Number(selectedVal)] : undefined;
    const input = {
      action: actionSelect.value,
      reason: reasonSelect.value,
      notes: notesField.value.trim()
    };

    const error = validateAnnotation({ scv: scvRow && scvRow.scv, action: input.action, reason: input.reason });
    if (error) {
      setStatus(error, 'err');
      return;
    }

    saveButton.disabled = true;
    let auth;
    try {
      setStatus('Authenticating...', '');
      auth = await ensureAuth();

      const vcv = { vcv: clinvarData.vcv, variation_id: clinvarData.variation_id };
      const doc = buildAnnotation(scvRow, vcv, input, auth.email);

      setStatus('Saving...', '');
      const result = await saveAnnotation(doc, auth.idToken);
      const docId = result.name ? result.name.split('/').pop() : '(unknown)';
      console.log('CvC saved Firestore doc:', result.name, new Date().toISOString());
      setStatus(`Saved. Firestore doc id: ${docId}`, 'ok');
    } catch (err) {
      console.error('CvC save failed:', err, new Date().toISOString());
      if (err.notAuthorized) {
        setStatus(
          `Your Google account (${(auth && auth.email) || ''}) is not authorized to submit. ` +
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
