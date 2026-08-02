/**
 * DESTRUCTIVE one-time utility: deletes EVERY document in a Firestore
 * collection, paginated + paced, so the Firestore -> BigQuery streaming
 * extension's delete events can keep up (a fast unpaced burst drops events).
 *
 * Intended use: wiping clinvar_cvc_ext_annotations for a clean-slate reload
 * before re-running migrate.js. See migration/README.md.
 *
 * Usage:
 *   node migration/wipe-collection.js --project <p> \
 *     [--collection clinvar_cvc_ext_annotations] [--delay-ms N] \
 *     [--dry-run] [--confirm]
 *
 * SAFETY: without --confirm, this NEVER deletes anything — it only lists
 * and reports what it would delete. This script is not run by CI/tests.
 */

// Node shim: fetch's global crypto isn't needed here, but keep parity with
// migrate.js in case future changes need it.
if (!globalThis.crypto) globalThis.crypto = require('node:crypto').webcrypto;

const { chunk } = require('./native-to-v4.js');

const BATCH_SIZE = 500;
const PAGE_SIZE = 1000;
const DEFAULT_COLLECTION = 'clinvar_cvc_ext_annotations';

function parseArgs(argv) {
  const args = {
    project: null,
    collection: DEFAULT_COLLECTION,
    delayMs: 0,
    dryRun: false,
    confirm: false
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case '--project':
        args.project = argv[++i];
        break;
      case '--collection':
        args.collection = argv[++i];
        break;
      case '--delay-ms':
        args.delayMs = parseInt(argv[++i], 10);
        break;
      case '--dry-run':
        args.dryRun = true;
        break;
      case '--confirm':
        args.confirm = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!args.project) {
    throw new Error('Missing required --project <p>');
  }
  if (Number.isNaN(args.delayMs)) {
    throw new Error('--delay-ms requires a numeric value');
  }

  return args;
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function docPath(project, collection, id) {
  return `projects/${project}/databases/(default)/documents/${collection}/${id}`;
}

// Lists every document id in `collection`, paginated via runQuery + a
// __name__ cursor (startAt), selecting only __name__ to keep pages cheap.
async function listAllDocumentIds(project, collection, token) {
  const url = `https://firestore.googleapis.com/v1/projects/${project}/databases/(default)/documents:runQuery`;
  const ids = [];
  let lastDocName = null;

  for (;;) {
    const structuredQuery = {
      from: [{ collectionId: collection }],
      select: { fields: [{ fieldPath: '__name__' }] },
      orderBy: [{ field: { fieldPath: '__name__' }, direction: 'ASCENDING' }],
      limit: PAGE_SIZE
    };
    if (lastDocName) {
      structuredQuery.startAt = {
        values: [{ referenceValue: lastDocName }],
        before: false
      };
    }

    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`
      },
      body: JSON.stringify({ structuredQuery })
    });

    const text = await res.text();
    if (res.status !== 200) {
      throw new Error(`HTTP ${res.status} while listing documents\n${text}`);
    }

    const rows = text ? JSON.parse(text) : [];
    let pageCount = 0;
    for (const row of rows) {
      if (!row.document) continue; // heartbeat-only entries carry no document
      pageCount++;
      lastDocName = row.document.name;
      ids.push(lastDocName.split('/').pop());
    }

    if (pageCount < PAGE_SIZE) break;
  }

  return ids;
}

// Sends one batchWrite request of deletes given fully-resolved doc paths.
async function sendDeleteBatch(project, docPaths, token) {
  const url = `https://firestore.googleapis.com/v1/projects/${project}/databases/(default)/documents:batchWrite`;
  const body = {
    writes: docPaths.map(name => ({ delete: name }))
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

async function run() {
  const args = parseArgs(process.argv.slice(2));

  const token = process.env.GCP_TOKEN;
  if (!token) {
    console.error('Error: GCP_TOKEN environment variable is not set.');
    console.error('  export GCP_TOKEN=$(gcloud auth print-access-token)');
    process.exit(1);
    return;
  }

  console.log(`Listing documents in ${args.project}/${args.collection}...`);
  const ids = await listAllDocumentIds(args.project, args.collection, token);
  console.log(`Found ${ids.length} documents in ${args.project}/${args.collection}.`);

  // SAFETY GUARD: deletion only ever proceeds when --confirm was passed AND
  // --dry-run was not. Any other combination (no flags, --dry-run alone, or
  // --dry-run together with --confirm) takes the report-only path below and
  // exits before any delete request is built.
  if (!args.confirm || args.dryRun) {
    console.log('\nSample ids:');
    for (const id of ids.slice(0, 10)) {
      console.log(`  ${id}`);
    }
    console.log(`\nDRY RUN — no deletes. Re-run with --confirm to delete all ${ids.length} documents.`);
    process.exit(0);
    return;
  }

  console.log(`Pacing: ${args.delayMs}ms between batches`);

  const batches = chunk(ids, BATCH_SIZE);
  let deleted = 0;
  let hadError = false;

  for (let b = 0; b < batches.length; b++) {
    const batch = batches[b];
    const docPaths = batch.map(id => docPath(args.project, args.collection, id));

    try {
      await sendDeleteBatch(args.project, docPaths, token);
    } catch (err) {
      console.error(`Batch ${b + 1}/${batches.length} failed — aborting:`);
      console.error(err.message);
      hadError = true;
      break;
    }

    deleted += batch.length;
    console.log(`batch ${b + 1}/${batches.length}: deleted ${batch.length} (running total ${deleted})`);

    if (args.delayMs > 0 && b < batches.length - 1) {
      await sleep(args.delayMs);
    }
  }

  console.log('\n=== Wipe summary ===');
  console.log(`Wiped: ${deleted} / ${ids.length}`);

  process.exit(hadError ? 1 : 0);
}

if (require.main === module) {
  run().catch(err => {
    console.error('Fatal error:', err);
    process.exit(1);
  });
}

module.exports = { parseArgs, docPath, listAllDocumentIds, sendDeleteBatch };
