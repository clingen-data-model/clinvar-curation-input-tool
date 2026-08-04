# Phase 0 — Canonical CvC Data Layer Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a durable, v4-sourced BigQuery data layer for the CvC downstream — consolidating the curator SQL into this repo, storing a computed `annotation_id` on each v4 document (so the downstream never recomputes it), loading **all** historical annotations without dedup, and proving a parallel `clinvar_curator_v4` lineage matches the legacy one — without disturbing the live Review&Submit pipeline.

**Architecture:** `annotation_id = UNIX_MILLIS(created_at)` is computed at write time and stored as a field on every v4 doc (added to the Chrome extension's `buildAnnotation` and the historical migration). Historical `created_at` values are all unique (verified: 31,362 rows → 31,362 distinct `annotation_id`, 0 collisions), so **no dedup is applied to history** — a clean-slate re-migration of prod-staging v4 (`clingen-cvc`) loads every record, keyed by its `annotation_id` doc id. A full-snapshot cross-region copy lands that capture into a `US` native table (`cvc_annotations_native_v4`) carrying the choke-point contract (with `annotation_id` passed through, not recomputed). A parameterized deploy builds a shadow `clinvar_curator_v4` lineage (choke point + 11-table impact SP) over it — its `base_mv` reading the stored `annotation_id` via an `@@ANNO_ID@@` token — then diff-tested for parity. Legacy `clinvar_curator` is never mutated; the extension's live content-hash doc id (double-save guard) is unchanged.

**Tech Stack:** BigQuery (Standard SQL, `bq` CLI, US + us-central1), GCS (cross-region staging), Firestore REST (re-migration), Node.js + Vitest (extension + migration tooling), bash (deploy + transfer scripts).

**Spec:** `docs/superpowers/specs/2026-08-03-phase0-canonical-data-layer-design.md` — read it before starting. Section references below (e.g. "spec §6.4") point into it.

**Conventions used throughout this plan**
- All `bq` calls against `clinvar_curator`/`clinvar_ingest` use `--location=US`; against `clinvar_cvc_ext` use `--location=us-central1`.
- Env vars assumed exported by the worker: `CVC_PROD=clingen-cvc`, `CURATOR_PROJECT=clingen-dev`, `GCS_BUCKET=gs://<a us-central1 bucket the runner SA can read/write>` (create if absent; **must be us-central1** to colocate with the `bq extract` source; a us-central1 bucket also loads fine into the US dataset). `GCP_TOKEN=$(gcloud auth print-access-token)` for the Firestore REST migration tooling.
- "Legacy native" = `clingen-dev.clinvar_curator.clinvar_annotations_native` (sheet-derived, untouched).
- Never run `CREATE OR REPLACE` against a legacy `clinvar_curator` object; all new objects are new names or live in `clinvar_curator_v4`.

---

## File Structure

**New — repo consolidation (Chunk 1):**
- `bigquery/curator/` — the moved SQL tree (from `clinvar-ingest-bq-tools/scripts/clinvar-curation/`), numbered apply order preserved.
- `bigquery/curator/deploy.sh` — parameterized deploy: substitutes a dataset token + source-binding token into the numbered SQL and applies in order.
- `bigquery/curator/README.md` — how to deploy legacy vs `_v4`; the impact-SP dependency map (spec §3.6).

**Modified — store `annotation_id` on the doc (Chunk 2):**
- `clinvar-cvc/annotation.js` — `buildAnnotation` adds `annotation_id: String(created_at.getTime())`; keep it OUT of `DEDUP_FIELDS` (derived from `created_at`).
- `clinvar-cvc/migration/native-to-v4.js` — `nativeRowToV4Doc` adds `annotation_id` (from the row's `annotation_id`, computed in `source.sql`).
- `clinvar-cvc/migration/source.sql` — add `CAST(UNIX_MILLIS(TIMESTAMP(annotation_date)) AS STRING) AS annotation_id`.
- `clinvar-cvc/bigquery/annotations_view.sql` — expose the `annotation_id` field (with `COALESCE(annotation_id, CAST(created_at_millis AS STRING))` fallback for any legacy doc lacking it).
- `clinvar-cvc/test/*.test.js` — cover the new field.

**Modified — re-migration, no dedup (Chunk 3):**
- `clinvar-cvc/migration/migrate.js` — doc id becomes the record's `annotation_id` (unique); **no content-hash dedup** — every historical record is loaded.
- `bigquery/curator/audit/restored-records-audit.sql` — the "records previously dropped by content-hash dedup, now restored" audit (action-segmented).

**New — adapter (Chunk 4):**
- `bigquery/curator/adapter/refresh-native-v4.sh` — **full-snapshot** cross-region copy (materialize view → GCS → LOAD) + reshape trigger.
- `bigquery/curator/adapter/native_v4_reshape.sql` — flatten + contract reshape, **passing `annotation_id` through** (`COALESCE` fallback), not recomputing. (No crosswalk — every staging id resolves directly.)

**New — shadow lineage (Chunk 5):**
- `bigquery/curator/adapter/staging_passthrough_views.sql` — plain `SELECT *` views of the staging tables in `clinvar_curator_v4` (no id remap needed).
- (Deployed via `deploy.sh` with `DATASET=clinvar_curator_v4`, `ANNO_SOURCE=cvc_annotations_native_v4`, `MV=""`, `ANNO_ID=annotation_id`.)

**New — parity (Chunk 6):**
- `bigquery/curator/tests/*.sql` — parity diff queries (each returns 0 rows on success; shared seed is now **exact** — no collapse bucket).
- `bigquery/curator/tests/run-parity.sh` — runs all diff queries, prints pass/fail.
- `docs/superpowers/plans/2026-08-03-phase0-parity-report.md` — the written go/no-go report (filled during execution).

---

## Chunk 1: Repo consolidation + parameterized deploy

Moves the curator SQL into this repo as the single CvC home and gives it a dataset/source-parameterized deploy mechanism, deleting the ingest-repo copies in the same change (spec §4). No BigQuery objects change behavior yet — this is a lift-and-shift plus templating.

### Task 1.1: Move the curator SQL tree into this repo

**Files:**
- Create: `bigquery/curator/**` (moved from `clinvar-ingest-bq-tools/scripts/clinvar-curation/**`)
- Delete: `clinvar-ingest-bq-tools/scripts/clinvar-curation/**`

- [ ] **Step 1: Copy the tree into this repo**

Run:
```bash
mkdir -p bigquery/curator
cp -R /Users/lbabb/Development/clinvar-ingest-bq-tools/scripts/clinvar-curation/. bigquery/curator/
ls bigquery/curator            # expect the 00-*.sql .. 05-*.sql, cvc-impact-analysis/, manuscript-figures/, *.md
```
Expected: the full file list from spec §3.6's source (00-initialize-cvc-tables.sql, 01–05 funcs, cvc-impact-analysis/ with 00–09 + run script, etc.).

- [ ] **Step 2: Verify nothing references the old path**

Run:
```bash
grep -rn "scripts/clinvar-curation" bigquery/curator || echo "no self path refs — good"
```
Expected: no matches (the SQL uses dataset-qualified names, not file paths).

- [ ] **Step 3: Commit the copy (additive, before deletion)**

```bash
git add bigquery/curator
git commit -m "chore(curator): vendor clinvar-curation SQL tree into bigquery/curator (pre-templating)"
```

- [ ] **Step 4: Delete the ingest-repo copies and commit there**

Run (in the ingest repo):
```bash
cd /Users/lbabb/Development/clinvar-ingest-bq-tools
git rm -r scripts/clinvar-curation
git commit -m "chore: move clinvar-curation SQL to clinvar-curation-input-tool (bigquery/curator) — single CvC home"
cd -
```
Expected: the directory is removed from the ingest repo; commit succeeds. (Do NOT push either repo yet — the user pushes when ready.)

### Task 1.2: Parameterize the DDL by dataset + source binding

The legacy SQL hardcodes `clinvar_curator` and `clinvar_annotations_native`. Introduce two tokens so the same SQL deploys the legacy lineage OR the `_v4` shadow. Use `@@`-delimited tokens that are invalid SQL on their own (so an un-substituted deploy fails loudly).

**Files:**
- Modify: `bigquery/curator/00-initialize-cvc-tables.sql` (and every file that names `clinvar_curator.` or `clinvar_annotations_native`)

- [ ] **Step 1: Inventory the tokens to replace**

Run (scope to the files `deploy.sh` actually deploys — `-E` for portable alternation):
```bash
grep -rlnE "clinvar_curator\.|clinvar_annotations_native" bigquery/curator/0*-*.sql bigquery/curator/cvc-impact-analysis/0*-*.sql
```
Expected: only the DEPLOYED core files (00-initialize, 01–05 funcs, cvc-impact-analysis/00,03,04,06,07,09). **Do NOT tokenize the ad-hoc report files** `cvc-submitted-outcomes-stats.sql`, `cvc-annotation-history-report.sql`, or `manuscript-figures/*` — they are not in `deploy.sh`'s glob, so they stay legacy-only with literal `clinvar_curator` references (tokenizing them would leave un-substituted `@@`-tokens with no deploy path).

- [ ] **Step 2: Tokenize 00-initialize-cvc-tables.sql (dataset + source + MV keyword)**

Apply in this order so the source ref isn't swallowed by the blanket dataset replace:
1. First replace the single base_mv source reference `` `clinvar_curator.clinvar_annotations_native` `` → `` `@@ANNO_SOURCE@@` ``.
2. Then replace every remaining `` `clinvar_curator. `` → `` `@@DATASET@@. ``.
3. **Tokenize the materialized-view keyword** so the shadow can use a plain view: a BigQuery materialized view cannot read the `_x` staging *views* (spec §3.4 — the same MV-over-view restriction). On `cvc_annotations_base_mv`, change `CREATE OR REPLACE MATERIALIZED VIEW` → `CREATE OR REPLACE @@MV@@VIEW` (legacy substitutes `@@MV@@`→`MATERIALIZED `, shadow→empty).

Leave `clinvar_ingest.` references untouched (shared upstream).

- [ ] **Step 3: Verify the file still parses after substituting the legacy values**

Run:
```bash
sed -e 's/@@DATASET@@/clinvar_curator/g' -e 's/@@ANNO_SOURCE@@/clinvar_curator.clinvar_annotations_native/g' -e 's/@@MV@@/MATERIALIZED /g' \
  bigquery/curator/00-initialize-cvc-tables.sql \
  | bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --dry_run --format=prettyjson >/dev/null && echo "DRY-RUN OK"
```
Expected: `DRY-RUN OK` (dry-run validates syntax + references without executing). If it fails, the token substitution missed a reference.

- [ ] **Step 4: Apply the same tokenization to the remaining files**

Repeat Step 2 across every file from Step 1's inventory. For files that reference `clinvar_curator` objects but not the raw source, only `@@DATASET@@` applies.

- [ ] **Step 5: Dry-run-validate the whole tree substituted with legacy values**

Run (write a tiny loop):
```bash
for f in $(grep -rln "@@DATASET@@" bigquery/curator); do
  sed -e 's/@@DATASET@@/clinvar_curator/g' -e 's/@@ANNO_SOURCE@@/clinvar_curator.clinvar_annotations_native/g' -e 's/@@MV@@/MATERIALIZED /g' "$f" \
  | bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --dry_run --format=prettyjson >/dev/null \
  && echo "OK $f" || echo "FAIL $f"
done
```
Expected: `OK` for every file (functions/procedures dry-run-validate their bodies).

- [ ] **Step 6: Commit**

```bash
git add bigquery/curator
git commit -m "refactor(curator): parameterize DDL by @@DATASET@@ + @@ANNO_SOURCE@@ tokens"
```

### Task 1.3: Write the parameterized deploy script

**Files:**
- Create: `bigquery/curator/deploy.sh`

- [ ] **Step 1: Write `deploy.sh`**

```bash
#!/usr/bin/env bash
# Deploy the curator SQL into a target dataset with a chosen annotation source.
# Usage: DATASET=clinvar_curator_v4 ANNO_SOURCE=clinvar_curator.cvc_annotations_native_v4 ./deploy.sh [--dry-run]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"    # run from repo root regardless of invocation dir
: "${CURATOR_PROJECT:=clingen-dev}"
: "${DATASET:?set DATASET (e.g. clinvar_curator or clinvar_curator_v4)}"
: "${ANNO_SOURCE:?set ANNO_SOURCE (fully-qualified source table)}"
: "${MV:=MATERIALIZED }"   # legacy default; pass MV="" for the shadow so base_mv is a plain VIEW
DRY=""; [ "${1:-}" = "--dry-run" ] && DRY="--dry_run"
# Numbered apply order: base tables/views/funcs first, then impact-analysis.
FILES=$(ls bigquery/curator/0*-*.sql | sort; ls bigquery/curator/cvc-impact-analysis/0*-*.sql | sort)
for f in $FILES; do
  echo ">> $f"
  sed -e "s/@@DATASET@@/${DATASET}/g" -e "s#@@ANNO_SOURCE@@#${ANNO_SOURCE}#g" -e "s/@@MV@@/${MV}/g" "$f" \
    | bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false $DRY --format=none
done
echo "deploy complete: DATASET=$DATASET ANNO_SOURCE=$ANNO_SOURCE MV='${MV}' ${DRY:+(dry-run)}"
```

- [ ] **Step 2: Make it executable and dry-run against the legacy binding**

Run:
```bash
chmod +x bigquery/curator/deploy.sh
DATASET=clinvar_curator ANNO_SOURCE=clinvar_curator.clinvar_annotations_native ./bigquery/curator/deploy.sh --dry-run
```
Expected: `>> ` lines for each file and `deploy complete ... (dry-run)`; no errors. (Dry-run does not modify legacy.)

- [ ] **Step 3: Commit**

```bash
git add bigquery/curator/deploy.sh
git commit -m "feat(curator): parameterized deploy.sh (dataset + annotation-source binding)"
```

### Task 1.4: Capture the impact-SP dependency map in repo docs

**Files:**
- Create/Modify: `bigquery/curator/README.md`

- [ ] **Step 1: Write the dependency map + deploy usage into README.md**

Include verbatim the 11-table table from spec §3.6 (build order + inputs), the choke-point cascade (base_mv → view → baseline TVF → cvc_annotations TVF → SP), the note that `cvc_version_bumps`/`cvc_full_record_version_bumps` are pure-`clinvar_ingest` parity anchors, and a "Deploy" section showing the legacy vs `_v4` invocations of `deploy.sh`.

- [ ] **Step 2: Commit**

```bash
git add bigquery/curator/README.md
git commit -m "docs(curator): impact-SP dependency map + deploy usage"
```

---

## Chunk 2: Store `annotation_id` on every v4 document

Computes `annotation_id = UNIX_MILLIS(created_at)` at write time and stores it as a field, in BOTH the live extension and the historical migration, so the downstream never recomputes it (spec §6). Kept OUT of the dedup hash. Pure code + Vitest (`cd clinvar-cvc && npm test`; tests live in `clinvar-cvc/test/`, use the `createRequire` header).

### Task 2.1: Add `annotation_id` to the extension's `buildAnnotation`

**Files:**
- Modify: `clinvar-cvc/annotation.js`
- Test: `clinvar-cvc/test/annotation.test.js`

- [ ] **Step 1: Write the failing test**

Add to `clinvar-cvc/test/annotation.test.js` (reuse its `createRequire` header):
```js
const { buildAnnotation, annotationDocId } = require('../annotation.js');

test('buildAnnotation stores annotation_id = UNIX_MILLIS(created_at) as a string', () => {
  const scv = { scv: 'SCV1', submitter: 'S', submitter_id: '9', interp: 'Pathogenic', review: 'criteria' };
  const vcv = { variation_id: '1', vcv: 'VCV1', name: 'X' };
  const a = buildAnnotation(scv, vcv, { action: 'Flagging Candidate', reason: 'r', notes: 'n' }, 'a@b.org');
  expect(a.annotation_id).toBe(String(a.created_at.getTime()));
  expect(typeof a.annotation_id).toBe('string');
});

test('annotation_id does NOT affect the dedup doc id (excluded from DEDUP_FIELDS)', async () => {
  const scv = { scv: 'SCV1', submitter: 'S', submitter_id: '9', interp: 'Pathogenic', review: 'criteria' };
  const vcv = { variation_id: '1', vcv: 'VCV1', name: 'X' };
  const a = buildAnnotation(scv, vcv, { action: 'No Change', reason: '', notes: '' }, 'a@b.org');
  const b = { ...a, annotation_id: 'different', created_at: new Date(0) };
  expect(await annotationDocId(a)).toBe(await annotationDocId(b));
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd clinvar-cvc && npx vitest run annotation.test.js -t annotation_id`
Expected: FAIL — `buildAnnotation` doesn't set `annotation_id` yet.

- [ ] **Step 3: Implement**

In `buildAnnotation`, capture `created_at` once and derive `annotation_id`:
```js
function buildAnnotation(scvRow, vcv, input, userEmail) {
  const created_at = new Date();
  return {
    variation_id: vcv.variation_id, vcv: vcv.vcv, name: vcv.name,
    scv: scvRow.scv, submitter: scvRow.submitter, submitter_id: scvRow.submitter_id,
    interp: scvRow.interp, review_status: scvRow.review,
    action: input.action, reason: input.reason, notes: input.notes,
    user_email: userEmail,
    created_at,
    annotation_id: String(created_at.getTime())
  };
}
```
Do NOT add `annotation_id` to `DEDUP_FIELDS` (it's derived from `created_at`, which is already excluded). No change to `annotationDocId`. `toFirestoreFields` already serializes string fields, so `annotation_id` is written automatically.

- [ ] **Step 4: Run to verify pass (and no regressions)**

Run: `cd clinvar-cvc && npm test`
Expected: PASS — new cases green; existing `annotationDocId`/`buildAnnotation` tests unchanged.

- [ ] **Step 5: Commit**

```bash
git add clinvar-cvc/annotation.js clinvar-cvc/test/annotation.test.js
git commit -m "feat(cvc): store annotation_id = UNIX_MILLIS(created_at) on the v4 doc (excluded from dedup)"
```

### Task 2.2: Add `annotation_id` to the migration source + doc mapping

**Files:**
- Modify: `clinvar-cvc/migration/source.sql`
- Modify: `clinvar-cvc/migration/native-to-v4.js`
- Test: `clinvar-cvc/test/migration.test.js`

- [ ] **Step 1: Write the failing test**

Add to `clinvar-cvc/test/migration.test.js`:
```js
const { nativeRowToV4Doc } = require('../migration/native-to-v4.js');

test('nativeRowToV4Doc carries annotation_id through', () => {
  const row = { variation_id: '1', vcv_id: 'VCV1', variation_name: 'X', scv_id: 'SCV1',
    submitter_name: 'S', submitter_id: '9', interpretation: 'Pathogenic', review_status: 'criteria',
    action: 'Flagging Candidate', reason: 'r', notes: 'n', curator_email: 'a@b.org',
    annotation_date: '2020-01-01T00:00:05Z', annotation_id: '1577836805000' };
  const doc = nativeRowToV4Doc(row);
  expect(doc.annotation_id).toBe('1577836805000');
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd clinvar-cvc && npx vitest run migration.test.js -t annotation_id`
Expected: FAIL — `nativeRowToV4Doc` doesn't map `annotation_id`.

- [ ] **Step 3: Implement**

`source.sql`: add the column (before `annotation_date`, keep both):
```sql
  CAST(UNIX_MILLIS(TIMESTAMP(annotation_date)) AS STRING) AS annotation_id,
  FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', TIMESTAMP(annotation_date), 'UTC') AS annotation_date
```
`native-to-v4.js` `nativeRowToV4Doc`: add `annotation_id: row.annotation_id` to the returned object (do NOT add it to any dedup logic).

- [ ] **Step 4: Run to verify pass**

Run: `cd clinvar-cvc && npm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add clinvar-cvc/migration/source.sql clinvar-cvc/migration/native-to-v4.js clinvar-cvc/test/migration.test.js
git commit -m "feat(migration): compute + carry annotation_id (UNIX_MILLIS) on migrated v4 docs"
```

### Task 2.3: Expose `annotation_id` in the flattened BQ view

**Files:**
- Modify: `clinvar-cvc/bigquery/annotations_view.sql`

- [ ] **Step 1: Add the field to the view**

Following the same extraction pattern the view already uses for the other string fields (e.g. `scv`, `user_email`), add an `annotation_id` column, with a fallback so any pre-existing doc without the field still resolves:
```sql
COALESCE(<extract annotation_id string from the doc>, CAST(created_at_millis AS STRING)) AS annotation_id
```
(`created_at_millis` already exists in the view — it equals `UNIX_MILLIS(created_at)`, so the fallback is exact.)

- [ ] **Step 2: Apply the view to dev capture and confirm the column**

Run (substitute the project; this recreates the view — safe, it's `CREATE OR REPLACE VIEW`):
```bash
sed 's/@@PROJECT@@/clingen-cvc/g' clinvar-cvc/bigquery/annotations_view.sql 2>/dev/null || cat clinvar-cvc/bigquery/annotations_view.sql
```
Then verify against prod-staging (read-only) that the new view exposes `annotation_id` after Chunk 3's reload. For NOW, just dry-run-validate the SQL parses:
```bash
bq --project_id=clingen-cvc --location=us-central1 query --use_legacy_sql=false --dry_run --format=none < clinvar-cvc/bigquery/annotations_view.sql && echo "DRY-RUN OK"
```
Expected: `DRY-RUN OK`. (Actual recreation happens in Chunk 3 after the reload, so post-reload docs carry the field.)

- [ ] **Step 3: Commit**

```bash
git add clinvar-cvc/bigquery/annotations_view.sql
git commit -m "feat(cvc): expose annotation_id in the flattened BQ annotations view (COALESCE fallback)"
```

---

## Chunk 3: Re-migration (no dedup) + restored-records audit

Loads ALL historical records — no content-hash dedup — keyed by their unique `annotation_id`. Verified premise: 31,362 legacy rows → 31,362 distinct `annotation_id`, 0 collisions (spec §6). The re-migration is **irreversible** and touches capture, so it stays fenced behind an enumeration + explicit user confirmation.

### Task 3.1: Repoint `migrate.js` to key by `annotation_id`, no dedup

**Files:**
- Modify: `clinvar-cvc/migration/migrate.js`
- Test: `clinvar-cvc/test/migration.test.js`

- [ ] **Step 1: Write the failing test**

```js
const { loadDocsFromRows } = require('../migration/migrate.js');  // new pure helper (rows -> {id,doc}[])
const row = (over) => ({ variation_id:'1', vcv_id:'VCV1', variation_name:'X', scv_id:'SCV1',
  submitter_name:'S', submitter_id:'9', interpretation:'Pathogenic', review_status:'criteria',
  action:'Flagging Candidate', reason:'r', notes:'n', curator_email:'a@b.org',
  annotation_date:'2020-01-01T00:00:05Z', annotation_id:'1577836805000', ...over });

test('loadDocsFromRows keys by annotation_id and drops NOTHING (content-identical, distinct timestamps both kept)', () => {
  const out = loadDocsFromRows([
    row({ annotation_id:'1577836805000' }),
    row({ annotation_id:'1577836999000' })   // same content, different timestamp
  ]);
  expect(out.length).toBe(2);
  expect(out.map(o => o.id).sort()).toEqual(['1577836805000','1577836999000']);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd clinvar-cvc && npx vitest run migration.test.js -t 'keys by annotation_id'`
Expected: FAIL — `loadDocsFromRows` not exported.

- [ ] **Step 3: Implement**

Replace the content-hash dedup in `migrate.js` with a straight map keyed by `annotation_id`:
```js
const { nativeRowToV4Doc } = require('./native-to-v4.js');
function loadDocsFromRows(rows) {
  return rows.map(r => { const doc = nativeRowToV4Doc(r); return { id: doc.annotation_id, doc }; });
}
```
Rewire `loadUniqueDocs(sourcePath)` to `JSON.parse` the file and return `{ totalRows, uniqueDocs, intraSourceDups }` where `uniqueDocs = loadDocsFromRows(rows)` and `intraSourceDups = 0` (there is no dedup; if you want a guard, assert `new Set(uniqueDocs.map(d => d.id)).size === uniqueDocs.length` and throw on any `annotation_id` collision). Remove the `annotationDocId` import if now unused. Export `loadDocsFromRows`.

- [ ] **Step 4: Run to verify pass**

Run: `cd clinvar-cvc && npm test`
Expected: PASS — new case green; existing migration tests updated to the `annotation_id` doc-id where they asserted the old content-hash id.

- [ ] **Step 5: Commit**

```bash
git add clinvar-cvc/migration/migrate.js clinvar-cvc/test/migration.test.js
git commit -m "feat(migration): load ALL historical records keyed by annotation_id (no dedup)"
```

### Task 3.2: Build the restored-records audit (SQL)

**Files:**
- Create: `bigquery/curator/audit/restored-records-audit.sql`

- [ ] **Step 1: Write the audit query**

Lists the records the OLD content-hash dedup would have dropped (content-identical, distinct timestamps) — now all loaded — joined to any downstream review/submission they reference, action-segmented (`flagging candidate`/`remove flagged submission` first). Persist to a NEW table `clinvar_curator.cvc_restored_records_audit`:
```sql
CREATE OR REPLACE TABLE `clingen-dev.clinvar_curator.cvc_restored_records_audit` AS
WITH base AS (
  SELECT
    TO_JSON_STRING([
      COALESCE(CAST(variation_id AS STRING),''), COALESCE(CAST(vcv_id AS STRING),''),
      COALESCE(CAST(scv_id AS STRING),''), COALESCE(CAST(submitter_name AS STRING),''),
      COALESCE(CAST(submitter_id AS STRING),''), COALESCE(CAST(interpretation AS STRING),''),
      COALESCE(CAST(review_status AS STRING),''), COALESCE(CAST(action AS STRING),''),
      COALESCE(CAST(reason AS STRING),''), COALESCE(CAST(notes AS STRING),''),
      COALESCE(CAST(curator_email AS STRING),'')
    ]) AS content_key,
    LOWER(action) AS action, scv_id, curator_email,
    CAST(annotation_date AS TIMESTAMP) AS annotated_on,
    CAST(UNIX_MILLIS(CAST(annotation_date AS TIMESTAMP)) AS STRING) AS annotation_id
  FROM `clingen-dev.clinvar_curator.clinvar_annotations_native`
  WHERE `ignore` IS NOT TRUE
),
dup_content AS (   -- content keys with >1 row = would have been collapsed by content-hash dedup
  SELECT content_key FROM base GROUP BY content_key HAVING COUNT(*) > 1
)
SELECT
  b.annotation_id, b.action, b.scv_id, b.curator_email, b.annotated_on,
  r.batch_id AS impacted_review_batch_id,
  s.batch_id AS impacted_submission_batch_id
FROM base b
JOIN dup_content d USING (content_key)
LEFT JOIN `clingen-dev.clinvar_curator.cvc_clinvar_reviews`     r ON r.annotation_id = b.annotation_id
LEFT JOIN `clingen-dev.clinvar_curator.cvc_clinvar_submissions` s ON s.annotation_id = b.annotation_id
ORDER BY
  CASE b.action WHEN 'flagging candidate' THEN 0 WHEN 'remove flagged submission' THEN 1 ELSE 2 END,
  b.scv_id, b.annotated_on;
```

- [ ] **Step 2: Run it and record the summary**

Run:
```bash
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=none < bigquery/curator/audit/restored-records-audit.sql
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty \
'SELECT action, COUNT(*) AS restored_rows, COUNTIF(impacted_submission_batch_id IS NOT NULL) AS impacted_submissions
 FROM `clingen-dev.clinvar_curator.cvc_restored_records_audit` GROUP BY action ORDER BY action'
```
Expected: ~578 restored rows total (the records the old content-hash dedup dropped), `flagging candidate` showing the submission-impacting cases. Record for the parity report. (`cvc_clinvar_batches` has no `annotation_id`; batch impact is surfaced via the joined review/submission `batch_id`.)

- [ ] **Step 3: Commit**

```bash
git add bigquery/curator/audit/restored-records-audit.sql
git commit -m "feat(curator): restored-records audit (previously content-dedup-dropped, now loaded)"
```

### Task 3.3: Enumerate post-seed v4-only captures (pre-wipe gate)

**Files:** none (operational)

- [ ] **Step 1: Export current v4 + legacy native as JSON**

```bash
bq --project_id="$CVC_PROD" --location=us-central1 query --use_legacy_sql=false --format=json --max_rows=100000 \
'SELECT variation_id, vcv, scv, submitter, submitter_id, interp, review_status, action, reason, notes, user_email, created_at
 FROM `clingen-cvc.clinvar_cvc_ext.annotations`' > /tmp/v4-current.json
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=json --max_rows=100000 \
'SELECT variation_id, vcv_id, variation_name, scv_id, submitter_name, submitter_id, interpretation, review_status, action, reason, notes, curator_email, annotation_date
 FROM `clingen-dev.clinvar_curator.clinvar_annotations_native` WHERE `ignore` IS NOT TRUE' > /tmp/legacy-native.json
```

- [ ] **Step 2: Report v4-only content (reusing `annotationDocId` for a stable content key)**

```bash
cd clinvar-cvc && node -e '
const fs=require("node:fs");
const {annotationDocId}=require("./annotation.js");
const {nativeRowToV4Doc}=require("./migration/native-to-v4.js");
(async () => {
  const v4=JSON.parse(fs.readFileSync("/tmp/v4-current.json","utf8"));
  const legacy=JSON.parse(fs.readFileSync("/tmp/legacy-native.json","utf8")).map(nativeRowToV4Doc);
  const legacyKeys=new Set(await Promise.all(legacy.map(annotationDocId)));
  const v4keys=await Promise.all(v4.map(annotationDocId));
  const only=v4.filter((_,i)=>!legacyKeys.has(v4keys[i]));
  console.log("v4-only content rows (absent from sheet-derived legacy native):",only.length);
  console.log(JSON.stringify(only.slice(0,10),null,2));
})();
'; cd -
```
Expected: a count + samples. (Content-key match is timestamp-agnostic; a time-distinct v4 capture of content also in the sheet is not flagged — the reload recreates it. Only sheet-absent content is at risk.)

- [ ] **Step 2b: STOP — surface to the user (hard gate)**

Report: "N v4-only annotations found (not in the sheet). The clean-slate reload will drop them. Proceed / restore-first / abort?" Do not continue to Task 3.4 without an explicit answer. (Spec §10.)

### Task 3.4: Execute the gated clean-slate re-migration

**Files:** none (operational; existing `migration/` tooling + `cvc-provision` skill for IAM)

> **GATE:** proceed only if the user answered "proceed" at Task 3.3 Step 2b. This wipes and reloads prod-staging v4 and is irreversible.
> **Auth:** every `migrate.js`/`wipe-collection.js` call needs `export GCP_TOKEN=$(gcloud auth print-access-token)` and an explicit `--project clingen-cvc`. Input is `--source <file>`.

- [ ] **Step 1: Verify `run.invoker` BEFORE any load**

Follow the `cvc-provision` skill §C check: confirm the compute SA and `ext-firestore-bigquery-export@clingen-cvc.iam` have `roles/run.invoker` on the us-central1 Cloud Run service; grant + wait if missing. (A bulk load during a broken binding permanently drops events.)

- [ ] **Step 2: Regenerate the migration source extract (now includes annotation_id)**

```bash
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=json --max_rows=100000 \
  "$(cat clinvar-cvc/migration/source.sql)" > /tmp/cvc-history.json
```
Expected: ~31,362 rows, each with an `annotation_id`.

- [ ] **Step 3: Dry-run the migration (expect the FULL population)**

```bash
export GCP_TOKEN=$(gcloud auth print-access-token)
cd clinvar-cvc && node migration/migrate.js --dry-run --source /tmp/cvc-history.json --project clingen-cvc | tail -20; cd -
```
Expected: ~31,362 unique docs (ALL records — NOT 30,784). If it reports ~30,784, the dedup wasn't removed (Task 3.1) — stop.

- [ ] **Step 4: Recreate the flattened view with the annotation_id column (from Chunk 2.3)**

```bash
bq --project_id="$CVC_PROD" --location=us-central1 query --use_legacy_sql=false --format=none < clinvar-cvc/bigquery/annotations_view.sql
```

- [ ] **Step 5: Clean-slate wipe (paced)**

```bash
export GCP_TOKEN=$(gcloud auth print-access-token)
cd clinvar-cvc && node migration/wipe-collection.js --project clingen-cvc --confirm --delay-ms 2000; cd -
```
Expected: Firestore aggregate count → 0.

- [ ] **Step 6: Paced reload**

```bash
export GCP_TOKEN=$(gcloud auth print-access-token)
cd clinvar-cvc && node migration/migrate.js --source /tmp/cvc-history.json --project clingen-cvc --delay-ms 3000; cd -
```
Expected: ~31,362 create-only writes, 0 errors.

- [ ] **Step 7: Reconcile Firestore vs BigQuery + confirm annotation_id present**

```bash
bq --project_id="$CVC_PROD" --location=us-central1 query --use_legacy_sql=false --format=pretty \
'SELECT COUNT(*) AS bq_rows, COUNTIF(annotation_id IS NULL) AS missing_annotation_id
 FROM `clingen-cvc.clinvar_cvc_ext.annotations`'
```
Expected: `bq_rows` ≈ 31,362 (== Firestore), `missing_annotation_id` = 0. If BQ < Firestore, a streaming burst-drop occurred — re-check `run.invoker`, re-run clean-slate.

- [ ] **Step 8: Record the reconciliation**

Append counts (legacy rows 31,362, loaded docs ≈31,362, 578 restored, 0 dropped, Firestore==BQ, annotation_id present) to `docs/superpowers/plans/2026-08-03-phase0-parity-report.md`. Commit tooling/doc changes.

---

## Chunk 4: The adapter (v4 capture → US native contract table)

Lands the full v4 capture into a `US` native table carrying the choke-point contract **with `annotation_id` passed through** (spec §5). No crosswalk — every staging id resolves directly.

> **Copy mechanism:** full snapshot of the flattened `annotations` view per run (on-demand + daily), not a 15-min cadence — the data is <60 MB, so a full cross-region copy is pennies and keeps the flatten logic in the single existing view.

### Task 4.1: Cross-region snapshot + load script

**Files:**
- Create: `bigquery/curator/adapter/refresh-native-v4.sh`

- [ ] **Step 1: Write `refresh-native-v4.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${CVC_PROD:=clingen-cvc}"; : "${CURATOR_PROJECT:=clingen-dev}"; : "${GCS_BUCKET:?set GCS_BUCKET (us-central1)}"
cd "$(git rev-parse --show-toplevel)"
SNAP="${CVC_PROD}:clinvar_cvc_ext._native_v4_snapshot"
RAW="${CURATOR_PROJECT}:clinvar_curator._annotations_v4_raw"
bq --project_id="$CVC_PROD" --location=us-central1 query --use_legacy_sql=false --destination_table="$SNAP" --replace \
  'SELECT * FROM `clingen-cvc.clinvar_cvc_ext.annotations`'
bq --project_id="$CVC_PROD" --location=us-central1 extract --destination_format=NEWLINE_DELIMITED_JSON \
  "$SNAP" "${GCS_BUCKET}/native_v4/*.json"
bq --project_id="$CURATOR_PROJECT" --location=US load --replace --source_format=NEWLINE_DELIMITED_JSON \
  --autodetect "$RAW" "${GCS_BUCKET}/native_v4/*.json"
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=none \
  < bigquery/curator/adapter/native_v4_reshape.sql
echo "native_v4 refreshed."
```

- [ ] **Step 2: `chmod +x` (run after 4.2 exists)**

Run: `chmod +x bigquery/curator/adapter/refresh-native-v4.sh`

- [ ] **Step 3: Commit**

```bash
git add bigquery/curator/adapter/refresh-native-v4.sh
git commit -m "feat(adapter): cross-region snapshot+load script for native_v4"
```

### Task 4.2: Reshape raw → contract native table (annotation_id passthrough)

**Files:**
- Create: `bigquery/curator/adapter/native_v4_reshape.sql`

- [ ] **Step 1: Write the reshape SQL**

Maps the flattened v4 columns → the choke-point contract (renames + passthroughs), sets `ignore = FALSE`, and **passes `annotation_id` through** (COALESCE fallback), keeping `annotation_date` too:
```sql
CREATE OR REPLACE TABLE `clingen-dev.clinvar_curator.cvc_annotations_native_v4` AS
SELECT
  COALESCE(annotation_id, CAST(created_at_millis AS STRING)) AS annotation_id,
  CAST(created_at AS TIMESTAMP) AS annotation_date,
  vcv           AS vcv_id,
  scv           AS scv_id,
  variation_id  AS variation_id,
  submitter_id  AS submitter_id,
  action        AS action,
  user_email    AS curator_email,
  interp        AS interpretation,
  reason        AS reason,
  notes         AS notes,
  review_status AS review_status,
  FALSE         AS `ignore`
FROM `clingen-dev.clinvar_curator._annotations_v4_raw`;
```

- [ ] **Step 2: Run the full adapter and verify**

```bash
./bigquery/curator/adapter/refresh-native-v4.sh
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty \
'SELECT COUNT(*) rows, COUNT(DISTINCT annotation_id) distinct_ids, COUNTIF(annotation_id IS NULL) null_ids
 FROM `clingen-dev.clinvar_curator.cvc_annotations_native_v4`'
```
Expected: `rows` ≈ 31,362; `distinct_ids` == `rows` (all unique); `null_ids` = 0.

- [ ] **Step 3: Confirm annotation_id matches the legacy-computed id (sample)**

```bash
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty \
'SELECT COUNT(*) AS mismatches
 FROM `clingen-dev.clinvar_curator.cvc_annotations_native_v4` n
 WHERE n.annotation_id != CAST(UNIX_MILLIS(n.annotation_date) AS STRING)'
```
Expected: 0 (the stored id equals `UNIX_MILLIS(annotation_date)` — proves stored == legacy-computed).

- [ ] **Step 4: Commit**

```bash
git add bigquery/curator/adapter/native_v4_reshape.sql
git commit -m "feat(adapter): native_v4 reshape (annotation_id passthrough, no recompute)"
```

---

## Chunk 5: The shadow `clinvar_curator_v4` lineage

Deploys the full curator object graph into `clinvar_curator_v4` over `native_v4`, reading the stored `annotation_id` via the `@@ANNO_ID@@` token, with plain passthrough staging views (spec §7.1). Legacy `clinvar_curator` untouched.

### Task 5.1: Split staging-table DDL + add the `@@ANNO_ID@@` token

**Files:**
- Modify: `bigquery/curator/00-initialize-cvc-tables.sql`
- Modify: `bigquery/curator/deploy.sh`
- Create: `bigquery/curator/staging-tables.sql`

- [ ] **Step 1: Move the three `CREATE TABLE` staging blocks out**

Cut `CREATE TABLE @@DATASET@@.cvc_clinvar_reviews/submissions/batches` from `00-initialize-cvc-tables.sql` into new `bigquery/curator/staging-tables.sql` (header: legacy-only bootstrap; the v4 shadow uses passthrough VIEWS of the same names). The view/MV layer stays in `00-initialize`.

- [ ] **Step 2: Tokenize the base_mv `annotation_id` expression**

In `00-initialize-cvc-tables.sql`, the base_mv currently derives `CAST(UNIX_MILLIS(a.annotation_date) AS STRING) AS annotation_id`. Replace the expression with `@@ANNO_ID@@ AS annotation_id` (legacy substitutes `@@ANNO_ID@@` → `CAST(UNIX_MILLIS(a.annotation_date) AS STRING)`; shadow → `a.annotation_id`).

- [ ] **Step 3: Add `@@ANNO_ID@@` to `deploy.sh`**

Add `: "${ANNO_ID:=CAST(UNIX_MILLIS(a.annotation_date) AS STRING)}"` (legacy default) and a fourth sed substitution `-e "s#@@ANNO_ID@@#${ANNO_ID}#g"` (use `#` delimiter — the value has parens/spaces but no `#`).

- [ ] **Step 4: Dry-run-validate the trimmed 00 (legacy binding)**

```bash
sed -e 's/@@DATASET@@/clinvar_curator/g' -e 's#@@ANNO_SOURCE@@#clinvar_curator.clinvar_annotations_native#g' \
    -e 's/@@MV@@/MATERIALIZED /g' -e 's#@@ANNO_ID@@#CAST(UNIX_MILLIS(a.annotation_date) AS STRING)#g' \
  bigquery/curator/00-initialize-cvc-tables.sql \
  | bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --dry_run --format=none && echo "DRY-RUN OK"
```
Expected: `DRY-RUN OK` (the trimmed file has no `CREATE TABLE` collision now).

- [ ] **Step 5: Commit**

```bash
git add bigquery/curator/00-initialize-cvc-tables.sql bigquery/curator/staging-tables.sql bigquery/curator/deploy.sh
git commit -m "refactor(curator): split staging DDL + @@ANNO_ID@@ token (shadow reads stored annotation_id)"
```

### Task 5.2: Passthrough staging views for the shadow

**Files:**
- Create: `bigquery/curator/adapter/staging_passthrough_views.sql`

- [ ] **Step 1: Write the views (in `clinvar_curator_v4`, named as the tables)**

No id remap is needed (all staging ids resolve directly), so these are plain passthroughs:
```sql
CREATE OR REPLACE VIEW `clingen-dev.clinvar_curator_v4.cvc_clinvar_reviews`     AS SELECT * FROM `clingen-dev.clinvar_curator.cvc_clinvar_reviews`;
CREATE OR REPLACE VIEW `clingen-dev.clinvar_curator_v4.cvc_clinvar_submissions` AS SELECT * FROM `clingen-dev.clinvar_curator.cvc_clinvar_submissions`;
CREATE OR REPLACE VIEW `clingen-dev.clinvar_curator_v4.cvc_clinvar_batches`     AS SELECT * FROM `clingen-dev.clinvar_curator.cvc_clinvar_batches`;
CREATE OR REPLACE VIEW `clingen-dev.clinvar_curator_v4.cvc_rejected_scvs`       AS SELECT * FROM `clingen-dev.clinvar_curator.cvc_rejected_scvs`;
```

- [ ] **Step 2: Commit**

```bash
git add bigquery/curator/adapter/staging_passthrough_views.sql
git commit -m "feat(shadow): passthrough staging + shared-ref views for clinvar_curator_v4"
```

### Task 5.3: Deploy the shadow lineage + run the impact SP

**Files:** none (uses `deploy.sh`)

- [ ] **Step 1: Create the dataset + deploy passthrough views first**

```bash
bq --project_id="$CURATOR_PROJECT" mk --location=US --dataset "$CURATOR_PROJECT:clinvar_curator_v4" || echo "exists"
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=none < bigquery/curator/adapter/staging_passthrough_views.sql
```

- [ ] **Step 2: Dry-run the v4 binding, then deploy**

`MV=""` → plain view (can read the passthrough views); `ANNO_ID=a.annotation_id` → reads the stored id.
```bash
DATASET=clinvar_curator_v4 ANNO_SOURCE=clinvar_curator.cvc_annotations_native_v4 MV="" ANNO_ID="a.annotation_id" ./bigquery/curator/deploy.sh --dry-run
DATASET=clinvar_curator_v4 ANNO_SOURCE=clinvar_curator.cvc_annotations_native_v4 MV="" ANNO_ID="a.annotation_id" ./bigquery/curator/deploy.sh
```
Expected: dry-run passes; then `>>` per file and `deploy complete`.

> **Naming note:** the shadow SP is `clinvar_curator_v4.refresh_cvc_impact_analysis` writing `clinvar_curator_v4.cvc_*` tables — the `_v4` is in the dataset name, matching the spec's `_v4` intent.

- [ ] **Step 3: Run the shadow impact SP**

```bash
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=none \
  'CALL `clingen-dev.clinvar_curator_v4.refresh_cvc_impact_analysis`()'
```
Expected: completes; the 11 `clinvar_curator_v4.cvc_*` tables populate.

- [ ] **Step 4: Smoke-check the shadow choke point**

```bash
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty \
'SELECT COUNT(*) rows FROM `clingen-dev.clinvar_curator_v4.cvc_annotations`("all")'
```
Expected: ~31,362 rows; no error.

- [ ] **Step 5: Commit any deploy tweaks**

```bash
git add bigquery/curator
git commit -m "chore(shadow): deploy clinvar_curator_v4 lineage" || echo "nothing to commit"
```

---

## Chunk 6: Parity verification + go/no-go report

Proves the v4 lineage matches legacy on the shared seed (spec §7.2). Because no dedup is applied and the stored `annotation_id` equals the legacy-computed one, the shared seed is **exact** — no collapse bucket, no crosswalk on either side.

### Task 6.1: Parity anchors (pure-upstream tables identical)

**Files:**
- Create: `bigquery/curator/tests/01-anchor-version-bumps.sql`

- [ ] **Step 1: Write the anchor diff**

```sql
-- returns 0 rows on success
SELECT 'version_bumps' AS tbl, * FROM (
  (SELECT * FROM `clingen-dev.clinvar_curator.cvc_version_bumps`
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_version_bumps`)
  UNION ALL
  (SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_version_bumps`
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator.cvc_version_bumps`)
);
```

- [ ] **Step 2: Run, expect 0 rows**

Run: `bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty < bigquery/curator/tests/01-anchor-version-bumps.sql`
Expected: 0 rows. Non-zero ⇒ environment/config difference, not the adapter.

- [ ] **Step 3: Commit**

```bash
git add bigquery/curator/tests/01-anchor-version-bumps.sql
git commit -m "test(parity): pure-upstream version-bump anchors identical"
```

### Task 6.2: Id-integrity — 0 orphans, stored == computed

**Files:**
- Create: `bigquery/curator/tests/02-id-integrity.sql`

- [ ] **Step 1: Write the diff**

```sql
-- returns 0 rows on success
-- (a) every staging annotation_id exists in native_v4
SELECT s.annotation_id AS orphan_staging_id
FROM (
  SELECT annotation_id FROM `clingen-dev.clinvar_curator.cvc_clinvar_reviews` WHERE annotation_id IS NOT NULL
  UNION DISTINCT
  SELECT annotation_id FROM `clingen-dev.clinvar_curator.cvc_clinvar_submissions` WHERE annotation_id IS NOT NULL
) s
LEFT JOIN `clingen-dev.clinvar_curator.cvc_annotations_native_v4` n ON n.annotation_id = s.annotation_id
WHERE n.annotation_id IS NULL
UNION ALL
-- (b) stored annotation_id equals UNIX_MILLIS(annotation_date) for every v4 row
SELECT n.annotation_id
FROM `clingen-dev.clinvar_curator.cvc_annotations_native_v4` n
WHERE n.annotation_id != CAST(UNIX_MILLIS(n.annotation_date) AS STRING);
```

- [ ] **Step 2: Run, expect 0 rows**

Run: `bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty < bigquery/curator/tests/02-id-integrity.sql`
Expected: 0 rows (no orphans; stored id == computed id everywhere).

- [ ] **Step 3: Commit**

```bash
git add bigquery/curator/tests/02-id-integrity.sql
git commit -m "test(parity): id-integrity (0 orphans; stored==computed annotation_id)"
```

### Task 6.3: Choke-point column diff (exact on shared seed)

**Files:**
- Create: `bigquery/curator/tests/03-chokepoint-diff.sql`

- [ ] **Step 1: Write the diff**

Compare `cvc_annotations("all")` legacy vs v4 on shared `annotation_id`s (they match directly now). Column diff must be exactly 0.
```sql
-- returns 0 rows on success
WITH leg AS (
  SELECT annotation_id, variation_id, vcv_id, scv_id, action, reason, notes, curator, clinvar_review_status
  FROM `clingen-dev.clinvar_curator.cvc_annotations`("all")
),
v4 AS (
  SELECT annotation_id, variation_id, vcv_id, scv_id, action, reason, notes, curator, clinvar_review_status
  FROM `clingen-dev.clinvar_curator_v4.cvc_annotations`("all")
),
shared AS (SELECT annotation_id FROM leg INTERSECT DISTINCT SELECT annotation_id FROM v4)
SELECT 'legacy_only_cols' AS side, * FROM (
  SELECT * FROM leg WHERE annotation_id IN (SELECT annotation_id FROM shared)
  EXCEPT DISTINCT
  SELECT * FROM v4 WHERE annotation_id IN (SELECT annotation_id FROM shared))
UNION ALL
SELECT 'v4_only_cols', * FROM (
  SELECT * FROM v4 WHERE annotation_id IN (SELECT annotation_id FROM shared)
  EXCEPT DISTINCT
  SELECT * FROM leg WHERE annotation_id IN (SELECT annotation_id FROM shared));
```

- [ ] **Step 2: Run, expect 0 rows**

Run: `bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty < bigquery/curator/tests/03-chokepoint-diff.sql`
Expected: 0 rows on the shared seed. Any diff is an adapter bug (drift is enumerated separately, Task 6.5).

- [ ] **Step 3: Commit**

```bash
git add bigquery/curator/tests/03-chokepoint-diff.sql
git commit -m "test(parity): choke-point column diff = 0 on shared seed"
```

### Task 6.4: End-to-end batch parity

**Files:**
- Create: `bigquery/curator/tests/04-batch-endtoend.sql`
- Create: `bigquery/curator/tests/run-parity.sh`

- [ ] **Step 1: Pick a pre-seed finalized batch**

```bash
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty \
'SELECT batch_id, finalized_datetime FROM `clingen-dev.clinvar_curator.cvc_clinvar_batches`
 ORDER BY finalized_datetime DESC LIMIT 10'
```
Choose a `batch_id` finalized before the `clingen-cvc` seed boundary. Record as `$BATCH`.

- [ ] **Step 2: Write the batch diff SQL**

For the chosen batch, symmetric `EXCEPT DISTINCT` (both directions) of `cvc_flagging_version_bump_intersection` and `cvc_resubmission_candidates` scoped `WHERE batch_id=@batch` (full rows — `annotation_id` now matches on both sides, so no `EXCEPT(annotation_id)` needed), plus a whole-table diff of `cvc_impact_summary`, plus the current submission set (`cvc_annotations("unreviewed")` JOIN submissions, `action != 'no change'`, on shared `scv_id`). Each sub-query returns 0 rows on success:
```sql
-- #8 flagging_version_bump_intersection (batch-scoped, symmetric)
WITH d8 AS (
  (SELECT * FROM `clingen-dev.clinvar_curator.cvc_flagging_version_bump_intersection` WHERE batch_id=@batch
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_flagging_version_bump_intersection` WHERE batch_id=@batch)
  UNION ALL
  (SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_flagging_version_bump_intersection` WHERE batch_id=@batch
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator.cvc_flagging_version_bump_intersection` WHERE batch_id=@batch)
),
d9 AS (
  (SELECT * FROM `clingen-dev.clinvar_curator.cvc_resubmission_candidates` WHERE batch_id=@batch
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_resubmission_candidates` WHERE batch_id=@batch)
  UNION ALL
  (SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_resubmission_candidates` WHERE batch_id=@batch
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator.cvc_resubmission_candidates` WHERE batch_id=@batch)
),
d11 AS (
  (SELECT * FROM `clingen-dev.clinvar_curator.cvc_impact_summary`
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_impact_summary`)
  UNION ALL
  (SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_impact_summary`
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator.cvc_impact_summary`)
)
SELECT 'flag_vbump' t, TO_JSON_STRING(d8) row FROM d8
UNION ALL SELECT 'resubmission', TO_JSON_STRING(d9) FROM d9
UNION ALL SELECT 'impact_summary', TO_JSON_STRING(d11) FROM d11;
```

- [ ] **Step 3: Write `run-parity.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
: "${CURATOR_PROJECT:=clingen-dev}"; : "${BATCH:?set BATCH}"
fail=0
for q in bigquery/curator/tests/0[1-4]*.sql; do
  echo "== $q =="
  n=$(bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=csv \
        --parameter=batch:STRING:"$BATCH" "$(cat "$q")" | tail -n +2 | wc -l | tr -d ' ')
  if [ "$n" = "0" ]; then echo "PASS ($q)"; else echo "FAIL: $n diff rows ($q)"; fail=1; fi
done
exit $fail
```

- [ ] **Step 4: Run the suite**

Run: `chmod +x bigquery/curator/tests/run-parity.sh && BATCH=$BATCH ./bigquery/curator/tests/run-parity.sh`
Expected: `PASS` for every query. Any `FAIL` ⇒ investigate before declaring parity.

- [ ] **Step 5: Commit**

```bash
git add bigquery/curator/tests/04-batch-endtoend.sql bigquery/curator/tests/run-parity.sh
git commit -m "test(parity): end-to-end batch diff + runner"
```

### Task 6.5: Drift enumeration (sheet-only vs v4-only)

**Files:**
- Create: `bigquery/curator/tests/05-drift-enumeration.sql`

- [ ] **Step 1: Count annotation_ids on only one side (informational, spec §7.2 item 7)**

```sql
WITH leg AS (SELECT DISTINCT annotation_id AS aid FROM `clingen-dev.clinvar_curator.cvc_annotations`("all")),
     v4  AS (SELECT DISTINCT annotation_id AS aid FROM `clingen-dev.clinvar_curator_v4.cvc_annotations`("all"))
SELECT
  (SELECT COUNT(*) FROM (SELECT aid FROM leg EXCEPT DISTINCT SELECT aid FROM v4)) AS sheet_only_drift,
  (SELECT COUNT(*) FROM (SELECT aid FROM v4 EXCEPT DISTINCT SELECT aid FROM leg)) AS v4_only_drift;
```

- [ ] **Step 2: Run and record (no pass/fail; feeds the report)**

Run: `bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty < bigquery/curator/tests/05-drift-enumeration.sql`
Expected: two small counts, explainable by the seed boundary. Record in the report. (The runner's `0[1-4]*` glob excludes this file from pass/fail.)

- [ ] **Step 3: Commit**

```bash
git add bigquery/curator/tests/05-drift-enumeration.sql
git commit -m "test(parity): drift enumeration (sheet-only vs v4-only)"
```

### Task 6.6: Write the go/no-go parity report

**Files:**
- Modify: `docs/superpowers/plans/2026-08-03-phase0-parity-report.md`

- [ ] **Step 1: Fill the report**

Sections (spec §7.3): re-migration reconciliation (all 31,362 loaded, 578 restored, 0 dropped, Firestore==BQ, annotation_id present), anchor result, id-integrity (0 orphans; stored==computed), choke-point diff (0 on shared seed), batch end-to-end result, drift enumeration counts, and a reference to the §6 restored-records audit. End with an explicit **GO / NO-GO for Phase 1** recommendation.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-08-03-phase0-parity-report.md
git commit -m "docs(parity): Phase-0 go/no-go parity report"
```

---

## Done criteria

- `bigquery/curator/` is the single CvC SQL home; `deploy.sh` deploys legacy or `_v4` from one templated tree (`@@DATASET@@/@@ANNO_SOURCE@@/@@MV@@/@@ANNO_ID@@`).
- `annotation_id = UNIX_MILLIS(created_at)` is stored on every v4 doc (extension + migration); exposed in the BQ view; passed through (not recomputed) by the v4 lineage.
- Prod-staging v4 re-migrated with NO dedup: all ~31,362 records loaded (578 restored, 0 dropped); Firestore == BQ; annotation_id present.
- `cvc_annotations_native_v4` + the full `clinvar_curator_v4` lineage (incl. 11-table SP) build and run; every staging id resolves directly (no crosswalk).
- Parity suite green (0-row diffs) on an exact shared seed; drift enumerated; restored-records audit produced; **go/no-go report written**.
