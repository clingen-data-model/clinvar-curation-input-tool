/**
 * ClinVar CvC background service worker (classic MV3 worker — no
 * "type":"module" so importScripts works).
 *
 * Serves the in-page SCV highlight content script's request for a
 * variation's prior-annotation history. chrome.identity is unavailable in
 * content scripts, so only the worker (or an extension page) can mint a
 * token; routing the fetch through here reuses S6's silent-auth + history
 * fetch (firestore-history.js) and never triggers an interactive sign-in —
 * no cached Google grant simply means no highlight.
 */
importScripts('env.js', 'firebase-config.js', 'history.js', 'firestore-history.js');

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.subject !== 'getScvHistory') return false;
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
  return true;
});
