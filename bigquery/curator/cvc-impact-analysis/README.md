# CVC Impact Analysis

## Purpose

This pipeline tracks the impact of **ClinVar Curation (CVC) project submissions** on conflict resolution. It answers the key question: **What percentage of conflict resolutions are attributable to CVC curation vs organic changes?**

## Background

The CVC project began in August 2023 with the goal of improving ClinVar data quality by flagging SCVs that meet specific criteria (see [CURATION_CRITERIA_GUIDE.md](../CURATION_CRITERIA_GUIDE.md)). When an SCV is flagged and the submitter doesn't respond within 60 days, the flag is applied and that SCV is excluded from conflict calculations.

### CVC Submission Timeline

```
[Curation Period]     [Batch Submission]    [60-Day Grace Period]    [Flag Applied]
    ~1 month                  |                   60 days                  |
├─────────────────┤          │             ├───────────────────┤          │
                             │                                            │
  Curators flag SCVs   Batch finalized     Submitters can              Flagged SCVs
  as "flagging         and submitted to    respond (remove/            excluded from
  candidates"          ClinVar             update their SCV)           conflict calc
```

### Key Data Sources

| Table | Dataset | Purpose |
|-------|---------|---------|
| `cvc_clinvar_batches` | clinvar_curator | Batch metadata with finalization dates |
| `cvc_clinvar_submissions` | clinvar_curator | Maps annotations to SCV submissions |
| `cvc_submitted_outcomes_view` | clinvar_curator | Outcomes of submitted annotations |
| `monthly_conflict_scv_changes` | clinvar_ingest | SCV-level changes in conflict resolution |
| `conflict_vcv_change_detail` | clinvar_ingest | VCV-level changes with reason categorization |

## Pipeline Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          CVC Curation Data                                   │
│  cvc_clinvar_batches  │  cvc_clinvar_submissions  │  cvc_submitted_outcomes │
└──────────────┬────────┴────────────┬──────────────┴─────────────────────────┘
               │                     │
               ▼                     ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ 01-cvc-submitted-variants.sql                                               │
│                                                                              │
│ cvc_submitted_variants                                                       │
│ (All CVC-submitted SCVs with batch dates, outcomes, and variation_id)       │
└──────────────────────────────────────────┬─────────────────────────────────┘
                                           │
                                           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Conflict Resolution Data                                 │
│  monthly_conflict_scv_changes  │  conflict_vcv_change_detail                │
└──────────────┬─────────────────┴────────────────────────────────────────────┘
               │
               ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ 02-cvc-conflict-attribution.sql                                             │
│                                                                              │
│ cvc_variant_conflict_status                                                  │
│ (CVC variants joined with their conflict status over time)                   │
│                                                                              │
│ cvc_resolution_attribution                                                   │
│ (Resolutions categorized as CVC-attributed vs organic)                       │
└──────────────────────────────────────────┬─────────────────────────────────┘
                                           │
                                           ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ 03-cvc-impact-analytics.sql                                                 │
│                                                                              │
│ cvc_impact_summary                                                           │
│ (Monthly summary of CVC impact on resolutions)                               │
│                                                                              │
│ cvc_attribution_rates                                                        │
│ (Attribution rates: CVC vs organic resolutions)                              │
└────────────────────────────────────────────────────────────────────────────┘
```

## Attribution Logic

### Resolution Attribution Categories

| Category | Description | Detection Logic |
|----------|-------------|-----------------|
| **CVC Flagged** | Resolution occurred because CVC flagged contributing SCV(s) | `scv_id` in CVC submissions AND `outcome = 'flagged'` AND SCV appears in `monthly_conflict_scv_changes` with `is_first_time_flagged = TRUE` |
| **CVC Prompted** | Resolution occurred because submitter responded to CVC flag (deleted/reclassified during grace period) | `scv_id` in CVC submissions AND `outcome IN ('deleted', 'resubmitted, reclassified')` AND timing aligns with grace period |
| **Organic** | Resolution occurred without CVC involvement | No CVC submission for any contributing SCV, or CVC submission was invalid/pending |

### SCV Outcome Categories (from cvc_submitted_outcomes_view)

| Outcome | Description | Impact on Attribution |
|---------|-------------|----------------------|
| `flagged` | SCV was successfully flagged by ClinVar | Direct CVC attribution |
| `deleted` | Submitter deleted their SCV (during grace period) | CVC-prompted attribution |
| `resubmitted, reclassified` | Submitter changed classification (during grace period) | CVC-prompted attribution |
| `resubmitted, same classification` | Submitter updated but kept classification | No resolution impact |
| `pending (or rejected)` | Awaiting ClinVar processing or rejected | Not yet attributable |
| `invalid submission` | SCV version mismatch at submission time | Not attributable |

## Key Metrics

### Attribution Rate

```
CVC Attribution Rate = (CVC Flagged + CVC Prompted) / Total Resolutions
```

### Breakdown Dimensions

- **By Batch**: Track effectiveness of each curation batch
- **By Flagging Reason**: Which curation criteria lead to most resolutions?
- **By Conflict Type**: ClinSig vs Non-ClinSig resolution rates
- **By Time Since Submission**: How long until CVC curations lead to resolution?

## Output Tables

All tables and views are created in the `clinvar_curator` dataset.

| Table | Description | Grain |
|-------|-------------|-------|
| `cvc_submitted_variants` | All CVC-submitted SCVs with outcomes | One row per SCV submission |
| `cvc_variant_conflict_history` | CVC variants with monthly conflict status | One row per variant per month |
| `cvc_resolution_attribution` | Resolutions with attribution category | One row per resolved variant |
| `cvc_impact_summary` | Monthly aggregated impact metrics | One row per month |
| `cvc_batch_effectiveness` | Per-batch effectiveness metrics | One row per batch |
| `cvc_reason_effectiveness` | Per-curation-reason effectiveness | One row per reason |

## Usage

### Running the Pipeline

```bash
# Run all CVC impact analysis scripts
./00-run-cvc-impact-analysis.sh

# Or run individual scripts
bq query < 01-cvc-submitted-variants.sql
bq query < 02-cvc-conflict-attribution.sql
bq query < 03-cvc-impact-analytics.sql
```

### Example Queries

**Get overall attribution rate:**
```sql
SELECT
  snapshot_release_date,
  total_resolutions,
  cvc_flagged_resolutions,
  cvc_prompted_deletion + cvc_prompted_reclassification AS cvc_prompted_resolutions,
  organic_resolutions,
  cvc_attribution_rate_pct
FROM `clinvar_curator.cvc_impact_summary`
ORDER BY snapshot_release_date DESC;
```

**Find CVC-attributed resolutions by batch:**
```sql
SELECT
  batch_id,
  COUNT(*) AS resolutions,
  COUNTIF(primary_attribution = 'cvc_flagged') AS flagged,
  COUNTIF(primary_attribution LIKE 'cvc_prompted%') AS prompted
FROM `clinvar_curator.cvc_resolution_attribution`
WHERE variant_attribution = 'cvc_attributed'
GROUP BY batch_id
ORDER BY batch_id;
```

## Data Freshness

- **CVC submissions**: Updated when new batches are finalized (~monthly)
- **Conflict resolution data**: Updated when parent pipeline runs (after new monthly ClinVar release)
- **First batch date**: September 7, 2023
- **Total batches through Dec 2025**: 27 batches, 5,694 SCV submissions

## Directory Contents

### Pipeline Scripts

| File | Description |
|------|-------------|
| `00-run-cvc-impact-analysis.sh` | Main pipeline runner with `--dry-run`, `--force`, `--check-only`, `--skip-load` options |
| `00-cvc-batch-enriched-view.sql` | Adds grace period dates to batch metadata |
| `01-cvc-submitted-variants.sql` | Creates master list of CVC-submitted SCVs |
| `02-cvc-conflict-attribution.sql` | Attributes resolutions to CVC vs organic |
| `03-cvc-impact-analytics.sql` | Creates summary views and analytics |
| `04-flagging-candidate-outcomes.sql` | Tracks outcomes of flagging candidates |
| `05-version-bump-detection.sql` | Detects version bumps (4-field comparison) |
| `06-version-bump-flagging-intersection.sql` | Analyzes version bumps on CVC-submitted SCVs |
| `07-resubmission-candidates.sql` | Flagging candidates (all labs) needing resubmission |
| `08-autoreflag-candidates.sql` | Auto-reflag candidates for the 7 target labs |
| `full-record-version-bump-detection.sql` | Comprehensive 19-field version bump detection |
| `09-refresh-cvc-impact-analysis.sql` | Stored procedure to rebuild all 11 materialized tables in dependency order |
| `10-flagging-report-suppressions.sql` | Manually-maintained "hide list" table (`cvc_flagging_report_suppressions`) of flagging-candidate submissions to exclude from the report, keyed by scv_id + scv_ver + batch_id. Deploy before the report TVFs. |
| `10-flagging-status-report.sql` | Parameterized table functions for the by-submitter flagging status report (flagged submissions + pending candidates) as of a passed-in release date, with aging |

### Apps Script / Automation

| File | Description |
|------|-------------|
| `appscript-refresh-impact.js` | Apps Script snippet to call refresh procedure after batch finalization |

### Data Loaders

| File | Description |
|------|-------------|
| `load-rejected-scvs.sh` | Loads `rejected-scvs.tsv` into BigQuery |

### Ad-Hoc Query Scripts

| File | Description |
|------|-------------|
| `query-accepted-vs-rejected.sql` | Compares accepted vs rejected submissions by batch |
| `query-pending-rejected-scvs.sh` | Finds pending/rejected SCVs (with `--batch` and `--tsv` options) |
| `query-submission-flagging-status.sql` | Checks which submissions actually got flagged in ClinVar |

### Data Files

| File | Description |
|------|-------------|
| `rejected-scvs.tsv` | SCVs rejected by ClinVar with rejection reasons |

### Documentation

| File | Description |
|------|-------------|
| `README.md` | This file - pipeline overview and usage |
| `GOOGLE-SHEETS-SETUP.md` | Guide for creating dashboards from BigQuery views |
| `BATCH-107-ANALYSIS.md` | Deep-dive into Batch 107's low resolution rate |
| `NON-CONTRIBUTING-SCV-ANALYSIS.md` | Analysis of submissions against non-contributing SCVs |

## How the Pipeline Works (Non-Technical Overview)

This section explains what each query file does in plain language, without requiring SQL knowledge.

### Step 0: Enrich Batch Information (`00-cvc-batch-enriched-view.sql`)

**What it does:** Adds important dates to each batch of CVC submissions.

When curators submit a batch of flagging candidates to ClinVar, they need to know:

- When did ClinVar actually process/accept the batch?
- When does the 60-day grace period end?
- What's the first ClinVar release after the grace period?

This query takes the batch end dates from `cvc_clinvar_batches` and calculates these key dates. The grace period is important because submitters have 60 days to respond to a flagging candidate before the flag is applied.

---

### Step 1: Track All Submitted Variants (`01-cvc-submitted-variants.sql`)

**What it does:** Creates a complete list of every SCV that CVC has ever submitted, with their current outcomes.

Think of this as a master list showing:

- Every submission the CVC project has made
- Which batch it was part of
- What happened to it (was it flagged? did the submitter delete it? did they change their classification?)
- Whether it was a valid submission

This also identifies "resolution candidates" - submissions that led to meaningful outcomes (flagged, deleted, or reclassified), which are the ones that potentially resolved conflicts.

---

### Step 2: Determine Who Gets Credit (`02-cvc-conflict-attribution.sql`)

**What it does:** When a conflict gets resolved, this query figures out whether CVC deserves credit or if it happened naturally (organically).

Imagine a conflict between labs is resolved. This query asks: "Did this happen because of CVC's intervention, or would it have happened anyway?"

It categorizes each resolution as:

- **CVC Flagged**: The SCV was flagged after CVC submitted it
- **CVC Prompted Deletion**: The submitter deleted their SCV during the grace period (responding to CVC's notification)
- **CVC Prompted Reclassification**: The submitter changed their classification during the grace period
- **Organic**: The resolution happened without CVC involvement

This is crucial for measuring CVC's real impact.

---

### Step 3: Calculate Impact Metrics (`03-cvc-impact-analytics.sql`)

**What it does:** Rolls up all the data into summary statistics and dashboards.

This creates monthly summaries showing:

- How many conflicts exist each month
- How many got resolved
- What percentage of resolutions were due to CVC vs organic changes
- How effective each batch has been
- Which curation reasons (like "outdated data" or "incorrect inheritance") lead to the most resolutions

These summaries are designed to be easily imported into Google Sheets for visualization.

---

### Step 4: Track Flagging Candidate Outcomes (`04-flagging-candidate-outcomes.sql`)

**What it does:** For each flagging candidate submission, tracks exactly what happened to it over time.

When CVC submits an SCV as a flagging candidate, several things can happen:

- It gets flagged (after the 60-day window)
- The submitter removes their SCV
- The submitter reclassifies (changes their interpretation)
- The submitter updates their SCV but keeps the same classification
- It's still pending

This query captures the SCV's state at three key moments:

1. When CVC submitted it
2. At the first release after the 60-day grace period
3. Currently

This helps track whether submitters are responding to CVC notifications and how they're responding.

---

### Step 5: Detect Version Bumps (`05-version-bump-detection.sql`)

**What it does:** Identifies when submitters resubmit their SCVs without making any real changes.

A "version bump" is when a submitter creates a new version of their SCV, but nothing substantive changed:

- Same classification
- Same evaluation date
- Same condition (trait)
- Same rank

Why does this matter? Version bumps may be used to reset the 60-day grace period. If a submitter is notified of a flagging candidate, they could theoretically avoid the flag by resubmitting their SCV without changes, resetting the clock.

This query compares consecutive versions of each SCV to detect:

- Which SCVs had version bumps
- When the bumps occurred
- Which submitters do this most often

---

### Step 6: Identify Grace Period Gaming (`06-version-bump-flagging-intersection.sql`)

**What it does:** Combines the flagging candidate data with version bump data to detect potential gaming of the system.

This query answers:

- How many flagging candidates received version bumps after being submitted?
- Did the version bump happen during the 60-day grace period?
- Did the version bump appear to prevent a flag from being applied?

This is important for understanding whether submitters are responding appropriately to CVC notifications or potentially trying to avoid flags without addressing the underlying data quality issues.

The query also breaks this down by submitter to identify patterns.

---

### Full Record Version Bump Detection (`full-record-version-bump-detection.sql`)

**What it does:** A more comprehensive version bump detector that compares ALL 19 substantive fields between consecutive SCV versions.

While Step 5 uses a "standard" 4-field comparison (classification, evaluation date, trait, rank), this script compares every field that a submitter controls:

- Classification fields (label, abbrev, submitted, comment, type)
- Review status and rank
- Statement type and proposition types
- Method type and origin
- Affected status and local key
- Trait set ID

This creates several analysis views:

- **By SCV**: Which SCVs have had multiple duplicate bumps (repeat offenders)
- **By Submitter**: Which submitters have the most duplicate bumps
- **By Release**: Monthly trends in version bump activity
- **Summary**: Overall statistics comparing bump categories

This helps distinguish between:

1. **Duplicate bumps**: The submission is identical to the prior version - should not have had a version bump at all
2. **Non-substantive change bumps**: Core 4 classification fields unchanged, but minor fields may have changed
3. **Substantive change bumps**: Actual meaningful updates to classification-relevant fields

---

### Summary of Data Flow

```text
CVC Curation Tables / External Files
    ↓                                      ↓
cvc_clinvar_batches.batch_end_date ─→ 00 ─→ cvc_batches_enriched
                                          ↓
rejected-scvs.tsv        ─→ cvc_rejected_scvs (external table)
                                          ↓
                    ┌─────────────────────┴──────────────────────┐
                    ↓                                            ↓
         01 - Submitted Variants                   04 - Flagging Candidate Outcomes
                    ↓                                            ↓
         02 - Conflict Attribution                 05 - Version Bump Detection
                    ↓                                            ↓
         03 - Impact Analytics                     06 - Version Bump Intersection
```

## Flagging Status Report by Submitter (`10-flagging-status-report.sql`)

A standalone, parameterized report (not part of the `refresh_cvc_impact_analysis`
rebuild) that answers: **"For a given ClinVar release, what is the flagging status
of every SCV CVC submitted, broken down by submitter?"**

It reproduces the columns submitters receive in their post-processing email
notification — `SCV | Reason | Notes | Curation date` — and adds submitter
identity, the SCV state, the relevant anchor date, and aging.

### States reported

| State | Meaning | Anchor date used for aging |
|-------|---------|----------------------------|
| **flagged submission** | Flag applied (rank = -3) in the report release | First release the flag was applied (`first_flagged_date`) |
| **removed flagged submission** | Was flagged (rank = -3) at some point but no longer flagged in the report release — the flag was removed | Release the flag was removed (`flag_removed_date`) |
| **flagging candidate** | Submitted to and processed by ClinVar, never flagged (still pending or superseded by a newer submitter version) | Date ClinVar accepted/processed the batch (`batch_accepted_date`) |

Only CVC's own (non-rejected) flagging candidates are included, so NCBI-originated
flags are excluded. Rows are deduplicated to the most recent submission per SCV,
and SCVs that no longer exist in the report release (submitter-deleted) are dropped.

**Intentionally excluded ("resolved") categories** — these do not appear in any of
the three functions:

1. Flagging candidates **overridden by a newer submitter version** (the submitter
   put out a higher SCV version than the one CVC submitted).
2. Flagged submissions **intentionally removed via a CVC "remove flagged
   submission" request** (`removal_requested_date` present). Flags removed for
   other reasons (e.g. a submitter version bump with no CVC remove request) are
   **retained** as `removed flagged submission` rows.

**Manual hide list (`cvc_flagging_report_suppressions`):** individual
flagging-candidate submissions can be suppressed from the report by adding a row
to this table, keyed by `scv_id + scv_ver + batch_id` (see
`10-flagging-report-suppressions.sql`). Suppression is scoped to that exact
submission, so a **newer submission for the same SCV in a future batch is not
hidden** and re-enters the report. Add a row to hide a submission, delete the row
to un-hide it; deploy this table before the report table functions.

**Candidate disposition ("never flagged"):** a `flagging candidate` row is always
never-flagged (`was_ever_flagged` = FALSE, `first_flagged_date` IS NULL — a flag
that was applied and later removed is its own `removed flagged submission` state).
`candidate_disposition` classifies why it has not been flagged:

| `candidate_disposition` | Meaning |
|-------------------------|---------|
| `pending flag (within grace period)` | Still legitimately awaiting the flag |
| `never flagged — overridden by new submission version` | Submitter superseded our submitted version with a newer one — the dominant past-grace case |
| `never flagged — past grace, no flag applied` | Past grace, still the submitted version, flag never applied |

The by-submitter summary counts these as `never_flagged_overridden`,
`never_flagged_past_grace`, `never_flagged_total`, and `pending_in_grace`.

**Pending removal annotation:** a `flagged submission` row is flagged with
`pending_removal = TRUE` (Sheets: `Pending removal`) when a non-rejected
"remove flagged submission" request for the same SCV was submitted on or before
the report date but the flag is still applied — i.e. the SCV is currently flagged
yet already queued for removal. The removal request's date, batch, reason and
notes are surfaced alongside, and the by-submitter summary counts these as
`flagged_pending_removal`.

### Aging representations (both emitted)

- **Option A — Continuous** (`days_in_state`): days between the report release
  and the state anchor date. Best for "oldest first" triage and trend lines.
- **Option B — Buckets** (`aging_bucket`): `0-30 / 31-60 / 61-90 / 91-180 /
  181-365 / 365+` days. Best for at-a-glance staleness and the by-submitter
  aging matrix. For pending candidates, `grace_status` also states whether the
  SCV is still within its 60-day grace window or past it (`days_past_grace`).

### Objects produced (parameterized table functions)

Packaged as **table functions** so a `report_release_date` can be passed in —
ideal for a Looker Studio / Connected Sheets parameter + refresh workflow.

| Table function | Description |
|----------------|-------------|
| `cvc_flagging_status_report_fn(report_release_date DATE)` | Detail — one row per SCV (analysis-friendly snake_case columns) |
| `cvc_flagging_status_by_submitter_fn(report_release_date DATE)` | Summary — per submitter x state with an aging-bucket matrix |
| `sheets_flagging_status_report_fn(report_release_date DATE)` | Email-style column names for Looker Studio / Sheets |

`report_release_date` is snapped to the most recent **available** release on/before
the date via `clinvar_ingest.schema_on()`. Pass `NULL` for the latest release.
(Do not resolve releases via `clinvar_ingest.clinvar_releases` — it is a
periodically-refreshed external-table copy that can lag the real data.)

### Running the report

```sql
-- Latest release
SELECT * FROM `clinvar_curator.cvc_flagging_status_report_fn`(NULL);

-- Specific release (snaps to the most recent release on/before the date)
SELECT * FROM `clinvar_curator.cvc_flagging_status_report_fn`(DATE '2026-06-27');

-- Summary / email-style
SELECT * FROM `clinvar_curator.cvc_flagging_status_by_submitter_fn`(DATE '2026-06-27');
SELECT * FROM `clinvar_curator.sheets_flagging_status_report_fn`(DATE '2026-06-27');
```

### Looker Studio / Connected Sheets (parameter + refresh)

Use a **Custom Query** and expose `@report_release_date` as a report parameter
(type Date; default `CURRENT_DATE()` for latest):

```sql
SELECT * FROM `clinvar_curator.sheets_flagging_status_report_fn`(@report_release_date)
```

Changing the parameter control (or refreshing) re-runs the query against the
chosen release — no procedure call or materialized table to maintain.

## Related Documentation

- [Conflict Resolution Tracking Context](../conflict-resolution-tracking-context.md)
- [Curation Criteria Guide](../../clinvar-curation/CURATION_CRITERIA_GUIDE.md)
- [Resolution Reasons](../RESOLUTION-REASONS.md)
