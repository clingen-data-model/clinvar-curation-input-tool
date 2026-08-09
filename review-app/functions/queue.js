// queue.js — the review queue. Two sources merged so a just-captured annotation
// appears within seconds even before the cross-region adapter copies it to BQ
// (re-spec 2026-08-08, "Firestore LIST for freshness; BQ stays system of record"):
//   1. BQ: cvc_annotations("unreviewed") ⋈ cvc_review_state — the enriched,
//      auto-reviewed unreviewed rows already streamed/adapted into BQ (as built).
//   2. Firestore: the most recent captures (clinvar_cvc_ext_annotations); any NOT
//      yet in BQ are surfaced as "fresh" rows with null derived flags (auto-review
//      + flags fill in on the next adapter refresh — their natural cadence).
// Pure SQL/merge logic (unit-tested) + injected readers (BQ + Firestore). Reads
// only; never writes.
const { assertReadDataset, assertWriteDataset } = require('./dataset-guard.js');
const { autoReview } = require('./autoReview.js');

// The enriched-unreviewed columns (all clinvar_ingest-derived → expensive to
// compute). Materialized in cvc_review_queue_base; read fast by the queue.
const BASE_COLS = [
  'annotation_id', 'variation_id', 'vcv_id', 'scv_id', 'scv_ver',
  'submitter_id', 'submitter_name', 'action', 'reason', 'notes',
  'curator', 'clinvar_review_status', 'classif_type', 'latest_scv_classification',
  'is_outdated_scv', 'is_deleted_scv', 'is_latest_annotation',
  'has_prior_scv_id_annotation', 'latest_scv_ver', 'annotated_on'
];

// Refresh (materialize) the enriched-unreviewed set. This is the ONE ~2.5 GB
// cvc_annotations(TVF) scan, run BATCH-side (after the adapter / at finalize),
// NOT per queue load. Plain CREATE OR REPLACE TABLE (a BQ materialized view
// can't sit over a TVF). Write target → dataset-guarded (never clinvar_curator).
function buildRefreshQueueSql({ dataset }) {
  const ds = assertWriteDataset(assertReadDataset(dataset));
  return `CREATE OR REPLACE TABLE \`clingen-dev.${ds}.cvc_review_queue_base\` AS\n` +
    `SELECT ${BASE_COLS.join(', ')}\n` +
    `FROM \`clingen-dev.${ds}.cvc_annotations\`("unreviewed")`;
}

// The queue read: the small materialized base + a LIVE join to cvc_review_state
// (tiny; in-progress status/batch must be real-time, not materialized). Fast —
// no TVF, no clinvar_ingest scan.
function buildQueueSql({ dataset }) {
  const ds = assertReadDataset(dataset);
  return [
    'SELECT',
    '  ' + BASE_COLS.map((c) => 'base.' + c).join(', ') + ',',
    '  rs.review_status AS rs_review_status, rs.reviewer AS rs_reviewer,',
    '  rs.notes AS rs_notes, rs.batch_id AS rs_batch_id',
    `FROM \`clingen-dev.${ds}.cvc_review_queue_base\` base`,
    `LEFT JOIN \`clingen-dev.${ds}.cvc_review_state\` rs USING (annotation_id)`,
    'ORDER BY base.annotated_on'
  ].join('\n');
}

// Which of `ids` are ALREADY in BQ (native_v4 = what the adapter has copied). A
// Firestore candidate NOT in this set is a fresh, not-yet-adapted capture.
function buildInBqSql({ dataset, ids }) {
  const ds = assertReadDataset(dataset);
  return {
    sql: `SELECT annotation_id FROM \`clingen-dev.${ds}.cvc_annotations_native_v4\` WHERE annotation_id IN UNNEST(@ids)`,
    params: { ids: (ids || []).map(String) }
  };
}

// The saved in-progress review state for `ids` — so a fresh row reflects a
// status the curator already saved (else the overlay would show it as unsaved).
function buildReviewStateSql({ dataset, ids }) {
  const ds = assertReadDataset(dataset);
  return {
    sql: `SELECT annotation_id, review_status, reviewer, notes, batch_id FROM \`clingen-dev.${ds}.cvc_review_state\` WHERE annotation_id IN UNNEST(@ids)`,
    params: { ids: (ids || []).map(String) }
  };
}

// Attach the auto-review suggestion to a (BQ-enriched) queue row.
function enrichRow(r, reviewers) {
  const suggestion = autoReview({
    action: r.action, clinvarReviewStatus: r.clinvar_review_status, curator: r.curator,
    isDeletedScv: r.is_deleted_scv, isLatestAnnotation: r.is_latest_annotation,
    isOutdatedScv: r.is_outdated_scv,
    classificationChanged: !!r.is_outdated_scv && r.latest_scv_classification != null
      && r.latest_scv_classification !== r.classif_type
  }, reviewers);
  return { ...r, auto_status: suggestion.status, auto_note: suggestion.note, fresh: false };
}

// Split a full SCV accession "SCV000993408.4" -> { scv_id, scv_ver }.
function splitScv(scv) {
  const s = String(scv || '');
  const dot = s.lastIndexOf('.');
  return dot > 0 ? { scv_id: s.slice(0, dot), scv_ver: s.slice(dot + 1) } : { scv_id: s, scv_ver: '' };
}

// Shape a Firestore annotation doc into a queue row. Derived flags are null (not
// enriched yet) so `fresh` is marked; action is lowercased to match enriched
// rows; any SAVED review state (rs) the curator already recorded is surfaced so
// the overlay doesn't show a saved row as unsaved.
function shapeFreshRow(doc, rs) {
  const { scv_id, scv_ver } = splitScv(doc.scv);
  return {
    annotation_id: doc.annotation_id, variation_id: doc.variation_id, vcv_id: doc.vcv,
    scv_id, scv_ver, submitter_id: doc.submitter_id, submitter_name: doc.submitter,
    action: String(doc.action || '').toLowerCase(), reason: doc.reason, notes: doc.notes,
    curator: doc.user_email, clinvar_review_status: doc.review_status,
    classif_type: null, latest_scv_classification: null,
    is_outdated_scv: null, is_deleted_scv: null, is_latest_annotation: null,
    has_prior_scv_id_annotation: null, latest_scv_ver: null, annotated_on: doc.created_at || null,
    rs_review_status: (rs && rs.review_status) || null, rs_reviewer: (rs && rs.reviewer) || null,
    rs_notes: (rs && rs.notes) || null, rs_batch_id: (rs && rs.batch_id) || null,
    auto_status: '', auto_note: 'new capture — flags/auto-review pending next refresh',
    fresh: true
  };
}

// Merge BQ-enriched rows with fresh Firestore candidates not yet in BQ.
// `rsMap` = annotation_id -> saved cvc_review_state row (for fresh rows).
function mergeQueue(enrichedBqRows, candidates, inBqIds, rsMap) {
  const seen = new Set(enrichedBqRows.map((r) => r.annotation_id));
  const inBq = inBqIds instanceof Set ? inBqIds : new Set(inBqIds || []);
  const rs = rsMap || {};
  const fresh = (candidates || [])
    .filter((c) => c && c.annotation_id && !inBq.has(c.annotation_id) && !seen.has(c.annotation_id))
    .map((c) => shapeFreshRow(c, rs[c.annotation_id]));
  return [...enrichedBqRows, ...fresh];
}

// Injected: runQuery(sql, params?) -> rows; getReviewers() -> string[];
// getRecentCaptures() -> recent Firestore annotation docs. Returns { rows }.
function makeQueueHandler({ runQuery, dataset, getReviewers, getRecentCaptures }) {
  return async function queue() {
    const reviewers = getReviewers ? ((await getReviewers()) || []) : [];
    const enriched = ((await runQuery(buildQueueSql({ dataset }))) || []).map((r) => enrichRow(r, reviewers));
    if (!getRecentCaptures) return { rows: enriched };

    const candidates = (await getRecentCaptures()) || [];
    const ids = candidates.map((c) => c && c.annotation_id).filter(Boolean);
    let inBq = new Set();
    let rsMap = {};
    if (ids.length) {
      const inBqQ = buildInBqSql({ dataset, ids });
      inBq = new Set(((await runQuery(inBqQ.sql, inBqQ.params)) || []).map((r) => r.annotation_id));
      const rsQ = buildReviewStateSql({ dataset, ids });
      rsMap = Object.fromEntries(((await runQuery(rsQ.sql, rsQ.params)) || []).map((r) => [r.annotation_id, r]));
    }
    return { rows: mergeQueue(enriched, candidates, inBq, rsMap) };
  };
}

module.exports = { buildQueueSql, buildRefreshQueueSql, buildInBqSql, buildReviewStateSql, enrichRow, splitScv, shapeFreshRow, mergeQueue, makeQueueHandler };
