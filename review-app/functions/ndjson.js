// ndjson.js — pure newline-delimited-JSON assembly. The generate SQL returns one
// TO_JSON_STRING per row (booleans/null already emitted as JSON true/false/null
// by BigQuery — never "Yes"/"No"); this joins them into the submission file
// body, matching Generate.js (each row followed by '\n'). CommonJS; unit-tested.
function buildNdjson(jsonRows) {
  const rows = jsonRows || [];
  if (!rows.length) return '';
  return rows.map((s) => String(s) + '\n').join('');
}

module.exports = { buildNdjson };
