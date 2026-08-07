// index.js — Review & Submit web-app backend (Cloud Functions v2).
//
// Wiring only: the testable logic lives in the sibling modules (auth.js,
// queue.js, …), which ARE unit-tested. This file binds firebase-admin + a
// BigQuery client to those and routes /api/**. Verified via deploy + manual
// check. Deploy ONLY with: firebase deploy --only hosting,functions
// (never a bare `firebase deploy` — see review-app/README.md).
const { onRequest } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { BigQuery } = require('@google-cloud/bigquery');
const { makeAuthGuard, makeFirestoreAllowlistLookup, authErrorStatus } = require('./auth.js');
const { makeQueueHandler } = require('./queue.js');

admin.initializeApp();

// The BQ datasets live in clingen-dev/US; the runtime SA has jobUser there +
// dataset-scoped read/write (scripts/grant-iam.sh). REVIEW_DATASET selects the
// v4 shadow (dev default; set clinvar_curator_v4 for the prod shadow).
const CURATOR_PROJECT = process.env.CURATOR_PROJECT || 'clingen-dev';
const REVIEW_DATASET = process.env.REVIEW_DATASET || 'clinvar_curator_v4_dev';
const bq = new BigQuery({ projectId: CURATOR_PROJECT, location: 'US' });
const runQuery = async (sql) => {
  const [rows] = await bq.query({ query: sql, useLegacySql: false, location: 'US' });
  return rows;
};

const guard = makeAuthGuard({
  verifyIdToken: (tok) => admin.auth().verifyIdToken(tok),
  isAllowlisted: makeFirestoreAllowlistLookup(admin.firestore())
});
const queueHandler = makeQueueHandler({ runQuery, dataset: REVIEW_DATASET });

// Single HTTP entry (Hosting rewrites /api/** here). Chunks add routes here;
// review/assign/generate/finalize (POST) land in later chunks.
exports.api = onRequest(async (req, res) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Headers', 'Authorization, Content-Type');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  if (req.method === 'OPTIONS') { res.status(204).send(''); return; }
  try {
    const { email } = await guard(req);
    const path = (req.path || '/').replace(/^\/api/, '') || '/';
    if (path === '/whoami' || path === '/') { res.json({ ok: true, email }); return; }
    if (path === '/queue' && req.method === 'GET') {
      const { rows } = await queueHandler();
      res.json({ ok: true, rows });
      return;
    }
    res.status(404).json({ ok: false, error: 'notFound' });
  } catch (err) {
    res.status(authErrorStatus(err)).json({ ok: false, error: err.code || 'error', message: err.message });
  }
});
