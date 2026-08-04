-- =============================================================================
-- CVC Conflict Attribution Analysis
-- =============================================================================
--
-- Purpose:
--   Joins CVC-submitted variants with conflict resolution data to determine
--   which resolutions are attributable to CVC curation vs organic changes.
--
-- Dependencies:
--   - clinvar_curator.cvc_submitted_variants (from 01-cvc-submitted-variants.sql)
--   - clinvar_ingest.monthly_conflict_snapshots
--   - clinvar_ingest.monthly_conflict_scv_changes
--   - clinvar_ingest.conflict_vcv_change_detail
--
-- Output:
--   - clinvar_curator.cvc_variant_conflict_history
--   - clinvar_curator.cvc_resolution_attribution
--
-- =============================================================================

-- =============================================================================
-- Step 1: Track CVC variants through conflict snapshots over time
-- =============================================================================
-- This table shows the conflict status of each CVC-targeted variant
-- for every month since the variant was first submitted to CVC.

CREATE OR REPLACE TABLE `clinvar_curator.cvc_variant_conflict_history`
AS
WITH
-- Get all CVC-targeted variants with their first submission date
cvc_variants AS (
  SELECT DISTINCT
    variation_id,
    vcv_id,
    MIN(submission_date) AS first_cvc_submission_date,
    -- Find the first monthly snapshot after submission
    DATE_TRUNC(MIN(submission_date), MONTH) AS first_cvc_month
  FROM `clinvar_curator.cvc_submitted_variants`
  WHERE valid_submission = TRUE
  GROUP BY variation_id, vcv_id
),

-- Get all monthly snapshots for these variants
variant_snapshots AS (
  SELECT
    cv.variation_id,
    cv.vcv_id,
    cv.first_cvc_submission_date,
    ms.snapshot_release_date,
    ms.clinsig_conflict,
    ms.has_outlier,
    -- Derive conflict_rank_tier from rank
    CASE
      WHEN ms.rank = 0 THEN '0-star'
      WHEN ms.rank = 1 THEN '1-star'
      WHEN ms.rank IN (3, 4) THEN '3-4-star'
      ELSE CAST(ms.rank AS STRING) || '-star'
    END AS conflict_rank_tier,
    ms.agg_sig_type,
    -- Calculate months since first CVC submission
    DATE_DIFF(ms.snapshot_release_date, cv.first_cvc_submission_date, MONTH) AS months_since_cvc_submission,
    -- Flag if this is the first snapshot after CVC submission
    ROW_NUMBER() OVER (
      PARTITION BY cv.variation_id
      ORDER BY ms.snapshot_release_date
    ) = 1 AS is_first_post_cvc_snapshot
  FROM cvc_variants cv
  LEFT JOIN `clinvar_ingest.monthly_conflict_snapshots` ms
    ON ms.variation_id = cv.variation_id
    AND ms.snapshot_release_date >= cv.first_cvc_submission_date
),

-- Also include the snapshot BEFORE first CVC submission (baseline)
baseline_snapshots AS (
  SELECT
    cv.variation_id,
    cv.vcv_id,
    cv.first_cvc_submission_date,
    ms.snapshot_release_date,
    ms.clinsig_conflict,
    ms.has_outlier,
    -- Derive conflict_rank_tier from rank
    CASE
      WHEN ms.rank = 0 THEN '0-star'
      WHEN ms.rank = 1 THEN '1-star'
      WHEN ms.rank IN (3, 4) THEN '3-4-star'
      ELSE CAST(ms.rank AS STRING) || '-star'
    END AS conflict_rank_tier,
    ms.agg_sig_type,
    -1 AS months_since_cvc_submission,
    FALSE AS is_first_post_cvc_snapshot
  FROM cvc_variants cv
  LEFT JOIN `clinvar_ingest.monthly_conflict_snapshots` ms
    ON ms.variation_id = cv.variation_id
    AND ms.snapshot_release_date < cv.first_cvc_submission_date
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY cv.variation_id
    ORDER BY ms.snapshot_release_date DESC
  ) = 1
)

SELECT * FROM variant_snapshots
UNION ALL
SELECT * FROM baseline_snapshots
ORDER BY variation_id, snapshot_release_date
;


-- =============================================================================
-- Step 2: Identify resolutions and attribute them to CVC or organic causes
-- =============================================================================

CREATE OR REPLACE TABLE `clinvar_curator.cvc_resolution_attribution`
AS
WITH
-- Get all CVC submissions that could contribute to resolution
cvc_resolution_candidates AS (
  SELECT
    variation_id,
    scv_id,
    scv_ver,
    batch_id,
    submission_date,
    expected_flag_date,
    outcome,
    outcome_category,
    is_resolution_candidate,
    reason AS curation_reason
  FROM `clinvar_curator.cvc_submitted_variants`
  WHERE valid_submission = TRUE
    AND is_resolution_candidate = TRUE
),

-- Get all resolved conflicts from conflict_vcv_change_detail
resolved_conflicts AS (
  SELECT
    snapshot_release_date,
    prev_snapshot_release_date,
    variation_id,
    conflict_type,
    outlier_status,
    conflict_rank_tier,
    primary_reason,
    scv_reasons,
    scv_reasons_with_counts,
    scvs_flagged_count,
    scvs_first_time_flagged_count,
    scvs_removed_count,
    scvs_classification_changed_count
  FROM `clinvar_ingest.conflict_vcv_change_detail`
  WHERE vcv_change_status = 'resolved'
),

-- Get the SCV-level details for resolved variants
resolved_scv_details AS (
  SELECT
    scv.snapshot_release_date,
    scv.variation_id,
    scv.scv_id,
    scv.scv_change_status,
    scv.prev_scv_version,
    scv.curr_is_flagged,
    scv.prev_is_flagged,
    scv.is_first_time_flagged,
    scv.prev_is_contributing,
    scv.has_classification_change,
    scv.prev_submitted_classification,
    scv.curr_submitted_classification
  FROM `clinvar_ingest.monthly_conflict_scv_changes` scv
  INNER JOIN resolved_conflicts rc
    ON rc.variation_id = scv.variation_id
    AND rc.snapshot_release_date = scv.snapshot_release_date
  WHERE scv.prev_is_contributing = TRUE
    AND (
      scv.is_first_time_flagged = TRUE
      OR scv.scv_change_status = 'removed'
      OR scv.has_classification_change = TRUE
    )
),

-- Join resolved SCVs with CVC submissions to determine attribution
-- Attribution logic:
--   - CVC submitted version N and version N was flagged/deleted/reclassified = CVC attributed
--   - CVC submitted version N but version M resolved (M != N) = CVC submitted, organic outcome
--   - CVC submitted this SCV but other SCVs caused resolution = CVC submitted, organic outcome
--   - CVC never submitted this SCV = Organic
scv_attribution AS (
  SELECT
    rsd.*,
    crc.batch_id AS cvc_batch_id,
    crc.submission_date AS cvc_submission_date,
    crc.expected_flag_date AS cvc_expected_flag_date,
    crc.scv_ver AS cvc_submitted_version,
    crc.outcome AS cvc_outcome,
    crc.outcome_category AS cvc_outcome_category,
    crc.curation_reason AS cvc_curation_reason,
    -- Check if CVC submitted version matches the version that resolved
    (crc.scv_ver = rsd.prev_scv_version) AS version_matches,
    CASE
      -- Direct CVC flag attribution (version must match)
      WHEN rsd.is_first_time_flagged = TRUE
        AND crc.outcome = 'flagged'
        AND crc.scv_ver = rsd.prev_scv_version
        AND rsd.snapshot_release_date >= crc.expected_flag_date
        THEN 'cvc_flagged'
      -- CVC-prompted deletion: submitter deleted the SCV CVC submitted
      -- Any deletion after CVC notification is attributed (no timing restriction)
      WHEN rsd.scv_change_status = 'removed'
        AND crc.outcome = 'deleted'
        AND crc.scv_ver = rsd.prev_scv_version
        AND rsd.snapshot_release_date >= crc.submission_date
        THEN 'cvc_prompted_deletion'
      -- CVC-prompted reclassification: submitter changed classification on CVC-submitted version
      -- Any reclassification after CVC notification is attributed (no timing restriction)
      WHEN rsd.has_classification_change = TRUE
        AND crc.outcome = 'resubmitted, reclassified'
        AND crc.scv_ver = rsd.prev_scv_version
        AND rsd.snapshot_release_date >= crc.submission_date
        THEN 'cvc_prompted_reclassification'
      -- CVC submitted but version mismatch or outcome doesn't align
      -- This happens when CVC submitted version N but version M resolved
      WHEN crc.scv_id IS NOT NULL
        THEN 'cvc_submitted_but_organic'
      -- No CVC involvement at all
      ELSE 'organic'
    END AS attribution_type
  FROM resolved_scv_details rsd
  LEFT JOIN cvc_resolution_candidates crc
    ON crc.scv_id = rsd.scv_id
    AND crc.submission_date <= rsd.snapshot_release_date
),

-- Aggregate to variant level
variant_attribution AS (
  SELECT
    snapshot_release_date,
    variation_id,
    -- Count SCVs by attribution type
    COUNTIF(attribution_type = 'cvc_flagged') AS cvc_flagged_scvs,
    COUNTIF(attribution_type = 'cvc_prompted_deletion') AS cvc_prompted_deletion_scvs,
    COUNTIF(attribution_type = 'cvc_prompted_reclassification') AS cvc_prompted_reclassification_scvs,
    COUNTIF(attribution_type = 'cvc_submitted_but_organic') AS cvc_submitted_organic_scvs,
    COUNTIF(attribution_type = 'organic') AS organic_scvs,
    -- Collect CVC batch IDs involved
    ARRAY_AGG(DISTINCT cvc_batch_id IGNORE NULLS ORDER BY cvc_batch_id) AS cvc_batch_ids,
    -- Collect CVC curation reasons
    ARRAY_AGG(DISTINCT cvc_curation_reason IGNORE NULLS ORDER BY cvc_curation_reason) AS cvc_curation_reasons,
    -- Total contributing SCVs that changed
    COUNT(*) AS total_contributing_scvs_changed
  FROM scv_attribution
  GROUP BY snapshot_release_date, variation_id
)

SELECT
  rc.snapshot_release_date,
  rc.prev_snapshot_release_date,
  rc.variation_id,
  rc.conflict_type,
  rc.outlier_status,
  rc.conflict_rank_tier,
  rc.primary_reason,
  rc.scv_reasons_with_counts,
  va.cvc_flagged_scvs,
  va.cvc_prompted_deletion_scvs,
  va.cvc_prompted_reclassification_scvs,
  va.cvc_submitted_organic_scvs,
  va.organic_scvs,
  va.cvc_batch_ids,
  va.cvc_curation_reasons,
  va.total_contributing_scvs_changed,
  -- Determine overall variant attribution
  CASE
    WHEN va.cvc_flagged_scvs > 0
      OR va.cvc_prompted_deletion_scvs > 0
      OR va.cvc_prompted_reclassification_scvs > 0
      THEN 'cvc_attributed'
    WHEN va.cvc_submitted_organic_scvs > 0
      THEN 'cvc_submitted_organic'
    ELSE 'organic'
  END AS variant_attribution,
  -- More granular attribution
  CASE
    WHEN va.cvc_flagged_scvs > 0 THEN 'cvc_flagged'
    WHEN va.cvc_prompted_deletion_scvs > 0 THEN 'cvc_prompted_deletion'
    WHEN va.cvc_prompted_reclassification_scvs > 0 THEN 'cvc_prompted_reclassification'
    WHEN va.cvc_submitted_organic_scvs > 0 THEN 'cvc_submitted_organic'
    ELSE 'organic'
  END AS primary_attribution
FROM resolved_conflicts rc
LEFT JOIN variant_attribution va
  ON va.variation_id = rc.variation_id
  AND va.snapshot_release_date = rc.snapshot_release_date
ORDER BY rc.snapshot_release_date, rc.variation_id
;


-- =============================================================================
-- Step 3: Create summary view for attribution rates by month
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.cvc_attribution_by_month`
AS
SELECT
  snapshot_release_date,
  COUNT(*) AS total_resolutions,
  -- CVC-attributed resolutions
  COUNTIF(variant_attribution = 'cvc_attributed') AS cvc_attributed,
  COUNTIF(primary_attribution = 'cvc_flagged') AS cvc_flagged,
  COUNTIF(primary_attribution = 'cvc_prompted_deletion') AS cvc_prompted_deletion,
  COUNTIF(primary_attribution = 'cvc_prompted_reclassification') AS cvc_prompted_reclassification,
  -- Organic resolutions
  COUNTIF(variant_attribution = 'organic') AS organic,
  COUNTIF(variant_attribution = 'cvc_submitted_organic') AS cvc_submitted_organic,
  -- Attribution rates
  ROUND(100.0 * COUNTIF(variant_attribution = 'cvc_attributed') / COUNT(*), 1) AS cvc_attribution_rate,
  ROUND(100.0 * COUNTIF(variant_attribution = 'organic') / COUNT(*), 1) AS organic_rate,
  -- Breakdown by conflict type
  COUNTIF(variant_attribution = 'cvc_attributed' AND conflict_type = 'Clinsig') AS cvc_clinsig,
  COUNTIF(variant_attribution = 'cvc_attributed' AND conflict_type = 'Non-clinsig') AS cvc_non_clinsig,
  COUNTIF(variant_attribution = 'organic' AND conflict_type = 'Clinsig') AS organic_clinsig,
  COUNTIF(variant_attribution = 'organic' AND conflict_type = 'Non-clinsig') AS organic_non_clinsig
FROM `clinvar_curator.cvc_resolution_attribution`
GROUP BY snapshot_release_date
ORDER BY snapshot_release_date
;
