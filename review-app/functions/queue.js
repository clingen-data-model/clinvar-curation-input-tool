// queue.js — the review queue: unreviewed v4 annotations plus any in-progress
// review state the app has recorded. Pure SQL builder (unit-tested) + a thin
// injected handler (runQuery is passed in, so the BigQuery client is deploy-time
// only). Reads the v4 dataset; never writes.
const { assertReadDataset } = require('./dataset-guard.js');
const { autoReview } = require('./autoReview.js');

// Build the review-queue SQL for a v4 dataset. cvc_annotations(scope) already
// carries the FINALIZED review fields, but for the queue we want the app's
// IN-PROGRESS state, so we LEFT JOIN cvc_review_state and alias its fields
// `rs_*`. Scope "unreviewed" = annotations not yet in cvc_clinvar_reviews.
// latest_scv_classification + classif_type drive the auto-review suggestion.
function buildQueueSql({ dataset }) {
  const ds = assertReadDataset(dataset); // read is fine on any v4 dataset; kept explicit
  return [
    'SELECT',
    '  a.annotation_id, a.variation_id, a.vcv_id, a.scv_id, a.scv_ver,',
    '  a.submitter_id, a.submitter_name, a.action, a.reason, a.notes,',
    '  a.curator, a.clinvar_review_status, a.classif_type, a.latest_scv_classification,',
    '  a.is_outdated_scv, a.is_deleted_scv, a.is_latest_annotation,',
    '  a.has_prior_scv_id_annotation, a.latest_scv_ver, a.annotated_on,',
    '  rs.review_status AS rs_review_status, rs.reviewer AS rs_reviewer,',
    '  rs.notes AS rs_notes, rs.batch_id AS rs_batch_id',
    `FROM \`clingen-dev.${ds}.cvc_annotations\`("unreviewed") a`,
    `LEFT JOIN \`clingen-dev.${ds}.cvc_review_state\` rs USING (annotation_id)`,
    'ORDER BY a.annotated_on'
  ].join('\n');
}

// Attach the auto-review suggestion (autoReview.js) to a queue row.
// classification changed = outdated AND the latest SCV classification differs.
function enrichRow(r, reviewers) {
  const suggestion = autoReview({
    action: r.action, clinvarReviewStatus: r.clinvar_review_status, curator: r.curator,
    isDeletedScv: r.is_deleted_scv, isLatestAnnotation: r.is_latest_annotation,
    isOutdatedScv: r.is_outdated_scv,
    classificationChanged: !!r.is_outdated_scv && r.latest_scv_classification != null
      && r.latest_scv_classification !== r.classif_type
  }, reviewers);
  return { ...r, auto_status: suggestion.status, auto_note: suggestion.note };
}

// Injected handler: runQuery(sql) -> rows; getReviewers() -> string[] (the
// auto-OK allow-list from cvc_review_config). Returns { rows } with each row
// carrying auto_status/auto_note (the suggested default review).
function makeQueueHandler({ runQuery, dataset, getReviewers }) {
  return async function queue() {
    const reviewers = getReviewers ? ((await getReviewers()) || []) : [];
    const rows = (await runQuery(buildQueueSql({ dataset }))) || [];
    return { rows: rows.map((r) => enrichRow(r, reviewers)) };
  };
}

module.exports = { buildQueueSql, makeQueueHandler };
