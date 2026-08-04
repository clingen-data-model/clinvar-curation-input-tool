# Phase 0 — Canonical CvC Data Layer Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a durable, v4-sourced BigQuery data layer for the CvC downstream — consolidating the curator SQL into this repo, correcting the migration dedup to a 15-minute rule, and proving a parallel `clinvar_curator_v4` lineage matches the legacy one — without disturbing the live Review&Submit pipeline.

**Architecture:** A shared 15-min-windowed dedup module drives a clean-slate re-migration of prod-staging v4 (`clingen-cvc`). An incremental cross-region transfer lands that capture into a `US` native table (`cvc_annotations_native_v4`) carrying the choke-point contract. A parameterized deploy builds a shadow `clinvar_curator_v4` lineage (choke point + 11-table impact SP) over it, reconciled to the legacy staging tables through a non-destructive cluster-anchor crosswalk, then diff-tested for parity. Legacy `clinvar_curator` is never mutated.

**Tech Stack:** BigQuery (Standard SQL, `bq` CLI, US + us-central1), GCS (cross-region staging), Firestore REST (re-migration), Node.js + Vitest (dedup module + migration tooling), bash (deploy + transfer scripts).

**Spec:** `docs/superpowers/specs/2026-08-03-phase0-canonical-data-layer-design.md` — read it before starting. Section references below (e.g. "spec §6.4") point into it.

**Conventions used throughout this plan**
- All `bq` calls against `clinvar_curator`/`clinvar_ingest` use `--location=US`; against `clinvar_cvc_ext` use `--location=us-central1`.
- Env vars assumed exported by the worker: `CVC_PROD=clingen-cvc`, `CURATOR_PROJECT=clingen-dev`, `GCS_BUCKET=gs://<a US or us-central1 bucket the runner SA can read/write>` (create if absent; note its location).
- "Legacy native" = `clingen-dev.clinvar_curator.clinvar_annotations_native` (sheet-derived, untouched).
- Never run `CREATE OR REPLACE` against a legacy `clinvar_curator` object; all new objects are new names or live in `clinvar_curator_v4`.

---

## File Structure

**New — repo consolidation (Chunk 1):**
- `bigquery/curator/` — the moved SQL tree (from `clinvar-ingest-bq-tools/scripts/clinvar-curation/`), numbered apply order preserved.
- `bigquery/curator/deploy.sh` — parameterized deploy: substitutes a dataset token + source-binding token into the numbered SQL and applies in order.
- `bigquery/curator/README.md` — how to deploy legacy vs `_v4`; the impact-SP dependency map (spec §3.6).

**New — shared dedup module (Chunk 2):**
- `clinvar-cvc/dedup.js` — the single source of truth for the content+15-min-cluster dedup key.
- `clinvar-cvc/dedup.test.js` — Vitest unit tests.

**Modified — migration (Chunk 3):**
- `clinvar-cvc/annotation.js` — export `DEDUP_FIELDS` + `canonicalContent()` (DRY; consumed by `dedup.js`).
- `clinvar-cvc/migration/native-to-v4.js` — no dedup logic change; add `annotation_date`-aware helpers only if needed.
- `clinvar-cvc/migration/migrate.js` — replace content-only dedup with `dedup.js` clustering.
- `bigquery/curator/audit/dropped-impacted-audit.sql` — the dropped/impacted audit log (spec §6.5).

**New — adapter (Chunk 4):**
- `bigquery/curator/adapter/refresh-native-v4.sh` — incremental changelog mirror (EXPORT→GCS→LOAD) + reshape trigger.
- `bigquery/curator/adapter/native_v4_reshape.sql` — latest-per-doc + contract reshape + `annotation_id`.
- `bigquery/curator/adapter/cvc_annotation_id_xwalk.sql` — cluster-anchor crosswalk build.
- `bigquery/curator/adapter/staging_x_views.sql` — the `_x` crosswalk views.

**New — shadow lineage (Chunk 5):**
- (Deployed via `deploy.sh` with `DATASET=clinvar_curator_v4`, `ANNO_SOURCE=cvc_annotations_native_v4`, `STAGING=_x views`.)

**New — parity (Chunk 6):**
- `bigquery/curator/tests/*.sql` — parity diff queries (each returns 0 rows on success).
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

Run:
```bash
grep -rln "clinvar_curator\.\|clinvar_annotations_native" bigquery/curator
```
Expected: the list of files needing templating (00-initialize, 01–05 funcs, cvc-impact-analysis/00,03,04,06,07,09, cvc-submitted-outcomes-stats.sql, cvc-annotation-history-report.sql).

- [ ] **Step 2: Replace the dataset token in one file first (00-initialize-cvc-tables.sql)**

Replace every `` `clinvar_curator. `` with `` `@@DATASET@@. `` and the single source table reference `` `clinvar_curator.clinvar_annotations_native` `` (base_mv `FROM`) with `` `@@ANNO_SOURCE@@` ``. Leave `clinvar_ingest.` references untouched (shared upstream).

- [ ] **Step 3: Verify the file still parses after substituting the legacy values**

Run:
```bash
sed -e 's/@@DATASET@@/clinvar_curator/g' -e 's/@@ANNO_SOURCE@@/clinvar_curator.clinvar_annotations_native/g' \
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
  sed -e 's/@@DATASET@@/clinvar_curator/g' -e 's/@@ANNO_SOURCE@@/clinvar_curator.clinvar_annotations_native/g' "$f" \
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
: "${CURATOR_PROJECT:=clingen-dev}"
: "${DATASET:?set DATASET (e.g. clinvar_curator or clinvar_curator_v4)}"
: "${ANNO_SOURCE:?set ANNO_SOURCE (fully-qualified source table)}"
DRY=""; [ "${1:-}" = "--dry-run" ] && DRY="--dry_run"
# Numbered apply order: base tables/views/funcs first, then impact-analysis.
FILES=$(ls bigquery/curator/0*-*.sql | sort; ls bigquery/curator/cvc-impact-analysis/0*-*.sql | sort)
for f in $FILES; do
  echo ">> $f"
  sed -e "s/@@DATASET@@/${DATASET}/g" -e "s#@@ANNO_SOURCE@@#${ANNO_SOURCE}#g" "$f" \
    | bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false $DRY --format=none
done
echo "deploy complete: DATASET=$DATASET ANNO_SOURCE=$ANNO_SOURCE ${DRY:+(dry-run)}"
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

## Chunk 2: Shared 15-minute dedup module (TDD)

Builds the single source of truth for the content+15-min-cluster dedup key (spec §6.2, decision 10). Pure JS, unit-tested with Vitest. Consumed by the migration in Chunk 3 and (in Phase 2) by live reflag capture. Uses this repo's existing test harness (`cd clinvar-cvc && npm test`).

**Module interface (what Chunk 3 will rely on):**
- `canonicalContent(doc)` → the stable string of the 11 `DEDUP_FIELDS` (reused from `annotation.js`, so migration + capture can't diverge).
- `clusterKey(doc, clusterAnchorMillis)` → `Promise<string>` = SHA-256 hex of `canonicalContent(doc) + '|' + clusterAnchorMillis`.
- `clusterAnnotations(rows, windowMs = 15*60*1000)` → returns `rows` annotated with `{ clusterAnchorMillis }`, where rows are grouped by `canonicalContent`, sorted by `created_at`, and a new cluster starts when the **consecutive gap** exceeds `windowMs`; the anchor is the **earliest** `created_at` in the cluster. Each `row.created_at` is an ISO string or `Date`.

### Task 2.1: Export the shared content canonicalization from `annotation.js`

**Files:**
- Modify: `clinvar-cvc/annotation.js`
- Test: `clinvar-cvc/annotation.test.js` (existing; add one case)

- [ ] **Step 1: Write the failing test**

Add to `clinvar-cvc/annotation.test.js`:
```js
import { canonicalContent, DEDUP_FIELDS } from './annotation.js';

test('canonicalContent is stable and excludes name + created_at', () => {
  const base = { variation_id: '1', vcv: 'VCV1', scv: 'SCV1', submitter: 'S', submitter_id: '9',
    interp: 'Pathogenic', review_status: 'criteria', action: 'Flagging Candidate',
    reason: 'r', notes: 'n', user_email: 'a@b.org' };
  const a = canonicalContent({ ...base, name: 'X', created_at: '2020-01-01T00:00:00Z' });
  const b = canonicalContent({ ...base, name: 'Y', created_at: '2021-06-06T12:00:00Z' });
  expect(a).toBe(b);                       // name + created_at do not affect content identity
  expect(DEDUP_FIELDS).toContain('scv');   // still the 11-field set
  expect(DEDUP_FIELDS).not.toContain('name');
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd clinvar-cvc && npx vitest run annotation.test.js -t canonicalContent`
Expected: FAIL — `canonicalContent` is not exported.

- [ ] **Step 3: Implement `canonicalContent` in `annotation.js`**

Refactor `annotationDocId` to reuse it (DRY), and export both `DEDUP_FIELDS` and `canonicalContent`:
```js
function canonicalContent(doc) {
  return JSON.stringify(DEDUP_FIELDS.map(f => String(doc[f] ?? '')));
}
async function annotationDocId(doc) {
  const bytes = new TextEncoder().encode(canonicalContent(doc));
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
}
```
Add `canonicalContent` and `DEDUP_FIELDS` to the `module.exports` and `window.*` blocks.

- [ ] **Step 4: Run tests to verify pass (new + existing dedup tests unaffected)**

Run: `cd clinvar-cvc && npm test`
Expected: PASS — all existing tests still green (annotationDocId unchanged in behavior), plus the new case.

- [ ] **Step 5: Commit**

```bash
git add clinvar-cvc/annotation.js clinvar-cvc/annotation.test.js
git commit -m "refactor(cvc): extract canonicalContent + export DEDUP_FIELDS (DRY for dedup module)"
```

### Task 2.2: `clusterKey` — time-anchored dedup id

**Files:**
- Create: `clinvar-cvc/dedup.js`
- Test: `clinvar-cvc/dedup.test.js`

- [ ] **Step 1: Write the failing test**

```js
import { clusterKey } from './dedup.js';

const doc = { variation_id: '1', vcv: 'VCV1', scv: 'SCV1', submitter: 'S', submitter_id: '9',
  interp: 'Pathogenic', review_status: 'criteria', action: 'Flagging Candidate',
  reason: 'r', notes: 'n', user_email: 'a@b.org' };

test('same content + same anchor -> same key; different anchor -> different key', async () => {
  const k1 = await clusterKey(doc, 1_000_000);
  const k2 = await clusterKey(doc, 1_000_000);
  const k3 = await clusterKey(doc, 2_000_000);
  expect(k1).toBe(k2);
  expect(k1).not.toBe(k3);
  expect(k1).toMatch(/^[0-9a-f]{64}$/);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd clinvar-cvc && npx vitest run dedup.test.js -t 'same content'`
Expected: FAIL — `dedup.js` / `clusterKey` not defined.

- [ ] **Step 3: Implement `clusterKey` in `dedup.js`**

```js
if (typeof globalThis.crypto === 'undefined') globalThis.crypto = require('node:crypto').webcrypto;
const { canonicalContent } = (typeof require !== 'undefined') ? require('./annotation.js') : window;

async function clusterKey(doc, clusterAnchorMillis) {
  const material = canonicalContent(doc) + '|' + String(clusterAnchorMillis);
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(material));
  return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
}
module.exports = { clusterKey };
```

- [ ] **Step 4: Run to verify pass**

Run: `cd clinvar-cvc && npx vitest run dedup.test.js -t 'same content'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add clinvar-cvc/dedup.js clinvar-cvc/dedup.test.js
git commit -m "feat(cvc): dedup.js clusterKey (content + cluster-anchor SHA-256)"
```

### Task 2.3: `clusterAnnotations` — 15-minute gap sessionization

**Files:**
- Modify: `clinvar-cvc/dedup.js`
- Test: `clinvar-cvc/dedup.test.js`

- [ ] **Step 1: Write the failing tests (boundaries + chaining + content isolation)**

```js
import { clusterAnnotations } from './dedup.js';
const mk = (over) => ({ variation_id: '1', vcv: 'VCV1', scv: 'SCV1', submitter: 'S', submitter_id: '9',
  interp: 'Pathogenic', review_status: 'criteria', action: 'Flagging Candidate', reason: 'r',
  notes: 'n', user_email: 'a@b.org', ...over });
const at = (min) => new Date(Date.UTC(2020,0,1,0,min,0)).toISOString();

test('<=15 min apart collapse to one cluster (earliest anchor)', () => {
  const rows = clusterAnnotations([mk({created_at: at(0)}), mk({created_at: at(15)})]);
  const anchors = new Set(rows.map(r => r.clusterAnchorMillis));
  expect(anchors.size).toBe(1);
  expect([...anchors][0]).toBe(Date.parse(at(0)));
});
test('>15 min apart split into two clusters', () => {
  const rows = clusterAnnotations([mk({created_at: at(0)}), mk({created_at: at(16)})]);
  expect(new Set(rows.map(r => r.clusterAnchorMillis)).size).toBe(2);
});
test('chained <=15 min gaps stay one cluster even if span > 15 min', () => {
  const rows = clusterAnnotations([mk({created_at: at(0)}), mk({created_at: at(15)}), mk({created_at: at(30)})]);
  expect(new Set(rows.map(r => r.clusterAnchorMillis)).size).toBe(1);
});
test('different content never shares a cluster', () => {
  const rows = clusterAnnotations([mk({created_at: at(0)}), mk({scv: 'SCV2', created_at: at(1)})]);
  expect(new Set(rows.map(r => r.clusterAnchorMillis)).size).toBe(2);
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd clinvar-cvc && npx vitest run dedup.test.js -t cluster`
Expected: FAIL — `clusterAnnotations` not defined.

- [ ] **Step 3: Implement `clusterAnnotations`**

```js
const { canonicalContent } = require('./annotation.js');
const WINDOW_MS = 15 * 60 * 1000;

function clusterAnnotations(rows, windowMs = WINDOW_MS) {
  const byContent = new Map();
  for (const r of rows) {
    const k = canonicalContent(r);
    (byContent.get(k) || byContent.set(k, []).get(k)).push(r);
  }
  const out = [];
  for (const group of byContent.values()) {
    group.sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at));
    let anchor = null, prev = null;
    for (const r of group) {
      const t = Date.parse(r.created_at);
      if (prev === null || t - prev > windowMs) anchor = t;   // new cluster
      out.push({ ...r, clusterAnchorMillis: anchor });
      prev = t;
    }
  }
  return out;
}
module.exports = { clusterKey, clusterAnnotations, WINDOW_MS };
```
(Update the existing `module.exports` line rather than adding a second.)

- [ ] **Step 4: Run to verify all dedup tests pass**

Run: `cd clinvar-cvc && npx vitest run dedup.test.js`
Expected: PASS — all cluster + clusterKey tests green.

- [ ] **Step 5: Commit**

```bash
git add clinvar-cvc/dedup.js clinvar-cvc/dedup.test.js
git commit -m "feat(cvc): clusterAnnotations 15-min gap sessionization (earliest anchor)"
```

---

## Chunk 3: Migration correction + gated re-migration + audit log

Repoints the migration at the shared dedup module, produces the dropped/impacted audit log (spec §6.5), then executes the gated clean-slate re-migration of prod-staging v4 (spec §6.3). The re-migration is **irreversible** and touches capture, so it is fenced behind an enumeration + explicit user confirmation (spec §10).

### Task 3.1: Repoint `migrate.js` dedup at `clusterAnnotations`

Currently `loadUniqueDocs` dedups by content-only `annotationDocId` and keeps the first-seen row. Change it to: cluster rows (15-min), keep the **earliest** row per cluster with `created_at` set to the cluster anchor, and use `clusterKey` as the Firestore doc id.

**Files:**
- Modify: `clinvar-cvc/migration/migrate.js`
- Test: `clinvar-cvc/migration/migrate.test.js` (existing)

- [ ] **Step 1: Write the failing test**

Add to `clinvar-cvc/migration/migrate.test.js`:
```js
import { loadUniqueDocsFromRows } from './migrate.js';   // new pure helper (rows in, docs out)

const row = (over) => ({ variation_id:'1', vcv_id:'VCV1', variation_name:'X', scv_id:'SCV1',
  submitter_name:'S', submitter_id:'9', interpretation:'Pathogenic', review_status:'criteria',
  action:'Flagging Candidate', reason:'r', notes:'n', curator_email:'a@b.org', ...over });
const at = (m) => new Date(Date.UTC(2020,0,1,0,m,0)).toISOString();

test('<=15 min twins collapse to ONE doc anchored at earliest; >15 min stay two', async () => {
  const near = await loadUniqueDocsFromRows([row({annotation_date: at(0)}), row({annotation_date: at(10)})]);
  expect(near.length).toBe(1);
  expect(near[0].doc.created_at).toBe(at(0));
  const far = await loadUniqueDocsFromRows([row({annotation_date: at(0)}), row({annotation_date: at(30)})]);
  expect(far.length).toBe(2);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd clinvar-cvc && npx vitest run migration/migrate.test.js -t twins`
Expected: FAIL — `loadUniqueDocsFromRows` not exported.

- [ ] **Step 3: Implement the pure helper + rewire `loadUniqueDocs`**

In `migrate.js`, add a pure helper that takes native rows and returns `{ id, doc }[]`:
```js
const { clusterAnnotations, clusterKey } = require('../dedup.js');
const { nativeRowToV4Doc } = require('./native-to-v4.js');

async function loadUniqueDocsFromRows(rows) {
  // map native -> v4 doc, carry created_at (= annotation_date) for clustering
  const docs = rows.map(nativeRowToV4Doc);
  const clustered = clusterAnnotations(docs);           // adds clusterAnchorMillis
  const byId = new Map();                               // one doc per (content, cluster)
  for (const d of clustered) {
    const anchorIso = new Date(d.clusterAnchorMillis).toISOString();
    const doc = { ...d, created_at: anchorIso };        // survivor anchored at earliest
    delete doc.clusterAnchorMillis;
    const id = await clusterKey(doc, d.clusterAnchorMillis);
    if (!byId.has(id)) byId.set(id, { id, doc });       // earliest wins (sorted asc)
  }
  return [...byId.values()];
}
```
Rewire the existing `loadUniqueDocs(sourcePath)` to `JSON.parse` the file then call `loadUniqueDocsFromRows`. Export `loadUniqueDocsFromRows`.

> **Note on `annotation_date` precision:** `source.sql` formats to whole seconds (`%Y-%m-%dT%H:%M:%SZ`). The anchor ISO therefore has second precision, matching the crosswalk's `UNIX_MILLIS`. Keep `source.sql` as-is.

- [ ] **Step 4: Run to verify pass**

Run: `cd clinvar-cvc && npm test`
Expected: PASS — new twins test green; existing migration tests still pass (adjust any that asserted content-only ids to the new `clusterKey` where they exercised true ≤15-min dupes).

- [ ] **Step 5: Commit**

```bash
git add clinvar-cvc/migration/migrate.js clinvar-cvc/migration/migrate.test.js
git commit -m "feat(migration): 15-min-windowed dedup via shared dedup.js (earliest-anchored survivor)"
```

### Task 3.2: Build the dropped/impacted audit log (SQL)

**Files:**
- Create: `bigquery/curator/audit/dropped-impacted-audit.sql`

- [ ] **Step 1: Write the audit query**

It reproduces the 15-min clustering over legacy native, computes each row's `canonical_annotation_id = UNIX_MILLIS(earliest created_at in cluster)`, flags rows where `annotation_id != canonical_annotation_id` (collapsed/remapped), LEFT JOINs `cvc_clinvar_reviews`/`cvc_clinvar_submissions` (with their `batch_id`) to list impacted downstream records, and orders `flagging candidate` and `remove flagged submission` first. Persist to `clinvar_curator.cvc_dropped_impacted_audit` (a NEW table — allowed name, does not touch legacy objects). Full SQL:

```sql
CREATE OR REPLACE TABLE `clingen-dev.clinvar_curator.cvc_dropped_impacted_audit` AS
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
    CAST(annotation_date AS TIMESTAMP) AS ts,
    CAST(UNIX_MILLIS(CAST(annotation_date AS TIMESTAMP)) AS STRING) AS annotation_id
  FROM `clingen-dev.clinvar_curator.clinvar_annotations_native`
  WHERE `ignore` IS NOT TRUE
),
gapped AS (
  SELECT *, TIMESTAMP_DIFF(ts, LAG(ts) OVER (PARTITION BY content_key ORDER BY ts), MINUTE) AS gap_min
  FROM base
),
clustered AS (
  SELECT *, COUNTIF(gap_min IS NULL OR gap_min > 15)
              OVER (PARTITION BY content_key ORDER BY ts) AS cluster_id
  FROM gapped
),
anchored AS (
  SELECT *, CAST(UNIX_MILLIS(MIN(ts) OVER (PARTITION BY content_key, cluster_id)) AS STRING) AS canonical_annotation_id
  FROM clustered
)
SELECT
  a.annotation_id, a.canonical_annotation_id,
  (a.annotation_id != a.canonical_annotation_id) AS was_remapped,
  a.action, a.scv_id, a.curator_email, a.ts AS annotated_on,
  r.batch_id AS impacted_review_batch_id,
  s.batch_id AS impacted_submission_batch_id
FROM anchored a
LEFT JOIN `clingen-dev.clinvar_curator.cvc_clinvar_reviews`     r ON r.annotation_id = a.annotation_id
LEFT JOIN `clingen-dev.clinvar_curator.cvc_clinvar_submissions` s ON s.annotation_id = a.annotation_id
WHERE a.annotation_id != a.canonical_annotation_id            -- only collapsed/remapped rows
   OR r.annotation_id IS NOT NULL OR s.annotation_id IS NOT NULL
ORDER BY
  CASE a.action WHEN 'flagging candidate' THEN 0 WHEN 'remove flagged submission' THEN 1 ELSE 2 END,
  a.scv_id, a.ts;
```

- [ ] **Step 2: Run it and sanity-check the counts against the spec**

Run:
```bash
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=none < bigquery/curator/audit/dropped-impacted-audit.sql
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty \
'SELECT action, COUNTIF(was_remapped) AS remapped, COUNTIF(impacted_submission_batch_id IS NOT NULL) AS impacted_submissions
 FROM `clingen-dev.clinvar_curator.cvc_dropped_impacted_audit` GROUP BY action ORDER BY action'
```
Expected: `flagging candidate` shows the impacted submissions including the **11 cross-batch** cases; totals reconcile with spec §6.1 (268 remapped ≤15-min collapses across actions). Record the output for the parity report.

- [ ] **Step 3: Commit**

```bash
git add bigquery/curator/audit/dropped-impacted-audit.sql
git commit -m "feat(curator): dropped/impacted dedup audit log (flag/remove first)"
```

### Task 3.3: Enumerate post-seed v4-only captures (pre-wipe gate)

Before wiping v4, list any annotations that exist **only** in v4 (not derivable from legacy native) so they are not silently lost (spec §10 risk). This is a hard gate: do not proceed to 3.4 until the user confirms.

**Files:** none (operational query)

- [ ] **Step 1: Export the current v4 population keyed by content+anchor**

Run:
```bash
bq --project_id="$CVC_PROD" --location=us-central1 query --use_legacy_sql=false --format=csv \
'SELECT variation_id, vcv, scv, submitter, submitter_id, interp, review_status, action, reason, notes, user_email, created_at
 FROM `clingen-cvc.clinvar_cvc_ext.annotations`' > /tmp/v4-current.csv
wc -l /tmp/v4-current.csv
```
Expected: ~30,784 + any post-seed rows.

- [ ] **Step 2: Diff against legacy native content keys**

Compute the content key for both sides and report v4 rows whose content key is absent from legacy native. (Use the same 11-field `TO_JSON_STRING` key as the audit query; a small `bq` query joining a loaded temp table, or a Node script reusing `canonicalContent`.) Produce a count + a sample.

- [ ] **Step 2b: STOP — surface to the user**

Report: "N v4-only annotations found (not in the sheet). The clean-slate reload will drop them. Proceed / restore-first / abort?" Do not continue without an explicit answer. (Spec §10.)

### Task 3.4: Execute the gated clean-slate re-migration

**Files:** none (operational; uses existing `migration/` tooling + the `cvc-provision` skill for IAM)

- [ ] **Step 1: Verify `run.invoker` BEFORE any load (the documented gotcha)**

Follow the `cvc-provision` skill §C check: confirm the compute SA and `ext-firestore-bigquery-export@clingen-cvc.iam` have `roles/run.invoker` on the us-central1 Cloud Run service. If not, grant it and wait. (A bulk load during a broken binding permanently drops events.)

- [ ] **Step 2: Regenerate the migration source extract**

Run:
```bash
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=json --max_rows=100000 \
  "$(cat clinvar-cvc/migration/source.sql)" > /tmp/cvc-history.json
```
Expected: JSON array of ~31k native rows.

- [ ] **Step 3: Dry-run the migration to preview corrected doc count**

Run:
```bash
cd clinvar-cvc && node migration/migrate.js --dry-run < /tmp/cvc-history.json | tail -20; cd -
```
Expected: reports ~31,094 unique docs (the corrected population = legacy rows − 268 ≤15-min collapses), NOT 30,784. If it still says ~30,784, the dedup wiring (Task 3.1) is wrong — stop.

- [ ] **Step 4: Clean-slate wipe (paced)**

Run:
```bash
cd clinvar-cvc && node migration/wipe-collection.js --confirm --delay-ms 2000; cd -
```
Expected: paginated paced delete completes; Firestore aggregate count → 0.

- [ ] **Step 5: Paced reload**

Run:
```bash
cd clinvar-cvc && node migration/migrate.js --delay-ms 3000 < /tmp/cvc-history.json; cd -
```
Expected: ~31,094 create-only writes, 0 errors.

- [ ] **Step 6: Reconcile Firestore vs BigQuery**

Run (Firestore aggregate count via the migration tooling's reconcile path, and the BQ view count):
```bash
bq --project_id="$CVC_PROD" --location=us-central1 query --use_legacy_sql=false --format=pretty \
'SELECT COUNT(*) AS bq_rows FROM `clingen-cvc.clinvar_cvc_ext.annotations`'
```
Expected: `bq_rows` == the reloaded count (~31,094), matching Firestore. If BQ < Firestore, a streaming burst-drop occurred — re-check `run.invoker` and re-run the clean-slate (spec/`cvc-provision` §C).

- [ ] **Step 7: Record the reconciliation in the parity report**

Append the counts (legacy rows, corrected docs, 268 collapsed, 286 restored, Firestore==BQ) to `docs/superpowers/plans/2026-08-03-phase0-parity-report.md`.

- [ ] **Step 8: Commit any tooling/doc changes**

```bash
git add clinvar-cvc/migration docs/superpowers/plans/2026-08-03-phase0-parity-report.md
git commit -m "chore(migration): re-migration executed (15-min dedup) + reconciliation recorded"
```

---

## Chunk 4: The adapter (v4 capture → US native contract table)

Lands the corrected v4 capture into a `US` native table carrying the choke-point contract, plus the cluster-anchor crosswalk (spec §5, §6.4).

> **Copy-mechanism decision (spec §5.1 left this to the plan):** use a **full snapshot of the flattened `annotations` view per run**, at **on-demand + daily** cadence — not a 15-min cadence. Rationale: the flattened data is <60 MB / ~31k rows, so a full cross-region copy is pennies at low cadence and satisfies the spec's cost intent (which targeted the 15-min-cadence cost), while keeping the flatten logic in the **single** existing `annotations` view (no re-implementation, no watermark-correctness risk). If cadence ever rises, switch to an incremental changelog mirror; the reshape output is identical.

### Task 4.1: Cross-region snapshot + load script

**Files:**
- Create: `bigquery/curator/adapter/refresh-native-v4.sh`

- [ ] **Step 1: Write `refresh-native-v4.sh`**

```bash
#!/usr/bin/env bash
# Snapshot flattened v4 capture (us-central1) -> US raw table in clinvar_curator, then reshape.
set -euo pipefail
: "${CVC_PROD:=clingen-cvc}"; : "${CURATOR_PROJECT:=clingen-dev}"; : "${GCS_BUCKET:?set GCS_BUCKET}"
SNAP="${CVC_PROD}:clinvar_cvc_ext._native_v4_snapshot"
RAW="${CURATOR_PROJECT}:clinvar_curator._annotations_v4_raw"
# 1) materialize the flattened view to a real us-central1 table (bq extract can't read a view)
bq --project_id="$CVC_PROD" --location=us-central1 query --use_legacy_sql=false \
   --destination_table="$SNAP" --replace \
  'SELECT * FROM `clingen-cvc.clinvar_cvc_ext.annotations`'
# 2) extract to GCS (us-central1)
bq --project_id="$CVC_PROD" --location=us-central1 extract --destination_format=NEWLINE_DELIMITED_JSON \
   "$SNAP" "${GCS_BUCKET}/native_v4/*.json"
# 3) load into US raw table (truncate — full snapshot)
bq --project_id="$CURATOR_PROJECT" --location=US load --replace --source_format=NEWLINE_DELIMITED_JSON \
   --autodetect "$RAW" "${GCS_BUCKET}/native_v4/*.json"
# 4) reshape raw -> contract native table
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=none \
   < bigquery/curator/adapter/native_v4_reshape.sql
echo "native_v4 refreshed."
```

- [ ] **Step 2: `chmod +x` (do not run yet — needs 4.2's reshape SQL)**

Run: `chmod +x bigquery/curator/adapter/refresh-native-v4.sh`

- [ ] **Step 3: Commit**

```bash
git add bigquery/curator/adapter/refresh-native-v4.sh
git commit -m "feat(adapter): cross-region snapshot+load script for native_v4"
```

### Task 4.2: Reshape raw → contract native table

**Files:**
- Create: `bigquery/curator/adapter/native_v4_reshape.sql`

- [ ] **Step 1: Write the reshape SQL**

Maps the flattened v4 columns → the §3.2 contract (renames + passthroughs), sets `ignore = FALSE`, and computes `annotation_id`. The flattened `annotations` view already exposes `variation_id, vcv, name, scv, submitter, submitter_id, interp, review_status, action, reason, notes, user_email, created_at, created_at_millis`.

```sql
CREATE OR REPLACE TABLE `clingen-dev.clinvar_curator.cvc_annotations_native_v4` AS
SELECT
  CAST(created_at AS TIMESTAMP) AS annotation_date,
  vcv           AS vcv_id,
  scv           AS scv_id,
  variation_id  AS variation_id,
  submitter_id  AS submitter_id,
  action        AS action,           -- base_mv lowercases
  user_email    AS curator_email,
  interp        AS interpretation,   -- required by base_mv's scv_clinsig_map join
  reason        AS reason,
  notes         AS notes,
  review_status AS review_status,
  FALSE         AS `ignore`
FROM `clingen-dev.clinvar_curator._annotations_v4_raw`;
```

- [ ] **Step 2: Run the full adapter and verify the contract**

Run:
```bash
./bigquery/curator/adapter/refresh-native-v4.sh
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty \
'SELECT COUNT(*) rows,
        COUNT(DISTINCT CAST(UNIX_MILLIS(annotation_date) AS STRING)) distinct_ids
 FROM `clingen-dev.clinvar_curator.cvc_annotations_native_v4`'
```
Expected: `rows` ≈ corrected population (~31,094); `distinct_ids` equals `rows` (cluster anchors are distinct). Column names match `clinvar_annotations_native`.

- [ ] **Step 3: Verify schema parity with the legacy source**

Run:
```bash
diff <(bq show --schema --format=prettyjson "$CURATOR_PROJECT:clinvar_curator.clinvar_annotations_native" | jq -S 'map({name,type})') \
     <(bq show --schema --format=prettyjson "$CURATOR_PROJECT:clinvar_curator.cvc_annotations_native_v4" | jq -S 'map({name,type})') \
  && echo "SCHEMA MATCH" || echo "REVIEW DIFF (extra legacy columns like override_* are OK)"
```
Expected: the 12 contract columns match on name+type (legacy may carry extra unused columns — that's fine; base_mv only reads the contract subset).

- [ ] **Step 4: Commit**

```bash
git add bigquery/curator/adapter/native_v4_reshape.sql
git commit -m "feat(adapter): native_v4 reshape to choke-point contract"
```

### Task 4.3: Build the cluster-anchor crosswalk

**Files:**
- Create: `bigquery/curator/adapter/cvc_annotation_id_xwalk.sql`

- [ ] **Step 1: Write the crosswalk SQL**

Same 15-min clustering as the audit query; canonical = `UNIX_MILLIS(earliest created_at of the cluster)`:
```sql
CREATE OR REPLACE TABLE `clingen-dev.clinvar_curator.cvc_annotation_id_xwalk` AS
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
    CAST(annotation_date AS TIMESTAMP) AS ts,
    CAST(UNIX_MILLIS(CAST(annotation_date AS TIMESTAMP)) AS STRING) AS legacy_annotation_id
  FROM `clingen-dev.clinvar_curator.clinvar_annotations_native`
  WHERE `ignore` IS NOT TRUE
),
gapped AS (
  SELECT *, TIMESTAMP_DIFF(ts, LAG(ts) OVER (PARTITION BY content_key ORDER BY ts), MINUTE) AS gap_min FROM base
),
clustered AS (
  SELECT *, COUNTIF(gap_min IS NULL OR gap_min > 15) OVER (PARTITION BY content_key ORDER BY ts) AS cluster_id FROM gapped
)
SELECT DISTINCT
  legacy_annotation_id,
  CAST(UNIX_MILLIS(MIN(ts) OVER (PARTITION BY content_key, cluster_id)) AS STRING) AS canonical_annotation_id
FROM clustered;
```

- [ ] **Step 2: Run it and assert crosswalk ↔ native_v4 consistency**

Run:
```bash
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=none < bigquery/curator/adapter/cvc_annotation_id_xwalk.sql
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty \
'SELECT
   COUNT(*) AS legacy_ids,
   COUNTIF(legacy_annotation_id != canonical_annotation_id) AS remapped,
   (SELECT COUNT(*) FROM `clingen-dev.clinvar_curator.cvc_annotation_id_xwalk` x
     WHERE NOT EXISTS (SELECT 1 FROM `clingen-dev.clinvar_curator.cvc_annotations_native_v4` n
       WHERE CAST(UNIX_MILLIS(n.annotation_date) AS STRING) = x.canonical_annotation_id)) AS canonical_without_v4_row
 FROM `clingen-dev.clinvar_curator.cvc_annotation_id_xwalk`'
```
Expected: `remapped` ≈ 268 (the ≤15-min collapses); `canonical_without_v4_row` = **0** (every canonical id exists in `native_v4` — proves crosswalk and re-migration agree).

- [ ] **Step 3: Commit**

```bash
git add bigquery/curator/adapter/cvc_annotation_id_xwalk.sql
git commit -m "feat(adapter): cluster-anchor annotation-id crosswalk"
```

---

## Chunk 5: The shadow `clinvar_curator_v4` lineage

Deploys the full curator object graph into a new `clinvar_curator_v4` dataset over `native_v4`, with staging reconciled through the `_x` crosswalk views (spec §7.1). Legacy `clinvar_curator` is never touched.

**Key structural move:** in `clinvar_curator_v4`, the objects named `cvc_clinvar_reviews/submissions/batches` and `cvc_rejected_scvs` are **views** (crosswalk-applied / shared) rather than tables, so the templated `@@DATASET@@` substitution makes `base_mv` read them automatically. This requires separating the legacy `CREATE TABLE` staging DDL out of the deployed core.

### Task 5.1: Separate staging-table DDL from the deployed core

**Files:**
- Modify: `bigquery/curator/00-initialize-cvc-tables.sql`
- Create: `bigquery/curator/staging-tables.sql` (NOT matched by `deploy.sh`'s `0*-*.sql` glob)

- [ ] **Step 1: Move the three `CREATE TABLE` blocks**

Cut the `CREATE TABLE @@DATASET@@.cvc_clinvar_reviews`, `...cvc_clinvar_submissions`, `...cvc_clinvar_batches` statements from `00-initialize-cvc-tables.sql` into a new `bigquery/curator/staging-tables.sql`. What remains in `00-initialize-cvc-tables.sql` is the view/MV layer (base_mv, cvc_annotations_view, cvc_batch_scv_max_annotation_view, cvc_submitted_annotations_view, cvc_submitted_outcomes_view).

- [ ] **Step 2: Add a header note to `staging-tables.sql`**

At the top: `-- Legacy-only bootstrap: the real staging tables live in clinvar_curator (created once). The v4 shadow uses crosswalk VIEWS of the same names (see staging_x_views.sql), so this file is NOT deployed to clinvar_curator_v4.`

- [ ] **Step 3: Dry-run-validate the trimmed 00 file (legacy binding)**

Run:
```bash
sed -e 's/@@DATASET@@/clinvar_curator/g' -e 's#@@ANNO_SOURCE@@#clinvar_curator.clinvar_annotations_native#g' \
  bigquery/curator/00-initialize-cvc-tables.sql \
  | bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --dry_run --format=none && echo "DRY-RUN OK"
```
Expected: `DRY-RUN OK`.

- [ ] **Step 4: Commit**

```bash
git add bigquery/curator/00-initialize-cvc-tables.sql bigquery/curator/staging-tables.sql
git commit -m "refactor(curator): split legacy staging-table DDL out of the deployed core"
```

### Task 5.2: Write the `_x` staging + shared-reference views

**Files:**
- Create: `bigquery/curator/adapter/staging_x_views.sql`

- [ ] **Step 1: Write the views (created in `clinvar_curator_v4`, named as the tables)**

Each staging view passes rows through unchanged **except** `annotation_id` is remapped via the crosswalk, then `SELECT DISTINCT` (spec §6.4 collapse-cardinality rule). `cvc_rejected_scvs` is a plain shared view.

```sql
-- reviews: remap annotation_id -> canonical, dedup
CREATE OR REPLACE VIEW `clingen-dev.clinvar_curator_v4.cvc_clinvar_reviews` AS
SELECT DISTINCT COALESCE(x.canonical_annotation_id, r.annotation_id) AS annotation_id,
  r.date_added, r.status, r.reviewer, r.notes, r.date_last_updated, r.batch_id
FROM `clingen-dev.clinvar_curator.cvc_clinvar_reviews` r
LEFT JOIN `clingen-dev.clinvar_curator.cvc_annotation_id_xwalk` x ON x.legacy_annotation_id = r.annotation_id;
-- submissions: remap, dedup (batch_id differences legitimately stay distinct)
CREATE OR REPLACE VIEW `clingen-dev.clinvar_curator_v4.cvc_clinvar_submissions` AS
SELECT DISTINCT COALESCE(x.canonical_annotation_id, s.annotation_id) AS annotation_id,
  s.scv_id, s.scv_ver, s.batch_id
FROM `clingen-dev.clinvar_curator.cvc_clinvar_submissions` s
LEFT JOIN `clingen-dev.clinvar_curator.cvc_annotation_id_xwalk` x ON x.legacy_annotation_id = s.annotation_id;
-- batches + rejected_scvs: shared, no annotation_id -> plain passthrough views
CREATE OR REPLACE VIEW `clingen-dev.clinvar_curator_v4.cvc_clinvar_batches` AS
SELECT * FROM `clingen-dev.clinvar_curator.cvc_clinvar_batches`;
CREATE OR REPLACE VIEW `clingen-dev.clinvar_curator_v4.cvc_rejected_scvs` AS
SELECT * FROM `clingen-dev.clinvar_curator.cvc_rejected_scvs`;
```

- [ ] **Step 2: Commit (deployed in Task 5.3)**

```bash
git add bigquery/curator/adapter/staging_x_views.sql
git commit -m "feat(shadow): crosswalk _x staging views + shared-ref views for clinvar_curator_v4"
```

### Task 5.3: Deploy the shadow lineage and run the impact SP

**Files:** none (uses `deploy.sh`)

- [ ] **Step 1: Create the dataset (US) and deploy the `_x` + shared views first**

Run:
```bash
bq --project_id="$CURATOR_PROJECT" mk --location=US --dataset "$CURATOR_PROJECT:clinvar_curator_v4" || echo "exists"
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=none < bigquery/curator/adapter/staging_x_views.sql
```
Expected: dataset created; four views created (they depend on the crosswalk from Task 4.3, which exists).

- [ ] **Step 2: Deploy the core + impact SP into the shadow dataset**

Run:
```bash
DATASET=clinvar_curator_v4 ANNO_SOURCE=clinvar_curator.cvc_annotations_native_v4 ./bigquery/curator/deploy.sh
```
Expected: `>>` for each numbered file; `deploy complete`. base_mv_v4 now reads `native_v4` and the `_x` staging views; funcs/TVFs/SP created in `clinvar_curator_v4`.

- [ ] **Step 3: Run the shadow impact SP**

Run:
```bash
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=none \
  'CALL `clingen-dev.clinvar_curator_v4.refresh_cvc_impact_analysis`()'
```
Expected: completes; the 11 `clinvar_curator_v4.cvc_*` tables are populated.

- [ ] **Step 4: Smoke-check the shadow choke point returns rows**

Run:
```bash
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty \
'SELECT COUNT(*) rows FROM `clingen-dev.clinvar_curator_v4.cvc_annotations`("all")'
```
Expected: ~31,094 rows (the corrected population); no error.

- [ ] **Step 5: Commit any deploy-script tweaks discovered here**

```bash
git add bigquery/curator
git commit -m "chore(shadow): deploy clinvar_curator_v4 lineage (notes/fixes from first deploy)" || echo "nothing to commit"
```

---

## Chunk 6: Parity verification + go/no-go report

Proves the v4 lineage matches legacy on the shared seed (spec §7.2), with every diff query returning 0 rows on success. Runs the crosswalk-collapsed comparison on both sides.

### Task 6.1: Parity anchors (pure-upstream tables must be identical)

**Files:**
- Create: `bigquery/curator/tests/01-anchor-version-bumps.sql`

- [ ] **Step 1: Write the anchor diff**

`cvc_version_bumps` / `cvc_full_record_version_bumps` are pure-`clinvar_ingest`-derived (spec §3.6), so they must be byte-identical across datasets. (Legacy versions exist only after the legacy SP has run; assume the legacy `clinvar_curator.cvc_version_bumps` is current.)
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

- [ ] **Step 2: Run and expect 0 rows**

Run: `bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty < bigquery/curator/tests/01-anchor-version-bumps.sql`
Expected: 0 rows. Non-zero ⇒ an environment/config difference, not the adapter — investigate before continuing.

- [ ] **Step 3: Commit**

```bash
git add bigquery/curator/tests/01-anchor-version-bumps.sql
git commit -m "test(parity): pure-upstream version-bump anchors identical across lineages"
```

### Task 6.2: Id-integrity — 0 orphans, canonical resolves

**Files:**
- Create: `bigquery/curator/tests/02-id-integrity.sql`

- [ ] **Step 1: Write the diff**

```sql
-- returns 0 rows on success: every staging annotation_id resolves to a native_v4 row via the crosswalk
WITH staged AS (
  SELECT annotation_id FROM `clingen-dev.clinvar_curator.cvc_clinvar_reviews` WHERE annotation_id IS NOT NULL
  UNION DISTINCT
  SELECT annotation_id FROM `clingen-dev.clinvar_curator.cvc_clinvar_submissions` WHERE annotation_id IS NOT NULL
)
SELECT s.annotation_id AS orphan_staging_id
FROM staged s
LEFT JOIN `clingen-dev.clinvar_curator.cvc_annotation_id_xwalk` x ON x.legacy_annotation_id = s.annotation_id
LEFT JOIN `clingen-dev.clinvar_curator.cvc_annotations_native_v4` n
       ON CAST(UNIX_MILLIS(n.annotation_date) AS STRING) = COALESCE(x.canonical_annotation_id, s.annotation_id)
WHERE n.annotation_date IS NULL;
```

- [ ] **Step 2: Run and expect 0 rows**

Run: `bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty < bigquery/curator/tests/02-id-integrity.sql`
Expected: 0 rows. Non-zero ⇒ a staging id references an annotation missing from v4 (a re-migration/crosswalk gap) — list them for the report.

- [ ] **Step 3: Commit**

```bash
git add bigquery/curator/tests/02-id-integrity.sql
git commit -m "test(parity): staging id-integrity (0 orphans after crosswalk)"
```

### Task 6.3: Choke-point canonical-keyed column diff (must be 0)

**Files:**
- Create: `bigquery/curator/tests/03-chokepoint-diff.sql`

- [ ] **Step 1: Write the diff**

Compare `cvc_annotations("all")` legacy vs v4 on the shared seed, keyed by `canonical_annotation_id` (apply the crosswalk to the legacy side so its 268 ≤15-min twins collapse to the anchor, exactly as v4). Restrict to the shared seed (exclude post-seed drift by `annotation_release_date`/content intersection). Compare the stable business columns (`variation_id, vcv_id, scv_id, action, reason, notes, curator, review_status`).

```sql
-- returns 0 rows on success
WITH leg AS (
  SELECT COALESCE(x.canonical_annotation_id, a.annotation_id) AS cid,
         a.variation_id, a.vcv_id, a.scv_id, a.action, a.reason, a.notes, a.curator, a.clinvar_review_status
  FROM `clingen-dev.clinvar_curator.cvc_annotations`("all") a
  LEFT JOIN `clingen-dev.clinvar_curator.cvc_annotation_id_xwalk` x ON x.legacy_annotation_id = a.annotation_id
),
leg1 AS (SELECT DISTINCT * FROM leg),
v4 AS (
  SELECT annotation_id AS cid, variation_id, vcv_id, scv_id, action, reason, notes, curator, clinvar_review_status
  FROM `clingen-dev.clinvar_curator_v4.cvc_annotations`("all")
)
SELECT 'legacy_only' AS side, * FROM (SELECT * FROM leg1 EXCEPT DISTINCT SELECT * FROM v4)
UNION ALL
SELECT 'v4_only' AS side, * FROM (SELECT * FROM v4 EXCEPT DISTINCT SELECT * FROM leg1
  -- restrict to shared seed: exclude post-seed v4-only content (drift, spec §7.2.7)
  WHERE cid IN (SELECT canonical_annotation_id FROM `clingen-dev.clinvar_curator.cvc_annotation_id_xwalk`));
```

- [ ] **Step 2: Run and expect 0 rows (drift enumerated separately)**

Run: `bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty < bigquery/curator/tests/03-chokepoint-diff.sql`
Expected: 0 rows on the shared seed. Any `legacy_only`/`v4_only` row that is NOT explained by §7.2 drift is an adapter bug — record and fix. (Raw row-count difference of ~268 is expected and lives in the audit, not here.)

- [ ] **Step 3: Commit**

```bash
git add bigquery/curator/tests/03-chokepoint-diff.sql
git commit -m "test(parity): choke-point canonical-keyed column diff = 0 on shared seed"
```

### Task 6.4: End-to-end batch parity (11 impact tables + submission file)

**Files:**
- Create: `bigquery/curator/tests/04-batch-endtoend.sql`
- Create: `bigquery/curator/tests/run-parity.sh`

- [ ] **Step 1: Pick a pre-seed finalized batch**

Run:
```bash
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=pretty \
'SELECT batch_id, finalized_datetime FROM `clingen-dev.clinvar_curator.cvc_clinvar_batches`
 ORDER BY finalized_datetime DESC LIMIT 10'
```
Choose a `batch_id` finalized well before the `clingen-cvc` seed boundary (stable membership). Record it as `$BATCH`.

- [ ] **Step 2: Write the batch diff (impact tables + submission file)**

For the chosen batch, diff the key impact tables (#8 `cvc_flagging_version_bump_intersection`, #9 `cvc_resubmission_candidates`, #11 `cvc_impact_summary`) legacy vs v4 with `EXCEPT DISTINCT` both ways (crosswalk-collapsed keys), and diff the generated submission set (`cvc_annotations("unreviewed")` JOIN submissions, `action != 'no change'`). Each sub-query returns 0 rows on success. (Parameterize `@batch` via `--parameter=batch:STRING:$BATCH`.)

- [ ] **Step 3: Write `run-parity.sh` to run all diff queries**

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${CURATOR_PROJECT:=clingen-dev}"; : "${BATCH:?set BATCH}"
fail=0
for q in bigquery/curator/tests/0*.sql; do
  echo "== $q =="
  n=$(bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=csv \
        --parameter=batch:STRING:"$BATCH" "$(cat "$q")" | tail -n +2 | wc -l | tr -d ' ')
  if [ "$n" = "0" ]; then echo "PASS ($q)"; else echo "FAIL: $n diff rows ($q)"; fail=1; fi
done
exit $fail
```

- [ ] **Step 4: Run the full suite**

Run: `chmod +x bigquery/curator/tests/run-parity.sh && BATCH=$BATCH ./bigquery/curator/tests/run-parity.sh`
Expected: `PASS` for every query. Any `FAIL` ⇒ investigate (adapter bug vs documented drift/collapse) before declaring parity.

- [ ] **Step 5: Commit**

```bash
git add bigquery/curator/tests/04-batch-endtoend.sql bigquery/curator/tests/run-parity.sh
git commit -m "test(parity): end-to-end batch diff (impact tables + submission file) + runner"
```

### Task 6.5: Write the go/no-go parity report

**Files:**
- Modify: `docs/superpowers/plans/2026-08-03-phase0-parity-report.md`

- [ ] **Step 1: Fill the report**

Sections (spec §7.3): re-migration reconciliation (Chunk 3), anchor result, id-integrity (0 orphans), choke-point diff (0 on shared seed), the **268 collapse** and **286 restored** accounting, drift enumeration (sheet-only / v4-only counts), batch end-to-end result, and a reference to the §6.5 audit log (with the 11 cross-batch flag submissions). End with an explicit **GO / NO-GO for Phase 1** recommendation.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-08-03-phase0-parity-report.md
git commit -m "docs(parity): Phase-0 go/no-go parity report"
```

---

## Done criteria

- `bigquery/curator/` is the single CvC SQL home; ingest-repo copies deleted; `deploy.sh` deploys legacy or `_v4` from one templated tree.
- Shared `dedup.js` (15-min) unit-tested; migration re-run; prod-staging v4 corrected (~31,094; 286 restored, 268 collapsed); Firestore == BQ.
- `cvc_annotations_native_v4`, `cvc_annotation_id_xwalk`, `_x` views, and the full `clinvar_curator_v4` lineage (incl. 11-table SP) build and run.
- Parity suite is green (0-row diffs) on the shared seed; drift + collapse enumerated; audit log produced; **go/no-go report written**.
