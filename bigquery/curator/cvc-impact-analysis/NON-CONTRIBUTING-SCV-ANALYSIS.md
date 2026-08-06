# Non-Contributing SCV Submissions Analysis

**Date:** January 2026

---

## Summary

This analysis examines CVC flagging candidate submissions that were made against SCVs that were **not contributing** to the variant's conflict at the time of submission.

---

## Key Finding

**9.3%** of valid flagging candidate submissions (540 out of 5,841) were made against SCVs that were not contributing to the variant conflict at submission time.

---

## Overall Statistics

| Status at Submission Time | Count | Percentage |
|---------------------------|-------|------------|
| **Contributing to conflict** | 4,320 | **74.0%** |
| No snapshot found (new conflict or SCV) | 981 | 16.8% |
| **SCV was 0-star (not counted in conflict)** | 449 | **7.7%** |
| **Variant not in conflict at submission time** | 91 | **1.6%** |

---

## Non-Contributing Breakdown

### Category 1: 0-Star SCVs (7.7%)

**449 submissions** were made against SCVs with 0 stars (no assertion criteria provided).

- These SCVs are visible in ClinVar but don't count toward conflict calculations
- The conflict is determined by SCVs with 1+ stars
- Flagging these may be intentional to address low-quality submissions
- However, flagging them **won't directly resolve the conflict**

### Category 2: Variant Not in Conflict (1.6%)

**91 submissions** were made against SCVs where the variant wasn't in conflict at submission time.

This is more problematic and could indicate:
- The conflict resolved between annotation and submission
- A timing issue in the curation workflow
- Potential error in the curation process

### Category 3: No Snapshot Found (16.8%)

**981 submissions** had no matching snapshot data.

This likely represents:
- Newer conflicts that appeared after our snapshot history begins
- New SCVs not yet captured in monthly snapshots
- **Not necessarily errors** - just missing historical data

---

## Batch Analysis

### Batch with Highest Non-Contributing Rate

**Batch 127** had the highest percentage at **26.9%**:

| Metric | Value |
|--------|-------|
| Total submissions | 160 |
| Non-contributing | 43 (26.9%) |
| 0-star SCVs | 16 |
| Variant not in conflict | 27 |

Batch 127 stands out because **27 submissions** (16.9%) were against variants that weren't even in conflict at submission time—the highest absolute count of any batch.

### Top 10 Batches by Non-Contributing Rate

| Batch | Total | Contributing | 0-Star | Not in Conflict | No Snapshot | % Non-Contributing |
|-------|-------|--------------|--------|-----------------|-------------|-------------------|
| **127** | 160 | 89 | 16 | 27 | 28 | **26.9%** |
| 103 | 269 | 163 | 50 | 2 | 54 | 19.3% |
| 120 | 116 | 83 | 10 | 12 | 11 | 19.0% |
| 113 | 380 | 241 | 71 | 0 | 68 | 18.7% |
| 106 | 265 | 228 | 27 | 4 | 6 | 11.7% |
| 125 | 48 | 25 | 0 | 5 | 18 | 10.4% |
| 110 | 226 | 201 | 18 | 5 | 2 | 10.2% |
| 102 | 635 | 526 | 60 | 3 | 46 | 9.9% |
| 124 | 61 | 49 | 6 | 0 | 6 | 9.8% |
| 108 | 180 | 164 | 16 | 0 | 0 | 8.9% |

---

## Patterns Observed

### 0-Star Targeting Pattern

Batches 103 and 113 show high counts of 0-star SCV targeting:
- Batch 103: 50 submissions against 0-star SCVs
- Batch 113: 71 submissions against 0-star SCVs

This may reflect a deliberate strategy to flag low-quality submissions even though they don't contribute to the conflict calculation.

### Variant Not in Conflict Pattern

Batches with high "variant not in conflict" counts:
- Batch 127: 27 (most concerning)
- Batch 120: 12
- Batch 125: 5
- Batch 110: 5

These warrant investigation to understand why submissions were made against non-conflicting variants.

---

## Implications

### For Curation Workflow

1. **Pre-submission validation**: Consider adding a check to verify the SCV is in the contributing tier before finalizing the submission

2. **0-star SCVs**: Decide whether flagging 0-star SCVs is a valid use case or should be discouraged

3. **Conflict status verification**: Add a step to confirm the variant is still in conflict at submission time

### For Impact Analysis

1. **Resolution rate calculations**: Submissions against non-contributing SCVs shouldn't be expected to drive conflict resolution

2. **Batch effectiveness**: Batches with high non-contributing rates may show artificially lower effectiveness

3. **Success metrics**: Consider excluding non-contributing submissions from success rate calculations

---

## Queries Used

### Overall Status Summary

```sql
WITH submission_contribution_status AS (
  SELECT
    sv.batch_id,
    sv.annotation_id,
    sv.scv_id,
    sv.submission_date,
    sv.variation_id,
    snap.snapshot_release_date,
    snap.is_contributing,
    snap.vcv_is_conflicting,
    snap.scv_rank
  FROM `clinvar_curator.cvc_submitted_variants` sv
  LEFT JOIN `clinvar_ingest.monthly_conflict_scv_snapshots` snap
    ON sv.scv_id = snap.scv_id
    AND snap.snapshot_release_date <= sv.submission_date
  WHERE sv.action = 'flagging candidate'
    AND sv.valid_submission = TRUE
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY sv.annotation_id
    ORDER BY snap.snapshot_release_date DESC
  ) = 1
)

SELECT
  CASE
    WHEN is_contributing IS NULL THEN 'No snapshot found (new conflict or SCV)'
    WHEN is_contributing = TRUE THEN 'Contributing to conflict'
    WHEN vcv_is_conflicting = FALSE THEN 'Variant not in conflict at submission time'
    WHEN scv_rank = 0 THEN 'SCV was 0-star (not counted in conflict)'
    WHEN scv_rank < 0 THEN 'SCV was already flagged'
    ELSE 'SCV not in contributing tier (lower rank)'
  END AS status_at_submission,
  COUNT(*) as count,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 1) as pct
FROM submission_contribution_status
GROUP BY 1
ORDER BY count DESC
```

### Batch-Level Breakdown

```sql
WITH submission_contribution_status AS (
  SELECT
    sv.batch_id,
    sv.annotation_id,
    snap.is_contributing,
    snap.vcv_is_conflicting,
    snap.scv_rank,
    CASE
      WHEN snap.is_contributing IS NULL THEN 'no_snapshot'
      WHEN snap.is_contributing = TRUE THEN 'contributing'
      WHEN snap.vcv_is_conflicting = FALSE THEN 'variant_not_conflicting'
      WHEN snap.scv_rank = 0 THEN 'scv_0_star'
      WHEN snap.scv_rank < 0 THEN 'scv_already_flagged'
      ELSE 'not_in_tier'
    END AS status
  FROM `clinvar_curator.cvc_submitted_variants` sv
  LEFT JOIN `clinvar_ingest.monthly_conflict_scv_snapshots` snap
    ON sv.scv_id = snap.scv_id
    AND snap.snapshot_release_date <= sv.submission_date
  WHERE sv.action = 'flagging candidate'
    AND sv.valid_submission = TRUE
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY sv.annotation_id
    ORDER BY snap.snapshot_release_date DESC
  ) = 1
)

SELECT
  batch_id,
  COUNT(*) AS total,
  COUNTIF(status = 'contributing') AS contributing,
  COUNTIF(status = 'scv_0_star') AS scv_0_star,
  COUNTIF(status = 'variant_not_conflicting') AS variant_not_conflicting,
  COUNTIF(status = 'no_snapshot') AS no_snapshot,
  COUNTIF(status IN ('scv_0_star', 'variant_not_conflicting')) AS non_contributing_known,
  ROUND(COUNTIF(status IN ('scv_0_star', 'variant_not_conflicting')) * 100.0
        / NULLIF(COUNT(*), 0), 1) AS pct_non_contributing
FROM submission_contribution_status
GROUP BY batch_id
ORDER BY pct_non_contributing DESC
```

---

## Data Sources

- `clinvar_curator.cvc_submitted_variants` - CVC submission records
- `clinvar_ingest.monthly_conflict_scv_snapshots` - Monthly snapshots of SCV conflict contribution status
