/**
 * Shared create-only Firestore write for ClinVar CvC.
 *
 * Single source of truth for converting an annotation doc into the Firestore
 * REST payload and writing it with an explicit content-hash document id, so
 * re-saving the exact same annotation is rejected as ALREADY_EXISTS (409)
 * instead of creating a duplicate row. Moved out of popup.js so the
 * background service worker — which can't load popup.js — can
 * `importScripts` this module directly, exactly like firestore-history.js.
 *
 * References FIREBASE_CONFIG (firebase-config.js) and annotation.js's
 * annotationDocId.
 */

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

/**
 * Classifies a failed Firestore write response into a stable error kind, so
 * callers can branch on behavior (dedup vs. auth) instead of message text.
 *
 * @param {number} status - HTTP status code of the response.
 * @param {object} errorBody - parsed JSON error body (may be {} or undefined).
 * @returns {'alreadyExists'|'notAuthorized'|null}
 */
function classifyWriteError(status, errorBody) {
  const message = (errorBody && errorBody.error && errorBody.error.message) || '';
  const apiStatus = errorBody && errorBody.error && errorBody.error.status;

  if (status === 409 || apiStatus === 'ALREADY_EXISTS') {
    return 'alreadyExists';
  }
  if (status === 403 || /PERMISSION_DENIED|insufficient/i.test(message)) {
    return 'notAuthorized';
  }
  return null;
}

/**
 * Writes a single v4 annotation document to Firestore using createDocument
 * with an explicit, content-hash documentId (see annotation.js's
 * annotationDocId) — this makes the write create-only: re-saving the exact
 * same annotation fields is rejected as ALREADY_EXISTS (409) instead of
 * creating a duplicate row.
 */
async function saveAnnotation(data, idToken) {
  const { projectId, apiKey, collection } = FIREBASE_CONFIG;
  const databaseId = FIREBASE_CONFIG.databaseId || '(default)';
  const annotationDocIdFn = (typeof self !== 'undefined' && self.annotationDocId) ||
    require('./annotation.js').annotationDocId;

  const doc = { ...data, created_at: new Date() };
  const id = await annotationDocIdFn(data);

  const url =
    `https://firestore.googleapis.com/v1/projects/${projectId}` +
    `/databases/${encodeURIComponent(databaseId)}/documents/${collection}` +
    `?documentId=${id}&key=${apiKey}`;

  const payload = toFirestoreFields(doc);

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
    // curator allowlist (or email isn't verified); a 409 / ALREADY_EXISTS
    // means this exact annotation was already saved (create-only write).
    let body = {};
    try {
      body = await response.json();
    } catch (e) { /* keep body === {} */ }
    const kind = classifyWriteError(response.status, body);
    const detail = (body.error && body.error.message) || `HTTP ${response.status}`;
    const err = new Error(detail);
    if (kind === 'alreadyExists') {
      err.alreadyExists = true;
    } else if (kind === 'notAuthorized') {
      err.notAuthorized = true;
    }
    throw err;
  }

  return response.json();
}

(function (root) {
  if (root) { root.toFirestoreFields = toFirestoreFields; root.classifyWriteError = classifyWriteError; root.saveAnnotation = saveAnnotation; }
})(typeof self !== 'undefined' ? self : (typeof window !== 'undefined' ? window : null));
if (typeof module !== 'undefined' && module.exports) { module.exports = { toFirestoreFields, classifyWriteError, saveAnnotation }; }
