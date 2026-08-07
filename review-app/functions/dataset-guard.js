// dataset-guard.js — the write-path non-impact guard (SECOND layer; the primary
// control is dataset-scoped IAM, see scripts/grant-iam.sh). Refuses the live
// legacy dataset `clinvar_curator` as a WRITE/DDL target, while allowing it as a
// READ source (the parity harness legitimately reads legacy). Exact dataset
// match — NOT a substring, since `clinvar_curator` is a prefix of
// `clinvar_curator_v4[_dev]`. CommonJS; unit-tested.

const LEGACY_WRITE_FORBIDDEN = 'clinvar_curator';
// The app only ever operates on a v4 shadow dataset. (The parity harness reads
// legacy `clinvar_curator` directly — it does NOT go through this guard.)
const ALLOWED_V4_DATASETS = ['clinvar_curator_v4', 'clinvar_curator_v4_dev'];

// Throw if `dataset` is the live legacy dataset; otherwise return it. Use at
// every write/DDL target (query builders, deploy scripts via node).
function assertWriteDataset(dataset) {
  if (String(dataset) === LEGACY_WRITE_FORBIDDEN) {
    throw new Error(`dataset-guard: refusing to WRITE the live legacy dataset '${LEGACY_WRITE_FORBIDDEN}'`);
  }
  return dataset;
}

// The app's operating dataset must be a known v4 shadow — guards against a
// mis-configured REVIEW_DATASET pointing the app at the wrong (or legacy) data.
function assertReadDataset(dataset) {
  if (!ALLOWED_V4_DATASETS.includes(String(dataset))) {
    throw new Error(`dataset-guard: '${dataset}' is not an allowed v4 dataset (${ALLOWED_V4_DATASETS.join(', ')})`);
  }
  return dataset;
}

module.exports = { assertWriteDataset, assertReadDataset, LEGACY_WRITE_FORBIDDEN, ALLOWED_V4_DATASETS };
