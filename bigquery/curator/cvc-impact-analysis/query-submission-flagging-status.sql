-- =============================================================================
-- CVC Submission Flagging Status Query
-- =============================================================================
--
-- Purpose:
--   Compares valid (non-rejected) CVC submissions against monthly conflict
--   snapshots to determine which SCVs actually got flagged in ClinVar.
--
-- Categories:
--   - flagged_exact_version: SCV was flagged with the exact version we submitted
--   - flagged_different_version: SCV was flagged but with a different version
--   - not_flagged: SCV has not appeared as flagged in any monthly snapshot
--
-- Dependencies:
--   - clinvar_curator.cvc_clinvar_submissions
--   - clinvar_curator.cvc_clinvar_batches
--   - clinvar_curator.cvc_rejected_scvs
--   - clinvar_ingest.monthly_conflict_scv_snapshots
--
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Summary by Batch
-- -----------------------------------------------------------------------------
WITH
valid_submissions AS (
  SELECT
    s.batch_id,
    s.scv_id,
    CAST(s.scv_ver AS INT64) AS scv_ver,
    b.finalized_datetime,
    b.batch_release_date,
    b.submission.monyy AS submission_month
  FROM `clinvar_curator.cvc_clinvar_submissions` s
  JOIN `clinvar_curator.cvc_clinvar_batches` b ON b.batch_id = s.batch_id
  LEFT JOIN `clinvar_curator.cvc_rejected_scvs` r
    ON r.batch_id = s.batch_id
    AND r.scv_id = s.scv_id
    AND r.scv_ver = CAST(s.scv_ver AS INT64)
  WHERE r.scv_id IS NULL  -- Not rejected
),

flagged_in_snapshots AS (
  SELECT DISTINCT
    scv.scv_id,
    scv.scv_version AS flagged_version,
    scv.snapshot_release_date AS first_flagged_date
  FROM `clinvar_ingest.monthly_conflict_scv_snapshots` scv
  WHERE scv.is_flagged = TRUE
  QUALIFY ROW_NUMBER() OVER (PARTITION BY scv.scv_id ORDER BY scv.snapshot_release_date) = 1
)

SELECT
  vs.batch_id,
  vs.submission_month,
  COUNT(*) AS total_valid_submissions,
  COUNTIF(fs.scv_id IS NOT NULL AND fs.flagged_version = vs.scv_ver) AS flagged_exact_version,
  COUNTIF(fs.scv_id IS NOT NULL AND fs.flagged_version != vs.scv_ver) AS flagged_different_version,
  COUNTIF(fs.scv_id IS NULL) AS not_flagged_in_snapshots,
  -- Percentages
  ROUND(100.0 * COUNTIF(fs.scv_id IS NOT NULL AND fs.flagged_version = vs.scv_ver) / COUNT(*), 1) AS pct_flagged_exact,
  ROUND(100.0 * COUNTIF(fs.scv_id IS NULL) / COUNT(*), 1) AS pct_not_flagged
FROM valid_submissions vs
LEFT JOIN flagged_in_snapshots fs ON fs.scv_id = vs.scv_id
GROUP BY vs.batch_id, vs.submission_month
ORDER BY vs.batch_id
;


-- -----------------------------------------------------------------------------
-- Detail: SCVs Not Flagged or Flagged with Different Version
-- -----------------------------------------------------------------------------
-- Uncomment to run this query for detailed SCV-level analysis

/*
WITH
valid_submissions AS (
  SELECT
    s.batch_id,
    s.scv_id,
    CAST(s.scv_ver AS INT64) AS scv_ver,
    b.finalized_datetime,
    b.batch_release_date,
    b.submission.monyy AS submission_month
  FROM `clinvar_curator.cvc_clinvar_submissions` s
  JOIN `clinvar_curator.cvc_clinvar_batches` b ON b.batch_id = s.batch_id
  LEFT JOIN `clinvar_curator.cvc_rejected_scvs` r
    ON r.batch_id = s.batch_id
    AND r.scv_id = s.scv_id
    AND r.scv_ver = CAST(s.scv_ver AS INT64)
  WHERE r.scv_id IS NULL  -- Not rejected
),

flagged_in_snapshots AS (
  SELECT DISTINCT
    scv.scv_id,
    scv.scv_version AS flagged_version,
    MIN(scv.snapshot_release_date) AS first_flagged_date
  FROM `clinvar_ingest.monthly_conflict_scv_snapshots` scv
  WHERE scv.is_flagged = TRUE
  GROUP BY scv.scv_id, scv.scv_version
)

SELECT
  vs.batch_id,
  vs.submission_month,
  vs.scv_id,
  vs.scv_ver AS submitted_ver,
  fs.flagged_version,
  fs.first_flagged_date,
  CASE
    WHEN fs.scv_id IS NULL THEN 'not_flagged'
    WHEN fs.flagged_version = vs.scv_ver THEN 'flagged_exact_version'
    ELSE 'flagged_different_version'
  END AS status
FROM valid_submissions vs
LEFT JOIN flagged_in_snapshots fs ON fs.scv_id = vs.scv_id
WHERE fs.scv_id IS NULL OR fs.flagged_version != vs.scv_ver
ORDER BY vs.batch_id, vs.scv_id
;
*/


-- -----------------------------------------------------------------------------
-- Detail: All Valid Submissions with Flagging Status
-- -----------------------------------------------------------------------------
-- Uncomment to run this query for complete SCV-level data

/*
WITH
valid_submissions AS (
  SELECT
    s.batch_id,
    s.scv_id,
    CAST(s.scv_ver AS INT64) AS scv_ver,
    b.finalized_datetime,
    b.batch_release_date,
    b.submission.monyy AS submission_month
  FROM `clinvar_curator.cvc_clinvar_submissions` s
  JOIN `clinvar_curator.cvc_clinvar_batches` b ON b.batch_id = s.batch_id
  LEFT JOIN `clinvar_curator.cvc_rejected_scvs` r
    ON r.batch_id = s.batch_id
    AND r.scv_id = s.scv_id
    AND r.scv_ver = CAST(s.scv_ver AS INT64)
  WHERE r.scv_id IS NULL  -- Not rejected
),

flagged_in_snapshots AS (
  SELECT DISTINCT
    scv.scv_id,
    scv.scv_version AS flagged_version,
    MIN(scv.snapshot_release_date) AS first_flagged_date
  FROM `clinvar_ingest.monthly_conflict_scv_snapshots` scv
  WHERE scv.is_flagged = TRUE
  GROUP BY scv.scv_id, scv.scv_version
)

SELECT
  vs.batch_id,
  vs.submission_month,
  vs.scv_id,
  vs.scv_ver AS submitted_ver,
  fs.flagged_version,
  fs.first_flagged_date,
  CASE
    WHEN fs.scv_id IS NULL THEN 'not_flagged'
    WHEN fs.flagged_version = vs.scv_ver THEN 'flagged_exact_version'
    ELSE 'flagged_different_version'
  END AS status
FROM valid_submissions vs
LEFT JOIN flagged_in_snapshots fs ON fs.scv_id = vs.scv_id
ORDER BY vs.batch_id, vs.scv_id
;
*/
