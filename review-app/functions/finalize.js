// finalize.js — finalize a batch. Per the plan-review, this is NOT a single
// ACID unit (BigQuery can't transact DDL, and the impact SP is a 2–5 min full
// rebuild). Instead it is idempotent + ordered + compensating:
//   1. warn (don't block) on unreviewed/Question rows
//   2. generate the NDJSON file (Chunk 3) — read-only; skip persist if empty
//   3. ONE BQ transaction: promote review_state → reviews + submissions
//      (INSERT ... NOT IN, retry-safe) + append the batches row + bump
//      next_batch_id (guarded so a retry can't double-bump)
//   4. kick refresh_cvc_impact_analysis() ASYNC (a re-runnable full rebuild) —
//      never block finalize on it
// Pure SQL builders + an injected-deps handler. CommonJS.
const { assertReadDataset } = require('./dataset-guard.js');

// Count rows still needing review (unreviewed / Question) — surfaced as a
// warning; finalize proceeds with the reviewed remainder (matches Generate.js).
function buildWarningsSql({ dataset }) {
  const ds = assertReadDataset(dataset);
  return `SELECT COUNTIF(review_status IS NULL OR review_status = 'Question') AS needs_review,
                 COUNT(*) AS total
          FROM \`clingen-dev.${ds}.cvc_review_state\``;
}

// The finalize transaction. Idempotent: the INSERTs are NOT-IN guarded and the
// config bump only fires while next_batch_id still equals this batch, so a retry
// after a partial/committed run neither double-inserts nor double-bumps.
function buildFinalizeSql({ dataset, batchId }) {
  const ds = assertReadDataset(dataset);
  if (!/^\d+$/.test(String(batchId))) throw new Error(`finalize: batchId must be numeric, got '${batchId}'`);
  const B = `clingen-dev.${ds}`;
  const params = { batch: String(batchId), batchInt: Number(batchId), fdt: null }; // fdt bound by caller
  const sql = [
    'BEGIN TRANSACTION;',
    // reviews: all reviewed (OK/Fixed/Archive) not yet persisted, stamped this batch
    `INSERT INTO \`${B}.cvc_clinvar_reviews\` (annotation_id, date_added, status, reviewer, notes, date_last_updated, batch_id)`,
    `SELECT rs.annotation_id, rs.date_added, rs.review_status, rs.reviewer, rs.notes, rs.date_last_updated, @batch`,
    `FROM \`${B}.cvc_review_state\` rs`,
    `WHERE rs.review_status IN ('OK','Fixed','Archive')`,
    `  AND rs.annotation_id NOT IN (SELECT annotation_id FROM \`${B}.cvc_clinvar_reviews\`);`,
    // submissions: rows assigned to THIS batch, not yet persisted
    `INSERT INTO \`${B}.cvc_clinvar_submissions\` (annotation_id, scv_id, scv_ver, batch_id)`,
    `SELECT rs.annotation_id, rs.scv_id, rs.scv_ver, rs.batch_id`,
    `FROM \`${B}.cvc_review_state\` rs`,
    `WHERE rs.batch_id = @batch`,
    `  AND rs.annotation_id NOT IN (SELECT annotation_id FROM \`${B}.cvc_clinvar_submissions\`);`,
    // batches: derive the new row (6 cols incl the submission STRUCT), from the prior batch + ingest calendar
    `INSERT INTO \`${B}.cvc_clinvar_batches\` (batch_id, finalized_datetime, batch_release_date, batch_start_date, batch_end_date, submission)`,
    `SELECT @batch, TIMESTAMP(@fdt), rel.release_date, DATE(e.finalized_datetime)+1, DATE(DATETIME(@fdt)),`,
    '       `clinvar_ingest.determineMonthBasedOnRange`(DATE(e.finalized_datetime)+1, DATE(DATETIME(@fdt)))',
    `FROM \`${B}.cvc_clinvar_batches\` e, \`clinvar_ingest.release_on\`(DATE(DATETIME(@fdt))) rel`,
    `WHERE SAFE_CAST(e.batch_id AS INT64) < @batchInt`,
    `ORDER BY SAFE_CAST(e.batch_id AS INT64) DESC LIMIT 1;`,
    // bump next_batch_id — guarded so a retry can't double-bump
    `UPDATE \`${B}.cvc_review_config\` SET next_batch_id = CAST(@batchInt + 1 AS STRING), last_finalized_date = TIMESTAMP(@fdt) WHERE next_batch_id = @batch;`,
    'COMMIT TRANSACTION;'
  ].join('\n');
  return { sql, params };
}

// The async impact-SP refresh CALL (idempotent full rebuild).
function buildRefreshSpSql({ dataset }) {
  const ds = assertReadDataset(dataset);
  return `CALL \`clingen-dev.${ds}.refresh_cvc_impact_analysis\`()`;
}

// deps: generate({batchId,date}); runQuery(sql); runDml(sql, params); startSpRefresh(sql)
//       (fire-and-forget → returns a jobId, NOT awaited); config { dataset }.
function makeFinalizeHandler({ generate, runQuery, runDml, startSpRefresh, config }) {
  return async function finalize({ batchId, date, finalizedDatetime }) {
    const ds = config.dataset;
    const [w] = (await runQuery(buildWarningsSql({ dataset: ds }))) || [{}];
    const warnings = { needsReview: Number((w && w.needs_review) || 0) };

    const gen = await generate({ batchId, date });
    if (!gen.count) return { count: 0, warnings, finalized: false };

    const { sql, params } = buildFinalizeSql({ dataset: ds, batchId });
    params.fdt = finalizedDatetime; // "YYYY-MM-DD HH:MM:SS"
    const promoted = await runDml(sql, params);

    // Async, re-runnable — do NOT await (2–5 min); return the job handle.
    const spJob = startSpRefresh(buildRefreshSpSql({ dataset: ds }));

    return {
      count: gen.count, filename: gen.filename, link: gen.link, mailto: gen.mailto,
      nextBatchId: String(Number(batchId) + 1), warnings, finalized: true,
      promotedDmlRows: promoted, spRefreshJob: spJob || null
    };
  };
}

module.exports = { buildWarningsSql, buildFinalizeSql, buildRefreshSpSql, makeFinalizeHandler };
