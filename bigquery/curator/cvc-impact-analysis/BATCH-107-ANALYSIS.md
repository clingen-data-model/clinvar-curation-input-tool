# Batch 107 Resolution Rate Analysis

**Date:** January 2026
**Batch ID:** 107
**Submission Date:** May 6, 2024

---

## Summary

Batch 107 has an unusually low resolution rate of **13.5%** despite a high flag rate of **43.4%**. This analysis investigates the cause and explains why this batch is an outlier.

---

## Key Metrics

| Metric | Value |
|--------|-------|
| SCVs Submitted | 678 |
| Variants Targeted | 621 |
| SCVs Flagged | 294 (43.4%) |
| SCVs Deleted | 26 |
| SCVs Reclassified | 75 |
| Variants Resolved | 84 |
| Resolution Rate | 13.5% |
| Days Since Submission | 606 |

---

## Root Cause: Gene-Disease Relationship Targeting

The primary reason for the low resolution rate is that **batch 107 targeted a fundamentally different category of variants** compared to other batches.

### Curation Reason Breakdown for Batch 107

| Curation Reason | Count | % of Batch |
|-----------------|-------|------------|
| P/LP classification for a variant in a gene with insufficient evidence for a gene-disease relationship | 367 | **54.1%** |
| Outlier claim with insufficient supporting evidence | 192 | 28.3% |
| Claim with insufficient supporting evidence | 61 | 9.0% |
| Older claim that does not account for recent evidence | 49 | 7.2% |
| Other reasons | 9 | 1.4% |

### Comparison to Other Batches

| Batch | Primary Targeting Strategy | Resolution Rate |
|-------|----------------------------|-----------------|
| 106 | Outlier claims (70.9%) | 35.6% |
| **107** | **Gene-disease relationship (54.1%)** | **13.5%** |
| 108 | Outlier claims (40%) + older outliers (29%) | 37.7% |
| 111 | Outlier claims (67.4%) + older outliers (24.5%) | 44.2% |

---

## Why Gene-Disease Relationship Issues Are Harder to Resolve

When CVC flags an SCV as an "outlier with insufficient evidence," the submitter has clear, actionable options:
- Reclassify their submission
- Delete it
- Provide additional evidence

However, when the issue is about **gene-disease relationship evidence**, the problem is more fundamental:

1. **Not directly actionable by individual submitters** - The issue isn't with the submitter's interpretation of variant evidence, but with the underlying scientific question of whether the gene is actually associated with the disease

2. **Requires community consensus** - Resolving gene-disease relationship questions typically requires:
   - New research publications
   - Clinical studies
   - Expert panel reviews
   - ClinGen gene curation

3. **Timeline is measured in years, not months** - Unlike outlier corrections that can happen within weeks, gene-disease relationship evidence accumulates slowly through the scientific process

---

## Current Status of Batch 107 Variants

| Status | Count | Percentage |
|--------|-------|------------|
| Still unresolved | 509 | 82.0% |
| CVC-attributed resolution | 84 | 13.5% |
| Organic resolution | 29 | 4.7% |

### Resolution Attribution Breakdown

| Attribution Type | Count |
|------------------|-------|
| CVC Flagged | 56 |
| CVC Submitted (Organic Outcome) | 32 |
| CVC Prompted Reclassification | 18 |
| CVC Prompted Deletion | 10 |

---

## Outcome Distribution for Batch 107 Submissions

| Outcome | Count | Percentage |
|---------|-------|------------|
| Flagged | 294 | 43.4% |
| Resubmitted, same classification | 277 | 40.9% |
| Resubmitted, reclassified | 75 | 11.1% |
| Deleted | 26 | 3.8% |
| Pending (or rejected) | 6 | 0.9% |

The high "resubmitted, same classification" count (277 = 40.9%) is notable. These submitters maintained their P/LP classification despite the CVC submission questioning the gene-disease relationship, likely because they believe the gene-disease evidence is sufficient.

---

## Conclusions

1. **The low resolution rate is not a failure** - It reflects the nature of the variants being targeted

2. **Batch 107 was a strategic decision** to address a difficult but important category of conflicts in ClinVar

3. **Resolution will take time** - As gene-disease relationship evidence accumulates through ClinGen gene curation and other efforts, these conflicts should eventually resolve

4. **The high flag rate (43.4%) indicates success** in the immediate CVC goal of flagging problematic submissions

5. **Long-term monitoring recommended** - Re-evaluate this batch's resolution rate periodically (annually) to see if gene-disease evidence accumulation leads to more resolutions

---

## Queries Used for This Analysis

### Batch Effectiveness Comparison
```sql
SELECT
  batch_id,
  submission_date,
  variants_targeted,
  variants_resolved,
  resolution_rate_pct,
  flag_rate_pct,
  days_since_submission
FROM `clinvar_curator.cvc_batch_effectiveness`
WHERE batch_id IN ('105', '106', '107', '108', '109', '110', '111', '112')
ORDER BY batch_id
```

### Curation Reasons by Batch
```sql
SELECT
  batch_id,
  reason,
  COUNT(*) as count,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(PARTITION BY batch_id), 1) as pct_of_batch
FROM `clinvar_curator.cvc_submitted_variants`
WHERE batch_id IN ('106', '107', '108', '111')
  AND valid_submission = TRUE
GROUP BY batch_id, reason
ORDER BY batch_id, count DESC
```

### Resolution Attribution for Batch 107
```sql
SELECT
  CASE
    WHEN ra.variant_attribution IS NULL THEN 'not_resolved_yet'
    ELSE ra.variant_attribution
  END AS attribution,
  ra.primary_attribution,
  COUNT(*) as count
FROM (
  SELECT DISTINCT variation_id
  FROM `clinvar_curator.cvc_submitted_variants`
  WHERE batch_id = '107'
) b
LEFT JOIN `clinvar_curator.cvc_resolution_attribution` ra
  ON b.variation_id = ra.variation_id
  AND '107' IN UNNEST(ra.cvc_batch_ids)
GROUP BY ra.variant_attribution, ra.primary_attribution
ORDER BY count DESC
```
