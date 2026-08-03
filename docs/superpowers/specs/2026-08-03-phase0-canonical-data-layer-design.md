# Phase 0 — Canonical CvC Data Layer (v4-sourced, shadow + parity)

> **Type:** design spec (approved by the user 2026-08-03). Next step: superpowers:writing-plans.
> **Parent:** `docs/superpowers/plans/2026-08-03-curation-ops-platform-discovery.md` (§4 Phase 0).
> **Supersedes discovery gaps:** the impact-SP mapping and the adapter/consolidation approach.

## 0. Purpose & context

The ClinGen CvC downstream (review → submit → reflag → impact reporting) is an
88-object BigQuery graph in `clingen-dev:clinvar_curator` plus ~1,300 lines of Apps
Script, all currently reading curation annotations derived from the **legacy Google
Sheet** capture. Capture itself has already moved to the **v4 Firestore→BigQuery**
pipeline (`clingen-cvc:clinvar_cvc_ext.annotations`). Phase 0 builds the **durable,
UI-agnostic data layer** that lets the whole downstream read v4 capture — proven by a
side-by-side parity check — **without** disturbing the still-running legacy Review&Submit
sheet pipeline. No web app is built in Phase 0.

The entire downstream funnels through a **single choke point**: `cvc_annotations_base_mv`
(a materialized view) is the only object that reads the capture source
(`clinvar_annotations_native`); everything else cascades from it via
`cvc_annotations_view` → `cvc_baseline_annotations()` → `cvc_annotations()` → the impact
stored procedure. Repointing that one choke point at v4 repoints all 88 objects.

## 1. Decisions (locked with the user, 2026-08-03)

1. **`clinvar_curator` stays single** (one dataset in `clingen-dev`, `US`), matching its
   upstream `clinvar_ingest`. No dev/prod split in Phase 0.
2. **v4 source = prod-staging `clingen-cvc.clinvar_cvc_ext.annotations`** (the full ~30,784
   historical seed). `clingen-cvc-dev` is *not* used (it carries extra dev-test annotations).
3. **Shadow, don't flip.** Build a parallel v4-sourced lineage beside the legacy one and
   diff them; the live choke point is untouched. Flipping is a Phase-1 decision.
4. **Consolidate in one change.** Move `clinvar-ingest-bq-tools/scripts/clinvar-curation/`
   into this repo and delete the ingest-repo copies in the same coordinated change.
5. **Adapter refresh = incremental + on-demand**, never a fixed 15-min full copy.
6. **`annotation_id` stays `UNIX_MILLIS(annotation_date)`** for Phase 0 (content-hash ids
   are a Phase-2 concern) so the v4 lineage joins the existing legacy staging tables.
7. **Duplicate-id reconciliation is non-destructive** (crosswalk views, no staging mutation).

## 2. Scope & non-goals

**In scope**
- Repo consolidation (move + delete + parameterized deploy mechanism).
- The **adapter**: incremental cross-region landing of v4 capture into a `US` native
  table with the choke-point column contract, the `UNIX_MILLIS`→`annotation_id`
  conversion, and the duplicate-id crosswalk.
- The **`clinvar_curator_v4` shadow lineage** (choke point + `refresh_cvc_impact_analysis_v4()`
  producing the 11 impact tables), sourced from v4, legacy left untouched.
- **Parity verification** (shared-seed exact diff + drift reconciliation + sample-batch
  end-to-end), producing a go/no-go parity report.
- The impact-SP dependency map, captured in repo docs.

**Non-goals (explicitly deferred)**
- Flipping the live choke point to v4 — **Phase 1**.
- Any Apps Script change (`Generate.js`/`Reflag.js`/`Code.js`) — **Phase 1/2**.
- The Firestore∪sheet **UNION bridge** for full-population authority — **Phase 1**.
- Destructive rewrite of staging-table `annotation_id`s to canonical — **Phase 1 cutover**.
- The web app and the reflag **write** path — **Phase 2**.
- Any `clinvar_ingest` change (stable one-way upstream; refactor is external and future).
- `manuscript-figures/discordance_retraction.sql` (reads the bare `clinvar_annotations`
  external sheet directly; it is figure-generation, not the ops pipeline — out of scope).

## 3. Current-state facts this design depends on

### 3.1 The choke point (verified singular for the ops pipeline)
- `cvc_annotations_base_mv` (MATERIALIZED VIEW) is the **only** object reading
  `clinvar_curator.clinvar_annotations_native`. It joins that source to
  `clinvar_ingest.all_releases_materialized`, `clinvar_ingest.scv_clinsig_map`,
  `clinvar_ingest.status_definitions`.
- Cascade: `cvc_annotations_base_mv` → `cvc_annotations_view` (adds `is_latest`) →
  `cvc_baseline_annotations(scope)` TVF → `cvc_annotations(scope)` TVF → impact SP +
  `cvc_submitted_*` views + outcomes/stats.

### 3.2 The column contract `cvc_annotations_base_mv` requires from its source
`annotation_date` (TIMESTAMP), `vcv_id`, `scv_id`, `variation_id`, `submitter_id`,
`action`, `curator_email`, `interpretation`, `reason`, `notes`, `review_status`,
`ignore` (BOOL).
- `base_mv` lowercases `action` itself and uses `LOWER(interpretation)` to join
  `scv_clinsig_map` — so **`interpretation` is required** (it was omitted from the
  discovery doc's contract list; corrected here).
- v4 → contract mapping: `created_at→annotation_date`, `vcv→vcv_id`, `scv→scv_id`,
  `user_email→curator_email`, `interp→interpretation`, `action` passed through
  capitalized (base_mv lowercases), `ignore` → literal `FALSE`.

### 3.3 The primary key
`annotation_id = CAST(UNIX_MILLIS(annotation_date) AS STRING)`, threaded through
`cvc_clinvar_reviews`, `cvc_clinvar_submissions`, `cvc_clinvar_batches` (each stores
`annotation_id`). The v4 lineage must reproduce the identical formula so those existing
(legacy-populated) staging tables still join.

### 3.4 Dataset locations (the reason the adapter must copy, not federate)
- `clingen-dev:clinvar_curator` = **US**; `clingen-dev:clinvar_ingest` = **US**;
  `clingen-cvc:clinvar_cvc_ext` = **us-central1**.
- BigQuery cannot join tables across locations in one query, and `base_mv` must join the
  annotations source to `clinvar_ingest` (US). Therefore v4 data must be physically landed
  in a **US** dataset in `clingen-dev` before any join is legal. Permission grants do not
  remove this; it is a hard location constraint. Additionally, materialized views cannot
  reference cross-project bases nor read over a view/external, and
  `clinvar_cvc_ext.annotations` is a VIEW — so a native landing table is required regardless.

### 3.5 v4 capture object shapes
`clinvar_cvc_ext.annotations` is a VIEW over `annotations_raw_latest` (a view) over
`annotations_raw_changelog` (a real, append-only TABLE with `timestamp`/`event_id`).
Changelog today ≈ 59 MB / 84k rows (inflated ~2–3 change events per doc from the one-time
30,784 load); steady-state velocity is only ongoing curator activity.

### 3.6 Impact SP dependency map — `refresh_cvc_impact_analysis()` builds 11 tables
Build order and inputs (all annotation-derived tables trace to the choke point via
`cvc_annotations_view`/`cvc_submitted_outcomes_view`):

| # | Table | Inputs | Notes |
|---|-------|--------|-------|
| 1 | `cvc_submitted_variants` | `cvc_submitted_outcomes_view` | root of submitted-variant chain |
| 2 | `cvc_flagging_candidate_outcomes` | `cvc_annotations_view`, `cvc_batches_enriched`, `cvc_rejected_scvs`, `clinvar_scvs/releases/schema_on` | choke-point-derived |
| 3 | `cvc_remove_flagged_outcomes` | same input set as #2 | choke-point-derived |
| 4 | `cvc_version_bumps` | **`clinvar_ingest.clinvar_scvs` only** | pure-upstream; annotation-independent → **parity anchor** |
| 5 | `cvc_full_record_version_bumps` | **`clinvar_ingest.clinvar_scvs` only** | pure-upstream; **parity anchor** |
| 6 | `cvc_variant_conflict_history` | #1, `monthly_conflict_snapshots` | |
| 7 | `cvc_resolution_attribution` | #1, `conflict_vcv_change_detail`, `monthly_conflict_scv_changes` | |
| 8 | `cvc_flagging_version_bump_intersection` | **#2 ∩ #4** | **reflag / "submitter overwrote our flag" detection** |
| 9 | `cvc_resubmission_candidates` | #2, #3, #4, `cvc_annotations_view`, `clinvar_vcvs/submitters` | |
| 10 | `cvc_autoreflag_candidates` | #2, #3, `clinvar_scvs/submitters` | |
| 11 | `cvc_impact_summary` | #1, #7, `monthly_conflict_snapshots`, `conflict_vcv_change_detail` | top-level rollup |

Non-SP inputs the SP consumes: `cvc_batches_enriched` (from `00-cvc-batch-enriched-view.sql`)
and `cvc_rejected_scvs` (loaded from `rejected-scvs.tsv` via `load-rejected-scvs.sh`).

### 3.7 Source drift (affects only the parity method, not the design)
- `clingen-cvc` is a **recent** copy of the Google Sheet seed; the sheet is **still live**
  (`scvc/` capture), so post-seed **sheet-only** rows can exist (legacy has them, v4 does not).
- v4 gets post-seed **v4-only** captures (extension writes) the sheet may not have.
- `clingen-cvc-dev` has extra dev-test annotations — excluded by sourcing from `clingen-cvc`.
- Consequence: legacy and v4 are two diverging live populations; parity is evaluated on the
  **shared seed**, with drift **enumerated and explained** outside it (see §7).

## 4. Repo consolidation

- **Move** `clinvar-ingest-bq-tools/scripts/clinvar-curation/` → this repo at
  **`bigquery/curator/`**, preserving the numbered-SQL apply order and the
  `cvc-impact-analysis/00-run-cvc-impact-analysis.sh` runner. Keep dataset references to
  `clinvar_curator`/`clinvar_ingest` as-is.
- **Delete the ingest-repo copies in the same change** (removes the duplicated
  `appscript-refresh-impact.js` drift). Coordinate with `clinvar-ingest-bq-tools`.
- **Deploy-mechanism upgrade (the one targeted improvement):** parameterize the DDL by two
  binding tokens — a **target dataset** (`clinvar_curator` vs `clinvar_curator_v4`) and a
  **source binding** (annotations source + staging source). The same templated SQL then
  deploys both the legacy lineage (over the sheet external) and the v4 shadow (over
  `native_v4` + crosswalk views). This makes the Phase-1 flip a one-line binding change.

## 5. The adapter (v4 capture → US native contract table)

### 5.1 Incremental cross-region landing
An **incremental, watermarked** job copies only new `annotations_raw_changelog` rows
(`timestamp`/`event_id` beyond the last watermark) from `clingen-cvc:us-central1` into a
`US` staging table in `clingen-dev`. **Trigger model:** on-demand (reviewer "Refresh" /
batch run) plus a low-frequency backstop (e.g. hourly or daily). **No fixed 15-min full
copy.** Copy volume ≈ new annotations (not table size), so cost stays ≈ cents/month, flat
over time. Capture is never modified.
- **Mechanism choice is left to the plan** (BigQuery Data Transfer Service scheduled
  table-copy vs a Cloud Function/Cloud Run EXPORT→LOAD). Both satisfy incremental +
  on-demand. The choice must preserve the append-only watermark semantics.

### 5.2 Reshape → `clinvar_curator.cvc_annotations_native_v4`
A `US` query flattens the copied changelog to latest-per-document, applies the §3.2
contract mapping, sets `ignore = FALSE`, and computes
`annotation_id = CAST(UNIX_MILLIS(annotation_date) AS STRING)`. Output is a **native
table** so the shadow materialized view can sit over it. This is the single place the
`UNIX_MILLIS` conversion happens.

### 5.3 Interface (what consumers can rely on)
`cvc_annotations_native_v4` is a drop-in for `clinvar_annotations_native`: identical column
names, types, and `annotation_id` semantics. A consumer needs to know only that it carries
the §3.2 contract for the shared-seed population plus any post-seed v4 captures; it does not
need to know how the copy or reshape work.

## 6. Duplicate-id reconciliation (the 554)

**Problem.** The migration dropped 554 content-duplicate annotations (31,338 legacy native →
30,784 v4). Legacy staging tables (`cvc_clinvar_submissions`/`reviews`/`batches`) may
reference a **dropped twin's** `annotation_id`, which has no row in the v4 lineage (the
surviving twin has a different `created_at` → different `annotation_id`).

**Solution — non-destructive crosswalk.**
- Build `cvc_annotation_id_xwalk(legacy_annotation_id STRING, canonical_annotation_id STRING)`:
  group legacy `clinvar_annotations_native` by the v4 dedup fields (the `annotationDocId`
  content fields); for each group the `canonical_annotation_id` = `UNIX_MILLIS` of the
  surviving v4 row (join native→v4 by content). Dropped-twin ids map to the surviving id;
  singletons map to themselves.
- Apply it as thin **crosswalk views** over the shared staging tables (e.g.
  `cvc_clinvar_submissions_x` selecting the staging rows with `annotation_id` replaced by
  `canonical_annotation_id`). The shadow lineage binds its "staging source" to these `_x`
  views. **No staging table is mutated**, and the shadow DDL stays identical to legacy
  (only the source binding differs). Correct because twins are content-identical, so a
  review/submission of any twin is semantically the same annotation.

## 7. The shadow lineage & parity

### 7.1 Shadow lineage
Deploy the full templated curator object graph into a new **`clinvar_curator_v4`** dataset
(`clingen-dev`, `US`) via the §4 mechanism, bound to:
- annotations source = `cvc_annotations_native_v4`;
- staging source = the §6 crosswalk views over the primary dataset's staging tables;
- reference data = the **same** `clinvar_ingest` (US) and the **same**
  `cvc_clinvar_reviews/submissions/batches` state as legacy.
So the **only** variable vs legacy is the annotation source. Includes
`refresh_cvc_impact_analysis_v4()` writing 11 `*_v4` tables. Legacy `clinvar_curator` is
byte-for-byte unchanged → true side-by-side comparison.

### 7.2 Parity method (drift-aware)
1. **Comparison population = the intersection** keyed by `annotationDocId` (content hash) —
   the shared seed. **Within it, parity must be exact:** row-for-row and column-for-column
   at the choke point, and `annotation_id` id-integrity (0 orphaned staging ids after the
   crosswalk).
2. **Parity anchors:** `cvc_version_bumps` / `cvc_full_record_version_bumps` (pure-upstream)
   must be **identical** across lineages; a difference indicates an environment/config
   problem, not an adapter problem.
3. **Id-integrity check:** for the non-duplicate majority, assert
   `UNIX_MILLIS(v4 created_at) == legacy annotation_id` matches ≈100%. This also detects
   whether the migration's second-precision truncation
   (`FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', …)`) was lossless. If the match rate is below
   ~100%, widen the crosswalk to cover all shifted ids (mechanically identical fix).
4. **Choke-point diff:** `cvc_annotations("all")` vs `cvc_annotations_v4("all")` — counts
   plus full column diff keyed by `annotation_id`, restricted to the shared seed.
5. **End-to-end batch parity:** choose a batch **finalized before the seed boundary** (stable
   membership); diff all 11 impact tables (especially #8 `cvc_flagging_version_bump_intersection`,
   #9 `cvc_resubmission_candidates`, #11 `cvc_impact_summary`) and the **generated submission
   file** (`cvc_annotations("unreviewed")` JOIN submissions) legacy-vs-v4.
6. **Drift reconciliation:** enumerate and categorize every row outside the intersection —
   `sheet-only (post-seed)`, `v4-only (new capture)` — with **zero unexplained deltas
   attributable to adapter logic**. Snapshot both sources at one instant and record the
   seed-boundary timestamp so the diff is against a fixed frame.

### 7.3 Parity report (deliverable)
A short written report: anchor results, id-integrity match rate, shared-seed diff result,
sample-batch end-to-end result, and the drift reconciliation. This is the **go/no-go
evidence** for Phase 1.

## 8. Testing

This layer is BigQuery SQL + a shell deploy (no JS module to unit-test here), so:
- Parity assertions are **diff queries** checked into `bigquery/curator/tests/`, each
  returning **0 rows on success**, runnable via `bq`.
- The adapter reshape (contract mapping, `annotation_id` formula, crosswalk) gets small
  fixture-based checks where feasible (e.g. a synthetic content-dup set proving the
  crosswalk collapses to the surviving id).
- The deploy mechanism is validated by deploying the shadow dataset and confirming all
  objects create cleanly and `refresh_cvc_impact_analysis_v4()` runs end-to-end.

## 9. Deliverables

1. `bigquery/curator/` — moved, parameterized SQL + deploy script; ingest-repo copies deleted.
2. Adapter — incremental copy job + `cvc_annotations_native_v4` reshape + `cvc_annotation_id_xwalk`
   + crosswalk views.
3. `clinvar_curator_v4` shadow lineage + `refresh_cvc_impact_analysis_v4()`.
4. Parity test suite (`bigquery/curator/tests/`) + the written parity report.
5. Impact-SP dependency map (§3.6) captured in `bigquery/curator/` docs.

## 10. Risks

- **Second-precision truncation** could shift more ids than the 554 dups. Surfaced early by
  §7.2(3); the fix (widen the crosswalk) is mechanically identical.
- **Source drift** means Phase-0 parity proves correctness on the **shared seed only**;
  full-population authority still needs the Phase-1 union bridge or a re-seed at cutover.
- **`clinvar_ingest` refactor** (external, future) could move reference tables; out of scope
  now, flagged; the parity anchors (§7.2) would catch a break.
- **Cross-region copy mechanism** (DTS vs EXPORT→LOAD) is deferred to the plan; both meet the
  incremental + on-demand requirement, but the plan must confirm watermark correctness and
  on-demand latency for the reviewer Refresh path.
