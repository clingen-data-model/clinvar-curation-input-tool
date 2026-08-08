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
const { google } = require('googleapis');
const { makeAuthGuard, makeFirestoreAllowlistLookup, authErrorStatus } = require('./auth.js');
const { makeQueueHandler } = require('./queue.js');
const { makeDriveWriter } = require('./drive.js');
const { makeGenerateHandler } = require('./generate.js');
const { makeReviewHandler } = require('./review.js');
const { makeFinalizeHandler } = require('./finalize.js');
const { makeConfigHandler } = require('./config.js');

admin.initializeApp();

// The BQ datasets live in clingen-dev/US; the runtime SA has jobUser there +
// dataset-scoped read/write (scripts/grant-iam.sh). REVIEW_DATASET selects the
// v4 shadow (dev default; set clinvar_curator_v4 for the prod shadow).
const CURATOR_PROJECT = process.env.CURATOR_PROJECT || 'clingen-dev';
const REVIEW_DATASET = process.env.REVIEW_DATASET || 'clinvar_curator_v4_dev';
const bq = new BigQuery({ projectId: CURATOR_PROJECT, location: 'US' });
const runQuery = async (sql, params) => {
  const [rows] = await bq.query({ query: sql, useLegacySql: false, location: 'US', params: params || undefined });
  return rows;
};
// DML runner → number of affected rows (for MERGE/UPDATE gate results).
const runDml = async (sql, params) => {
  const [job] = await bq.createQueryJob({ query: sql, useLegacySql: false, location: 'US', params: params || undefined });
  await job.getQueryResults();
  const [meta] = await job.getMetadata();
  return Number((meta.statistics && meta.statistics.query && meta.statistics.query.numDmlAffectedRows) || 0);
};

const guard = makeAuthGuard({
  verifyIdToken: (tok) => admin.auth().verifyIdToken(tok),
  isAllowlisted: makeFirestoreAllowlistLookup(admin.firestore())
});
const configHandler = makeConfigHandler({ runQuery, dataset: REVIEW_DATASET });
// Firestore LIST read for queue freshness (re-spec 2026-08-08): the most recent
// captures, so a just-made annotation shows before the adapter copies it to BQ.
const REVIEW_CAPTURE_COLLECTION = process.env.REVIEW_CAPTURE_COLLECTION || 'clinvar_cvc_ext_annotations';
const RECENT_CAPTURE_LIMIT = Number(process.env.RECENT_CAPTURE_LIMIT || 500);
const getRecentCaptures = async () => {
  const snap = await admin.firestore().collection(REVIEW_CAPTURE_COLLECTION)
    .orderBy('created_at', 'desc').limit(RECENT_CAPTURE_LIMIT).get();
  return snap.docs.map((d) => d.data());
};
const queueHandler = makeQueueHandler({
  runQuery, dataset: REVIEW_DATASET,
  getReviewers: () => configHandler().then((c) => c.reviewers),
  getRecentCaptures
});

// Drive writer (deploy-time creds via ADC). Writes to the SEPARATE dev
// submission folder (REVIEW_DRIVE_FOLDER); the runtime SA must be a member of
// that Shared Drive. env = prod only when pointed at the prod shadow.
const driveWriter = makeDriveWriter(
  google.drive({ version: 'v3', auth: new google.auth.GoogleAuth({ scopes: ['https://www.googleapis.com/auth/drive'] }) })
);
const generateHandler = makeGenerateHandler({
  runQuery,
  writeNdjson: (a) => driveWriter.writeNdjson(a),
  config: {
    dataset: REVIEW_DATASET,
    driveFolderId: process.env.REVIEW_DRIVE_FOLDER || '',
    env: REVIEW_DATASET === 'clinvar_curator_v4' ? 'prod' : 'dev',
    recipients: (process.env.SUBMISSION_RECIPIENTS || '').split(',').map((s) => s.trim()).filter(Boolean),
    cc: (process.env.SUBMISSION_CC || '').split(',').map((s) => s.trim()).filter(Boolean)
  }
});
const yyyymmdd = (d) => `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`;
const reviewHandler = makeReviewHandler({ runDml, dataset: REVIEW_DATASET });

// Kick the impact-SP refresh as an async job (a 2–5 min re-runnable rebuild);
// do NOT block finalize on it. Returns synchronously.
const startSpRefresh = (sql) => {
  bq.createQueryJob({ query: sql, useLegacySql: false, location: 'US' })
    .then(([job]) => console.log('impact SP refresh started:', job.id))
    .catch((e) => console.error('impact SP refresh failed to start:', e && e.message));
  return 'submitting';
};
const finalizeHandler = makeFinalizeHandler({
  generate: (a) => generateHandler(a), runQuery, runDml, startSpRefresh, config: { dataset: REVIEW_DATASET }
});
const p2 = (n) => String(n).padStart(2, '0');

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
    if (path === '/config' && req.method === 'GET') {
      res.json({ ok: true, ...(await configHandler()) });
      return;
    }
    if (path === '/queue' && req.method === 'GET') {
      const { rows } = await queueHandler();
      res.json({ ok: true, rows });
      return;
    }
    if (path === '/generate' && req.method === 'POST') {
      const batchId = String((req.body && req.body.batchId) || '');
      const out = await generateHandler({ batchId, date: yyyymmdd(new Date()) });
      res.json({ ok: true, ...out });
      return;
    }
    if (path === '/review' && req.method === 'POST') {
      const b = req.body || {};
      const out = await reviewHandler.setReview({
        annotationId: b.annotationId, scvId: b.scvId, scvVer: b.scvVer,
        status: b.status, notes: b.notes, reviewer: email // server-verified, never client
      });
      res.json({ ok: true, ...out });
      return;
    }
    if (path === '/assign' && req.method === 'POST') {
      const b = req.body || {};
      const out = await reviewHandler.assign({ annotationId: b.annotationId, batchId: b.batchId });
      res.json({ ok: true, ...out });
      return;
    }
    if (path === '/unassign' && req.method === 'POST') {
      const b = req.body || {};
      const out = await reviewHandler.unassign({ annotationId: b.annotationId, batchId: b.batchId });
      res.json({ ok: true, ...out });
      return;
    }
    if (path === '/finalize' && req.method === 'POST') {
      const batchId = String((req.body && req.body.batchId) || '');
      const d = new Date();
      const fdt = `${d.getFullYear()}-${p2(d.getMonth() + 1)}-${p2(d.getDate())} ${p2(d.getHours())}:${p2(d.getMinutes())}:${p2(d.getSeconds())}`;
      const out = await finalizeHandler({ batchId, date: yyyymmdd(d), finalizedDatetime: fdt });
      res.json({ ok: true, ...out });
      return;
    }
    res.status(404).json({ ok: false, error: 'notFound' });
  } catch (err) {
    res.status(authErrorStatus(err)).json({ ok: false, error: err.code || 'error', message: err.message });
  }
});
