// config.js — read the single-row cvc_review_config (next_batch_id + the
// reviewers auto-OK allow-list). Pure SQL builder + injected handler. CommonJS.
const { assertReadDataset } = require('./dataset-guard.js');

function buildConfigSql({ dataset }) {
  const ds = assertReadDataset(dataset);
  return `SELECT next_batch_id, reviewers, submission_recipients, submission_cc, last_finalized_file
          FROM \`clingen-dev.${ds}.cvc_review_config\` LIMIT 1`;
}

function makeConfigHandler({ runQuery, dataset }) {
  return async function getConfig() {
    const [row] = (await runQuery(buildConfigSql({ dataset }))) || [];
    return {
      nextBatchId: (row && row.next_batch_id) || null,
      reviewers: (row && row.reviewers) || [],
      submissionRecipients: (row && row.submission_recipients) || [],
      submissionCc: (row && row.submission_cc) || [],
      lastFinalizedFile: (row && row.last_finalized_file) || null
    };
  };
}

module.exports = { buildConfigSql, makeConfigHandler };
