-- =============================================================================
-- CVC Submitted Variants Tracking Table
-- =============================================================================
--
-- Purpose:
--   Creates a comprehensive table of all CVC-submitted SCVs with their outcomes,
--   batch information, and the expected timeline for flag application.
--
-- Dependencies:
--   - clinvar_curator.cvc_clinvar_batches
--   - clinvar_curator.cvc_clinvar_submissions
--   - clinvar_curator.cvc_submitted_outcomes_view
--   - clinvar_ingest.clinvar_scvs (for variation_id lookup)
--
-- Output:
--   - clinvar_curator.cvc_submitted_variants
--
-- =============================================================================

CREATE OR REPLACE TABLE `clinvar_curator.cvc_submitted_variants`
AS
WITH
-- Get the submitted outcomes with all relevant metadata
submitted_outcomes AS (
  SELECT
    sov.annotation_id,
    sov.batch_id,
    sov.batch_release_date,
    sov.submission_date,
    sov.submission_month_year,
    sov.submission_yy_mm,
    sov.variation_id,
    sov.vcv_id,
    sov.vcv_ver,
    sov.scv_id,
    sov.scv_ver,
    sov.submitter_id,
    sov.action,
    sov.reason,
    sov.curator,
    sov.annotated_date,
    sov.annotation_release_date,
    -- Derive valid_submission from invalid_submission_reason
    (sov.invalid_submission_reason IS NULL) AS valid_submission,
    sov.invalid_submission_reason,
    sov.outcome,
    sov.report_release_date,
    -- Calculate expected flag application date (60 days after batch submission)
    DATE_ADD(sov.submission_date, INTERVAL 60 DAY) AS expected_flag_date,
    -- Determine if this is a "successful" curation (led to flag, deletion, or reclassification)
    CASE
      WHEN sov.outcome = 'flagged' THEN 'cvc_flagged'
      WHEN sov.outcome = 'deleted' THEN 'submitter_deleted'
      WHEN sov.outcome = 'resubmitted, reclassified' THEN 'submitter_reclassified'
      WHEN sov.outcome = 'resubmitted, same classification' THEN 'submitter_updated_no_change'
      WHEN sov.outcome = 'pending (or rejected)' THEN 'pending'
      WHEN sov.outcome = 'invalid submission' THEN 'invalid'
      ELSE 'unknown'
    END AS outcome_category,
    -- Determine if this outcome could contribute to resolution
    CASE
      WHEN sov.outcome IN ('flagged', 'deleted', 'resubmitted, reclassified') THEN TRUE
      ELSE FALSE
    END AS is_resolution_candidate
  FROM `clinvar_curator.cvc_submitted_outcomes_view` sov
),

-- Get the first submission date for each SCV (to handle resubmissions)
first_submission AS (
  SELECT
    scv_id,
    MIN(submission_date) AS first_submission_date,
    MIN(batch_id) AS first_batch_id
  FROM submitted_outcomes
  WHERE valid_submission = TRUE
  GROUP BY scv_id
)

SELECT
  so.*,
  fs.first_submission_date,
  fs.first_batch_id,
  (so.batch_id = fs.first_batch_id) AS is_first_submission
FROM submitted_outcomes so
LEFT JOIN first_submission fs ON so.scv_id = fs.scv_id
ORDER BY so.batch_id, so.scv_id
;

-- =============================================================================
-- Summary Statistics View
-- =============================================================================
-- Provides aggregate statistics for CVC submissions by batch and outcome

CREATE OR REPLACE VIEW `clinvar_curator.cvc_submission_summary`
AS
SELECT
  batch_id,
  submission_date,
  submission_month_year,
  COUNT(*) AS total_submissions,
  COUNTIF(valid_submission) AS valid_submissions,
  COUNTIF(NOT valid_submission) AS invalid_submissions,
  COUNTIF(outcome = 'flagged') AS flagged,
  COUNTIF(outcome = 'deleted') AS deleted,
  COUNTIF(outcome = 'resubmitted, reclassified') AS reclassified,
  COUNTIF(outcome = 'resubmitted, same classification') AS updated_same_class,
  COUNTIF(outcome = 'pending (or rejected)') AS pending,
  COUNTIF(is_resolution_candidate) AS resolution_candidates,
  COUNT(DISTINCT variation_id) AS unique_variants,
  COUNT(DISTINCT CASE WHEN is_resolution_candidate THEN variation_id END) AS resolution_candidate_variants
FROM `clinvar_curator.cvc_submitted_variants`
GROUP BY batch_id, submission_date, submission_month_year
ORDER BY batch_id
;

-- =============================================================================
-- CVC Variants with Conflict Potential View
-- =============================================================================
-- Shows all unique variants that CVC has targeted, with their cumulative outcomes

CREATE OR REPLACE VIEW `clinvar_curator.cvc_targeted_variants`
AS
SELECT
  variation_id,
  vcv_id,
  MIN(submission_date) AS first_cvc_submission_date,
  MAX(submission_date) AS latest_cvc_submission_date,
  COUNT(DISTINCT scv_id) AS total_scvs_submitted,
  COUNT(DISTINCT batch_id) AS batches_involved,
  COUNTIF(outcome = 'flagged') AS scvs_flagged,
  COUNTIF(outcome = 'deleted') AS scvs_deleted,
  COUNTIF(outcome = 'resubmitted, reclassified') AS scvs_reclassified,
  COUNTIF(is_resolution_candidate) AS scvs_with_resolution_impact,
  -- Summarize curation reasons used
  ARRAY_AGG(DISTINCT reason IGNORE NULLS ORDER BY reason) AS curation_reasons,
  -- Summarize curators involved
  ARRAY_AGG(DISTINCT curator IGNORE NULLS ORDER BY curator) AS curators
FROM `clinvar_curator.cvc_submitted_variants`
WHERE valid_submission = TRUE
GROUP BY variation_id, vcv_id
ORDER BY first_cvc_submission_date, variation_id
;
