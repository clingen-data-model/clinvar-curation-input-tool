// review.js — backend WRITE path: set review status + assign/unassign a batch,
// as parameterized MERGE/UPDATE against the app's cvc_review_state. Pure builders
// return { sql, params } (named params → no injection); handlers take an injected
// runDml(sql, params) -> affectedRows. The reviewer is the server-verified email
// (never trusted from the client). Dataset-guarded (v4 only). CommonJS.
const { assertReadDataset } = require('./dataset-guard.js');

const STATUSES = ['OK', 'Fixed', 'Archive', 'Question'];
// Only these actions may be assigned to a submission batch (mirrors
// ReviewSubmit.js assignToNextBatch); enforced server-side against the
// authoritative native table, not the client.
const ASSIGNABLE_ACTIONS = ['flagging candidate', 'remove flagged submission'];

function assertStatus(status) {
  if (!STATUSES.includes(status)) {
    throw new Error(`review: status must be one of ${STATUSES.join('/')}, got '${status}'`);
  }
  return status;
}
function assertNumeric(name, v) {
  if (!/^\d+$/.test(String(v))) throw new Error(`review: ${name} must be numeric, got '${v}'`);
  return String(v);
}

// Upsert the in-progress review for an annotation. INSERT carries scv_id/scv_ver
// (captured at review time — the SP joins submissions on them) + date_added;
// both branches stamp date_last_updated + the server reviewer.
function buildUpsertReviewSql({ dataset, annotationId, scvId, scvVer, status, notes, reviewer }) {
  const ds = assertReadDataset(dataset);
  assertStatus(status);
  const params = {
    aid: String(annotationId), scvId: scvId == null ? null : String(scvId),
    scvVer: scvVer == null ? null : Number(scvVer),
    status, notes: notes == null ? null : String(notes), reviewer: String(reviewer)
  };
  const sql = [
    `MERGE \`clingen-dev.${ds}.cvc_review_state\` T`,
    'USING (SELECT @aid AS annotation_id) S',
    'ON T.annotation_id = S.annotation_id',
    'WHEN MATCHED THEN UPDATE SET',
    '  review_status = @status, notes = @notes, reviewer = @reviewer,',
    '  date_last_updated = CURRENT_TIMESTAMP()',
    'WHEN NOT MATCHED THEN INSERT',
    '  (annotation_id, scv_id, scv_ver, review_status, reviewer, notes, date_added, date_last_updated)',
    '  VALUES (@aid, @scvId, @scvVer, @status, @reviewer, @notes, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP())'
  ].join('\n');
  return { sql, params };
}

// Assign an annotation to a batch — ONLY if it is reviewed OK, not already
// assigned, and its action is assignable (checked against the authoritative
// native table, a cheap point lookup). Affects 0 rows if the gate fails.
function buildAssignSql({ dataset, annotationId, batchId }) {
  const ds = assertReadDataset(dataset);
  const params = { aid: String(annotationId), batch: assertNumeric('batchId', batchId) };
  const sql = [
    `UPDATE \`clingen-dev.${ds}.cvc_review_state\` T`,
    'SET batch_id = @batch, date_last_updated = CURRENT_TIMESTAMP()',
    'WHERE T.annotation_id = @aid',
    "  AND T.review_status = 'OK'",
    '  AND T.batch_id IS NULL',
    '  AND EXISTS (',
    `    SELECT 1 FROM \`clingen-dev.${ds}.cvc_annotations_native_v4\` a`,
    `    WHERE a.annotation_id = @aid AND LOWER(a.action) IN ('flagging candidate','remove flagged submission'))`
  ].join('\n');
  return { sql, params };
}

// Unassign — only from the given (current) batch.
function buildUnassignSql({ dataset, annotationId, batchId }) {
  const ds = assertReadDataset(dataset);
  const params = { aid: String(annotationId), batch: assertNumeric('batchId', batchId) };
  const sql = [
    `UPDATE \`clingen-dev.${ds}.cvc_review_state\` T`,
    'SET batch_id = NULL, date_last_updated = CURRENT_TIMESTAMP()',
    'WHERE T.annotation_id = @aid AND T.batch_id = @batch'
  ].join('\n');
  return { sql, params };
}

function makeReviewHandler({ runDml, dataset }) {
  return {
    async setReview({ annotationId, scvId, scvVer, status, notes, reviewer }) {
      const { sql, params } = buildUpsertReviewSql({ dataset, annotationId, scvId, scvVer, status, notes, reviewer });
      return { applied: await runDml(sql, params) };
    },
    async assign({ annotationId, batchId }) {
      const { sql, params } = buildAssignSql({ dataset, annotationId, batchId });
      const applied = await runDml(sql, params);
      return { applied, eligible: applied > 0 }; // 0 => gate rejected (not OK / already assigned / not assignable)
    },
    async unassign({ annotationId, batchId }) {
      const { sql, params } = buildUnassignSql({ dataset, annotationId, batchId });
      return { applied: await runDml(sql, params) };
    }
  };
}

module.exports = {
  STATUSES, ASSIGNABLE_ACTIONS, assertStatus,
  buildUpsertReviewSql, buildAssignSql, buildUnassignSql, makeReviewHandler
};
