// enrich.js — event-driven enrichment. Reimplements adapter/refresh-native-v4.sh
// in Node so a Firestore capture trigger can run it, then refreshes the queue
// base. The capture (clinvar_cvc_ext, us-central1) and curator (US) datasets are
// in different locations, so — like the bash — this materializes a snapshot,
// extracts to a us-central1 GCS bucket, loads into the US dataset, reshapes to
// the native contract, then re-materializes cvc_review_queue_base.
//
// Pure builders (SQL + the debounce id) are unit-tested; makeEnricher's
// orchestration takes injected BQ clients + a GCS bucket and is deploy-verified.
const { buildRefreshQueueSql } = require('./queue.js');
const { assertReadDataset, assertWriteDataset } = require('./dataset-guard.js');

const SNAPSHOT_TABLE = '_native_v4_snapshot';   // in <captureProject>.clinvar_cvc_ext
const RAW_TABLE = '_annotations_v4_raw';        // in clingen-dev.<dataset>

// Snapshot the flattened capture view (drop document_id — autodetect trips over
// mixed numeric/hex doc-ids; the reshape never uses it). Runs in us-central1.
function snapshotSql({ captureProject }) {
  if (!/^[a-z0-9-]+$/.test(String(captureProject || ''))) throw new Error(`enrich: bad captureProject '${captureProject}'`);
  return `SELECT * EXCEPT(document_id) FROM \`${captureProject}.clinvar_cvc_ext.annotations\``;
}

// Reshape the raw load into the native_v4 contract (mirrors native_v4_reshape.sql).
function reshapeSql({ dataset }) {
  const ds = assertWriteDataset(assertReadDataset(dataset));
  return [
    `CREATE OR REPLACE TABLE \`clingen-dev.${ds}.cvc_annotations_native_v4\` AS`,
    'SELECT',
    '  COALESCE(CAST(annotation_id AS STRING), CAST(created_at_millis AS STRING)) AS annotation_id,',
    '  CAST(created_at AS TIMESTAMP) AS annotation_date,',
    '  vcv AS vcv_id, scv AS scv_id,',
    '  CAST(variation_id AS STRING) AS variation_id,',
    '  CAST(submitter_id AS STRING) AS submitter_id,',
    '  action AS action, user_email AS curator_email, interp AS interpretation,',
    '  reason AS reason, notes AS notes, review_status AS review_status, FALSE AS `ignore`',
    `FROM \`clingen-dev.${ds}.${RAW_TABLE}\``
  ].join('\n');
}

// Stamp the queue base with the clinvar_ingest release it was just enriched
// against, so the app can detect when a newer release makes the queue stale.
function stampReleaseSql({ dataset }) {
  const ds = assertReadDataset(dataset);
  return `UPDATE \`clingen-dev.${ds}.cvc_review_config\`
          SET base_release_date = (SELECT release_date FROM \`clinvar_ingest.release_on\`(CURRENT_DATE()))
          WHERE TRUE`;
}

// Debounce key: all captures within the same `windowSec` bucket enqueue the SAME
// Cloud Tasks id, so a burst collapses to ONE enrichment run.
function debounceTaskId(nowMs, windowSec) {
  return `enrich-${Math.floor(Number(nowMs) / (Number(windowSec) * 1000))}`;
}

// deps: centralBq (projectId=captureProject, us-central1), usBq (clingen-dev, US),
// bucket (@google-cloud/storage Bucket in us-central1), config { captureProject,
// dataset, gcsPrefix }. Runs the 5 adapter steps + the base refresh in order.
function makeEnricher({ centralBq, usBq, bucket, config, log }) {
  const say = log || (() => {});
  const { captureProject, dataset, gcsPrefix } = config;
  assertWriteDataset(assertReadDataset(dataset)); // fail fast on a bad dataset
  const wildcard = `${gcsPrefix}/part-*.json`;
  return {
    async run() {
      // 1. snapshot the capture (us-central1) → _native_v4_snapshot
      const [snapJob] = await centralBq.createQueryJob({
        query: snapshotSql({ captureProject }), location: 'us-central1',
        destination: centralBq.dataset('clinvar_cvc_ext').table(SNAPSHOT_TABLE),
        writeDisposition: 'WRITE_TRUNCATE'
      });
      await snapJob.getQueryResults();
      say('snapshot done');
      // 2. clear stale shards, then 3. extract snapshot → GCS (NDJSON)
      await bucket.deleteFiles({ prefix: `${gcsPrefix}/` }).catch(() => {});
      await centralBq.dataset('clinvar_cvc_ext').table(SNAPSHOT_TABLE)
        .extract(bucket.file(wildcard), { format: 'JSON', location: 'us-central1' });
      say('extract done');
      // 4. load GCS → _annotations_v4_raw (US), autodetect
      await usBq.dataset(dataset).table(RAW_TABLE).load(bucket.file(wildcard), {
        sourceFormat: 'NEWLINE_DELIMITED_JSON', autodetect: true, writeDisposition: 'WRITE_TRUNCATE'
      });
      say('load done');
      // 5. reshape → native_v4
      const [reshapeJob] = await usBq.createQueryJob({ query: reshapeSql({ dataset }), location: 'US' });
      await reshapeJob.getQueryResults();
      say('reshape done');
      // 6. re-materialize the queue base so the new captures show enriched
      const [baseJob] = await usBq.createQueryJob({ query: buildRefreshQueueSql({ dataset }), location: 'US' });
      await baseJob.getQueryResults();
      say('base refresh done');
      // 7. stamp the base with the clinvar_ingest release it now reflects
      const [stampJob] = await usBq.createQueryJob({ query: stampReleaseSql({ dataset }), location: 'US' });
      await stampJob.getQueryResults();
      say('release stamped');
      return { ok: true };
    }
  };
}

module.exports = { snapshotSql, reshapeSql, stampReleaseSql, debounceTaskId, makeEnricher, SNAPSHOT_TABLE, RAW_TABLE };
