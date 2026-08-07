// index.js — Review & Submit web-app backend (Cloud Functions v2).
//
// Wiring only: the testable logic lives in auth.js (unit-tested). This file
// binds firebase-admin to the injected auth guard and exposes the Chunk-0
// smoke endpoint GET /api/whoami. Verified via deploy + manual check, not unit
// tests. Deploy ONLY with: firebase deploy --only hosting,functions
// (never a bare `firebase deploy` — see review-app/README.md).
const { onRequest } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { makeAuthGuard, makeFirestoreAllowlistLookup, authErrorStatus } = require('./auth.js');

admin.initializeApp();

const guard = makeAuthGuard({
  verifyIdToken: (tok) => admin.auth().verifyIdToken(tok),
  isAllowlisted: makeFirestoreAllowlistLookup(admin.firestore())
});

// Single HTTP entry (Hosting rewrites /api/** here). Chunk 0 handles /whoami;
// later chunks add /queue, /generate, /review, /assign, /finalize.
exports.api = onRequest(async (req, res) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Headers', 'Authorization, Content-Type');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  if (req.method === 'OPTIONS') { res.status(204).send(''); return; }
  try {
    const { email } = await guard(req);
    const path = (req.path || '/').replace(/^\/api/, '') || '/';
    if (path === '/whoami' || path === '/') { res.json({ ok: true, email }); return; }
    res.status(404).json({ ok: false, error: 'notFound' });
  } catch (err) {
    res.status(authErrorStatus(err)).json({ ok: false, error: err.code || 'error', message: err.message });
  }
});
