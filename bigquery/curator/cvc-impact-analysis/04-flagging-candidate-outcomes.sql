-- =============================================================================
-- Flagging Candidate Outcomes Tracking
-- =============================================================================
--
-- Purpose:
--   Tracks the outcome of each flagging candidate submission over time.
--   Determines what happened to each submitted SCV:
--   - Flagged at 60-day window
--   - SCV removed by submitter
--   - SCV reclassified by submitter
--   - SCV updated (same classification) by submitter
--   - Rejected by ClinVar
--
-- Dependencies:
--   - clinvar_curator.cvc_clinvar_submissions
--   - clinvar_curator.cvc_annotations_view
--   - clinvar_curator.cvc_batches_enriched
--   - clinvar_curator.cvc_rejected_scvs
--   - clinvar_ingest.clinvar_scvs
--
-- Output:
--   - clinvar_curator.cvc_flagging_candidate_outcomes
--
-- =============================================================================

CREATE OR REPLACE TABLE `clinvar_curator.cvc_flagging_candidate_outcomes`
AS
WITH
-- Get all flagging candidate submissions (not rejected)
flagging_candidates AS (
  SELECT
    s.batch_id,
    s.annotation_id,
    s.scv_id,
    s.scv_ver,
    a.action,
    a.reason,
    a.variation_id,
    a.vcv_id,
    a.submitter_id,
    b.batch_accepted_date,
    b.grace_period_end_date,
    b.first_release_after_grace_period
  FROM `clinvar_curator.cvc_clinvar_submissions` s
  JOIN `clinvar_curator.cvc_annotations_view` a
    ON s.annotation_id = a.annotation_id
  JOIN `clinvar_curator.cvc_batches_enriched` b
    ON s.batch_id = b.batch_id
  LEFT JOIN `clinvar_curator.cvc_rejected_scvs` r
    ON s.batch_id = r.batch_id
    AND s.scv_id = r.scv_id
    AND s.scv_ver = r.scv_ver
  WHERE a.action = 'flagging candidate'
    AND r.scv_id IS NULL  -- Not rejected
),

-- Get the SCV state at time of submission (annotation release date)
scv_at_submission AS (
  SELECT
    fc.*,
    scv_sub.classif_type AS submitted_classif_type,
    scv_sub.classification_abbrev AS submitted_classification,
    scv_sub.rank AS submitted_rank,
    scv_sub.submitted_classification AS submitted_classification_text,
    scv_sub.last_evaluated AS submitted_last_evaluated
  FROM flagging_candidates fc
  JOIN `clinvar_curator.cvc_annotations_view` a
    ON fc.annotation_id = a.annotation_id
  LEFT JOIN `clinvar_ingest.clinvar_scvs` scv_sub
    ON fc.scv_id = scv_sub.id
    AND a.annotation_release_date BETWEEN scv_sub.start_release_date AND scv_sub.end_release_date
),

-- Get the SCV state at the first release after grace period
scv_after_grace AS (
  SELECT
    fc.annotation_id,
    fc.scv_id,
    fc.first_release_after_grace_period,
    scv_grace.version AS grace_version,
    scv_grace.classif_type AS grace_classif_type,
    scv_grace.classification_abbrev AS grace_classification,
    scv_grace.rank AS grace_rank,
    scv_grace.submitted_classification AS grace_classification_text,
    scv_grace.last_evaluated AS grace_last_evaluated
  FROM flagging_candidates fc
  LEFT JOIN `clinvar_ingest.clinvar_scvs` scv_grace
    ON fc.scv_id = scv_grace.id
    AND fc.first_release_after_grace_period BETWEEN scv_grace.start_release_date AND scv_grace.end_release_date
),

-- Get the current SCV state
scv_current AS (
  SELECT
    fc.annotation_id,
    fc.scv_id,
    scv_cur.version AS current_version,
    scv_cur.classif_type AS current_classif_type,
    scv_cur.classification_abbrev AS current_classification,
    scv_cur.rank AS current_rank,
    scv_cur.submitted_classification AS current_classification_text,
    scv_cur.last_evaluated AS current_last_evaluated,
    scv_cur.end_release_date AS current_end_release_date
  FROM flagging_candidates fc
  CROSS JOIN (
    SELECT release_date FROM `clinvar_ingest.schema_on`(CURRENT_DATE())
  ) latest
  LEFT JOIN `clinvar_ingest.clinvar_scvs` scv_cur
    ON fc.scv_id = scv_cur.id
    AND latest.release_date BETWEEN scv_cur.start_release_date AND scv_cur.end_release_date
)

SELECT
  sub.batch_id,
  sub.annotation_id,
  sub.scv_id,
  sub.scv_ver AS submitted_scv_ver,
  sub.action,
  sub.reason,
  sub.variation_id,
  sub.vcv_id,
  sub.submitter_id,
  sub.batch_accepted_date,
  sub.grace_period_end_date,
  sub.first_release_after_grace_period,
  -- Submitted state
  sub.submitted_classif_type,
  sub.submitted_classification,
  sub.submitted_rank,
  -- Grace period state
  grace.grace_version,
  grace.grace_classif_type,
  grace.grace_classification,
  grace.grace_rank,
  -- Current state
  cur.current_version,
  cur.current_classif_type,
  cur.current_classification,
  cur.current_rank,
  cur.current_end_release_date,
  -- Determine outcome
  CASE
    -- SCV was removed (not in current release)
    WHEN cur.current_version IS NULL THEN 'scv_removed'
    -- SCV is flagged (rank = -3)
    WHEN cur.current_rank = -3 THEN 'flagged'
    -- SCV was reclassified (classification type changed)
    WHEN cur.current_classif_type != sub.submitted_classif_type THEN 'scv_reclassified'
    -- SCV was updated but classification didn't change (version changed)
    WHEN cur.current_version > sub.scv_ver AND cur.current_classif_type = sub.submitted_classif_type THEN 'scv_updated_same_classification'
    -- Still pending (same version, not flagged)
    WHEN cur.current_version = sub.scv_ver AND cur.current_rank != -3 THEN 'pending'
    ELSE 'unknown'
  END AS outcome,
  -- Determine if outcome occurred during grace period
  CASE
    WHEN grace.grace_version IS NULL THEN TRUE  -- Removed during grace
    WHEN grace.grace_version > sub.scv_ver THEN TRUE  -- Updated during grace
    WHEN grace.grace_classif_type != sub.submitted_classif_type THEN TRUE  -- Reclassified during grace
    ELSE FALSE
  END AS action_during_grace_period,
  -- Flag applied timing
  CASE
    WHEN cur.current_rank = -3 THEN
      -- Find the first release where this SCV became flagged
      (
        SELECT MIN(release_date)
        FROM `clinvar_ingest.clinvar_scvs` s
        JOIN `clinvar_ingest.clinvar_releases` r
          ON r.release_date BETWEEN s.start_release_date AND s.end_release_date
        WHERE s.id = sub.scv_id
          AND s.rank = -3
      )
    ELSE NULL
  END AS date_flagged
FROM scv_at_submission sub
LEFT JOIN scv_after_grace grace
  ON sub.annotation_id = grace.annotation_id
LEFT JOIN scv_current cur
  ON sub.annotation_id = cur.annotation_id
ORDER BY sub.batch_id, sub.scv_id;


-- =============================================================================
-- Remove Flagged Submission Outcomes Tracking
-- =============================================================================
--
-- Purpose:
--   Tracks the outcome of "remove flagged submission" submissions.
--   These are submissions intended to UNFLAG a previously flagged SCV.
--   Note: To date, none of these have been successfully applied by NCBI,
--   but we track them for completeness and future analysis.
--
-- =============================================================================

CREATE OR REPLACE TABLE `clinvar_curator.cvc_remove_flagged_outcomes`
AS
WITH
-- Get all "remove flagged submission" submissions (not rejected)
remove_submissions AS (
  SELECT
    s.batch_id,
    s.annotation_id,
    s.scv_id,
    s.scv_ver,
    a.action,
    a.reason,
    a.variation_id,
    a.vcv_id,
    a.submitter_id,
    b.batch_accepted_date,
    b.grace_period_end_date,
    b.first_release_after_grace_period
  FROM `clinvar_curator.cvc_clinvar_submissions` s
  JOIN `clinvar_curator.cvc_annotations_view` a
    ON s.annotation_id = a.annotation_id
  JOIN `clinvar_curator.cvc_batches_enriched` b
    ON s.batch_id = b.batch_id
  LEFT JOIN `clinvar_curator.cvc_rejected_scvs` r
    ON s.batch_id = r.batch_id
    AND s.scv_id = r.scv_id
    AND s.scv_ver = r.scv_ver
  WHERE a.action = 'remove flagged submission'
    AND r.scv_id IS NULL  -- Not rejected
),

-- Get the SCV state at time of submission
scv_at_submission AS (
  SELECT
    rs.*,
    scv_sub.rank AS submitted_rank,
    scv_sub.classif_type AS submitted_classif_type
  FROM remove_submissions rs
  JOIN `clinvar_curator.cvc_annotations_view` a
    ON rs.annotation_id = a.annotation_id
  LEFT JOIN `clinvar_ingest.clinvar_scvs` scv_sub
    ON rs.scv_id = scv_sub.id
    AND a.annotation_release_date BETWEEN scv_sub.start_release_date AND scv_sub.end_release_date
),

-- Get the current SCV state
scv_current AS (
  SELECT
    rs.annotation_id,
    rs.scv_id,
    scv_cur.version AS current_version,
    scv_cur.rank AS current_rank,
    scv_cur.classif_type AS current_classif_type,
    scv_cur.classification_abbrev AS current_classification
  FROM remove_submissions rs
  CROSS JOIN (
    SELECT release_date FROM `clinvar_ingest.schema_on`(CURRENT_DATE())
  ) latest
  LEFT JOIN `clinvar_ingest.clinvar_scvs` scv_cur
    ON rs.scv_id = scv_cur.id
    AND latest.release_date BETWEEN scv_cur.start_release_date AND scv_cur.end_release_date
)

SELECT
  sub.batch_id,
  sub.annotation_id,
  sub.scv_id,
  sub.scv_ver AS submitted_scv_ver,
  sub.action,
  sub.reason,
  sub.variation_id,
  sub.vcv_id,
  sub.submitter_id,
  sub.batch_accepted_date,
  sub.grace_period_end_date,
  sub.first_release_after_grace_period,
  -- Submitted state
  sub.submitted_rank,
  sub.submitted_classif_type,
  -- Current state
  cur.current_version,
  cur.current_rank,
  cur.current_classif_type,
  cur.current_classification,
  -- Determine outcome
  CASE
    -- SCV was removed (not in current release)
    WHEN cur.current_version IS NULL THEN 'scv_removed'
    -- SCV was unflagged (rank is no longer -3)
    WHEN cur.current_rank != -3 AND sub.submitted_rank = -3 THEN 'unflagged_success'
    -- SCV is still flagged (rank = -3)
    WHEN cur.current_rank = -3 THEN 'still_flagged'
    -- SCV was never flagged (shouldn't happen but track it)
    WHEN sub.submitted_rank != -3 THEN 'was_not_flagged'
    ELSE 'unknown'
  END AS outcome
FROM scv_at_submission sub
LEFT JOIN scv_current cur
  ON sub.annotation_id = cur.annotation_id
ORDER BY sub.batch_id, sub.scv_id;


-- =============================================================================
-- Summary View: Remove Flagged Submission Outcomes by Batch
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.cvc_remove_flagged_by_batch`
AS
SELECT
  batch_id,
  batch_accepted_date,
  COUNT(*) AS total_remove_submissions,
  COUNTIF(outcome = 'unflagged_success') AS unflagged_success,
  COUNTIF(outcome = 'still_flagged') AS still_flagged,
  COUNTIF(outcome = 'scv_removed') AS scv_removed,
  COUNTIF(outcome = 'was_not_flagged') AS was_not_flagged,
  COUNTIF(outcome = 'unknown') AS unknown,
  -- Success rate
  ROUND(COUNTIF(outcome = 'unflagged_success') * 100.0 / NULLIF(COUNT(*), 0), 1) AS success_rate_pct
FROM `clinvar_curator.cvc_remove_flagged_outcomes`
GROUP BY batch_id, batch_accepted_date
ORDER BY batch_id;


-- =============================================================================
-- Summary View: Flagging Candidate Outcomes by Batch
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.cvc_flagging_outcomes_by_batch`
AS
SELECT
  batch_id,
  batch_accepted_date,
  grace_period_end_date,
  COUNT(*) AS total_flagging_candidates,
  COUNTIF(outcome = 'flagged') AS flagged,
  COUNTIF(outcome = 'scv_removed') AS scv_removed,
  COUNTIF(outcome = 'scv_reclassified') AS scv_reclassified,
  COUNTIF(outcome = 'scv_updated_same_classification') AS scv_updated_same_class,
  COUNTIF(outcome = 'pending') AS pending,
  COUNTIF(outcome = 'unknown') AS unknown,
  -- Success rate (flagged or submitter action)
  ROUND(COUNTIF(outcome IN ('flagged', 'scv_removed', 'scv_reclassified')) * 100.0 / COUNT(*), 1) AS success_rate_pct,
  -- Action during grace period
  COUNTIF(action_during_grace_period) AS actions_during_grace
FROM `clinvar_curator.cvc_flagging_candidate_outcomes`
GROUP BY batch_id, batch_accepted_date, grace_period_end_date
ORDER BY batch_id;
