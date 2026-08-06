# Phase 0 — Canonical CvC Data Layer (v4-sourced, shadow + parity)

> **Type:** design spec (approved by the user 2026-08-03). Next step: superpowers:writing-plans.
> **Parent:** `docs/superpowers/plans/2026-08-03-curation-ops-platform-discovery.md` (§4 Phase 0).
> **Supersedes discovery gaps:** the impact-SP mapping and the adapter/consolidation approach.
>
> **⚠️ REVISED 2026-08-04 — dedup dropped.** During execution the user determined that
> historical annotations must NOT be deduped: all 31,362 legacy rows have unique `created_at`
> (verified: 31,362 distinct `annotation_id`, 0 collisions), so the "554 duplicates" were
> distinct curation events, not dupes. The design was simplified: **no historical dedup** (load
> all records), and **`annotation_id = UNIX_MILLIS(created_at)` is computed at write time and
> stored on every v4 doc** (extension + migration) so the downstream reads it directly. This
> **removes** the 15-min dedup module, the cluster-anchor crosswalk, the `_x` remap views, and
> the dedup-collapse parity bucket. **§6 below is rewritten** to reflect this; the dedup/crosswalk
> specifics elsewhere (§3.3, §5.2, §7.2 items about collapse, §9, §10) are superseded by §6 and
> by the implementation plan (`2026-08-03-phase0-canonical-data-layer.md`), which is authoritative.

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

1. **(REVISED 2026-08-06) The v4 shadow lineage is split dev/prod.** The legacy live
   `clinvar_curator` dataset (sheet-sourced) is untouched and stays single. The *v4 shadow* now
   has two parallel datasets in `clingen-dev` (`US`): **`clinvar_curator_v4`** sourced from prod
   capture `clingen-cvc`, and **`clinvar_curator_v4_dev`** sourced from dev capture
   `clingen-cvc-dev`. (Originally decision 1 kept a single source-agnostic `clinvar_curator`; the
   user opted to give the v4 shadow a dev twin so `clingen-cvc-dev` capture has its own downstream.)
2. **v4 shadow sources are split by environment.** The **prod** shadow (`clinvar_curator_v4`) =
   `clingen-cvc.clinvar_cvc_ext.annotations` (the full historical seed, migrated-only, no test
   captures). The **dev** shadow (`clinvar_curator_v4_dev`) = `clingen-cvc-dev.…annotations` (same
   historical seed **plus** dev-test captures — that extra content is the point of the dev twin).
3. **Shadow, don't flip.** Build a parallel v4-sourced lineage beside the legacy one and
   diff them; the live choke point is untouched. Flipping is a Phase-1 decision.
4. **Consolidate in one change.** Move `clinvar-ingest-bq-tools/scripts/clinvar-curation/`
   into this repo and delete the ingest-repo copies in the same coordinated change.
5. **Adapter refresh = incremental + on-demand**, never a fixed 15-min full copy.
6. **`annotation_id = UNIX_MILLIS(created_at)` is stored on the doc** (STRING), computed at
   write time by the extension's `buildAnnotation` and by the migration. Downstream reads it
   directly (via the `@@ANNO_ID@@` template token) instead of recomputing.
7. **(REVISED) No historical dedup.** All 31,362 legacy rows have unique `created_at`/
   `annotation_id` (0 collisions), so the migration loads **every** record, keyed by its
   `annotation_id` doc id. The old content-hash dedup dropped 578 distinct events; those are
   restored.
8. **Re-migrate v4 now (no dedup).** Clean-slate wipe + reload of prod-staging v4 (`clingen-cvc`)
   loading all records with the stored `annotation_id`, emitting a **restored-records audit**.
   Prod is a re-loadable staging load, so this also preps the go-live migration.
9. **Extension live dedup unchanged.** The extension keeps its content-hash doc id
   (`annotationDocId`) as the live double-save guard; it only *adds* the `annotation_id` field.
10. **No crosswalk / no collapse.** Because every staging `annotation_id` resolves directly to a
    v4 record, the shadow uses plain passthrough staging views and the parity shared seed is exact.

## 2. Scope & non-goals

**In scope**
- Repo consolidation (move + delete + parameterized deploy mechanism).
- **Stored `annotation_id` + no-dedup re-migration (§6):** add `annotation_id` to the extension
  + migration, clean-slate re-migration of prod-staging v4 loading **all** records, and a
  **restored-records audit**.
- The **adapter**: full-snapshot cross-region landing of v4 capture into a `US` native
  table with the choke-point column contract, passing the stored `annotation_id` through
  (no recompute, no crosswalk).
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
- v4 → contract mapping (renames): `created_at→annotation_date`, `vcv→vcv_id`,
  `scv→scv_id`, `user_email→curator_email`, `interp→interpretation`; `action` passed
  through capitalized (base_mv lowercases); `ignore` → literal `FALSE`.
- v4 → contract mapping (passthroughs, name-identical): `variation_id`, `submitter_id`,
  `reason`, `notes`, `review_status`. (Listed explicitly so the contract is complete on
  its face — the discovery doc omitted `interpretation`; nothing else should be assumed.)

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
`US` staging table in `clingen-dev`. **Trigger model:** on-demand plus a low-frequency
backstop (e.g. hourly or daily). **No fixed 15-min full copy.** Copy volume ≈ new
annotations (not table size), so cost stays ≈ cents/month, flat over time. Capture is
never modified.
- **What "on-demand" means in Phase 0:** a manual/CLI/scriptable invocation (and the
  `refresh_cvc_impact_analysis_v4()` run), *not* a UI button — there is no web app in
  Phase 0. The forward-looking "reviewer Refresh latency" mentioned in §10 is a *validation
  target* for the Phase-2 web app, not a Phase-0 deliverable.
- **Mechanism choice is left to the plan** (BigQuery Data Transfer Service scheduled
  table-copy vs a Cloud Function/Cloud Run EXPORT→LOAD). Both satisfy incremental +
  on-demand. The choice must preserve the append-only watermark semantics.

### 5.2 Reshape → `clinvar_curator.cvc_annotations_native_v4`
A `US` query flattens the copied changelog to latest-per-document, applies the §3.2
contract mapping, sets `ignore = FALSE`, and computes
`annotation_id = CAST(UNIX_MILLIS(annotation_date) AS STRING)`. Output is a **native
table** so the shadow materialized view can sit over it. This is the single place the
`UNIX_MILLIS` conversion happens.
- **Changelog resolution semantics:** the document key is the Firestore `document_id` (the
  dedup key — post-re-migration this is `SHA-256(canonical(DEDUP_FIELDS) ‖ clusterAnchorMillis)`
  per §6.2, not the old content-only hash); "latest" is the newest changelog event for that
  key ordered by (`timestamp`, then `event_id` as tiebreak). Capture is create-only so there
  are no deletes, but an idempotent re-save appends a further `CREATE` event for the same
  key — latest-per-key collapses those to the surviving document.

### 5.3 Interface (what consumers can rely on)
`cvc_annotations_native_v4` is a drop-in for `clinvar_annotations_native`: identical column
names, types, and `annotation_id` semantics. A consumer needs to know only that it carries
the §3.2 contract for the shared-seed population plus any post-seed v4 captures; it does not
need to know how the copy or reshape work.

### 5.4 Source-environment separation (dev vs prod capture) — REVISED 2026-08-06

Capture environments stay separated **structurally — by named table + suffixed lineage, never
by row-mixing**. The v4 shadow now has BOTH lineages built (the `_dev` twin was promoted from
"if ever needed" to a standing dataset):

- `clinvar_annotations_native` — legacy sheet source → live legacy lineage (`clinvar_curator`).
- `clinvar_curator_v4.cvc_annotations_native_v4` — v4 **prod** capture (`clingen-cvc`) → shadow
  `clinvar_curator_v4` (migrated-only, no test captures).
- `clinvar_curator_v4_dev.cvc_annotations_native_v4` — v4 **dev** capture (`clingen-cvc-dev`) →
  shadow `clinvar_curator_v4_dev` (historical seed **plus** dev-test captures).

There is no code path that reads two capture sources into one table: each native table lives in
its own dataset with a single-valued source binding (the adapter's `CVC_PROD` + `CURATOR_DATASET`
env), and each has its own suffixed shadow lineage — same templated DDL, different binding,
coexisting with zero contamination. Both shadows share the **legacy `clinvar_curator` staging**
(reviews/submissions/batches) via read-only passthrough views, because that review/submission/
batch state is single and sheet-derived — so the dev twin validates adapter/capture plumbing +
per-source annotation fidelity, not a fully isolated ops environment (a true ops dev/prod split
is the deferred discovery open-question, not this). **Durable rule:** the **prod** shadow tracks
the prod capture (the eventual system of record); the **dev** shadow tracks dev capture for
trialing. Neither is the live pipeline — that stays the sheet-sourced `clinvar_curator` until a
Phase-1 flip.

Fidelity of each shadow against the legacy sheet source is asserted by
`bigquery/curator/tests/06-annotation-id-roundtrip.sql` (0 rows on success). Verified on the dev
shadow 2026-08-06: **31,383 `annotation_id`s matched with all 10 core fields byte-identical**;
the only set-diffs were 14 `ignore=TRUE` sheet rows (correctly excluded by the migration), 7
post-snapshot legacy appends, and 1 dev-test capture — i.e. zero lost annotations.

## 6. Storing `annotation_id` + the no-dedup re-migration

### 6.1 The finding: history has no real duplicates
The original migration deduped by `annotationDocId` (content hash excluding `created_at`), dropping 578 content-identical rows. Those are **distinct curation events**, not duplicates: verified against legacy native (`ignore` not true) — **31,362 rows → 31,362 distinct `created_at` → 31,362 distinct `annotation_id` (UNIX_MILLIS), 0 collisions**. So no dedup is applied to history.

### 6.2 Stored `annotation_id`
`annotation_id = CAST(UNIX_MILLIS(created_at) AS STRING)` is computed at write time and stored as a doc field:
- **Extension** (`buildAnnotation`): `annotation_id: String(created_at.getTime())`.
- **Migration** (`source.sql` + `nativeRowToV4Doc`): `UNIX_MILLIS(TIMESTAMP(annotation_date))`.

It is excluded from `DEDUP_FIELDS` (derived from `created_at`), so `annotationDocId` is unchanged. The flattened BQ `annotations` view exposes it with a fallback: `COALESCE(annotation_id, CAST(created_at_millis AS STRING))`. Downstream never recomputes `UNIX_MILLIS` — the shadow `base_mv` reads the stored `annotation_id` via the `@@ANNO_ID@@` template token; the legacy `base_mv` still computes it from the sheet source (which has no stored id).

### 6.3 Two doc-id schemes (deliberate)
- **Extension doc id = `annotationDocId`** (content hash) — the live double-save guard, unchanged.
- **Migration doc id = `annotation_id`** (unique per record) — so create-only loads every record with nothing dropped.

The two serve different purposes and need not match.

### 6.4 Re-migration
Clean-slate wipe + reload of prod-staging v4 (`clingen-cvc`) loading all ~31,362 records keyed by `annotation_id`, each carrying the stored field. Idempotent (re-run → same ids → `ALREADY_EXISTS`). Still needed because current prod-staging v4 was loaded with the old content-hash ids (missing 578 records). Paced per the documented burst-drop/`run.invoker` recipe; `run.invoker` verified BEFORE the load. Pre-wipe gate: enumerate any post-seed v4-only captures and confirm with the user (§10).

### 6.5 Restored-records audit (deliverable)
The 578 records the old content-hash dedup dropped are now loaded; the audit lists them with `annotation_id`, `action`, `curator`, `created_at`, and any downstream review/submission `batch_id` they reference, segmented by action (`flagging candidate`/`remove flagged submission` first) — a reviewable record of what the old dedup had hidden.

### 6.6 What this removes vs the earlier (dedup) design
No 15-min dedup module, no cluster-anchor crosswalk, no `_x` remap views, no dedup-collapse parity bucket. Every staging `annotation_id` resolves directly to a v4 record (0 orphans by construction), and the parity shared seed is **exact**.

## 7. The shadow lineage & parity

### 7.1 Shadow lineage
Deploy the full templated curator object graph into a new **`clinvar_curator_v4`** dataset
(`clingen-dev`, `US`) via the §4 mechanism, bound to:
- annotations source = `cvc_annotations_native_v4`;
- staging source = the §6 crosswalk `_x` views **only** — the shadow lineage never
  references the raw `cvc_clinvar_reviews/submissions/batches` tables directly; it reads
  the same underlying state exclusively *through* the `_x` views (which pass rows through
  unchanged except for the id remap + dedup);
- reference data = the **same** `clinvar_ingest` (US) as legacy.
So the **only** variable vs legacy is the annotation source (and the id-remap the `_x`
views apply to **collapse the 267 ≤15-min twins** — the 287 distinct events are reconciled by
the re-migration, restored as their own cluster anchors that map to themselves). Includes
`refresh_cvc_impact_analysis_v4()` writing 11 `*_v4` tables. Legacy `clinvar_curator` is
byte-for-byte unchanged → true side-by-side comparison.

### 7.2 Parity method (drift-aware)
Because Phase 0 **re-migrates** v4 with the corrected 15-min dedup (§6.3), the v4 population
now matches the legacy population **modulo the 267 genuine ≤15-min collapses** — the 287
distinct events are restored, so they are no longer a delta. Parity is evaluated with the
**cluster-anchor crosswalk applied to the legacy side too**, so both lineages are compared on
canonical (cluster) identity.

1. **Comparison population = the shared seed**, identified by **cluster identity**
   (`DEDUP_FIELDS` content + 15-min cluster anchor = the `canonical_annotation_id`). Apply the
   §6.4 crosswalk to legacy `cvc_annotations` so its 267 ≤15-min twins collapse to their anchor,
   exactly as v4 does. **Within this population, parity must be exact** at the annotation/
   choke-point level (row- and column-for-column) with `annotation_id` id-integrity: 0 orphaned
   staging ids after the crosswalk.
2. **Parity anchors:** `cvc_version_bumps` / `cvc_full_record_version_bumps` (pure-upstream)
   must be **identical** across lineages; a difference indicates an environment/config
   problem, not an adapter problem.
3. **Id-integrity check:** every crosswalk `canonical_annotation_id` must equal a re-migrated v4
   survivor's `annotation_id`, and every legacy staging id must resolve through the crosswalk to
   exactly one canonical (0 orphans). Also assert `UNIX_MILLIS(v4 created_at) == canonical id`
   ≈100% — this doubles as a check that the migration's second-precision truncation
   (`FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', …)`) was lossless; if below ~100%, widen the
   crosswalk to cover all shifted ids (mechanically identical fix).
4. **Choke-point diff:** `cvc_annotations("all")` (crosswalk-collapsed) vs
   `cvc_annotations_v4("all")` — two distinct checks on the shared seed: (a) a **canonical-keyed
   column diff** grouped by `canonical_annotation_id`, which must be **exactly 0 rows**; and
   (b) a **raw row-count** comparison, where the *only* permitted difference is the **267 ≤15-min
   raw-legacy duplicate rows** that collapse to their anchor (a raw-count artifact, bucketed in
   item 6). Any canonical-keyed diff, or any raw-count delta beyond the 267, is an adapter bug.
   (This closes the pass-1/pass-2 reviewer concern that an `annotation_id`-keyed diff would
   surface an unbucketed cardinality delta at the choke point.)
5. **End-to-end batch parity:** choose a batch **finalized before the seed boundary** (stable
   membership); diff all 11 impact tables (especially #8 `cvc_flagging_version_bump_intersection`,
   #9 `cvc_resubmission_candidates`, #11 `cvc_impact_summary`) and the **generated submission
   file** (`cvc_annotations("unreviewed")` JOIN submissions) legacy-vs-v4, both crosswalk-collapsed.
6. **Dedup-collapse bucket (the 267):** the only expected, quantified delta is the **267 genuine
   ≤15-min collapses** (no change 208, flagging candidate 56, remove flagged 3). Both sides
   collapse these to the cluster anchor via the crosswalk, so they should produce **no residual
   delta** once collapsed; a diff that maps to a known collapse cluster is expected, and only a
   diff *outside* it is an adapter bug. (The 287 restored distinct events must appear on **both**
   sides — their absence would be a re-migration defect, caught here.)
7. **Drift reconciliation:** enumerate and categorize every row outside the intersection —
   `sheet-only (post-seed)`, `v4-only (new capture)` — with **zero unexplained deltas
   attributable to adapter logic**. Snapshot both sources at one instant and record the
   seed-boundary timestamp so the diff is against a fixed frame.

### 7.3 Parity report (deliverable)
A short written report: anchor results, id-integrity match rate, shared-seed diff result,
the **dedup-collapse reconciliation** (§7.2 item 6 — the 267 ≤15-min collapses accounted for
and the 287 restored distinct events confirmed present on both sides), sample-batch end-to-end
result, and the drift reconciliation. It also references the **§6.5 dropped/impacted audit log**.
This is the **go/no-go evidence** for Phase 1.

## 8. Testing

This layer is a mix of a JS dedup module (unit-testable) and BigQuery SQL + a shell deploy:
- The **shared 15-min dedup module** (decision 10) is unit-tested with Vitest (this repo's
  existing harness): cluster boundaries at exactly 15 min, chained gaps, singletons, and the
  key property that batch-migration clustering and the live-capture path derive the same
  `(docId, clusterAnchor)` for identical inputs.
- Parity assertions are **diff queries** checked into `bigquery/curator/tests/`, each
  returning **0 rows on success**, runnable via `bq`.
- The adapter reshape + crosswalk get small fixture-based checks (e.g. a synthetic set of
  ≤15-min and >15-min twins proving the ≤15-min pair collapses to the anchor and the >15-min
  pair stays two distinct annotations).
- The re-migration is validated by reconciling counts (Firestore ≈ BQ view ≈ corrected
  legacy population) and by the §6.5 audit log.
- The deploy mechanism is validated by deploying the shadow dataset and confirming all
  objects create cleanly and `refresh_cvc_impact_analysis_v4()` runs end-to-end.

## 9. Deliverables

1. `bigquery/curator/` — moved, parameterized SQL + deploy script; ingest-repo copies deleted.
2. **Shared 15-min dedup module** (`clinvar-cvc/`) + updated `clinvar-cvc/migration/` using it;
   the corrected clean-slate re-migration of prod-staging v4; the **§6.5 dropped/impacted
   audit log**.
3. Adapter — incremental copy job + `cvc_annotations_native_v4` reshape +
   `cvc_annotation_id_xwalk` (cluster-anchor) + crosswalk `_x` views.
4. `clinvar_curator_v4` shadow lineage + `refresh_cvc_impact_analysis_v4()`.
5. Parity test suite (`bigquery/curator/tests/`) + the written parity report.
6. Impact-SP dependency map (§3.6) captured in `bigquery/curator/` docs.

## 10. Risks

- **Re-migration drops post-seed v4-only captures.** The clean-slate reload sources from
  legacy `clinvar_annotations_native` (sheet-derived), so any annotations captured **only** in
  the v4 extension since the seed (not in the sheet) are lost. Acceptable during staging (the
  `scvc/` sheet is the system of record now, and prod is explicitly re-loadable), but the plan
  must **enumerate any such v4-only rows first** and confirm with the user before wiping.
- **Second-precision truncation** could shift ids beyond the ≤15-min collapses. Surfaced early
  by §7.2 item 3; the fix (widen the crosswalk) is mechanically identical.
- **Source drift** means Phase-0 parity proves correctness on the **shared seed only**;
  full-population authority still needs the Phase-1 union bridge or a re-seed at cutover.
- **`clinvar_ingest` refactor** (external, future) could move reference tables; out of scope
  now, flagged; the parity anchors (§7.2) would catch a break.
- **Cross-region copy mechanism** (DTS vs EXPORT→LOAD) is deferred to the plan; both meet the
  incremental + on-demand requirement, but the plan must confirm watermark correctness and
  on-demand latency for the (Phase-2) reviewer Refresh path.
- **Live reflag-capture dedup key is a Phase-2 item.** The 15-min rule is *resolved for
  history* by the re-migration (§6.3), and the shared module (decision 10) will hold the key,
  but wiring the **read-within-15-min** check into the live extension write path so a genuine
  re-flag doesn't hit `ALREADY_EXISTS` is Phase-2 work, not resolved here. Phase 0 delivers the
  shared key and proves it on the batch/migration side.
