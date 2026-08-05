# bigquery/curator — CvC curator SQL (single home)

This tree is the single home for the ClinGen CvC curator BigQuery SQL: the
choke-point lineage that turns raw curator annotations into the
`clinvar_curator` reporting/impact-analysis objects, plus the 11-table
"impact SP" (`refresh_cvc_impact_analysis`) that downstream reporting reads.

It was moved here (vendored, not symlinked) from
`clinvar-ingest-bq-tools/scripts/clinvar-curation/` so the CvC data layer
lives alongside the extension that produces the annotations it consumes.
Numbered apply order is preserved from the source tree.

## Layout

- `staging-tables.sql` — legacy-only bootstrap for the
  `cvc_clinvar_reviews` / `cvc_clinvar_submissions` / `cvc_clinvar_batches`
  tables. Not part of `deploy.sh`'s numbered apply order (this file isn't
  matched by the `0*-*.sql` glob) since these are create-once tables, not
  idempotent view/function definitions. A shadow lineage deploys plain
  passthrough VIEWS of the same names instead (see
  `adapter/staging_passthrough_views.sql`).
- `00-initialize-cvc-tables.sql` — the
  `cvc_annotations_base_mv` materialized view (the **choke point** — see
  below), and the views built directly on it (`cvc_annotations_view`,
  `cvc_batch_scv_max_annotation_view`, `cvc_submitted_annotations_view`,
  `cvc_submitted_outcomes_view`).
- `01`–`05` `*-func.sql` — table functions layered on the choke point:
  `cvc_baseline_annotations(scope)` → `cvc_annotations(scope)` →
  `cvc_submitter_annotations()` / `cvc_annotations_impact()` /
  `cvc_outlier_clinsig()`.
- `cvc-impact-analysis/` — the 11-table impact-SP lineage
  (`00`–`09` numbered SQL + `00-run-cvc-impact-analysis.sh` runner), plus the
  `rejected-scvs.tsv` load helper and Apps Script sync (`appscript-refresh-impact.js`).
- `cvc-submitted-outcomes-stats.sql`, `cvc-annotation-history-report.sql`,
  `manuscript-figures/*` — **ad-hoc reports, not part of the deployed
  lineage.** They are not tokenized (see below) and always read the literal
  legacy `clinvar_curator` dataset.
- `deploy.sh` — parameterized deploy (dataset + annotation-source binding;
  see "Deploy" below).

## The choke point

`cvc_annotations_base_mv` (a **MATERIALIZED VIEW**) is the *only* object that
reads the raw annotations source (`clinvar_annotations_native` in the legacy
lineage). Everything else in this tree is downstream of it:

```
cvc_annotations_base_mv (MV, reads the raw annotation source)
  -> cvc_annotations_view (adds is_latest)
    -> cvc_baseline_annotations(scope)  [table function]
      -> cvc_annotations(scope)         [table function]
        -> cvc_submitter_annotations() / cvc_annotations_impact() / cvc_outlier_clinsig()
        -> refresh_cvc_impact_analysis() [the impact SP, cvc-impact-analysis/09]
        -> cvc_submitted_annotations_view -> cvc_submitted_outcomes_view
           -> cvc_submitted_variants (impact-analysis #1, root of the submitted-variant chain)
```

## Impact-SP dependency map

`refresh_cvc_impact_analysis()` (`cvc-impact-analysis/09-refresh-cvc-impact-analysis.sql`)
builds 11 tables, in this order, with these inputs:

| # | Table | Inputs | Notes |
|---|-------|--------|-------|
| 1 | `cvc_submitted_variants` | `cvc_submitted_outcomes_view` | root of submitted-variant chain |
| 2 | `cvc_flagging_candidate_outcomes` | `cvc_annotations_view`, `cvc_batches_enriched`, `cvc_rejected_scvs`, `clinvar_scvs`/`releases`/`schema_on` | choke-point-derived |
| 3 | `cvc_remove_flagged_outcomes` | same input set as #2 | choke-point-derived |
| 4 | `cvc_version_bumps` | **`clinvar_ingest.clinvar_scvs` only** | pure-upstream; annotation-independent → **parity anchor** |
| 5 | `cvc_full_record_version_bumps` | **`clinvar_ingest.clinvar_scvs` only** | pure-upstream; **parity anchor** |
| 6 | `cvc_variant_conflict_history` | #1, `monthly_conflict_snapshots` | |
| 7 | `cvc_resolution_attribution` | #1, `conflict_vcv_change_detail`, `monthly_conflict_scv_changes` | |
| 8 | `cvc_flagging_version_bump_intersection` | **#2 ∩ #4** | **reflag / "submitter overwrote our flag" detection** |
| 9 | `cvc_resubmission_candidates` | #2, #3, #4, `cvc_annotations_view`, `clinvar_vcvs`/`submitters` | |
| 10 | `cvc_autoreflag_candidates` | #2, #3, `clinvar_scvs`/`submitters` | |
| 11 | `cvc_impact_summary` | #1, #7, `monthly_conflict_snapshots`, `conflict_vcv_change_detail` | top-level rollup |

Non-SP inputs the SP consumes: `cvc_batches_enriched` (from
`cvc-impact-analysis/00-cvc-batch-enriched-view.sql`) and `cvc_rejected_scvs`
(loaded from `rejected-scvs.tsv` via `cvc-impact-analysis/load-rejected-scvs.sh`).

`cvc_version_bumps` (#4) and `cvc_full_record_version_bumps` (#5) are pure
`clinvar_ingest`-only tables — they don't derive from curator annotations at
all, so they are identical regardless of which annotation lineage
(`clinvar_curator` vs a future `clinvar_curator_v4` shadow) is deployed. That
makes them the **parity anchors**: if a shadow deploy's #4/#5 don't match the
legacy deploy's #4/#5 byte-for-byte, something is wrong with the deploy
itself (not with annotation data), since neither input depends on the
annotation source.

## Parameterization: `@@DATASET@@`, `@@ANNO_SOURCE@@`, `@@MV@@`, `@@ANNO_ID@@`

The deployed core files (`0*-*.sql` in `bigquery/curator/` and
`bigquery/curator/cvc-impact-analysis/`) are templated with four tokens so
the same SQL tree can deploy either the legacy `clinvar_curator` lineage or a
parallel shadow lineage over a different annotation source, without forking
the SQL:

- `@@DATASET@@` — the target dataset for every `clinvar_curator.*` object
  reference (e.g. `clinvar_curator` or `clinvar_curator_v4`).
- `@@ANNO_SOURCE@@` — the fully-qualified table `cvc_annotations_base_mv`
  reads as its raw annotation source (e.g.
  `clinvar_curator.clinvar_annotations_native` for legacy, or a native `_v4`
  landing table for the shadow).
- `@@MV@@` — the materialized-view keyword on `cvc_annotations_base_mv`.
  Legacy substitutes `MATERIALIZED ` (a real materialized view over the
  native table); a shadow deploy whose source is a **view** (not a native
  table) must substitute an empty string, because BigQuery materialized
  views cannot read over a view/external source — the shadow's `base_mv`
  becomes a plain `VIEW` instead.
- `@@ANNO_ID@@` — the expression `cvc_annotations_base_mv` uses to derive
  `annotation_id` from the annotation source row `a`. Legacy substitutes
  `CAST(UNIX_MILLIS(a.annotation_date) AS STRING)` (recomputed from the
  annotation timestamp, since the legacy source has no stored id). A shadow
  deploy over a `_v4` native table that already stores `annotation_id`
  substitutes `a.annotation_id` instead, reading the stored id directly
  rather than recomputing it.

The ad-hoc report files (`cvc-submitted-outcomes-stats.sql`,
`cvc-annotation-history-report.sql`, `manuscript-figures/*`) are **not**
tokenized and are **not** part of `deploy.sh`'s glob — they stay
legacy-only, with literal `clinvar_curator` references, since they are not
deployed objects.

## Deploy

`deploy.sh` substitutes the tokens and applies every numbered SQL file in
apply order (`bigquery/curator/0*-*.sql` then
`bigquery/curator/cvc-impact-analysis/0*-*.sql`) via `bq query`.

Legacy lineage (the live `clinvar_curator` dataset, materialized view over
the real native table):

```bash
CURATOR_PROJECT=clingen-dev \
DATASET=clinvar_curator \
ANNO_SOURCE=clinvar_curator.clinvar_annotations_native \
./bigquery/curator/deploy.sh
```

`_v4` shadow lineage (a parallel dataset over a `_v4` native landing table;
`base_mv` becomes a plain view since the shadow source isn't a native table
BigQuery can put a materialized view over):

```bash
CURATOR_PROJECT=clingen-dev \
DATASET=clinvar_curator_v4 \
ANNO_SOURCE=clinvar_curator.cvc_annotations_native_v4 \
MV="" \
./bigquery/curator/deploy.sh
```

Pass `--dry-run` as the first argument to validate without applying (no
data changes, no cost):

```bash
DATASET=clinvar_curator ANNO_SOURCE=clinvar_curator.clinvar_annotations_native \
./bigquery/curator/deploy.sh --dry-run
```

Note: `deploy.sh` only applies `0*-*.sql` files, so it never re-runs
`staging-tables.sql`'s `CREATE TABLE` statements (not
`CREATE OR REPLACE TABLE`) for `cvc_clinvar_reviews` / `cvc_clinvar_submissions`
/ `cvc_clinvar_batches` — those are bootstrapped once, separately, for the
legacy dataset only. A shadow deploy (e.g. a fresh `clinvar_curator_v4`)
instead deploys passthrough VIEWS of the same names
(`adapter/staging_passthrough_views.sql`) before running `deploy.sh`, so
`--dry-run` and a real deploy of `0*-*.sql` both pass cleanly regardless of
whether the dataset is fresh or already provisioned.
