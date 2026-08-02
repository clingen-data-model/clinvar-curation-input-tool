/**
 * One-time history migration runner: historical ClinVar CvC annotations
 * (exported from BigQuery via source.sql as a JSON array) -> the v4
 * extension's Firestore collection, via the Firestore REST batchWrite API.
 *
 * Usage:
 *   node migration/migrate.js --source <file.json> \
 *     [--project clingen-cvc-dev] [--collection clinvar_cvc_ext_annotations] \
 *     [--dry-run] [--limit N]
 *
 * See migration/README.md for the full staged runbook. This script performs
 * real network writes unless --dry-run is passed; it is not run by CI/tests.
 */

// Node shim: annotationDocId (annotation.js) uses global crypto.subtle, which
// browsers provide natively but plain `node` only exposes via node:crypto.
if (!globalThis.crypto) globalThis.crypto = require('node:crypto').webcrypto;

const fs = require('node:fs');

const { annotationDocId } = require('../annotation.js');
const { nativeRowToV4Doc, toFirestoreFields, chunk } = require('./native-to-v4.js');

const BATCH_SIZE = 500;
const DEFAULT_PROJECT = 'clingen-cvc-dev';
const DEFAULT_COLLECTION = 'clinvar_cvc_ext_annotations';

function parseArgs(argv) {
  const args = {
    source: null,
    project: DEFAULT_PROJECT,
    collection: DEFAULT_COLLECTION,
    dryRun: false,
    limit: null,
    delayMs: 0
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case '--source':
        args.source = argv[++i];
        break;
      case '--project':
        args.project = argv[++i];
        break;
      case '--collection':
        args.collection = argv[++i];
        break;
      case '--dry-run':
        args.dryRun = true;
        break;
      case '--limit':
        args.limit = parseInt(argv[++i], 10);
        break;
      case '--delay-ms':
        args.delayMs = parseInt(argv[++i], 10);
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!args.source) {
    throw new Error('Missing required --source <file.json>');
  }
  if (args.limit !== null && Number.isNaN(args.limit)) {
    throw new Error('--limit requires a numeric value');
  }
  if (Number.isNaN(args.delayMs)) {
    throw new Error('--delay-ms requires a numeric value');
  }

  return args;
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// Reads the bq --format=json export, maps every row to a v4 doc, computes its
// dedup id, and drops in-source duplicates (first occurrence wins).
async function loadUniqueDocs(sourcePath) {
  const raw = fs.readFileSync(sourcePath, 'utf8');
  const rows = JSON.parse(raw);
  if (!Array.isArray(rows)) {
    throw new Error(`Expected a JSON array in ${sourcePath}, got ${typeof rows}`);
  }

  const seen = new Map(); // id -> doc
  let intraSourceDups = 0;

  for (const row of rows) {
    const doc = nativeRowToV4Doc(row);
    const id = await annotationDocId(doc);
    if (seen.has(id)) {
      intraSourceDups++;
      continue;
    }
    seen.set(id, doc);
  }

  return {
    totalRows: rows.length,
    uniqueDocs: [...seen.entries()].map(([id, doc]) => ({ id, doc })),
    intraSourceDups
  };
}

function docPath(project, collection, id) {
  return `projects/${project}/databases/(default)/documents/${collection}/${id}`;
}

// Per-write outcome from the parallel status[] array in the batchWrite
// response: no status/code -> created; ALREADY_EXISTS(6) or
// FAILED_PRECONDITION(9, the exists:false violation) -> skipped; else error.
function classifyStatus(status) {
  if (!status || status.code === undefined || status.code === null || status.code === 0) {
    return 'created';
  }
  if (status.code === 6 || status.code === 9) {
    return 'skipped';
  }
  return 'error';
}

async function run() {
  const args = parseArgs(process.argv.slice(2));

  const { totalRows, uniqueDocs, intraSourceDups } = await loadUniqueDocs(args.source);

  let docsToWrite = uniqueDocs;
  if (args.limit !== null) {
    docsToWrite = docsToWrite.slice(0, args.limit);
  }

  console.log(`Source rows: ${totalRows}`);
  console.log(`Unique docs (post intra-source dedup): ${uniqueDocs.length}`);
  console.log(`Intra-source duplicates dropped: ${intraSourceDups}`);
  if (args.limit !== null) {
    console.log(`--limit ${args.limit}: processing ${docsToWrite.length} docs`);
  }
  console.log(`Target: ${args.project}/${args.collection}, pacing: ${args.delayMs}ms between batches`);

  if (args.dryRun) {
    console.log('\n--dry-run: no writes performed. Sample docs:');
    for (const sample of docsToWrite.slice(0, 3)) {
      console.log(JSON.stringify(sample, null, 2));
    }
    process.exit(0);
    return;
  }

  const token = process.env.GCP_TOKEN;
  if (!token) {
    console.error('Error: GCP_TOKEN environment variable is not set.');
    console.error('  export GCP_TOKEN=$(gcloud auth print-access-token)');
    process.exit(1);
    return;
  }

  const batches = chunk(docsToWrite, BATCH_SIZE);

  let created = 0;
  let skipped = 0;
  const errors = [];

  for (let b = 0; b < batches.length; b++) {
    const batch = batches[b];
    const writesPayload = batch.map(({ id, doc }) => ({
      id,
      name: docPath(args.project, args.collection, id),
      fields: toFirestoreFields(doc)
    }));

    let result;
    try {
      result = await sendBatch(args.project, writesPayload, token);
    } catch (err) {
      console.error(`Batch ${b + 1}/${batches.length} failed — aborting:`);
      console.error(err.message);
      process.exit(1);
      return;
    }

    const statuses = result.status || [];
    let batchCreated = 0;
    let batchSkipped = 0;
    let batchErrors = 0;

    for (let i = 0; i < batch.length; i++) {
      const outcome = classifyStatus(statuses[i]);
      if (outcome === 'created') {
        created++;
        batchCreated++;
      } else if (outcome === 'skipped') {
        skipped++;
        batchSkipped++;
      } else {
        batchErrors++;
        errors.push({
          id: batch[i].id,
          code: statuses[i] && statuses[i].code,
          message: statuses[i] && statuses[i].message
        });
      }
    }

    console.log(
      `batch ${b + 1}/${batches.length}: +${batchCreated} created +${batchSkipped} skipped ` +
      `+${batchErrors} errors (running: ${created} created, ${skipped} skipped, ${errors.length} errors)`
    );

    if (args.delayMs > 0 && b < batches.length - 1) {
      await sleep(args.delayMs);
    }
  }

  console.log('\n=== Migration summary ===');
  console.log(`Total source rows: ${totalRows}`);
  console.log(`Unique docs: ${uniqueDocs.length}`);
  console.log(`Intra-source duplicates: ${intraSourceDups}`);
  console.log(`Created: ${created}`);
  console.log(`Skipped (already migrated): ${skipped}`);
  console.log(`Errors: ${errors.length}`);

  if (errors.length) {
    console.log('\nFirst 10 errors:');
    for (const e of errors.slice(0, 10)) {
      console.log(`  id=${e.id} code=${e.code} message=${e.message}`);
    }
    process.exit(1);
    return;
  }

  process.exit(0);
}

// Sends one batchWrite request given fully-resolved doc paths + fields.
async function sendBatch(project, writesPayload, token) {
  const url = `https://firestore.googleapis.com/v1/projects/${project}/databases/(default)/documents:batchWrite`;
  const body = {
    writes: writesPayload.map(({ name, fields }) => ({
      update: { name, fields },
      currentDocument: { exists: false }
    }))
  };

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`
    },
    body: JSON.stringify(body)
  });

  const text = await res.text();
  if (res.status !== 200) {
    throw new Error(`HTTP ${res.status}\n${text}`);
  }
  return JSON.parse(text);
}

if (require.main === module) {
  run().catch(err => {
    console.error('Fatal error:', err);
    process.exit(1);
  });
}

module.exports = { parseArgs, loadUniqueDocs, classifyStatus, docPath };
