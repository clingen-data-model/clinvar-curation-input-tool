// config.js — read the single-row cvc_review_config (next_batch_id + the
// reviewers auto-OK allow-list). Pure SQL builder + injected handler. CommonJS.
const { assertReadDataset } = require('./dataset-guard.js');

function buildConfigSql({ dataset }) {
  const ds = assertReadDataset(dataset);
  // Also pull the CURRENT clinvar_ingest release so the app can tell when the
  // queue (enriched at base_release_date) is stale vs a newer ClinVar release.
  return `SELECT c.next_batch_id, c.reviewers, c.submission_recipients, c.submission_cc,
                 c.last_finalized_file, c.base_release_date,
                 (SELECT release_date FROM \`clinvar_ingest.release_on\`(CURRENT_DATE())) AS current_release
          FROM \`clingen-dev.${ds}.cvc_review_config\` c LIMIT 1`;
}

// BQ DATE comes back as { value: 'YYYY-MM-DD' } or a string; normalize to string.
function dstr(v) { return v == null ? null : (v.value != null ? v.value : String(v)); }

function makeConfigHandler({ runQuery, dataset }) {
  return async function getConfig() {
    const [row] = (await runQuery(buildConfigSql({ dataset }))) || [];
    const baseRelease = dstr(row && row.base_release_date);
    const currentRelease = dstr(row && row.current_release);
    return {
      nextBatchId: (row && row.next_batch_id) || null,
      reviewers: (row && row.reviewers) || [],
      submissionRecipients: (row && row.submission_recipients) || [],
      submissionCc: (row && row.submission_cc) || [],
      lastFinalizedFile: (row && row.last_finalized_file) || null,
      baseReleaseDate: baseRelease,
      currentRelease,
      // stale when the queue was enriched against an older release than current
      releaseStale: !!(currentRelease && (!baseRelease || baseRelease < currentRelease))
    };
  };
}

module.exports = { buildConfigSql, makeConfigHandler };
