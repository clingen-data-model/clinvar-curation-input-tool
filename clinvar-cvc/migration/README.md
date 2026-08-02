# CvC history migration (S4)

One-time migration of historical ClinVar Curation annotations from the legacy
BigQuery table (`clingen-dev.clinvar_curator.clinvar_annotations_native`) into
the v4 extension's Firestore collection, so they stream into the new
Firestore → BigQuery pipeline alongside live extension writes.

This is a **staged, human-run** process. Nothing in `migration/migrate.js`
runs automatically — every step below is a command a human executes and
inspects before moving to the next.

## Files

- `source.sql` — the BigQuery export query (read-only against the source table).
- `native-to-v4.js` — pure row-mapping + Firestore `fields` encoding (unit-tested in `test/migration.test.js`).
- `migrate.js` — the CLI runner that reads the exported JSON and writes to Firestore.

## Staged runbook

### a) Export the source rows

```bash
bq --project_id=clingen-dev query --use_legacy_sql=false --format=json --max_rows=100000 \
  "$(cat clinvar-cvc/migration/source.sql)" > /tmp/cvc-history.json
```

Expect roughly 31,338 rows (post `ignore` filter).

### b) Get a token

```bash
export GCP_TOKEN=$(gcloud auth print-access-token)
```

The token is short-lived (~1 hour); re-run this if a later step reports 401s.

### c) Dry run — eyeball counts and sample docs

```bash
node clinvar-cvc/migration/migrate.js --source /tmp/cvc-history.json --dry-run
```

No network writes happen. Confirm:
- total source rows matches the export count,
- unique docs / intra-source duplicate count look sane,
- the 3 sample `{id, doc}` pairs have the expected shape (11 dedup fields + `name` + `created_at`, no override/retired fields).

### d) Sample run against dev

```bash
node clinvar-cvc/migration/migrate.js --project clingen-cvc-dev --limit 50 --source /tmp/cvc-history.json
```

Then verify in the dev BigQuery dataset (`clinvar_cvc_ext` in `clingen-cvc-dev`)
that ~50 new rows showed up in `annotations_raw_latest` / the flattened view,
with fields matching the source sample.

### e) Full dev run

```bash
node clinvar-cvc/migration/migrate.js --project clingen-cvc-dev --source /tmp/cvc-history.json
```

Re-running this is safe (see Idempotency below) — if it's interrupted partway,
just run it again; already-created docs come back as skipped.

### f) Reconcile

Compare:
- source row count (post `ignore` filter) minus intra-source duplicates,
  against
- `created + skipped` from the final summary,
  against
- row count in the dev BigQuery `annotations_raw_latest` table / flattened view.

Investigate any error entries the runner printed (first 10 are shown; re-run
with the same `--source` file to retry — creates are still create-only so
nothing double-writes).

### g) Prod run (only after dev is confirmed correct)

```bash
node clinvar-cvc/migration/migrate.js --project clingen-cvc --source /tmp/cvc-history.json
```

Optionally repeat the `--limit N` sample-then-full pattern from steps d–e
against prod if you want an extra staged check before the full write.

## Idempotency

Every write is a Firestore `batchWrite` `update` with `currentDocument.exists:
false` — i.e. **create-only**. The doc id is `annotationDocId(doc)`, the same
content hash the live extension uses for its own dedup (`annotation.js`). This
means:

- Re-running the migration (same source file, same project) is safe: already-written
  docs come back `ALREADY_EXISTS` (code 6) or `FAILED_PRECONDITION` (code 9)
  and are counted as **skipped**, not overwritten or duplicated.
- A migrated historical row and a *future* live re-save of the same
  annotation (same variation/vcv/scv/submitter/interp/review_status/action/reason/notes/user_email)
  produce the *same* doc id, so the live save will correctly no-op against the
  migrated history instead of creating a duplicate entry.

## Clean-slate reload (recommended for prod)

If historical data needs to be reloaded from scratch (e.g. the source export
changed, or a prior load was contaminated), wipe the Firestore collection
first rather than layering a second load on top of a partial one:

```bash
# 1. Get a token
export GCP_TOKEN=$(gcloud auth print-access-token)

# 2. Preview current contents (dry-run — shows count + up to 10 sample ids;
#    this is the default behavior without --confirm)
node migration/wipe-collection.js --project <p>

# 3. Wipe (destructive — requires --confirm; paced so BigQuery delete
#    events aren't dropped)
node migration/wipe-collection.js --project <p> --confirm --delay-ms 2000

# 4. Reload, paced (see note below on why --delay-ms matters)
node migration/migrate.js --source /tmp/cvc-history.json --project <p> --delay-ms 3000

# 5. Verify: Firestore doc count == unique docs from the migration summary,
#    and the BigQuery annotations_raw_latest / flattened view converges to
#    the same count once the streaming extension catches up.
```

**Pacing note:** `--delay-ms` inserts a pause between successive
`batchWrite` requests (writes or deletes). This exists because the
Firestore → BigQuery streaming extension processes change events at a
finite rate; a fast unpaced bulk load or wipe (500-per-request, back to
back) has been observed to drop roughly **2%** of stream events, silently
under-counting rows in BigQuery relative to Firestore. Pacing the requests
(e.g. 2000-3000ms apart) keeps the extension caught up.

**Destructive warning:** `wipe-collection.js` deletes every document in the
target collection. It refuses to delete anything unless `--confirm` is
explicitly passed (and `--dry-run`, if also passed, always wins over
`--confirm`) — without `--confirm` it only lists and reports what it would
delete.

## Access control note

`migrate.js` authenticates with a bearer token from `gcloud auth
print-access-token` (the operator's own GCP identity), writing directly via
the Firestore REST API. This **bypasses `firestore.rules`** (rules only gate
the client SDK path used by signed-in curators through the extension), which
is required here: many historical `curator_email` values are not — and may
never be — in the `allowed_curators` allowlist, but their historical
annotations still need to land in Firestore/BigQuery. No allowlist changes are
needed to run this migration.
