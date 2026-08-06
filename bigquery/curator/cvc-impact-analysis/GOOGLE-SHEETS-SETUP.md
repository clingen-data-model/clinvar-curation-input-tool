# Google Sheets Dashboard Setup Guide

This guide explains how to set up Google Sheets dashboards using the visualization views created by the CVC Impact Analysis pipeline.

---

## Dashboard Overview (README Sheet)

Use the table below as a README sheet in your Google Sheets file. Replace `[Link]` with actual hyperlinks to each chart's sheet.

| Chart | Name | Purpose | BigQuery View | Link |
|-------|------|---------|---------------|------|
| 1a | Flagging Candidate Attrition Funnel | Compares total submitted flagging candidates with their outcome breakdown as a stacked bar | `sheets_flagging_candidate_funnel_pivoted` | [Link] |
| 1b | Flagging Candidate Outcome Pie | Shows the proportion of each outcome category as a pie chart | `sheets_flagging_candidate_pie` | [Link] |
| 2 | Version Bump Impact by Submitter | Per-submitter breakdown of flagging candidate outcomes showing which submitters are version-bumping | `sheets_version_bump_impact_by_submitter` | [Link] |
| 3a | Version Bump Timing Distribution | Shows WHEN version bumps occur relative to the 60-day grace period to detect strategic timing | `sheets_version_bump_timing` | [Link] |
| 3b | Version Bump Timing Summary | Simplified 2-bar comparison of within-grace vs after-grace totals | `sheets_version_bump_timing_summary` | [Link] |
| 4 | CVC Monthly Impact Summary | Monthly trends in CVC-attributed vs organic conflict resolutions | `sheets_cvc_impact_monthly` | [Link] |
| 5a | CVC Attribution Breakdown | Detailed monthly breakdown of resolution attribution types | `sheets_cvc_attribution_breakdown` | [Link] |
| 5b | CVC Attribution Pie | All-time summary pie chart of attribution categories (unfiltered) | `sheets_cvc_attribution_breakdown_pie` | [Link] |
| 6A | Batch Effectiveness: Rates | Grouped bar chart comparing resolution rate vs flag rate across CVC batches | `sheets_cvc_batch_effectiveness` | [Link] |
| 6B | Batch Effectiveness: Volume | Stacked bar showing variants resolved vs unresolved for each batch | `sheets_cvc_batch_effectiveness` | [Link] |
| 6C | Batch Effectiveness: Maturity | Bubble chart showing batch age (X) vs resolution rate (Y) with bubble size = submission volume | `sheets_cvc_batch_effectiveness` | [Link] |
| 7 | Cumulative Impact | Cumulative growth of CVC submissions, flags, and resolutions over time | `sheets_cvc_cumulative_impact` | [Link] |
| 8a | Version Bump Categories by Month | Monthly timeline showing duplicate, non-substantive, and substantive version changes | `sheets_duplicate_bumps_by_month` | [Link] |
| 8b | Duplicate Bumps by Submitter | Horizontal bar showing submitters with the most duplicate bumps (identical resubmissions) | `cvc_duplicate_bumps_by_submitter` | [Link] |
| 8c | Version Bump Summary | Overall statistics comparing duplicate, non-substantive, and substantive changes | `sheets_duplicate_bumps_summary` | [Link] |
| 9a | Auto-Reflag Actionable | Previously flagged SCVs from 7 target labs that lost their flag via version bump with no meaningful changes | `sheets_autoreflag_actionable` | [Link] |
| 9b | Auto-Reflag by Submitter | Per-submitter breakdown of auto-reflag eligible SCVs across the 7 target labs | `sheets_autoreflag_by_submitter` | [Link] |

### Key Insights by Chart

| Chart | Key Question Answered |
|-------|----------------------|
| 1a/1b | What happens to flagging candidate submissions? How many get flagged vs other outcomes? |
| 2 | Which submitters are avoiding flags through version bumps? |
| 3a/3b | Are submitters strategically timing version bumps to avoid the 60-day grace period deadline? |
| 4 | How do CVC-attributed resolutions compare to organic resolutions over time? |
| 5a/5b | What's driving CVC-attributed resolutions—flags, prompted deletions, or prompted reclassifications? |
| 6A/B/C | Which CVC batches have been most effective at driving conflict resolutions? |
| 7 | How has CVC's cumulative impact grown since the program started? |
| 8a/8b/8c | Which submitters and releases have duplicate bumps (identical resubmissions with zero field changes)? |
| 9a/9b | Which previously-flagged SCVs from 7 target labs should be auto-reflagged (no changes to classification, evidence summary, or condition)? |

### Data Refresh

- **Source**: BigQuery `clinvar_curator` dataset
- **Refresh frequency**: After each ClinVar release (~monthly) or when new CVC batches are submitted
- **Last pipeline run**: Check `cvc_impact_summary` table for latest `snapshot_release_date`

---

## Keeping Data Current

**Important:** The tables behind these charts are materialized (not live views). They only reflect data from when the pipeline was last run. If your charts are missing recent months, the pipeline needs to be re-run.

### Step 1: Verify which upstream data is available

The pipeline can only show data for ClinVar releases that have been fully processed through the temporal data collection pipeline. Check what's available:

```sql
-- Latest monthly conflict snapshot (drives Charts 4, 5a, 5b, 6, 7)
SELECT MAX(snapshot_release_date) FROM `clinvar_ingest.monthly_conflict_snapshots`;

-- Latest ClinVar release with SCV data (drives Charts 1-3, 8, 9)
SELECT MAX(end_release_date) FROM `clinvar_ingest.clinvar_scvs`;
```

If these dates are behind the current ClinVar release, the temporal data collection pipeline needs to run first (this is a separate upstream process — contact the data team).

### Step 2: Re-run the CVC Impact Analysis pipeline

Once upstream data is current, rebuild the materialized tables by either:

**Option A: Call the stored procedure (recommended after batch finalization)**

```sql
CALL `clinvar_curator.refresh_cvc_impact_analysis`();
```

This rebuilds all 11 materialized tables in dependency order. Takes 2-5 minutes. Can also be triggered from the batch finalization Apps Script.

**Option B: Run the shell script**

```bash
cd scripts/clinvar-curation/cvc-impact-analysis
./00-run-cvc-impact-analysis.sh --force
```

Or run individual phases if you know which charts are affected:

| Charts | Phase | Scripts to run | What they rebuild |
|--------|-------|----------------|-------------------|
| 4, 5a, 5b, 6, 7 | Phase 2: Impact Analysis | `01-cvc-submitted-variants.sql`, `02-cvc-conflict-attribution.sql`, `03-cvc-impact-analytics.sql` | Resolution attribution, monthly impact summary, batch effectiveness |
| 1a, 1b, 2, 3a, 3b | Phase 3: Flagging Analysis | `04-flagging-candidate-outcomes.sql`, `06-version-bump-flagging-intersection.sql`, `07-resubmission-candidates.sql` | Flagging candidate outcomes, version bump intersection |
| 8a, 8b, 8c | Phase 3: Version Bumps | `05-version-bump-detection.sql`, `full-record-version-bump-detection.sql` | Version bump tables |
| 9a, 9b | Phase 3: Auto-Reflag | `08-autoreflag-candidates.sql` | Auto-reflag candidates (depends on step 04) |

### Step 3: Refresh Google Sheets

After the pipeline completes, refresh the data in Google Sheets:
**Data** → **Data connectors** → **Refresh data**

### Quick diagnostic queries

```sql
-- Check when each key table was last built
SELECT 'cvc_impact_summary' AS table_name, MAX(snapshot_release_date) AS latest_date
FROM `clinvar_curator.cvc_impact_summary`
UNION ALL
SELECT 'cvc_resolution_attribution', MAX(snapshot_release_date)
FROM `clinvar_curator.cvc_resolution_attribution`
UNION ALL
SELECT 'cvc_flagging_candidate_outcomes', MAX(batch_accepted_date)
FROM `clinvar_curator.cvc_flagging_candidate_outcomes`
UNION ALL
SELECT 'cvc_version_bumps', MAX(current_start_date)
FROM `clinvar_curator.cvc_version_bumps`
UNION ALL
SELECT 'cvc_autoreflag_candidates', MAX(batch_accepted_date)
FROM `clinvar_curator.cvc_autoreflag_candidates`;
```

If any of these dates are significantly behind the latest `monthly_conflict_snapshots` date, that phase of the pipeline needs re-running.

---

## Outcome Category Reference

All flagging candidate submissions are categorized into exactly one of the following mutually exclusive outcome categories. Categories are numbered for consistent ordering across charts.

| # | Category | Column Name | Description |
|---|----------|-------------|-------------|
| 00 | Total Submitted | `00_Total_Submitted` | Total count of all flagging candidate submissions (used only in funnel chart) |
| 01 | Flagged | `01_Flagged` | CVC flag was successfully applied to the SCV (primary success) |
| 02 | Reclassified | `02_Reclassified` | Submitter changed their classification before/instead of being flagged (submitter success) |
| 03 | Removed | `03_Removed` | Submitter deleted their SCV before/instead of being flagged (submitter success) |
| 04 | Substantive Changes | `04_Substantive_Changes` | Submitter made real changes (rank, last_evaluated, trait, pmids) but kept the same classification |
| 05 | Within Grace Pending | `05_Within_Grace_Pending` | Recent submissions still within the 60-day grace period; outcome not yet determined |
| 06 | Version Bump During Grace | `06_Version_Bump_During_Grace` | Submitter resubmitted during grace period with no substantive changes (resets the clock) |
| 07 | Version Bump After Grace | `07_Version_Bump_After_Grace` | Submitter resubmitted after grace period with no substantive changes (avoided flag) |
| 08 | Stale at Submission | `08_Stale_at_Submission` | Submitted version was already outdated when NCBI accepted the batch (NCBI validation gap) |
| 09 | Unflagged | `09_Unflagged` | CVC submitted a "remove flagged submission" for this SCV after the flagging candidate was submitted (intentional CVC action) |
| 10 | Anomaly - Should Flag | `10_Anomaly_Should_Flag` | Past grace period, same version, still pending—should have been flagged (needs investigation) |
| 11 | Rejected by NCBI | `11_Rejected_by_NCBI` | NCBI rejected the submission before processing (excluded from outcome analysis) |
| 12 | Other/Unknown | `12_Other_Unknown` | Edge cases not fitting other categories |

### Category Groupings

| Group | Categories | Interpretation |
|-------|------------|----------------|
| **Success** | 01-03 (Flagged, Reclassified, Removed) | Conflict was addressed—either by CVC flag or submitter action |
| **Neutral** | 04 (Substantive Changes) | Submitter made real changes but maintained their classification |
| **In Progress** | 05 (Within Grace Pending) | Too early to determine outcome |
| **Concerning** | 06-07 (Version Bumps) | Submitter avoided flag without making substantive changes |
| **CVC Action** | 09 (Unflagged) | CVC explicitly requested flag removal after the original flagging candidate |
| **Process Issues** | 08, 10-11 (Stale, Anomaly, Rejected) | Issues requiring investigation or outside normal workflow |
| **Edge Cases** | 12 (Other/Unknown) | Rare situations not covered by other categories |

---

## Prerequisites

1. Access to BigQuery with the `clinvar_curator` dataset
2. Google Sheets with Connected Sheets enabled (requires Workspace account)
3. Pipeline has been run to populate the views

## Connecting BigQuery to Google Sheets

1. Open a new Google Sheet
2. Go to **Data** → **Data connectors** → **Connect to BigQuery**
3. Select the project `clingen-dev`
4. Navigate to `clinvar_curator` dataset
5. Select the view you want to visualize

---

## Chart 1a: Flagging Candidate Attrition Funnel

**View:** `sheets_flagging_candidate_funnel_pivoted`

**Purpose:** Compares total submitted flagging candidates with their outcome breakdown.

### Data Format

The view outputs two rows:
| sort_order | label | Total_Submitted | Flagged | Reclassified | ... |
|------------|-------|-----------------|---------|--------------|-----|
| 1 | Total Submitted | 5632 | 0 | 0 | ... |
| 2 | Breakdown | 0 | 2218 | 1002 | ... |

- **Row 1 (Total Submitted)**: Shows the total count in a single column, creating a solid bar
- **Row 2 (Breakdown)**: Shows each category as a stacked segment, summing to the same total

### Setup Steps

1. Connect to `clinvar_curator.sheets_flagging_candidate_funnel_pivoted`
2. Click **Extract** to pull the data into a regular sheet (this enables full charting options)
3. **Important**: Delete the `sort_order` column from your extracted data (it's only for ordering)
4. Select the extracted data range (all columns including header row, excluding sort_order)
5. Insert → Chart
6. Choose **Stacked bar chart**
7. In Chart Editor **Setup** tab:
   - Set **X-axis** to `label` column
   - Add all numeric columns as **Series** (Total_Submitted, Flagged, Reclassified, Removed, etc.)

### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Stacked Bar (horizontal) |
| Stacking | Stacked |
| Data range | All columns from the pivoted view (except sort_order) |

### Customizing Series Colors

1. Click on the chart → **Edit chart**
2. Go to **Customize** tab → **Series**
3. Select each series from the dropdown and set its color:

| Series (Column) | Color | Hex Code |
|-----------------|-------|----------|
| `Total_Submitted` | Blue | #4285F4 |
| `Flagged` | Dark Green | #1B7F37 |
| `Reclassified` | Light Green | #6AA84F |
| `Removed` | Light Green | #93C47D |
| `Substantive_Changes` | Yellow | #F1C232 |
| `Within_Grace_Pending` | Light Gray | #B7B7B7 |
| `Version_Bump_During_Grace` | Red | #CC0000 |
| `Version_Bump_After_Grace` | Orange | #E69138 |
| `Stale_at_Submission` | Light Purple | #B4A7D6 |
| `Unflagged` | Teal | #0097A7 |
| `Anomaly_Should_Flag` | Purple | #674EA7 |
| `Rejected_by_NCBI` | Gray | #666666 |
| `Other_Unknown` | Dark Gray | #999999 |

### Recommended Series Order (left to right in stacked bar)

For best visual impact, order the series so the total bar is first, then success outcomes on the left (start of bar):

1. `Total_Submitted` (blue) - Total count (only shows on "Total Submitted" row)
2. `Flagged` (dark green) - Primary success
3. `Reclassified` (light green) - Submitter success
4. `Removed` (light green) - Submitter success
5. `Substantive_Changes` (yellow) - Neutral
6. `Within_Grace_Pending` (light gray) - In progress
7. `Version_Bump_During_Grace` (red) - Concerning
8. `Version_Bump_After_Grace` (orange) - Concerning
9. `Stale_at_Submission` (light purple) - Process issue
10. `Unflagged` (teal) - CVC requested removal
11. `Anomaly_Should_Flag` (purple) - Needs investigation
12. `Rejected_by_NCBI` (gray) - Out of scope
13. `Other_Unknown` (dark gray) - Edge cases

To reorder series in Google Sheets:
1. Go to **Customize** → **Series**
2. Use the series dropdown and adjust order in the legend, or
3. Reorder columns in the source data extract

### Category Descriptions

| Category | Description |
|----------|-------------|
| Flagged | Flag was applied (success) |
| Reclassified | Submitter changed the classification (success) |
| Removed | Submitter deleted the SCV (success) |
| Substantive_Changes | Real changes made (rank, last_evaluated, etc.) but classification unchanged |
| Within_Grace_Pending | Recent batches still within 60-day grace period |
| Version_Bump_During_Grace | Version bumps with no substantive changes during 60-day grace period |
| Version_Bump_After_Grace | Version bumps with no substantive changes after grace period ended |
| Stale_at_Submission | Submitted version was already outdated when batch was accepted |
| Unflagged | CVC submitted a "remove flagged submission" after the flagging candidate (intentional) |
| Anomaly_Should_Flag | Past grace period, same version, but not flagged (needs investigation) |
| Rejected_by_NCBI | SCVs rejected by NCBI before processing |
| Other_Unknown | Edge cases not fitting other categories |

### Interpretation

- **Green segments** (Flagged, Reclassified, Removed): Success outcomes - either CVC flag applied or submitter took appropriate action
- **Red/Orange segments** (Version Bumps): Concerning pattern - submitters avoiding flags without making substantive changes
- **Yellow segment** (Substantive Changes): Neutral - submitters made real changes but kept the same classification
- **Light Purple segment** (Stale at Submission): Process issue where NCBI accepted a stale version reference
- **Teal segment** (Unflagged): CVC explicitly requested flag removal for these SCVs after the original flagging candidate
- **Purple segment** (Anomaly): SCVs that should have been flagged but weren't - needs investigation
- The total bar width represents all submitted flagging candidates (100%)

---

## Chart 1b: Flagging Candidate Outcome Pie Chart

**View:** `sheets_flagging_candidate_pie`

**Purpose:** Shows the proportion of each outcome category.

### Setup Steps

1. Connect to `clinvar_curator.sheets_flagging_candidate_pie`
2. Click **Extract** to pull the data into a regular sheet
3. Select the data range (all rows and columns)
4. Insert → Chart
5. Choose **Pie chart**
6. In Chart Editor **Setup** tab:
   - Set **Labels** to `category`
   - Set **Values** to `count`

### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Pie |
| Labels | category |
| Values | count |

### Slice Colors

| Category | Color | Hex Code |
|----------|-------|----------|
| Flagged | Dark Green | #1B7F37 |
| Reclassified | Light Green | #6AA84F |
| Removed | Medium Green | #93C47D |
| Substantive Changes | Yellow | #F1C232 |
| Within Grace Pending | Light Gray | #B7B7B7 |
| Version Bump During Grace | Red | #CC0000 |
| Version Bump After Grace | Orange | #E69138 |
| Stale at Submission | Light Purple | #B4A7D6 |
| Unflagged | Teal | #0097A7 |
| Anomaly - Should Flag | Purple | #674EA7 |
| Rejected by NCBI | Gray | #666666 |
| Other/Unknown | Dark Gray | #999999 |

---

## Chart 2: Version Bump Impact by Submitter

**View:** `sheets_version_bump_impact_by_submitter`

**Purpose:** Shows per-submitter breakdown of what happened to their flagging candidates.

### Setup Steps

1. Connect to `clinvar_curator.sheets_version_bump_impact_by_submitter`
2. Select all data
3. Insert → Chart
4. Choose **Stacked Bar chart**

### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Stacked Bar (horizontal) |
| X-axis | `submitter_name` |
| Series | All columns except `submitter_name` and `total_flagging_candidates` |
| Stacking | Stacked |

### Recommended Series Order (bottom to top)

1. `Flagged` (green)
2. `Reclassified` (blue)
3. `Removed` (light blue)
4. `Substantive_Changes` (yellow)
5. `Pending_Other` (gray)
6. `Version_Bump_During_Grace` (orange)
7. `Version_Bump_After_Grace` (red)

### Interpretation

- Submitters with large orange/red segments are avoiding flags through version bumps
- Yellow segments indicate submitters made real changes (last_evaluated, trait_set_id, pmids, etc.) but kept same classification
- Compare the green (flagged) portion across submitters
- Submitters with mostly green/blue segments are responding appropriately

---

## Chart 3a: Version Bump Timing Distribution

**View:** `sheets_version_bump_timing`

**Purpose:** Shows WHEN version bumps occur relative to the grace period to detect strategic timing.

### Setup Steps

1. Connect to `clinvar_curator.sheets_version_bump_timing`
2. Select all data
3. Insert → Chart
4. Choose **Column chart** or **Grouped Bar chart**

### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Column or Bar |
| X-axis | `days_bucket` |
| Series 1 | `version_bumps_no_change` (red/orange) |
| Series 2 | `version_changes_substantive` (blue) |
| Sort by | `sort_order` (ascending) |

### Time Buckets

| Bucket | Days | Grace Period Status |
|--------|------|---------------------|
| Before Acceptance | < 0 | N/A |
| Days 0-14 | 0-14 | Within grace |
| Days 15-30 | 15-30 | Within grace |
| Days 31-45 | 31-45 | Within grace |
| Days 46-60 (End of Grace) | 46-60 | End of grace period |
| Days 61-90 | 61-90 | After grace |
| Days 91-180 | 91-180 | After grace |
| Days 180+ | > 180 | Long after grace |

### Indicating the Grace Period Boundary

Google Sheets does not support reference lines on stacked column charts. Alternatives:

1. **Use color coding**: The "04. Days 46-60 (End of Grace)" bucket label indicates the boundary
2. **Add a text box**: Insert → Drawing → Text box with "← Within Grace | After Grace →" and position it above the chart between buckets 04 and 05
3. **Conditional formatting**: In the extracted data, highlight the row for bucket 04 to visually distinguish it

### Interpretation

- Spikes in the "Days 46-60" bucket suggest strategic timing to avoid flags
- Compare red (no change) vs blue (substantive) to see if changes are meaningful
- Activity after Day 60 shows continued pattern of bumping

---

## Chart 3b: Version Bump Timing Summary

**View:** `sheets_version_bump_timing_summary`

**Purpose:** Simplified 2-bar comparison showing totals within vs after the 60-day grace period for easy summing.

### Setup Steps

1. Connect to `clinvar_curator.sheets_version_bump_timing_summary`
2. Click **Extract** to pull the data into a regular sheet
3. Select all data (excluding sort_order column)
4. Insert → Chart
5. Choose **Column chart** (grouped bars)

### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Column or Bar |
| X-axis | `grace_period_label` |
| Series 1 | `version_bumps_no_change` (red/orange) |
| Series 2 | `version_changes_substantive` (blue) |

### Data Columns

| Column | Description |
|--------|-------------|
| `grace_period_label` | "Within Grace (0-60 days)" or "After Grace (61+ days)" |
| `total_version_changes` | Total version changes in this period |
| `unique_scvs` | Count of distinct SCVs with changes |
| `version_bumps_no_change` | Changes with no substantive modifications (concerning) |
| `version_changes_substantive` | Changes with real content modifications (neutral/positive) |

### Interpretation

- Compare the red bars (version bumps) between the two periods
- If "After Grace" has significant version bumps, submitters are avoiding flags after the deadline
- Substantive changes (blue) in either period indicate real updates were made

---

## Chart 4: CVC Monthly Impact Summary

**View:** `sheets_cvc_impact_monthly`

**Purpose:** Shows monthly trends in CVC impact on conflict resolution.

### Setup Steps

1. Connect to `clinvar_curator.sheets_cvc_impact_monthly`
2. Select all data
3. Insert → Chart
4. Choose **Line chart** or **Area chart**

### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Line or Stacked Area |
| X-axis | `month_label` |
| Series | `cvc_attributed_resolutions`, `organic_resolutions` |

### Interpretation

- Compare CVC-attributed resolutions to organic resolutions over time
- Look for trends as CVC submission volume increases

> **Note:** A filtered view (`sheets_cvc_impact_monthly_filtered`) is available if you want to exclude bulk downgrade events.

---

## Charts 5a/5b: CVC Resolution Attribution

### Background

When a ClinVar conflict resolves (one or more conflicting SCVs change so that the variant is no longer in conflict), the resolution may or may not be attributable to CVC's curation work. Attribution analysis answers: **"Did CVC's intervention cause this resolution, or would it have happened anyway?"**

Each resolved conflict is classified into one of five mutually exclusive attribution categories:

| Category | What it means | Why it matters |
|----------|--------------|----------------|
| **CVC Flagged** | CVC submitted a flagging candidate, the flag was applied (rank = -3), and the conflict subsequently resolved. The flag directly prompted the resolution. | Direct CVC impact — the strongest evidence that CVC intervention drove the outcome |
| **Submitter Deleted - CVC Prompted** | CVC submitted a flagging candidate for this variant, and the submitter deleted their SCV (rather than being flagged). The deletion resolved the conflict. | CVC-prompted impact — the submitter responded to CVC's submission by removing their assertion |
| **Submitter Reclassified - CVC Prompted** | CVC submitted a flagging candidate, and the submitter changed their classification. The reclassification resolved the conflict. | CVC-prompted impact — the submitter changed their assertion after CVC's intervention |
| **Organic** | The conflict resolved without any CVC involvement — CVC never submitted a flagging candidate for this variant. | Baseline resolution rate — conflicts that resolve on their own through normal ClinVar activity |
| **CVC Submitted, Organic Outcome** | CVC submitted a flagging candidate for this variant, but the resolution appears to have occurred independently (e.g., a different submitter not targeted by CVC changed their assertion). | Ambiguous — CVC was involved but likely didn't cause the resolution |

The green categories (CVC Flagged, Submitter Deleted, Submitter Reclassified) represent CVC's measurable impact. The blue categories (Organic, CVC Submitted Organic) represent resolutions that occurred outside CVC's direct influence.

> **Note:** Filtered views (`sheets_cvc_attribution_breakdown_filtered` and `sheets_cvc_attribution_breakdown_pie_filtered`) are available to exclude bulk downgrade events (e.g., Counsyl's mass reclassification in July 2025) which can distort the attribution picture.

---

## Chart 5a: CVC Attribution Breakdown

**View:** `sheets_cvc_attribution_breakdown`

**Purpose:** Monthly timeline showing how conflict resolutions are attributed across the five categories. Use this to track whether CVC's impact is growing over time, how it compares to organic resolution rates, and whether specific months show unusual patterns (e.g., a spike in organic resolutions from a bulk submitter action).

### Setup Steps

1. Connect to `clinvar_curator.sheets_cvc_attribution_breakdown`
2. Select all data
3. Insert → Chart
4. Choose **Stacked Area chart** or **Stacked Bar chart**

### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Stacked Area or Stacked Bar |
| X-axis | `month_label` |
| Series | `CVC_Flagged`, `Submitter_Deleted_CVC_Prompted`, `Submitter_Reclassified_CVC_Prompted`, `Organic`, `CVC_Submitted_Organic_Outcome` |

### Attribution Categories

| Category | Description |
|----------|-------------|
| CVC_Flagged | CVC flag directly caused resolution |
| Submitter_Deleted_CVC_Prompted | Submitter deleted SCV after CVC submission |
| Submitter_Reclassified_CVC_Prompted | Submitter reclassified after CVC submission |
| Organic | Resolution unrelated to CVC |
| CVC_Submitted_Organic_Outcome | CVC submitted but outcome was organic |

> **Note:** A filtered view (`sheets_cvc_attribution_breakdown_filtered`) is available if you want to exclude bulk downgrade events.

---

## Chart 5b: CVC Attribution Pie Chart

**View:** `sheets_cvc_attribution_breakdown_pie`

**Purpose:** All-time summary showing the overall proportion of each attribution category across all resolved conflicts. While Chart 5a shows trends over time, this chart answers the simple question: **"Of all conflicts that have ever resolved, what percentage were driven by CVC?"**

### Setup Steps

1. Connect to `clinvar_curator.sheets_cvc_attribution_breakdown_pie`
2. Click **Extract** to pull the data into a regular sheet
3. Select all data
4. Insert → Chart
5. Choose **Pie chart**

### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Pie |
| Labels | `category` |
| Values | `total_count` |

### Data Columns

| Column | Description |
|--------|-------------|
| `category` | Attribution type (CVC Flagged, Organic, etc.) |
| `total_count` | Total resolutions in this category across all time |
| `pct` | Percentage of total resolutions |

### Slice Colors

| Category | Color | Hex Code |
|----------|-------|----------|
| CVC Flagged | Dark Green | #1B7F37 |
| Submitter Deleted (CVC Prompted) | Light Green | #6AA84F |
| Submitter Reclassified (CVC Prompted) | Medium Green | #93C47D |
| Organic | Blue | #4285F4 |
| CVC Submitted, Organic Outcome | Light Blue | #A4C2F4 |

### Interpretation

- **Green slices** (CVC Flagged, Submitter Deleted, Submitter Reclassified) represent CVC-attributed resolutions — conflicts that resolved because of CVC's intervention
- **Blue slices** (Organic, CVC Submitted Organic) represent resolutions not attributed to CVC
- The total green percentage is CVC's overall attribution rate — the headline measure of program impact
- Compare the relative sizes of the three green slices to understand HOW CVC drives resolutions: primarily through flags being applied, or through prompting submitters to self-correct before flags are needed
- Consider using the filtered view (`sheets_cvc_attribution_breakdown_pie_filtered`) if bulk submitter events are skewing the proportions

---

## Chart 6: Batch Effectiveness

**View:** `sheets_cvc_batch_effectiveness`

**Purpose:** Compare effectiveness metrics across CVC batches to see which batches have been most successful at driving resolutions.

**Implementation:** The dashboard uses all three chart options (A, B, and C) to provide different perspectives on batch effectiveness.

### Data Columns

| Column | Description |
|--------|-------------|
| `batch_id` | CVC batch identifier (101, 102, etc.) |
| `batch_month` | Month/year label for the batch (e.g., "Aug '23") |
| `scvs_submitted` | Total SCVs submitted in this batch |
| `variants_targeted` | Unique variants targeted by this batch |
| `variants_resolved` | Number of targeted variants that have since resolved |
| `resolution_rate_pct` | % of targeted variants that resolved |
| `flag_rate_pct` | % of submissions that resulted in flags being applied |
| `days_since_submission` | Days since batch was submitted (older = more mature) |

---

### Chart 6A: Grouped Bar Chart (Comparing Rates)

**Best for:** Comparing resolution and flag rates across batches

#### Setup Steps

1. Connect to `clinvar_curator.sheets_cvc_batch_effectiveness`
2. Click **Extract** to pull data into a regular sheet
3. Select columns: `batch_month`, `resolution_rate_pct`, `flag_rate_pct`
4. Insert → Chart → **Bar chart**

#### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Bar chart (vertical) |
| X-axis | `batch_month` |
| Series 1 | `resolution_rate_pct` (Blue) |
| Series 2 | `flag_rate_pct` (Green) |
| Stacking | None (grouped bars side by side) |

#### Customize Tab Settings

- **Chart & axis titles**: Title = "Batch Effectiveness: Resolution vs Flag Rates"
- **Series**: Set Resolution Rate to blue (#4285F4), Flag Rate to green (#1B7F37)
- **Legend**: Position = Bottom

---

### Chart 6B: Stacked Bar Chart (Volume Breakdown)

**Best for:** Showing submission volume and how many resolved

#### Setup Steps

1. Connect to `clinvar_curator.sheets_cvc_batch_effectiveness`
2. Click **Extract** to pull data into a regular sheet
3. Select columns: `batch_month`, `variants_resolved`, `variants_targeted`
4. **Important**: Create a calculated column `variants_unresolved` = `variants_targeted` - `variants_resolved`
5. Select: `batch_month`, `variants_resolved`, `variants_unresolved`
6. Insert → Chart → **Stacked bar chart**

#### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Stacked bar chart (vertical) |
| X-axis | `batch_month` |
| Series 1 | `variants_resolved` (Green - bottom of stack) |
| Series 2 | `variants_unresolved` (Gray - top of stack) |

---

### Chart 6C: Bubble Chart (Maturity vs Effectiveness) ⭐ Recommended

**Best for:** Seeing if older batches have higher resolution rates, with bubble size showing batch volume

> **This is the primary implementation** used in the dashboard for visualizing batch maturity vs effectiveness.

#### Setup Steps (Bubble Chart)

Google Sheets bubble charts require columns in a specific order. Follow these steps exactly:

1. Connect to `clinvar_curator.sheets_cvc_batch_effectiveness`
2. Click **Extract** to pull data into a regular sheet
3. **Rearrange columns in this exact order** (left to right):
   - Column A: `batch_month` (this becomes the ID/Label)
   - Column B: `days_since_submission` (this becomes X-axis)
   - Column C: `resolution_rate_pct` (this becomes Y-axis)
   - Column D: `scvs_submitted` (this becomes bubble Size)
4. Select all four columns (A through D, including headers)
5. Insert → Chart → Choose **Bubble chart**

Google Sheets auto-assigns columns based on position:
- 1st column → ID (label)
- 2nd column → X-axis
- 3rd column → Y-axis
- 4th column → Size (optional)

#### Bubble Chart Setup Tab Configuration

After inserting the chart, verify in the **Setup** tab:

| Field | Should Be Set To |
|-------|------------------|
| ID | `batch_month` (Column A) |
| X-axis | `days_since_submission` (Column B) |
| Y-axis | `resolution_rate_pct` (Column C) |
| Size | `scvs_submitted` (Column D) |

If the Size field shows "None" or wrong column:

1. Click the **Size** dropdown
2. Select `scvs_submitted`
3. If it's not listed, your columns may not be in the correct order—rearrange and recreate the chart

#### Showing Labels on Bubbles

1. **Customize** tab → **Bubble** section
2. Check **Show bubble labels**
3. Labels will display the `batch_month` value on each bubble

---

### Interpretation (All Chart 6 Options)

- **Resolution rate** shows what % of variants CVC targeted have since resolved (by any means)
- **Flag rate** shows what % of SCVs actually got flagged (direct CVC success)
- Older batches (`days_since_submission` > 365) should have higher resolution rates as more time has passed
- If flag rate is high but resolution rate is low, flags may not be driving resolutions
- Batch 107 (Apr '24) shows unusually low resolution rate (13.5%) despite high flag rate (43.4%) - see [BATCH-107-ANALYSIS.md](BATCH-107-ANALYSIS.md) for investigation

---

## Chart 7: Cumulative Impact

**View:** `sheets_cvc_cumulative_impact`

**Purpose:** Shows cumulative growth in CVC activity and impact over time.

### Setup Steps

1. Connect to `clinvar_curator.sheets_cvc_cumulative_impact`
2. Select all data
3. Insert → Chart
4. Choose **Line chart**

### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Line |
| X-axis | `month_label` |
| Series | `cumulative_scvs_submitted`, `cumulative_cvc_resolutions`, `cumulative_organic_resolutions` |

---

## Charts 8a/8b/8c: Version Bump Analysis

### Background

When a submitter resubmits an SCV to ClinVar, the version number increments. But not all resubmissions represent meaningful changes. Some submitters resubmit with little or no modification to their assertion — a practice known as "version bumping." This is significant because version bumps can prevent or remove CVC flags without the submitter actually addressing the underlying clinical disagreement.

The version bump analysis classifies every version change in ClinVar into three mutually exclusive categories based on what changed between consecutive versions:

| Category | What it means | How it's detected | Concern Level |
|----------|--------------|-------------------|---------------|
| **Duplicate Bump** | The resubmission is identical to the prior version — nothing changed at all. The version increment should not have occurred. | All 20 comparable SCV fields are the same between versions | Most concerning |
| **Non-substantive Change Bump** | The 6 key classification-relevant fields are unchanged, but some minor fields (like `rank`, `review_status`, `origin`, etc.) changed. The submitter's actual clinical assertion is the same. | All 6 key fields unchanged, but at least one of the other 14 fields changed | Moderate concern |
| **Substantive Change** | At least one of the 6 key fields changed — the submitter made a real update to their clinical assertion. This is a legitimate resubmission. | At least one of the 6 key fields changed | Not concerning |

**Important:** Duplicate bumps are always a **subset** of non-substantive bumps. Every duplicate bump is also non-substantive (6 key fields unchanged), but not every non-substantive bump is a duplicate (minor fields may have changed). The `Nonsubstantive_Change_Bumps` column in Chart 8a shows the difference — cases where the 6 key fields didn't change but other fields did.

**The 6 key fields** (substantive change detection):

| Field | What it represents |
|-------|--------------------|
| `classif_type` | Classification category (e.g., Pathogenic, VUS) |
| `submitted_classification` | Free-text classification provided by the submitter |
| `last_evaluated` | Date the submitter last evaluated the variant |
| `trait_set_id` | The condition/disease associated with the assertion |
| `pmids` | Ordered list of PubMed citation IDs cited as evidence |
| `classification_comment` | Evidence summary / interpretation text |

**The other 14 fields** compared only in the full-record (20-field) duplicate bump check include structural fields (`statement_type`, `gks_proposition_type`), display fields (`classification_label`, `classification_abbrev`), metadata (`origin`, `affected_status`, `method_type`, `review_status`), and derived fields (`rank`, `clinsig_type`, `local_key`).

---

## Chart 8a: Version Bump Categories by Month

**View:** `sheets_duplicate_bumps_by_month`

**Purpose:** Shows monthly trends across the three version bump categories described above. Use this to identify whether version bumping is increasing over time, whether it's concentrated in certain months (which may correlate with CVC batch submissions), and whether the pattern is shifting between duplicate and non-substantive bumps.

### Setup Steps

1. Connect to `clinvar_curator.sheets_duplicate_bumps_by_month`
2. Click **Extract** to pull data into a regular sheet
3. Select columns: `month_label`, `Duplicate_Bumps`, `Nonsubstantive_Change_Bumps`, `Substantive_Change_Bumps`
4. Insert → Chart
5. Choose **Stacked Column chart**

### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Stacked Column |
| X-axis | `month_label` |
| Series 1 | `Duplicate_Bumps` (red - most concerning) |
| Series 2 | `Nonsubstantive_Change_Bumps` (orange - 5 fields same, others changed) |
| Series 3 | `Substantive_Change_Bumps` (blue - real changes) |

### Data Columns

| Column | Description |
|--------|-------------|
| `release_month` | First day of the month (for sorting) |
| `month_label` | Human-readable label (e.g., "Jan 2024") |
| `total_version_changes` | All version changes in this month |
| `Duplicate_Bumps` | Identical resubmissions: ALL 20 fields same (most concerning) |
| `Nonsubstantive_Change_Bumps` | 6 key fields same, but other minor fields changed |
| `Substantive_Change_Bumps` | Real changes made to classification-relevant fields |
| `duplicate_also_nonsubstantive` | Duplicate bumps also detected by 6-field check (should equal duplicates) |
| `duplicate_only` | Duplicates NOT detected by 6-field check (should be 0 - sanity check) |
| `duplicate_bump_pct` | % of changes that were duplicate bumps |
| `nonsubstantive_bump_pct` | % of changes that were non-substantive bumps |
| `pct_nonsubstantive_that_are_duplicate` | What % of non-substantive bumps are actually duplicates |
| `unique_scvs_duplicate_bumped` | Distinct SCVs with duplicate bumps |
| `unique_scvs_nonsubstantive_bumped` | Distinct SCVs with non-substantive bumps |

### Series Colors

| Series | Color | Hex Code |
|--------|-------|----------|
| `Duplicate_Bumps` | Red | #CC0000 |
| `Nonsubstantive_Change_Bumps` | Orange | #E69138 |
| `Substantive_Change_Bumps` | Blue | #4285F4 |

### Interpretation

- **Red (Duplicate Bumps)**: Most concerning - the submission is identical to the prior version and should not have had a version bump at all
- **Orange (Non-substantive Change)**: Detected by 6-field check but not 20-field - some minor fields changed but no classification-relevant updates
- **Blue (Substantive Change)**: Real changes made to classification-relevant fields - legitimate updates
- `pct_nonsubstantive_that_are_duplicate` tells you what portion of non-substantive bumps are pure duplicates
- If `duplicate_only > 0`, there's a data issue (duplicates should always be a subset of non-substantive)

---

## Chart 8b: Duplicate Bumps by Submitter

**View:** `cvc_duplicate_bumps_by_submitter`

**Purpose:** Identifies which submitters are most frequently resubmitting identical SCVs (duplicate bumps). This helps prioritize outreach or investigation — submitters with high duplicate bump counts and high `avg_bumps_per_scv` are systematically resubmitting the same records without changes, which may be an automated process or a deliberate strategy to avoid flags.

### Setup Steps

1. Connect to `clinvar_curator.cvc_duplicate_bumps_by_submitter`
2. Click **Extract** to pull data into a regular sheet
3. Sort by `duplicate_bumps` descending (should already be sorted)
4. Select columns: `submitter_name`, `duplicate_bumps`, `substantive_changes`
5. Insert → Chart
6. Choose **Horizontal Stacked Bar chart**

### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Horizontal Stacked Bar |
| Y-axis | `submitter_name` |
| Series 1 | `duplicate_bumps` (red) |
| Series 2 | `substantive_changes` (blue) |

### Data Columns

| Column | Description |
|--------|-------------|
| `submitter_id` | ClinVar submitter ID |
| `submitter_name` | Current submitter organization name |
| `unique_scvs_with_bumps` | Distinct SCVs that have had at least one duplicate bump |
| `total_version_changes` | Total version changes across all submitter's SCVs |
| `duplicate_bumps` | Count of duplicate bumps (identical resubmissions) |
| `substantive_changes` | Count of version changes with actual modifications |
| `duplicate_bump_pct` | Percentage of changes that were duplicate bumps |
| `avg_bumps_per_scv` | Average duplicate bumps per SCV (for SCVs with bumps) |
| `first_duplicate_bump_date` | Earliest duplicate bump by this submitter |
| `last_duplicate_bump_date` | Most recent duplicate bump |

### Series Colors

| Series | Color | Hex Code |
|--------|-------|----------|
| `duplicate_bumps` | Red | #CC0000 |
| `substantive_changes` | Blue | #4285F4 |

### Interpretation

- Submitters with high `duplicate_bumps` are frequently resubmitting identical records without any changes — all 20 comparable fields are the same between versions
- High `avg_bumps_per_scv` indicates repeat behavior on the same SCVs, suggesting a systematic pattern rather than isolated incidents
- Compare `duplicate_bump_pct` across submitters to identify outliers — a submitter whose version changes are 80%+ duplicate bumps is behaving very differently from one at 10%
- Look at the date range (`first_duplicate_bump_date` to `last_duplicate_bump_date`) to determine if the behavior is ongoing or was a one-time event
- Cross-reference with Charts 9a/9b (auto-reflag) to see whether these duplicate bumps are preventing CVC flags from being applied

---

## Chart 8c: Version Bump Summary

**View:** `sheets_duplicate_bumps_summary`

**Purpose:** All-time summary statistics across all submitters and all version changes, providing the big-picture view of version bump behavior in ClinVar. Use this as a reference table alongside Charts 8a and 8b to contextualize individual submitter or monthly patterns against the overall totals.

### Setup Steps

1. Connect to `clinvar_curator.sheets_duplicate_bumps_summary`
2. Click **Extract** to pull data into a regular sheet
3. The data is already in a two-column format (`metric`, `value`) — display as a table

### Data Format

The view unpivots the single-row summary into a vertical data table:

| metric | value |
|--------|-------|
| total_version_changes | 12345 |
| total_duplicate_bumps | 678 |
| total_nonsubstantive_bumps | 890 |
| ... | ... |

### Metrics Reference

| Metric | Description |
|--------|-------------|
| `total_version_changes` | Total consecutive version changes in the dataset |
| `total_duplicate_bumps` | Duplicate bumps: ALL 20 fields identical (most concerning) |
| `total_nonsubstantive_bumps` | Non-substantive bumps: 6 key fields identical |
| `duplicate_also_nonsubstantive` | Duplicate bumps also detected by 6-field check (should = duplicates) |
| `duplicate_only` | Duplicates NOT in non-substantive (should be 0 - sanity check) |
| `nonsubstantive_only` | Non-substantive bumps that aren't duplicates (5 fields same, others changed) |
| `total_substantive_changes` | Changes where classification-relevant fields changed |
| `overall_duplicate_bump_pct` | % of all changes that are duplicate bumps |
| `overall_nonsubstantive_bump_pct` | % of all changes that are non-substantive bumps |
| `pct_nonsubstantive_that_are_duplicate` | What % of non-substantive bumps are duplicates |
| `unique_scvs_with_version_changes` | Distinct SCVs that have had version changes |
| `unique_scvs_with_duplicate_bumps` | Distinct SCVs with at least one duplicate bump |
| `unique_scvs_with_nonsubstantive_bumps` | Distinct SCVs with at least one non-substantive bump |
| `unique_submitters_with_version_changes` | Submitters who have made version changes |
| `unique_submitters_with_duplicate_bumps` | Submitters with at least one duplicate bump |
| `earliest_version_change` | First version change date in dataset |
| `latest_version_change` | Most recent version change date |

### Key Metrics to Watch

- **`pct_nonsubstantive_that_are_duplicate`** — What portion of non-substantive bumps (6 key fields unchanged) are actually pure duplicates (all 20 fields unchanged). A high percentage means most non-substantive bumps are identical resubmissions that should not have had a version increment at all — the submitter changed nothing.
- **`overall_duplicate_bump_pct`** — What percentage of ALL version changes across ClinVar are duplicate bumps. This is the headline number for how prevalent the practice is.
- **`duplicate_only`** — A sanity check. This should always be 0 because every duplicate bump (20 fields same) should also be a non-substantive bump (6 fields same). A non-zero value indicates a data issue.
- **`unique_scvs_with_duplicate_bumps` vs `unique_scvs_with_version_changes`** — Shows what fraction of SCVs that have had any version change have also had at least one duplicate bump.

---

## Charts 9a/9b: Auto-Reflag Analysis

### Background

When CVC identifies an SCV as an outlier, it submits a "flagging candidate" to ClinVar. ClinVar then gives the submitter a 60-90 day grace period to respond before applying the flag (setting rank = -3). Some submitters respond by resubmitting their SCV — incrementing the version number — without making any meaningful changes to their classification, evidence summary, or condition. This "version bump" can either **prevent a flag from being applied** (if the bump occurs during the grace period, ClinVar treats it as a response and may not apply the flag) or **remove an existing flag** (if the flag was already applied, a new version resets the SCV and removes the flag).

In either case, if the submitter did not actually change their classification, evidence summary (the interpretation comment), or condition name, the original reason for flagging still stands and the SCV should be re-flagged.

**Auto-reflagging is limited to 7 target labs** where this pattern has been confirmed: LabCorp Genetics, CeGaT, Revvity (formerly PerkinElmer Genomics), OMIM, Baylor Genetics, Counsyl, and Eurofins. Other labs require manual review before re-flagging.

**Important filtering rules:**
- Only the **most recent** flagging candidate submission per SCV is considered, to avoid double-counting SCVs that were submitted across multiple batches.
- If CVC subsequently submitted a **"remove flagged submission"** for an SCV (requesting that the flag be taken off), that SCV is excluded — unless a newer flagging candidate submission was made after the remove request.

**The 6 substantive fields** compared between the submitted version and the current version are the same fields used by version bump detection (script 05):
- **Classification** (`classif_type`) — the clinical significance category (e.g., Pathogenic, VUS)
- **Submitted classification** (`submitted_classification`) — the free-text classification provided by the submitter
- **Last evaluated** (`last_evaluated`) — the date the submitter last evaluated the variant
- **Condition/trait** (`trait_set_id`) — the disease/condition associated with the variant-level assertion
- **PubMed citations** (`pmids`) — the ordered list of PubMed IDs cited as evidence
- **Evidence summary** (`classification_comment`) — the interpretation text or evidence description

If all 6 are unchanged, the SCV qualifies for auto-reflagging (same as a "version bump" in script 05). If any changed, it requires manual review.

**Related:** Prior work documented in [clingen-data-model/clinvar-curation-reporting#37](https://github.com/clingen-data-model/clinvar-curation-reporting/issues/37).

### Target Labs

| Lab | Description |
|-----|-------------|
| LabCorp Genetics | Laboratory Corporation of America |
| CeGaT | CeGaT GmbH |
| Revvity | Formerly PerkinElmer Genomics |
| OMIM | Online Mendelian Inheritance in Man |
| Baylor Genetics | Baylor College of Medicine |
| Counsyl | Genetic testing laboratory |
| Eurofins | Eurofins Clinical Genetics |

---

## Chart 9a: Auto-Reflag Actionable List

**View:** `sheets_autoreflag_actionable`

**Purpose:** The complete list of SCVs from the 7 target labs that were submitted as flagging candidates, are not currently flagged, and had a version change since submission. Each row shows whether the SCV qualifies for automatic re-flagging or needs manual review.

### Setup Steps

1. Connect to `clinvar_curator.sheets_autoreflag_actionable`
2. Click **Extract** to pull the data into a regular sheet
3. Sort by `Action` (Auto-Reflag first), then by `Submitter Name`
4. Optionally filter to only `Action = "Auto-Reflag"` rows for the submission-ready list

### Data Columns

| Column | Description |
|--------|-------------|
| `SCV ID` | The submission accession (e.g., SCV000123456) |
| `ClinVar VCV Link` | Click to view variant in ClinVar |
| `Variation ID` | Internal variation identifier |
| `Submitter Name` | Name of the submitting lab/organization |
| `Target Lab` | Which of the 7 target labs this belongs to |
| `Original Flagging Reason` | The reason CVC originally flagged this SCV |
| `Original Batch ID` | CVC batch that submitted the flagging candidate |
| `Original Submission Date` | When ClinVar accepted the flagging candidate submission |
| `Current Outcome` | Current status from flagging candidate outcomes tracking |
| `Was Ever Flagged` | "Yes" if ClinVar applied the flag at any point, or "No — Grace period bump" if the submitter prevented it |
| `Date Flag Applied` | When the flag (rank = -3) first appeared (blank if never flagged) |
| `Date Flag Removed` | When the flag was removed (blank if never flagged) |
| `Submitted SCV Version` | The SCV version number when CVC submitted the flagging candidate |
| `Current SCV Version` | The current version number of the SCV |
| `Version Bumps Since Submitted` | Number of version increments since the flagging candidate was submitted |
| `Current Classification` | Current classification abbreviation |
| `Current Classification Type` | Current classification type |
| `Changes Since Submission` | "None — Ready to Re-Flag" or a comma-separated list of which substantive fields changed (classification, submitted_classification, last_evaluated, trait_set_id, pmids, classification_comment) |
| `Action` | "Auto-Reflag" (all 6 substantive fields unchanged — eligible) or "Review Needed" (at least one changed) |

### Conditional Formatting Recommended

| Condition | Format | Purpose |
|-----------|--------|---------|
| `Action` = "Auto-Reflag" | Light green background | Ready for immediate re-flagging |
| `Action` = "Review Needed" | Light yellow background | Needs manual review before re-flagging |

### Interpretation

- **Auto-Reflag** rows: The submitter resubmitted with no changes to any of the 6 substantive fields (same as a "version bump" in the version bump detection). The original flagging reason still applies and the SCV should be re-flagged.
- **Review Needed** rows: At least one of the 6 substantive fields changed — check the `Changes Since Submission` column to see which. The change may or may not address the original flagging reason; a curator should review before deciding to re-flag.
- **Was Ever Flagged = "No"**: These SCVs were never flagged because the submitter bumped the version during the grace period. They are just as valid for re-flagging as SCVs that were flagged and then lost the flag.
- **Version Bumps Since Submitted** > 1 indicates the submitter resubmitted multiple times since the flagging candidate was submitted — a pattern of repeated avoidance.

---

## Chart 9b: Auto-Reflag by Submitter

**View:** `sheets_autoreflag_by_submitter`

**Purpose:** Per-submitter summary showing which of the 7 target labs have the most SCVs eligible for auto-reflagging, broken down by whether the SCVs were previously flagged or never flagged.

### Setup Steps

1. Connect to `clinvar_curator.sheets_autoreflag_by_submitter`
2. Click **Extract** to pull data into a regular sheet
3. Select columns: `Submitter Name`, `Ready to Auto-Reflag`, `Excluded - Has Changes`
4. Insert → Chart
5. Choose **Horizontal Stacked Bar chart**

### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Horizontal Stacked Bar |
| Y-axis | `Submitter Name` |
| Series 1 | `Ready to Auto-Reflag` (green) |
| Series 2 | `Excluded - Has Changes` (gray) |

### Data Columns

| Column | Description |
|--------|-------------|
| `Submitter Name` | Lab/organization name |
| `Ready to Auto-Reflag` | SCVs eligible for automatic re-flagging (all 6 substantive fields unchanged) |
| `Excluded - Has Changes` | SCVs where at least one of the 6 substantive fields changed |
| `Total Candidates` | Total SCVs from this lab that were submitted as flagging candidates and had a version change |
| `Previously Flagged` | Count of SCVs that were flagged (rank = -3) at some point then lost the flag |
| `Never Flagged - Grace Period Bump` | Count of SCVs that were never flagged because the submitter bumped during the grace period |
| `Classification Changed` | Count where classif_type changed |
| `Submitted Classification Changed` | Count where submitted_classification text changed |
| `Last Evaluated Changed` | Count where last_evaluated date changed |
| `Condition Changed` | Count where trait_set_id changed |
| `PMIDs Changed` | Count where pmids changed |
| `Evidence Summary Changed` | Count where classification_comment changed |
| `% Eligible for Auto-Reflag` | Percentage of total candidates eligible for auto-reflagging |
| `Unique Variants` | Number of distinct variants affected |

### Series Colors

| Series | Color | Hex Code |
|--------|-------|----------|
| `Ready to Auto-Reflag` | Green | #1B7F37 |
| `Excluded - Has Changes` | Gray | #B7B7B7 |

### Interpretation

- Labs with large green bars have many SCVs that should be auto-reflagged
- The `% Eligible for Auto-Reflag` shows what proportion of candidates qualify — a high percentage means the lab is consistently version-bumping without making meaningful changes
- The `Previously Flagged` vs `Never Flagged - Grace Period Bump` breakdown shows whether the lab is primarily avoiding flags during the grace period or removing them after the fact
- Check the change breakdown columns (`Classification Changed`, `Submitted Classification Changed`, `Last Evaluated Changed`, `Condition Changed`, `PMIDs Changed`, `Evidence Summary Changed`) to understand why excluded SCVs don't qualify

---

## Tips for Google Sheets Dashboards

### Performance

- Use **Extract** mode instead of **Live** for large datasets
- Set up scheduled refreshes (Data → Data connectors → Refresh options)
- Consider filtering to recent batches for faster loading

### Formatting

- Use consistent color schemes across charts
- Add chart titles that explain the insight, not just the data
- Include the data freshness date in a header cell

### Interactivity

- Add slicers for filtering by:
  - Batch ID
  - Submitter
  - Date range
- Link slicers across multiple charts for coordinated filtering

### Sharing

- Viewers need BigQuery access to see connected data
- Consider exporting static copies for broader distribution
- Use **Publish to web** for embedding in other tools

---

## Refresh Schedule

The underlying BigQuery views are refreshed when:

1. New ClinVar release is processed (~monthly)
2. New CVC batch is finalized (triggers `CALL clinvar_curator.refresh_cvc_impact_analysis()` via Apps Script or manually)
3. Pipeline is manually run with `./00-run-cvc-impact-analysis.sh --force`

Recommended Google Sheets refresh: **Weekly** or **After each ClinVar release**

---

## Troubleshooting

### "No data" in chart

- Verify the pipeline has been run: check that `cvc_flagging_version_bump_intersection` table exists
- Check BigQuery permissions
- Ensure the Connected Sheets connection is active

### Slow loading

- Switch from Live to Extract mode
- Add filters to reduce data volume
- Check if the underlying views need optimization

### Missing submitter names

- Some submitters may have NULL names if they were deleted
- The views filter for `deleted_release_date IS NULL` to show current names

### Funnel doesn't balance

- All categories should be mutually exclusive and sum to 100%
- If the math doesn't add up, check for NULL values in the source data
- The "Other/Unknown" category catches edge cases

### Anomaly SCVs showing up

- The "Anomaly - Should Be Flagged" category identifies SCVs that:
  - Are past the grace period
  - Have the same version as when submitted
  - Are still marked as "pending"
  - Do NOT have a subsequent "remove flagged submission" from CVC (those are categorized as "Unflagged")
- These need manual investigation in the ClinVar system
- Common causes: submitter disputed directly with NCBI, conflict resolved organically, or missing rejection record

### Unflagged SCVs

- The "Unflagged" category identifies SCVs where:
  - CVC submitted the SCV as a flagging candidate
  - CVC later submitted a "remove flagged submission" for the same SCV
  - The SCV is not currently flagged
- These are intentional CVC actions, not anomalies — CVC decided the flag should be removed
- Previously these were counted as anomalies, inflating the "should be flagged" count

### Stale at Submission SCVs

- The "Stale at Submission (NCBI missed)" category identifies SCVs where:
  - The submitter updated their SCV before the CVC batch was accepted by NCBI
  - NCBI should have rejected these submissions because the version was outdated
  - Instead, NCBI accepted the stale version reference
- These represent a gap in NCBI's validation process
- The submitted version in CVC is older than what was current in ClinVar at batch acceptance time
