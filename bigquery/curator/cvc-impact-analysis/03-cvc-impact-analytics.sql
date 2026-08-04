-- =============================================================================
-- CVC Impact Analytics
-- =============================================================================
--
-- Purpose:
--   Creates comprehensive analytics tables and views for understanding
--   the impact of CVC curation on conflict resolution over time.
--
-- Dependencies:
--   - clinvar_curator.cvc_submitted_variants (from 01-cvc-submitted-variants.sql)
--   - clinvar_curator.cvc_resolution_attribution (from 02-cvc-conflict-attribution.sql)
--   - clinvar_ingest.monthly_conflict_snapshots
--   - clinvar_ingest.conflict_vcv_change_detail
--
-- Output:
--   Tables (materialized):
--   - clinvar_curator.cvc_impact_summary
--   - clinvar_curator.cvc_bulk_downgrade_exclusions
--   Views (live):
--   - clinvar_curator.cvc_batch_effectiveness
--   - clinvar_curator.cvc_reason_effectiveness
--   - Various Google Sheets optimized views
--
-- =============================================================================

-- =============================================================================
-- Monthly Impact Summary Table
-- =============================================================================
-- Comprehensive monthly summary comparing CVC impact to overall resolution trends

CREATE OR REPLACE TABLE `clinvar_curator.cvc_impact_summary`
AS
WITH
-- Get overall conflict counts by month
monthly_conflicts AS (
  SELECT
    snapshot_release_date,
    COUNT(*) AS total_conflicts,
    COUNTIF(clinsig_conflict) AS clinsig_conflicts,
    COUNTIF(NOT clinsig_conflict) AS nonclinsig_conflicts,
    COUNTIF(has_outlier) AS conflicts_with_outlier
  FROM `clinvar_ingest.monthly_conflict_snapshots`
  GROUP BY snapshot_release_date
),

-- Get resolution counts by month from change detail
monthly_resolutions AS (
  SELECT
    snapshot_release_date,
    COUNT(*) AS total_resolutions,
    COUNTIF(conflict_type = 'Clinsig') AS clinsig_resolutions,
    COUNTIF(conflict_type = 'Non-clinsig') AS nonclinsig_resolutions,
    COUNTIF(outlier_status = 'With Outlier') AS outlier_resolutions
  FROM `clinvar_ingest.conflict_vcv_change_detail`
  WHERE vcv_change_status = 'resolved'
  GROUP BY snapshot_release_date
),

-- Get CVC attribution by month
cvc_attribution AS (
  SELECT
    snapshot_release_date,
    COUNTIF(variant_attribution = 'cvc_attributed') AS cvc_attributed_resolutions,
    COUNTIF(primary_attribution = 'cvc_flagged') AS cvc_flagged_resolutions,
    COUNTIF(primary_attribution = 'cvc_prompted_deletion') AS cvc_prompted_deletion,
    COUNTIF(primary_attribution = 'cvc_prompted_reclassification') AS cvc_prompted_reclassification,
    COUNTIF(variant_attribution = 'organic') AS organic_resolutions,
    COUNTIF(variant_attribution = 'cvc_submitted_organic') AS cvc_submitted_organic
  FROM `clinvar_curator.cvc_resolution_attribution`
  GROUP BY snapshot_release_date
),

-- Get CVC submission activity by month
cvc_submissions AS (
  SELECT
    DATE_TRUNC(submission_date, MONTH) AS submission_month,
    COUNT(DISTINCT batch_id) AS batches_submitted,
    COUNT(*) AS scvs_submitted,
    COUNT(DISTINCT variation_id) AS variants_targeted,
    COUNTIF(outcome = 'flagged') AS scvs_flagged,
    COUNTIF(outcome = 'deleted') AS scvs_deleted,
    COUNTIF(outcome = 'resubmitted, reclassified') AS scvs_reclassified
  FROM `clinvar_curator.cvc_submitted_variants`
  WHERE valid_submission = TRUE
  GROUP BY DATE_TRUNC(submission_date, MONTH)
),

-- Get cumulative CVC statistics calculated at each submission month
cumulative_at_submission AS (
  SELECT
    submission_month,
    SUM(scvs_submitted) OVER (ORDER BY submission_month) AS cumulative_scvs_submitted,
    SUM(variants_targeted) OVER (ORDER BY submission_month) AS cumulative_variants_targeted,
    SUM(scvs_flagged) OVER (ORDER BY submission_month) AS cumulative_scvs_flagged
  FROM cvc_submissions
),

-- Generate all months from the first CVC submission to latest snapshot
-- This ensures we have a row for every month, even without submissions
all_months AS (
  SELECT DISTINCT DATE_TRUNC(snapshot_release_date, MONTH) AS month
  FROM `clinvar_ingest.monthly_conflict_snapshots`
  WHERE snapshot_release_date >= '2023-09-01'
),

-- Join all months with cumulative data, carrying forward the last known value
cumulative_cvc AS (
  SELECT
    am.month AS submission_month,
    -- Use LAST_VALUE to carry forward the cumulative total from the most recent
    -- month that had submissions (or NULL if before first submission)
    LAST_VALUE(cas.cumulative_scvs_submitted IGNORE NULLS) OVER (
      ORDER BY am.month
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_scvs_submitted,
    LAST_VALUE(cas.cumulative_variants_targeted IGNORE NULLS) OVER (
      ORDER BY am.month
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_variants_targeted,
    LAST_VALUE(cas.cumulative_scvs_flagged IGNORE NULLS) OVER (
      ORDER BY am.month
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_scvs_flagged
  FROM all_months am
  LEFT JOIN cumulative_at_submission cas
    ON am.month = cas.submission_month
)

SELECT
  mc.snapshot_release_date,
  -- Overall conflict status
  mc.total_conflicts,
  mc.clinsig_conflicts,
  mc.nonclinsig_conflicts,
  mc.conflicts_with_outlier,
  -- Resolution counts
  COALESCE(mr.total_resolutions, 0) AS total_resolutions,
  COALESCE(mr.clinsig_resolutions, 0) AS clinsig_resolutions,
  COALESCE(mr.nonclinsig_resolutions, 0) AS nonclinsig_resolutions,
  COALESCE(mr.outlier_resolutions, 0) AS outlier_resolutions,
  -- CVC attribution
  COALESCE(ca.cvc_attributed_resolutions, 0) AS cvc_attributed_resolutions,
  COALESCE(ca.cvc_flagged_resolutions, 0) AS cvc_flagged_resolutions,
  COALESCE(ca.cvc_prompted_deletion, 0) AS cvc_prompted_deletion,
  COALESCE(ca.cvc_prompted_reclassification, 0) AS cvc_prompted_reclassification,
  COALESCE(ca.organic_resolutions, 0) AS organic_resolutions,
  COALESCE(ca.cvc_submitted_organic, 0) AS cvc_submitted_organic,
  -- CVC submission activity (for the month the snapshot represents)
  COALESCE(cs.batches_submitted, 0) AS batches_submitted_this_month,
  COALESCE(cs.scvs_submitted, 0) AS scvs_submitted_this_month,
  COALESCE(cs.variants_targeted, 0) AS variants_targeted_this_month,
  -- Cumulative CVC statistics
  COALESCE(cc.cumulative_scvs_submitted, 0) AS cumulative_scvs_submitted,
  COALESCE(cc.cumulative_variants_targeted, 0) AS cumulative_variants_targeted,
  COALESCE(cc.cumulative_scvs_flagged, 0) AS cumulative_scvs_flagged,
  -- Attribution rates
  CASE
    WHEN mr.total_resolutions > 0
    THEN ROUND(100.0 * COALESCE(ca.cvc_attributed_resolutions, 0) / mr.total_resolutions, 1)
    ELSE 0
  END AS cvc_attribution_rate_pct,
  CASE
    WHEN mr.total_resolutions > 0
    THEN ROUND(100.0 * COALESCE(ca.organic_resolutions, 0) / mr.total_resolutions, 1)
    ELSE 0
  END AS organic_rate_pct,
  -- Resolution rate (resolutions as % of conflicts)
  CASE
    WHEN mc.total_conflicts > 0
    THEN ROUND(100.0 * COALESCE(mr.total_resolutions, 0) / mc.total_conflicts, 2)
    ELSE 0
  END AS resolution_rate_pct
FROM monthly_conflicts mc
LEFT JOIN monthly_resolutions mr ON mr.snapshot_release_date = mc.snapshot_release_date
LEFT JOIN cvc_attribution ca ON ca.snapshot_release_date = mc.snapshot_release_date
LEFT JOIN cvc_submissions cs ON cs.submission_month = DATE_TRUNC(mc.snapshot_release_date, MONTH)
LEFT JOIN cumulative_cvc cc ON cc.submission_month = DATE_TRUNC(mc.snapshot_release_date, MONTH)
WHERE mc.snapshot_release_date >= '2023-09-01'  -- Start from first CVC batch
ORDER BY mc.snapshot_release_date
;


-- =============================================================================
-- Batch Effectiveness Analysis
-- =============================================================================
-- Track how effective each CVC batch has been at driving resolutions
-- NOTE: Drop existing table first if migrating from TABLE to VIEW
DROP TABLE IF EXISTS `clinvar_curator.cvc_batch_effectiveness`;

CREATE OR REPLACE VIEW `clinvar_curator.cvc_batch_effectiveness`
AS
WITH
batch_submissions AS (
  SELECT
    batch_id,
    submission_date,
    submission_month_year,
    COUNT(*) AS scvs_submitted,
    COUNT(DISTINCT variation_id) AS variants_targeted,
    COUNTIF(outcome = 'flagged') AS scvs_flagged,
    COUNTIF(outcome = 'deleted') AS scvs_deleted,
    COUNTIF(outcome = 'resubmitted, reclassified') AS scvs_reclassified,
    COUNTIF(is_resolution_candidate) AS resolution_candidates
  FROM `clinvar_curator.cvc_submitted_variants`
  WHERE valid_submission = TRUE
  GROUP BY batch_id, submission_date, submission_month_year
),

-- Count how many resolutions each batch has contributed to
batch_resolutions AS (
  SELECT
    batch_id,
    COUNT(DISTINCT variation_id) AS variants_resolved
  FROM `clinvar_curator.cvc_resolution_attribution`,
  UNNEST(cvc_batch_ids) AS batch_id
  WHERE variant_attribution = 'cvc_attributed'
  GROUP BY batch_id
)

SELECT
  bs.batch_id,
  bs.submission_date,
  bs.submission_month_year,
  bs.scvs_submitted,
  bs.variants_targeted,
  bs.scvs_flagged,
  bs.scvs_deleted,
  bs.scvs_reclassified,
  bs.resolution_candidates,
  COALESCE(br.variants_resolved, 0) AS variants_resolved,
  -- Effectiveness metrics
  CASE
    WHEN bs.variants_targeted > 0
    THEN ROUND(100.0 * COALESCE(br.variants_resolved, 0) / bs.variants_targeted, 1)
    ELSE 0
  END AS resolution_rate_pct,
  CASE
    WHEN bs.scvs_submitted > 0
    THEN ROUND(100.0 * bs.scvs_flagged / bs.scvs_submitted, 1)
    ELSE 0
  END AS flag_rate_pct,
  -- Days since submission (for maturity tracking)
  DATE_DIFF(CURRENT_DATE(), bs.submission_date, DAY) AS days_since_submission
FROM batch_submissions bs
LEFT JOIN batch_resolutions br ON br.batch_id = bs.batch_id
ORDER BY bs.batch_id
;


-- =============================================================================
-- Curation Reason Effectiveness
-- =============================================================================
-- Analyze which curation reasons are most effective at driving resolutions
-- NOTE: Drop existing table first if migrating from TABLE to VIEW
DROP TABLE IF EXISTS `clinvar_curator.cvc_reason_effectiveness`;

CREATE OR REPLACE VIEW `clinvar_curator.cvc_reason_effectiveness`
AS
WITH
-- Count submissions by reason
reason_submissions AS (
  SELECT
    reason AS curation_reason,
    COUNT(*) AS times_used,
    COUNT(DISTINCT variation_id) AS variants_targeted,
    COUNTIF(outcome = 'flagged') AS scvs_flagged,
    COUNTIF(outcome = 'deleted') AS scvs_deleted,
    COUNTIF(outcome = 'resubmitted, reclassified') AS scvs_reclassified
  FROM `clinvar_curator.cvc_submitted_variants`
  WHERE valid_submission = TRUE
    AND reason IS NOT NULL
  GROUP BY reason
),

-- Count resolutions by reason
reason_resolutions AS (
  SELECT
    curation_reason,
    COUNT(DISTINCT variation_id) AS variants_resolved
  FROM `clinvar_curator.cvc_resolution_attribution`,
  UNNEST(cvc_curation_reasons) AS curation_reason
  WHERE variant_attribution = 'cvc_attributed'
  GROUP BY curation_reason
)

SELECT
  rs.curation_reason,
  rs.times_used,
  rs.variants_targeted,
  rs.scvs_flagged,
  rs.scvs_deleted,
  rs.scvs_reclassified,
  COALESCE(rr.variants_resolved, 0) AS variants_resolved,
  -- Effectiveness metrics
  CASE
    WHEN rs.variants_targeted > 0
    THEN ROUND(100.0 * COALESCE(rr.variants_resolved, 0) / rs.variants_targeted, 1)
    ELSE 0
  END AS resolution_rate_pct,
  CASE
    WHEN rs.times_used > 0
    THEN ROUND(100.0 * rs.scvs_flagged / rs.times_used, 1)
    ELSE 0
  END AS flag_rate_pct
FROM reason_submissions rs
LEFT JOIN reason_resolutions rr ON rr.curation_reason = rs.curation_reason
ORDER BY rs.times_used DESC
;


-- =============================================================================
-- Google Sheets Optimized Views
-- =============================================================================

-- Monthly summary for dashboard
CREATE OR REPLACE VIEW `clinvar_curator.sheets_cvc_impact_monthly`
AS
SELECT
  snapshot_release_date,
  FORMAT_DATE('%b %Y', snapshot_release_date) AS month_label,
  total_conflicts,
  total_resolutions,
  cvc_attributed_resolutions,
  organic_resolutions,
  cvc_attribution_rate_pct,
  organic_rate_pct,
  cumulative_scvs_submitted,
  cumulative_scvs_flagged
FROM `clinvar_curator.cvc_impact_summary`
ORDER BY snapshot_release_date
;

-- Attribution breakdown for stacked charts
CREATE OR REPLACE VIEW `clinvar_curator.sheets_cvc_attribution_breakdown`
AS
SELECT
  snapshot_release_date,
  FORMAT_DATE('%b %Y', snapshot_release_date) AS month_label,
  cvc_flagged_resolutions AS CVC_Flagged,
  cvc_prompted_deletion AS Submitter_Deleted_CVC_Prompted,
  cvc_prompted_reclassification AS Submitter_Reclassified_CVC_Prompted,
  organic_resolutions AS Organic,
  cvc_submitted_organic AS CVC_Submitted_Organic_Outcome
FROM `clinvar_curator.cvc_impact_summary`
ORDER BY snapshot_release_date
;

-- Attribution breakdown pie chart (all-time totals, unfiltered)
CREATE OR REPLACE VIEW `clinvar_curator.sheets_cvc_attribution_breakdown_pie`
AS
SELECT
  category,
  total_count,
  ROUND(100.0 * total_count / SUM(total_count) OVER (), 1) AS pct
FROM (
  SELECT 'CVC Flagged' AS category,
         SUM(cvc_flagged_resolutions) AS total_count
  FROM `clinvar_curator.cvc_impact_summary`
  UNION ALL
  SELECT 'Submitter Deleted (CVC Prompted)' AS category,
         SUM(cvc_prompted_deletion) AS total_count
  FROM `clinvar_curator.cvc_impact_summary`
  UNION ALL
  SELECT 'Submitter Reclassified (CVC Prompted)' AS category,
         SUM(cvc_prompted_reclassification) AS total_count
  FROM `clinvar_curator.cvc_impact_summary`
  UNION ALL
  SELECT 'Organic' AS category,
         SUM(organic_resolutions) AS total_count
  FROM `clinvar_curator.cvc_impact_summary`
  UNION ALL
  SELECT 'CVC Submitted, Organic Outcome' AS category,
         SUM(cvc_submitted_organic) AS total_count
  FROM `clinvar_curator.cvc_impact_summary`
)
WHERE total_count > 0
ORDER BY total_count DESC
;

-- Batch effectiveness for comparison charts
CREATE OR REPLACE VIEW `clinvar_curator.sheets_cvc_batch_effectiveness`
AS
SELECT
  batch_id,
  submission_month_year AS batch_month,
  scvs_submitted,
  variants_targeted,
  variants_resolved,
  resolution_rate_pct,
  flag_rate_pct,
  days_since_submission
FROM `clinvar_curator.cvc_batch_effectiveness`
ORDER BY batch_id
;

-- Curation reason effectiveness for comparison
CREATE OR REPLACE VIEW `clinvar_curator.sheets_cvc_reason_effectiveness`
AS
SELECT
  curation_reason,
  times_used,
  variants_targeted,
  variants_resolved,
  resolution_rate_pct,
  flag_rate_pct
FROM `clinvar_curator.cvc_reason_effectiveness`
ORDER BY times_used DESC
;

-- Cumulative impact over time
CREATE OR REPLACE VIEW `clinvar_curator.sheets_cvc_cumulative_impact`
AS
SELECT
  snapshot_release_date,
  FORMAT_DATE('%b %Y', snapshot_release_date) AS month_label,
  cumulative_scvs_submitted,
  cumulative_variants_targeted,
  cumulative_scvs_flagged,
  SUM(cvc_attributed_resolutions) OVER (ORDER BY snapshot_release_date) AS cumulative_cvc_resolutions,
  SUM(organic_resolutions) OVER (ORDER BY snapshot_release_date) AS cumulative_organic_resolutions,
  SUM(total_resolutions) OVER (ORDER BY snapshot_release_date) AS cumulative_total_resolutions
FROM `clinvar_curator.cvc_impact_summary`
ORDER BY snapshot_release_date
;


-- =============================================================================
-- Filtered Views: Excluding Bulk SCV Downgrade Events
-- =============================================================================
--
-- Purpose:
--   These views provide alternate versions of Chart 4 and Chart 5 data that
--   exclude conflict resolutions caused by bulk SCV star rating downgrades.
--
-- Background:
--   Two major bulk downgrade events significantly impacted resolution counts:
--   1. October 2024: PreventionGenetics (submitter_id: 239772) downgraded
--      ~15,000 SCVs from 1-star to 0-star, causing 2,864 conflict resolutions
--   2. July 2025: Counsyl (submitter_id: 320494) downgraded ~4,000 SCVs
--      from 1-star to 0-star, causing 800 conflict resolutions
--
--   These bulk events can skew the visualization of organic resolution trends.
--   The filtered views allow comparing CVC impact against a baseline that
--   excludes these outlier events.
--
-- Identification Method:
--   Resolutions are excluded when ALL of the following are true:
--   - primary_reason = 'scv_rank_downgraded'
--   - snapshot_release_date is in affected months (2024-10-09, 2025-07-06)
--   - At least one contributing SCV in that resolution was from the
--     submitter doing the bulk downgrade (verified via scv_changes join)
--
-- =============================================================================

-- Table to identify bulk downgrade resolutions
-- This is a lookup table of (snapshot_date, variation_id) pairs to exclude
CREATE OR REPLACE TABLE `clinvar_curator.cvc_bulk_downgrade_exclusions`
AS
WITH
-- Known bulk downgrade events
bulk_events AS (
  SELECT '2024-10-09' AS snapshot_date, 239772 AS submitter_id, 'PreventionGenetics' AS submitter_name UNION ALL
  SELECT '2025-07-06', 320494, 'Counsyl'
),

-- Find resolutions where primary reason is scv_rank_downgraded in those months
-- and at least one SCV from the bulk submitter was involved
bulk_resolutions AS (
  SELECT DISTINCT
    cd.snapshot_release_date,
    cd.variation_id,
    be.submitter_name AS bulk_event_submitter
  FROM `clinvar_ingest.conflict_vcv_change_detail` cd
  JOIN bulk_events be
    ON CAST(cd.snapshot_release_date AS STRING) = be.snapshot_date
  JOIN `clinvar_ingest.monthly_conflict_scv_changes` scv
    ON cd.variation_id = scv.variation_id
    AND cd.snapshot_release_date = scv.snapshot_release_date
  WHERE cd.vcv_change_status = 'resolved'
    AND cd.primary_reason = 'scv_rank_downgraded'
    AND scv.scv_change_status = 'rank_changed'
    AND CAST(scv.curr_submitter_id AS INT64) = be.submitter_id
)

SELECT
  snapshot_release_date,
  variation_id,
  bulk_event_submitter,
  'bulk_scv_rank_downgrade' AS exclusion_reason
FROM bulk_resolutions
ORDER BY snapshot_release_date, variation_id
;


-- =============================================================================
-- Chart 4 Filtered: Monthly Impact Summary (Excluding Bulk Downgrades)
-- =============================================================================
--
-- Same as sheets_cvc_impact_monthly but excludes resolutions from bulk
-- SCV downgrade events to show organic resolution trends more clearly.
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.sheets_cvc_impact_monthly_filtered`
AS
WITH
-- Get filtered resolution counts (excluding bulk downgrades)
filtered_resolutions AS (
  SELECT
    cd.snapshot_release_date,
    COUNT(*) AS total_resolutions,
    COUNTIF(cd.conflict_type = 'Clinsig') AS clinsig_resolutions,
    COUNTIF(cd.conflict_type = 'Non-clinsig') AS nonclinsig_resolutions,
    COUNTIF(cd.outlier_status = 'With Outlier') AS outlier_resolutions
  FROM `clinvar_ingest.conflict_vcv_change_detail` cd
  LEFT JOIN `clinvar_curator.cvc_bulk_downgrade_exclusions` excl
    ON cd.variation_id = excl.variation_id
    AND cd.snapshot_release_date = excl.snapshot_release_date
  WHERE cd.vcv_change_status = 'resolved'
    AND excl.variation_id IS NULL  -- Exclude bulk downgrades
  GROUP BY cd.snapshot_release_date
),

-- Get filtered CVC attribution (excluding bulk downgrades)
filtered_attribution AS (
  SELECT
    ra.snapshot_release_date,
    COUNTIF(ra.variant_attribution = 'cvc_attributed') AS cvc_attributed_resolutions,
    COUNTIF(ra.primary_attribution = 'cvc_flagged') AS cvc_flagged_resolutions,
    COUNTIF(ra.primary_attribution = 'cvc_prompted_deletion') AS cvc_prompted_deletion,
    COUNTIF(ra.primary_attribution = 'cvc_prompted_reclassification') AS cvc_prompted_reclassification,
    COUNTIF(ra.variant_attribution = 'organic') AS organic_resolutions,
    COUNTIF(ra.variant_attribution = 'cvc_submitted_organic') AS cvc_submitted_organic
  FROM `clinvar_curator.cvc_resolution_attribution` ra
  LEFT JOIN `clinvar_curator.cvc_bulk_downgrade_exclusions` excl
    ON ra.variation_id = excl.variation_id
    AND ra.snapshot_release_date = excl.snapshot_release_date
  WHERE excl.variation_id IS NULL  -- Exclude bulk downgrades
  GROUP BY ra.snapshot_release_date
)

SELECT
  ims.snapshot_release_date,
  FORMAT_DATE('%b %Y', ims.snapshot_release_date) AS month_label,
  ims.total_conflicts,
  COALESCE(fr.total_resolutions, 0) AS total_resolutions,
  COALESCE(fa.cvc_attributed_resolutions, 0) AS cvc_attributed_resolutions,
  COALESCE(fa.organic_resolutions, 0) AS organic_resolutions,
  -- Recalculate attribution rate with filtered numbers
  CASE
    WHEN fr.total_resolutions > 0
    THEN ROUND(100.0 * COALESCE(fa.cvc_attributed_resolutions, 0) / fr.total_resolutions, 1)
    ELSE 0
  END AS cvc_attribution_rate_pct,
  CASE
    WHEN fr.total_resolutions > 0
    THEN ROUND(100.0 * COALESCE(fa.organic_resolutions, 0) / fr.total_resolutions, 1)
    ELSE 0
  END AS organic_rate_pct,
  ims.cumulative_scvs_submitted,
  ims.cumulative_scvs_flagged,
  -- Include exclusion count for transparency
  COALESCE(
    (SELECT COUNT(*) FROM `clinvar_curator.cvc_bulk_downgrade_exclusions` e
     WHERE e.snapshot_release_date = ims.snapshot_release_date),
    0
  ) AS excluded_bulk_downgrades
FROM `clinvar_curator.cvc_impact_summary` ims
LEFT JOIN filtered_resolutions fr
  ON fr.snapshot_release_date = ims.snapshot_release_date
LEFT JOIN filtered_attribution fa
  ON fa.snapshot_release_date = ims.snapshot_release_date
ORDER BY ims.snapshot_release_date
;


-- =============================================================================
-- Chart 5 Filtered: Attribution Breakdown (Excluding Bulk Downgrades)
-- =============================================================================
--
-- Same as sheets_cvc_attribution_breakdown but excludes resolutions from bulk
-- SCV downgrade events for cleaner stacked chart visualization.
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.sheets_cvc_attribution_breakdown_filtered`
AS
WITH
filtered_attribution AS (
  SELECT
    ra.snapshot_release_date,
    COUNTIF(ra.primary_attribution = 'cvc_flagged') AS cvc_flagged_resolutions,
    COUNTIF(ra.primary_attribution = 'cvc_prompted_deletion') AS cvc_prompted_deletion,
    COUNTIF(ra.primary_attribution = 'cvc_prompted_reclassification') AS cvc_prompted_reclassification,
    COUNTIF(ra.variant_attribution = 'organic') AS organic_resolutions,
    COUNTIF(ra.variant_attribution = 'cvc_submitted_organic') AS cvc_submitted_organic
  FROM `clinvar_curator.cvc_resolution_attribution` ra
  LEFT JOIN `clinvar_curator.cvc_bulk_downgrade_exclusions` excl
    ON ra.variation_id = excl.variation_id
    AND ra.snapshot_release_date = excl.snapshot_release_date
  WHERE excl.variation_id IS NULL  -- Exclude bulk downgrades
  GROUP BY ra.snapshot_release_date
)

SELECT
  fa.snapshot_release_date,
  FORMAT_DATE('%b %Y', fa.snapshot_release_date) AS month_label,
  fa.cvc_flagged_resolutions AS CVC_Flagged,
  fa.cvc_prompted_deletion AS Submitter_Deleted_CVC_Prompted,
  fa.cvc_prompted_reclassification AS Submitter_Reclassified_CVC_Prompted,
  fa.organic_resolutions AS Organic,
  fa.cvc_submitted_organic AS CVC_Submitted_Organic_Outcome,
  -- Include exclusion count for transparency
  COALESCE(
    (SELECT COUNT(*) FROM `clinvar_curator.cvc_bulk_downgrade_exclusions` e
     WHERE e.snapshot_release_date = fa.snapshot_release_date),
    0
  ) AS excluded_bulk_downgrades
FROM filtered_attribution fa
ORDER BY fa.snapshot_release_date
;
