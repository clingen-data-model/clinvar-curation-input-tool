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
  return exchangeGoogleToken(googleToken);
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
          // Expected when the active tab isn't a ClinVar variation page, OR when
          // a ClinVar tab was open before the extension loaded/reloaded (static
          // content scripts don't inject into pre-existing tabs — reload the tab).
          // Handled by the isScrapeable() guard below; not a failure, so info-level.
          console.info(
            'CvC: no ClinVar content script in the active tab —',
            chrome.runtime.lastError.message
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

/**
 * Cache of the current variation's prior-annotation rows (as returned by
 * fetchHistory), so the SCV picker's `change` handler can re-render the
 * current-SCV highlight via renderHistory without refetching.
 */
let historyRows = [];

/**
 * Renders the "Prior annotations" panel (#historypanel) from history rows.
 * Pure re-render — no network calls — so it can be called both after a fetch
 * and again (with the same rows) whenever the selected SCV changes, to
 * update the current-SCV highlight. Builds DOM nodes with textContent only
 * (never innerHTML) since notes/user_email are curator-entered text.
 */
function renderHistory(rows, currentScv) {
  const emptyEl = document.getElementById('history-empty');
  const listEl = document.getElementById('history-list');
  if (!emptyEl || !listEl) return;

  const historyViewFn = (typeof window !== 'undefined' && window.historyView) ||
    require('./popup-view.js').historyView;
  const displayRows = historyViewFn(rows || [], currentScv || '');

  while (listEl.firstChild) listEl.removeChild(listEl.firstChild);

  if (displayRows.length === 0) {
    emptyEl.style.display = '';
    return;
  }
  emptyEl.style.display = 'none';

  displayRows.forEach((r) => {
    const entry = document.createElement('div');
    entry.className = r.isCurrent ? 'history-entry current' : 'history-entry';

    const metaRow = document.createElement('div');
    metaRow.className = 'row';
    const metaLabel = document.createElement('span');
    metaLabel.textContent = `${r.when} · ${r.who}`;
    const metaValue = document.createElement('span');
    metaValue.textContent = r.summary;
    metaRow.appendChild(metaLabel);
    metaRow.appendChild(metaValue);
    entry.appendChild(metaRow);

    if (r.notes) {
      const notesRow = document.createElement('div');
      notesRow.className = 'row';
      const notesLabel = document.createElement('span');
      notesLabel.textContent = 'Notes';
      const notesValue = document.createElement('span');
      notesValue.textContent = r.notes;
      notesRow.appendChild(notesLabel);
      notesRow.appendChild(notesValue);
      entry.appendChild(notesRow);
    }

    listEl.appendChild(entry);
  });
}

/**
 * Loads and renders prior-annotation history for the current ClinVar
 * variation. Best-effort and non-blocking: leaves the panel's built-in empty
 * state untouched whenever there's no variationId, no silent auth available
 * (never prompts interactively), or the fetch fails for any reason — history
 * must never block or break the save flow.
 */
async function loadHistory(variationId, currentScv) {
  if (!variationId) return;
  try {
    const idToken = await silentIdToken();
    if (!idToken) return;
    historyRows = await fetchHistory(variationId, idToken);
    renderHistory(historyRows, currentScv);
  } catch (e) {
    console.info('CvC: history load failed —', e && e.message);
  }
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
  if (!window.isScrapeable(clinvarData)) {
    setStatus(
      'No ClinVar variation data found on this tab. Open a ClinVar variation ' +
      'record (…/clinvar/variation/<id>); if you are already on one, reload the ' +
      'tab (the extension only injects on page load), then reopen this popup.',
      'err'
    );
    [scvSelect, actionSelect, reasonSelect, saveButton].forEach((el) => { el.disabled = true; });
    return;
  }

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

  // Best-effort, silent-auth-only history load — never blocks the picker and
  // never prompts for interactive sign-in just because the popup was opened.
  loadHistory(clinvarData.variation_id, '');

  scvSelect.addEventListener('change', () => {
    const selectedVal = scvSelect.value;

    // Every SCV switch resets the action/reason so the curator re-chooses per
    // SCV — otherwise a stale, still-valid action/reason from the previously
    // selected SCV would be submitted against the newly selected one.
    actionSelect.value = '';
    reasonSelect.disabled = true;
    clearOptions(reasonSelect);
    addChooseOption(reasonSelect);

    if (!selectedVal || !clinvarData) {
      resetScvDisplay();
      actionSelect.disabled = true;
      renderHistory(historyRows, '');
      return;
    }
    const scvRow = clinvarData.row[Number(selectedVal)];
    populateScvDisplay(scvRow);
    actionSelect.disabled = false;
    // Re-render (not refetch) so this SCV's prior entries are highlighted.
    renderHistory(historyRows, scvRow.scv);
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

      const vcv = { vcv: clinvarData.vcv, variation_id: clinvarData.variation_id, name: clinvarData.name };
      const doc = buildAnnotation(scvRow, vcv, input, auth.email);

      setStatus('Saving...', '');
      await saveAnnotation(doc, auth.idToken);
      console.log('CvC saved annotation', new Date().toISOString());
      // Reload the ClinVar tab so the in-page annotation highlights refresh
      // with the just-saved curation, then close the popup. Best-effort — a
      // reload failure must not block closing.
      try {
        const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
        if (tab && tab.id != null) await chrome.tabs.reload(tab.id);
      } catch (e) {
        console.info('CvC: tab reload after save skipped —', e && e.message);
      }
      window.close();
    } catch (err) {
      console.error('CvC save failed:', err, new Date().toISOString());
      if (err.alreadyExists) {
        setStatus('This annotation was already saved.', 'err');
      } else if (err.notAuthorized) {
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

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {};
}
