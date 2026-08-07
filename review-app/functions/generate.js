// generate.js — produce the ClinVar submission NDJSON for a batch off the v4
// feed. buildGenerateSql is the VALIDATED 13-field projection from Generate.js
// (proven byte-identical to legacy over the SUBMITTED scope, 0 field diffs),
// now sourced from cvc_annotations(v4) and joined to the app's cvc_review_state
// for batch membership. makeGenerateHandler wires SQL → NDJSON → Drive (all
// injected → unit-testable). CommonJS.
const { assertReadDataset } = require('./dataset-guard.js');
const { buildNdjson } = require('./ndjson.js');
const { submissionFilename, buildSubmissionEmail, mailtoUrl } = require('./submission.js');

// The submission projection (matches SUBMISSION_FILE_SPEC.md / Generate.js).
// Booleans (is_outdated_scv, is_deleted_scv) are selected RAW so TO_JSON_STRING
// emits JSON true/false (never "Yes"/"No").
function buildGenerateSql({ dataset, batchId }) {
  const ds = assertReadDataset(dataset);
  if (!/^\d+$/.test(String(batchId))) {
    throw new Error(`buildGenerateSql: batchId must be numeric, got '${batchId}'`);
  }
  return [
    'WITH x AS (',
    '  SELECT',
    '    cvc.variation_id AS `Variation ID`,',
    '    cvc.vcv_id AS VCV,',
    "    cvc.scv_id||'.'||cvc.scv_ver AS `SCV ID`,",
    '    cvc.submitter_id AS `Submitter ID`,',
    '    cvc.action AS Action,',
    '    cvc.reason AS Reason,',
    "    REPLACE(cvc.notes, '\\n', ' ') AS Notes,",
    "    FORMAT_TIMESTAMP('%FT%TZ', cvc.annotated_on) AS `Timestamp`,",
    '    cvc.as_of_date AS `Date Created`,',
    '    cvc.annotation_release_date AS `ClinVar Release Date`,',
    '    cvc.is_outdated_scv AS `Is Annotation Outdated`,',
    '    cvc.is_deleted_scv AS `Is Annotated SCV Deleted`,',
    '    cvc.deleted_scv_release_date AS `SCV Deleted Release Date`',
    `  FROM \`clingen-dev.${ds}.cvc_annotations\`("unreviewed") cvc`,
    `  JOIN \`clingen-dev.${ds}.cvc_review_state\` rs ON rs.annotation_id = cvc.annotation_id`,
    `  WHERE rs.batch_id = "${batchId}"`,
    ')',
    'SELECT TO_JSON_STRING(x) AS js FROM x'
  ].join('\n');
}

// makeGenerateHandler deps: runQuery(sql)->rows[{js}]; writeNdjson({folderId,
// filename,content})->{id,link}; config { dataset, driveFolderId, env,
// recipients, cc }. Returns { count, filename, link, mailto } (count<=0 writes
// nothing). Read-only w.r.t. state.
function makeGenerateHandler({ runQuery, writeNdjson, config }) {
  return async function generate({ batchId, date }) {
    const rows = (await runQuery(buildGenerateSql({ dataset: config.dataset, batchId }))) || [];
    const filename = submissionFilename({ batchId, date, env: config.env });
    if (!rows.length) return { count: 0, filename, link: null, mailto: null };
    const content = buildNdjson(rows.map((r) => r.js));
    const { link } = await writeNdjson({ folderId: config.driveFolderId, filename, content });
    const email = buildSubmissionEmail({
      count: rows.length, batchId, generatedDatetime: date,
      recipients: config.recipients, cc: config.cc, fileName: filename
    });
    return { count: rows.length, filename, link, mailto: mailtoUrl(email) };
  };
}

module.exports = { buildGenerateSql, makeGenerateHandler };
