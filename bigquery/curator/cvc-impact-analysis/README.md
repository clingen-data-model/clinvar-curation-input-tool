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
| `full-record-version-bump-detection.sql` | Comprehensive 19-field version bump detection |
| `09-refresh-cvc-impact-analysis.sql` | Stored procedure to rebuild all 11 materialized tables in dependency order |

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

## Related Documentation

- [Conflict Resolution Tracking Context](../conflict-resolution-tracking-context.md)
- [Curation Criteria Guide](../../clinvar-curation/CURATION_CRITERIA_GUIDE.md)
- [Resolution Reasons](../RESOLUTION-REASONS.md)
