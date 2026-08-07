// dataset-guard.js — the write-path non-impact guard (SECOND layer; the primary
// control is dataset-scoped IAM, see scripts/grant-iam.sh). Refuses the live
// legacy dataset `clinvar_curator` as a WRITE/DDL target, while allowing it as a
// READ source (the parity harness legitimately reads legacy). Exact dataset
// match — NOT a substring, since `clinvar_curator` is a prefix of
// `clinvar_curator_v4[_dev]`. CommonJS; unit-tested.

const LEGACY_WRITE_FORBIDDEN = 'clinvar_curator';

// Throw if `dataset` is the live legacy dataset; otherwise return it. Use at
// every write/DDL target (query builders, deploy scripts via node).
function assertWriteDataset(dataset) {
  if (String(dataset) === LEGACY_WRITE_FORBIDDEN) {
    throw new Error(`dataset-guard: refusing to WRITE the live legacy dataset '${LEGACY_WRITE_FORBIDDEN}'`);
  }
  return dataset;
}

module.exports = { assertWriteDataset, LEGACY_WRITE_FORBIDDEN };
