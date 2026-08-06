-- =============================================================================
-- CVC Submissions: Accepted vs Rejected by Batch
-- =============================================================================
--
-- Purpose:
--   Compare submitted records from cvc_clinvar_submissions against the
--   cvc_rejected_scvs table to get an accurate view of which submissions
--   were accepted vs rejected by ClinVar.
--
-- Dependencies:
--   - clinvar_curator.cvc_clinvar_submissions
--   - clinvar_curator.cvc_clinvar_batches
--   - clinvar_curator.cvc_annotations_view
--   - clinvar_curator.cvc_rejected_scvs
--
-- =============================================================================

WITH
-- All submissions from batches with action type
all_submissions AS (
  SELECT
    s.batch_id,
    s.scv_id,
    s.scv_ver,
    s.annotation_id,
    b.batch_release_date,
    a.action
  FROM `clinvar_curator.cvc_clinvar_submissions` s
  JOIN `clinvar_curator.cvc_clinvar_batches` b
    ON s.batch_id = b.batch_id
  JOIN `clinvar_curator.cvc_annotations_view` a
    ON s.annotation_id = a.annotation_id
),

-- Rejected submissions
rejected AS (
  SELECT
    batch_id,
    scv_id,
    scv_ver,
    rejection_reason,
    date_rejected
  FROM `clinvar_curator.cvc_rejected_scvs`
)

SELECT
  a.batch_id,
  a.batch_release_date,
  COUNT(*) AS total_submitted,
  COUNTIF(r.scv_id IS NULL) AS accepted,
  COUNTIF(r.scv_id IS NOT NULL) AS rejected,
  ROUND(COUNTIF(r.scv_id IS NULL) * 100.0 / COUNT(*), 1) AS accepted_pct,
  ROUND(COUNTIF(r.scv_id IS NOT NULL) * 100.0 / COUNT(*), 1) AS rejected_pct,
  -- Breakdown of accepted submissions by action type
  COUNTIF(r.scv_id IS NULL AND a.action = 'flagging candidate') AS accepted_flagging_candidate,
  COUNTIF(r.scv_id IS NULL AND a.action = 'remove flagged submission') AS accepted_remove_flagging,
  -- Breakdown of rejection reasons
  COUNTIF(r.rejection_reason = 'deleted SCV') AS rejected_deleted,
  COUNTIF(r.rejection_reason = 'SCV current but with previous version') AS rejected_version_mismatch,
  COUNTIF(r.rejection_reason LIKE 'duplicate%') AS rejected_duplicate,
  COUNTIF(r.rejection_reason = 'secondary SCV') AS rejected_secondary,
  COUNTIF(r.rejection_reason = 'mistaken submission') AS rejected_mistaken
FROM all_submissions a
LEFT JOIN rejected r
  ON a.batch_id = r.batch_id
  AND a.scv_id = r.scv_id
  AND a.scv_ver = r.scv_ver
GROUP BY a.batch_id, a.batch_release_date
ORDER BY a.batch_id;
