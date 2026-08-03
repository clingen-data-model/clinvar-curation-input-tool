/**
 * ClinVar CvC background service worker (classic MV3 worker — no
 * "type":"module" so importScripts works).
 *
 * Serves two requests from the in-page content script, which can't mint a
 * Google/Firebase auth token itself (chrome.identity is unavailable in
 * content scripts):
 *  - getScvHistory: a variation's prior-annotation history, via S6's
 *    silent-auth + history fetch (firestore-history.js). Never triggers an
 *    interactive sign-in — no cached Google grant simply means no highlight.
 *  - saveAnnotation: the S7 in-page Annotate form's save, via the same
 *    create-only write path the popup uses (annotation.js +
 *    firestore-write.js), with ensureWriteAuth's silent-then-interactive
 *    auth fallback.
 */
importScripts(
  'env.js',
  'firebase-config.js',
  'history.js',
  'firestore-history.js',
  'annotation.js',
  'firestore-write.js'
);

function handleGetScvHistory(message, sendResponse) {
  (async () => {
    try {
      const idToken = await silentIdToken();
      if (!idToken) { sendResponse({ ok: false, reason: 'no-auth', rows: [] }); return; }
      const rows = await fetchHistory(message.variationId, idToken);
      sendResponse({ ok: true, rows });
    } catch (e) {
      sendResponse({ ok: false, reason: 'error', rows: [] });
    }
  })();
}

function handleSaveAnnotation(message, sendResponse) {
  (async () => {
    try {
      const { idToken, email } = await ensureWriteAuth();
      const doc = buildAnnotation(message.scvRow, message.vcv, message.input, email);
      const invalid = validateAnnotation(doc);
      if (invalid) { sendResponse({ ok: false, reason: 'invalid', message: invalid }); return; }
      await saveAnnotation(doc, idToken);
      sendResponse({ ok: true, email });
    } catch (e) {
      if (e && e.alreadyExists) { sendResponse({ ok: false, reason: 'alreadyExists' }); return; }
      if (e && e.notAuthorized) { sendResponse({ ok: false, reason: 'notAuthorized' }); return; }
      sendResponse({ ok: false, reason: 'error', message: e && e.message });
    }
  })();
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message) return false;
  if (message.subject === 'getScvHistory') {
    handleGetScvHistory(message, sendResponse);
    return true;
  }
  if (message.subject === 'saveAnnotation') {
    handleSaveAnnotation(message, sendResponse);
    return true;
  }
  return false;
});
