-- =============================================================================
-- Version Bump and Flagging Candidate Intersection Report
-- =============================================================================
--
-- Purpose:
--   Identifies cases where submitters performed version bumps on SCVs that
--   were submitted as flagging candidates. This helps detect potential
--   "gaming" of the 60-day grace period.
--
--   Key questions answered:
--   1. How many flagging candidate SCVs received version bumps?
--   2. Did the version bump occur during the 60-day grace period?
--   3. Did the version bump prevent a flag from being applied?
--
-- Dependencies:
--   - clinvar_curator.cvc_flagging_candidate_outcomes
--   - clinvar_curator.cvc_version_bumps
--   - clinvar_curator.cvc_batches_enriched
--
-- Output:
--   - clinvar_curator.cvc_flagging_version_bump_intersection
--   - clinvar_curator.cvc_flagging_version_bump_summary
--
-- =============================================================================

CREATE OR REPLACE TABLE `@@DATASET@@.cvc_flagging_version_bump_intersection`
AS
WITH
-- Get all flagging candidates with their submitted version
flagging_candidates AS (
  SELECT
    fco.batch_id,
    fco.annotation_id,
    fco.scv_id,
    fco.submitted_scv_ver,
    fco.submitter_id,
    fco.variation_id,
    fco.vcv_id,
    fco.reason,
    fco.batch_accepted_date,
    fco.grace_period_end_date,
    fco.first_release_after_grace_period,
    fco.outcome,
    fco.current_version,
    fco.date_flagged
  FROM `@@DATASET@@.cvc_flagging_candidate_outcomes` fco
),

-- Find version bumps that occurred on flagging candidate SCVs
-- after the batch was accepted
relevant_version_bumps AS (
  SELECT
    fc.batch_id,
    fc.annotation_id,
    fc.scv_id,
    fc.submitted_scv_ver,
    fc.batch_accepted_date,
    fc.grace_period_end_date,
    vb.previous_version AS bump_from_version,
    vb.current_version AS bump_to_version,
    vb.current_start_date AS bump_date,
    vb.is_version_bump,
    vb.changes_made,
    -- Did the bump happen during the grace period?
    (vb.current_start_date BETWEEN fc.batch_accepted_date AND fc.grace_period_end_date) AS bump_during_grace_period,
    -- Did the bump affect the submitted version specifically?
    (vb.previous_version = fc.submitted_scv_ver) AS bump_from_submitted_version
  FROM flagging_candidates fc
  JOIN `@@DATASET@@.cvc_version_bumps` vb
    ON fc.scv_id = vb.scv_id
    AND vb.current_start_date >= fc.batch_accepted_date  -- Bump happened after batch acceptance
)

SELECT
  fc.batch_id,
  fc.annotation_id,
  fc.scv_id,
  fc.submitted_scv_ver,
  fc.submitter_id,
  fc.variation_id,
  fc.vcv_id,
  fc.reason AS flagging_reason,
  fc.batch_accepted_date,
  fc.grace_period_end_date,
  fc.outcome AS current_outcome,
  fc.current_version,
  fc.date_flagged,
  -- Version bump info
  vb.bump_from_version,
  vb.bump_to_version,
  vb.bump_date,
  vb.is_version_bump,
  vb.changes_made,
  vb.bump_during_grace_period,
  vb.bump_from_submitted_version,
  -- Count of version bumps for this SCV after submission
  (
    SELECT COUNT(*)
    FROM `@@DATASET@@.cvc_version_bumps` vb2
    WHERE vb2.scv_id = fc.scv_id
      AND vb2.current_start_date >= fc.batch_accepted_date
      AND vb2.is_version_bump = TRUE
  ) AS total_version_bumps_after_submission,
  -- Determine if version bump may have prevented flagging
  CASE
    WHEN fc.outcome = 'flagged' THEN 'flagged_despite_bump'
    WHEN fc.outcome = 'scv_updated_same_classification' AND vb.is_version_bump THEN 'version_bump_prevented_flag'
    WHEN fc.outcome = 'scv_reclassified' THEN 'reclassified'
    WHEN fc.outcome = 'scv_removed' THEN 'removed'
    ELSE 'other'
  END AS bump_impact
FROM flagging_candidates fc
LEFT JOIN relevant_version_bumps vb
  ON fc.annotation_id = vb.annotation_id
  AND vb.bump_from_submitted_version = TRUE  -- Focus on bumps from the submitted version
ORDER BY fc.batch_id, fc.scv_id;


-- =============================================================================
-- Summary View: Version Bump Impact on Flagging Candidates
-- =============================================================================

CREATE OR REPLACE VIEW `@@DATASET@@.cvc_flagging_version_bump_summary`
AS
SELECT
  batch_id,
  batch_accepted_date,
  grace_period_end_date,
  COUNT(DISTINCT scv_id) AS total_flagging_candidates,
  -- SCVs that received version bumps
  COUNT(DISTINCT CASE WHEN is_version_bump = TRUE THEN scv_id END) AS scvs_with_version_bump,
  COUNT(DISTINCT CASE WHEN bump_during_grace_period = TRUE AND is_version_bump = TRUE THEN scv_id END) AS scvs_with_bump_during_grace,
  -- Impact breakdown
  COUNTIF(bump_impact = 'version_bump_prevented_flag') AS bumps_prevented_flag,
  COUNTIF(bump_impact = 'flagged_despite_bump') AS flagged_despite_bump,
  COUNTIF(bump_impact = 'reclassified') AS reclassified,
  COUNTIF(bump_impact = 'removed') AS removed,
  -- Percentage of flagging candidates with version bumps
  ROUND(
    COUNT(DISTINCT CASE WHEN is_version_bump = TRUE THEN scv_id END) * 100.0 /
    NULLIF(COUNT(DISTINCT scv_id), 0),
    1
  ) AS pct_with_version_bump
FROM `@@DATASET@@.cvc_flagging_version_bump_intersection`
GROUP BY batch_id, batch_accepted_date, grace_period_end_date
ORDER BY batch_id;


-- =============================================================================
-- Submitter Analysis: Who is doing version bumps on flagged SCVs?
-- =============================================================================

CREATE OR REPLACE VIEW `@@DATASET@@.cvc_flagging_version_bump_by_submitter`
AS
SELECT
  fvi.submitter_id,
  sub.current_name AS submitter_name,
  COUNT(DISTINCT fvi.scv_id) AS scvs_submitted_as_flagging_candidates,
  COUNT(DISTINCT CASE WHEN fvi.is_version_bump = TRUE THEN fvi.scv_id END) AS scvs_with_version_bump,
  COUNT(DISTINCT CASE WHEN fvi.bump_during_grace_period = TRUE AND fvi.is_version_bump = TRUE THEN fvi.scv_id END) AS scvs_bumped_during_grace,
  COUNT(DISTINCT CASE WHEN fvi.bump_during_grace_period = FALSE AND fvi.is_version_bump = TRUE THEN fvi.scv_id END) AS scvs_bumped_after_grace,
  COUNTIF(fvi.bump_impact = 'version_bump_prevented_flag') AS bumps_prevented_flag,
  COUNTIF(fvi.bump_impact = 'flagged_despite_bump') AS flagged_despite_bump,
  -- Rate of version bumps during grace period
  ROUND(
    COUNT(DISTINCT CASE WHEN fvi.bump_during_grace_period = TRUE AND fvi.is_version_bump = TRUE THEN fvi.scv_id END) * 100.0 /
    NULLIF(COUNT(DISTINCT fvi.scv_id), 0),
    1
  ) AS pct_bumped_during_grace,
  -- Rate of version bumps after grace period
  ROUND(
    COUNT(DISTINCT CASE WHEN fvi.bump_during_grace_period = FALSE AND fvi.is_version_bump = TRUE THEN fvi.scv_id END) * 100.0 /
    NULLIF(COUNT(DISTINCT fvi.scv_id), 0),
    1
  ) AS pct_bumped_after_grace
FROM `@@DATASET@@.cvc_flagging_version_bump_intersection` fvi
LEFT JOIN `clinvar_ingest.clinvar_submitters` sub
  ON fvi.submitter_id = sub.id
  AND sub.deleted_release_date IS NULL
GROUP BY fvi.submitter_id, sub.current_name
HAVING COUNT(DISTINCT CASE WHEN fvi.is_version_bump = TRUE THEN fvi.scv_id END) > 0
ORDER BY scvs_bumped_during_grace DESC;


-- =============================================================================
-- Google Sheets View: Stacked Bar Chart - Flagging Candidate Outcomes by Submitter
-- =============================================================================
--
-- Visualization: Stacked Bar Chart
-- Purpose: Shows how flagging candidates are "washed out" by version bumps
--          with no substantive changes, broken down by submitter
--
-- Chart Setup in Google Sheets:
--   - Chart Type: Stacked Bar Chart
--   - X-axis: submitter_name
--   - Series (stacked, in this order for visual impact):
--       1. "Flagged" (green) - Success: flag was applied
--       2. "Reclassified" (blue) - Success: submitter changed classification
--       3. "Removed" (light blue) - Success: submitter removed SCV
--       4. "Substantive_Changes" (yellow) - Neutral: real updates but kept classification
--       5. "Pending/Other" (gray) - Still in progress
--       6. "Version Bump During Grace" (orange) - Concerning: avoided flag during grace period
--       7. "Version Bump After Grace" (red) - Pattern: continued bumping after grace
--
-- =============================================================================

CREATE OR REPLACE VIEW `@@DATASET@@.sheets_version_bump_impact_by_submitter`
AS
SELECT
  sub.current_name AS submitter_name,
  -- Successful outcomes (flag applied or submitter action)
  COUNT(DISTINCT CASE WHEN fvi.current_outcome = 'flagged' THEN fvi.scv_id END) AS Flagged,
  COUNT(DISTINCT CASE WHEN fvi.current_outcome = 'scv_reclassified' THEN fvi.scv_id END) AS Reclassified,
  COUNT(DISTINCT CASE WHEN fvi.current_outcome = 'scv_removed' THEN fvi.scv_id END) AS Removed,
  -- Substantive changes (real updates but kept same classification)
  COUNT(DISTINCT CASE
    WHEN fvi.current_outcome = 'scv_updated_same_classification' AND fvi.is_version_bump = FALSE
    THEN fvi.scv_id
  END) AS Substantive_Changes,
  -- Pending or other
  COUNT(DISTINCT CASE
    WHEN fvi.current_outcome NOT IN ('flagged', 'scv_reclassified', 'scv_removed', 'scv_updated_same_classification')
    THEN fvi.scv_id
  END) AS Pending_Other,
  -- Version bumps that prevented flags (the concerning pattern)
  COUNT(DISTINCT CASE
    WHEN fvi.is_version_bump = TRUE AND fvi.bump_during_grace_period = TRUE
    THEN fvi.scv_id
  END) AS Version_Bump_During_Grace,
  COUNT(DISTINCT CASE
    WHEN fvi.is_version_bump = TRUE AND fvi.bump_during_grace_period = FALSE
    THEN fvi.scv_id
  END) AS Version_Bump_After_Grace,
  -- Total for reference
  COUNT(DISTINCT fvi.scv_id) AS total_flagging_candidates
FROM `@@DATASET@@.cvc_flagging_version_bump_intersection` fvi
LEFT JOIN `clinvar_ingest.clinvar_submitters` sub
  ON fvi.submitter_id = sub.id
  AND sub.deleted_release_date IS NULL
GROUP BY sub.current_name
HAVING COUNT(DISTINCT fvi.scv_id) >= 5  -- Only show submitters with meaningful volume
ORDER BY COUNT(DISTINCT CASE WHEN fvi.is_version_bump = TRUE THEN fvi.scv_id END) DESC;


-- =============================================================================
-- Google Sheets View: Funnel/Waterfall - Flagging Candidate Attrition
-- =============================================================================
--
-- Visualization: Funnel Chart or Waterfall Chart
-- Purpose: Shows how many flagging candidates "survive" to get flagged
--          vs being washed out by version bumps or other outcomes
--
-- Chart Setup in Google Sheets:
--   - Chart Type: Funnel or Waterfall
--   - Categories: stage_name (in order)
--   - Values: scv_count
--
-- =============================================================================

CREATE OR REPLACE VIEW `@@DATASET@@.sheets_flagging_candidate_funnel`
AS
WITH
-- Identify stale submissions: submitted version was already outdated when batch was accepted
-- Now keyed by annotation_id to handle same SCV in multiple batches
stale_submissions AS (
  SELECT DISTINCT fco.annotation_id
  FROM `@@DATASET@@.cvc_flagging_candidate_outcomes` fco
  JOIN `@@DATASET@@.cvc_version_bumps` vb
    ON fco.scv_id = vb.scv_id
    AND vb.previous_version = fco.submitted_scv_ver
    AND vb.current_start_date < fco.batch_accepted_date  -- Version changed BEFORE batch was accepted
),
-- Flagging candidate submissions where CVC also submitted a "remove flagged submission"
-- for the same SCV (meaning CVC explicitly requested the flag be removed).
-- Queries source tables directly rather than cvc_remove_flagged_outcomes (materialized)
-- to avoid stale data issues.
remove_flagged_submissions AS (
  SELECT DISTINCT fco.annotation_id
  FROM `@@DATASET@@.cvc_flagging_candidate_outcomes` fco
  WHERE EXISTS (
    SELECT 1
    FROM `@@DATASET@@.cvc_annotations_view` a
    WHERE a.action = 'remove flagged submission'
      AND a.scv_id = fco.scv_id
      AND a.is_submitted = TRUE
  )
),
-- Each row in the intersection table represents a unique batch submission (annotation_id)
-- Aggregate version bump info per submission, not per SCV
submission_summary AS (
  SELECT
    fvi.annotation_id,
    fvi.scv_id,
    fvi.batch_id,
    fvi.current_outcome,
    fvi.submitted_scv_ver,
    fvi.current_version,
    fvi.grace_period_end_date,
    -- Did this submission have any version bump (no substantive change) during grace period?
    LOGICAL_OR(fvi.is_version_bump = TRUE AND fvi.bump_during_grace_period = TRUE) AS had_bump_during_grace,
    -- Did this submission have any version bump (no substantive change) after grace period?
    LOGICAL_OR(fvi.is_version_bump = TRUE AND fvi.bump_during_grace_period = FALSE) AS had_bump_after_grace,
    -- Did this submission have any substantive change (is_version_bump = FALSE means real changes)?
    LOGICAL_OR(fvi.is_version_bump = FALSE AND fvi.bump_from_submitted_version = TRUE) AS had_substantive_change,
    -- Was this submission rejected by NCBI?
    LOGICAL_OR(fvi.scv_id IN (SELECT scv_id FROM `@@DATASET@@.cvc_rejected_scvs` WHERE batch_id = fvi.batch_id)) AS was_rejected,
    -- Was the submitted version already stale when batch was accepted?
    LOGICAL_OR(fvi.annotation_id IN (SELECT annotation_id FROM stale_submissions)) AS was_stale_at_submission,
    -- Did CVC later submit a "remove flagged submission" for this SCV?
    LOGICAL_OR(fvi.annotation_id IN (SELECT annotation_id FROM remove_flagged_submissions)) AS had_remove_flagged_submission
  FROM `@@DATASET@@.cvc_flagging_version_bump_intersection` fvi
  GROUP BY fvi.annotation_id, fvi.scv_id, fvi.batch_id, fvi.current_outcome,
           fvi.submitted_scv_ver, fvi.current_version, fvi.grace_period_end_date
),
-- Categorize each submission (not SCV) into exactly ONE mutually exclusive bucket
submission_categories AS (
  SELECT
    annotation_id,
    scv_id,
    batch_id,
    current_outcome,
    submitted_scv_ver,
    current_version,
    grace_period_end_date,
    had_bump_during_grace,
    had_bump_after_grace,
    had_substantive_change,
    was_rejected,
    was_stale_at_submission,
    had_remove_flagged_submission,
    CASE
      -- Rejected by NCBI (highest priority - never had a chance)
      WHEN was_rejected THEN 'rejected'
      -- CVC explicitly requested flag removal — supersedes other outcomes
      -- (CVC's latest intent is "don't flag this SCV")
      WHEN had_remove_flagged_submission THEN 'unflagged'
      -- Successfully flagged (this is the goal)
      WHEN current_outcome = 'flagged' THEN 'flagged'
      -- Submitter reclassified (success - submitter changed classification)
      WHEN current_outcome = 'scv_reclassified' THEN 'reclassified'
      -- Submitter removed SCV (success - submitter responded)
      WHEN current_outcome = 'scv_removed' THEN 'removed'
      -- Version bump during grace period prevented flag (concerning - no real changes)
      WHEN current_outcome = 'scv_updated_same_classification'
        AND had_bump_during_grace THEN 'bump_during_grace'
      -- Version bump after grace period only (pattern of continued bumping)
      WHEN current_outcome = 'scv_updated_same_classification'
        AND had_bump_after_grace THEN 'bump_after_grace'
      -- Substantive changes made but classification unchanged
      WHEN current_outcome = 'scv_updated_same_classification'
        AND had_substantive_change THEN 'substantive_same_class'
      -- Stale at submission: version was already outdated when batch was accepted (NCBI didn't catch)
      WHEN current_outcome = 'scv_updated_same_classification'
        AND was_stale_at_submission THEN 'stale_at_submission'
      -- Pending but past grace period with same version = should be flagged (anomaly)
      WHEN current_outcome = 'pending'
        AND CURRENT_DATE() > grace_period_end_date
        AND current_version = submitted_scv_ver THEN 'anomaly_should_flag'
      -- Within grace period - still pending
      WHEN current_outcome = 'pending'
        AND CURRENT_DATE() <= grace_period_end_date THEN 'within_grace_pending'
      -- Other/unknown
      ELSE 'other'
    END AS category
  FROM submission_summary
),
totals AS (
  SELECT
    COUNT(*) AS total_submitted,
    COUNTIF(category = 'rejected') AS rejected,
    COUNTIF(category = 'flagged') AS flagged,
    COUNTIF(category = 'reclassified') AS reclassified,
    COUNTIF(category = 'removed') AS removed,
    COUNTIF(category = 'bump_during_grace') AS bump_during_grace,
    COUNTIF(category = 'bump_after_grace') AS bump_after_grace,
    COUNTIF(category = 'substantive_same_class') AS substantive_same_class,
    COUNTIF(category = 'stale_at_submission') AS stale_at_submission,
    COUNTIF(category = 'unflagged') AS unflagged,
    COUNTIF(category = 'anomaly_should_flag') AS anomaly_should_flag,
    COUNTIF(category = 'within_grace_pending') AS within_grace_pending,
    COUNTIF(category = 'other') AS other
  FROM submission_categories
)
-- Waterfall format: start with total, subtract each category
SELECT 1 AS sort_order, 'Submitted as Flagging Candidates' AS stage_name, total_submitted AS scv_count, 100.0 AS pct_of_total FROM totals
UNION ALL
SELECT 2, 'Less: Rejected by NCBI', -rejected, ROUND(-100.0 * rejected / NULLIF(total_submitted, 0), 1) FROM totals
UNION ALL
SELECT 3, 'Less: Stale at Submission (NCBI missed)', -stale_at_submission, ROUND(-100.0 * stale_at_submission / NULLIF(total_submitted, 0), 1) FROM totals
UNION ALL
SELECT 4, 'Less: Version Bumps During Grace (No Change)', -bump_during_grace, ROUND(-100.0 * bump_during_grace / NULLIF(total_submitted, 0), 1) FROM totals
UNION ALL
SELECT 5, 'Less: Version Bumps After Grace (No Change)', -bump_after_grace, ROUND(-100.0 * bump_after_grace / NULLIF(total_submitted, 0), 1) FROM totals
UNION ALL
SELECT 6, 'Less: Substantive Changes (Same Classification)', -substantive_same_class, ROUND(-100.0 * substantive_same_class / NULLIF(total_submitted, 0), 1) FROM totals
UNION ALL
SELECT 7, 'Less: Submitter Reclassified', -reclassified, ROUND(-100.0 * reclassified / NULLIF(total_submitted, 0), 1) FROM totals
UNION ALL
SELECT 8, 'Less: Submitter Removed SCV', -removed, ROUND(-100.0 * removed / NULLIF(total_submitted, 0), 1) FROM totals
UNION ALL
SELECT 9, 'Less: Within Grace Period (Pending)', -within_grace_pending, ROUND(-100.0 * within_grace_pending / NULLIF(total_submitted, 0), 1) FROM totals
UNION ALL
SELECT 10, 'Less: Unflagged (CVC Requested Removal)', -unflagged, ROUND(-100.0 * unflagged / NULLIF(total_submitted, 0), 1) FROM totals
UNION ALL
SELECT 11, 'Less: Anomaly - Should Be Flagged', -anomaly_should_flag, ROUND(-100.0 * anomaly_should_flag / NULLIF(total_submitted, 0), 1) FROM totals
UNION ALL
SELECT 12, 'Less: Other/Unknown', -other, ROUND(-100.0 * other / NULLIF(total_submitted, 0), 1) FROM totals
UNION ALL
SELECT 13, 'Equals: Successfully Flagged', flagged, ROUND(100.0 * flagged / NULLIF(total_submitted, 0), 1) FROM totals
ORDER BY sort_order;


-- =============================================================================
-- Google Sheets View: Pivoted Funnel for Horizontal Stacked Bar Chart
-- =============================================================================
--
-- Visualization: Horizontal Stacked Bar Chart
-- Purpose: Single-row pivoted format where each category is a column,
--          enabling per-segment color customization in Google Sheets
--
-- Chart Setup in Google Sheets:
--   - Chart Type: Stacked Bar Chart (horizontal)
--   - Each column becomes a series with its own color
--   - Order columns to control segment order (left to right)
--
-- =============================================================================

CREATE OR REPLACE VIEW `@@DATASET@@.sheets_flagging_candidate_funnel_pivoted`
AS
WITH
-- Identify stale submissions: submitted version was already outdated when batch was accepted
-- Now keyed by annotation_id to handle same SCV in multiple batches
stale_submissions AS (
  SELECT DISTINCT fco.annotation_id
  FROM `@@DATASET@@.cvc_flagging_candidate_outcomes` fco
  JOIN `@@DATASET@@.cvc_version_bumps` vb
    ON fco.scv_id = vb.scv_id
    AND vb.previous_version = fco.submitted_scv_ver
    AND vb.current_start_date < fco.batch_accepted_date
),
-- Flagging candidate submissions where CVC also submitted a "remove flagged submission"
-- for the same SCV (meaning CVC explicitly requested the flag be removed).
-- Queries source tables directly rather than cvc_remove_flagged_outcomes (materialized)
-- to avoid stale data issues.
remove_flagged_submissions AS (
  SELECT DISTINCT fco.annotation_id
  FROM `@@DATASET@@.cvc_flagging_candidate_outcomes` fco
  WHERE EXISTS (
    SELECT 1
    FROM `@@DATASET@@.cvc_annotations_view` a
    WHERE a.action = 'remove flagged submission'
      AND a.scv_id = fco.scv_id
      AND a.is_submitted = TRUE
  )
),
-- Each row in the intersection table represents a unique batch submission (annotation_id)
-- Aggregate version bump info per submission, not per SCV
submission_summary AS (
  SELECT
    fvi.annotation_id,
    fvi.scv_id,
    fvi.batch_id,
    fvi.current_outcome,
    fvi.submitted_scv_ver,
    fvi.current_version,
    fvi.grace_period_end_date,
    LOGICAL_OR(fvi.is_version_bump = TRUE AND fvi.bump_during_grace_period = TRUE) AS had_bump_during_grace,
    LOGICAL_OR(fvi.is_version_bump = TRUE AND fvi.bump_during_grace_period = FALSE) AS had_bump_after_grace,
    LOGICAL_OR(fvi.is_version_bump = FALSE AND fvi.bump_from_submitted_version = TRUE) AS had_substantive_change,
    LOGICAL_OR(fvi.scv_id IN (SELECT scv_id FROM `@@DATASET@@.cvc_rejected_scvs` WHERE batch_id = fvi.batch_id)) AS was_rejected,
    LOGICAL_OR(fvi.annotation_id IN (SELECT annotation_id FROM stale_submissions)) AS was_stale_at_submission,
    LOGICAL_OR(fvi.annotation_id IN (SELECT annotation_id FROM remove_flagged_submissions)) AS had_remove_flagged_submission
  FROM `@@DATASET@@.cvc_flagging_version_bump_intersection` fvi
  GROUP BY fvi.annotation_id, fvi.scv_id, fvi.batch_id, fvi.current_outcome,
           fvi.submitted_scv_ver, fvi.current_version, fvi.grace_period_end_date
),
-- Categorize each submission (not SCV) into exactly ONE mutually exclusive bucket
submission_categories AS (
  SELECT
    annotation_id,
    CASE
      WHEN was_rejected THEN 'rejected'
      -- CVC explicitly requested flag removal — supersedes other outcomes
      WHEN had_remove_flagged_submission THEN 'unflagged'
      WHEN current_outcome = 'flagged' THEN 'flagged'
      WHEN current_outcome = 'scv_reclassified' THEN 'reclassified'
      WHEN current_outcome = 'scv_removed' THEN 'removed'
      WHEN current_outcome = 'scv_updated_same_classification'
        AND had_bump_during_grace THEN 'bump_during_grace'
      WHEN current_outcome = 'scv_updated_same_classification'
        AND had_bump_after_grace THEN 'bump_after_grace'
      WHEN current_outcome = 'scv_updated_same_classification'
        AND had_substantive_change THEN 'substantive_same_class'
      WHEN current_outcome = 'scv_updated_same_classification'
        AND was_stale_at_submission THEN 'stale_at_submission'
      WHEN current_outcome = 'pending'
        AND CURRENT_DATE() > grace_period_end_date
        AND current_version = submitted_scv_ver THEN 'anomaly_should_flag'
      WHEN current_outcome = 'pending'
        AND CURRENT_DATE() <= grace_period_end_date THEN 'within_grace_pending'
      ELSE 'other'
    END AS category
  FROM submission_summary
),
-- Calculate totals for both rows
totals AS (
  SELECT
    COUNT(*) AS total_submitted,
    COUNTIF(category = 'flagged') AS flagged,
    COUNTIF(category = 'reclassified') AS reclassified,
    COUNTIF(category = 'removed') AS removed,
    COUNTIF(category = 'substantive_same_class') AS substantive_changes,
    COUNTIF(category = 'within_grace_pending') AS within_grace_pending,
    COUNTIF(category = 'bump_during_grace') AS version_bump_during_grace,
    COUNTIF(category = 'bump_after_grace') AS version_bump_after_grace,
    COUNTIF(category = 'stale_at_submission') AS stale_at_submission,
    COUNTIF(category = 'unflagged') AS unflagged,
    COUNTIF(category = 'anomaly_should_flag') AS anomaly_should_flag,
    COUNTIF(category = 'rejected') AS rejected_by_ncbi,
    COUNTIF(category = 'other') AS other_unknown
  FROM submission_categories
)
-- Two-row output: Row 1 = Total as single solid bar, Row 2 = Breakdown as stacked segments
-- Column names match pie chart category labels with zero-padded numbering
-- Row 1: Total Submitted - puts entire count in first column for a solid bar
SELECT
  1 AS sort_order,
  'Total Submitted' AS label,
  total_submitted AS `00_Total_Submitted`,
  0 AS `01_Flagged`,
  0 AS `02_Reclassified`,
  0 AS `03_Removed`,
  0 AS `04_Substantive_Changes`,
  0 AS `05_Within_Grace_Pending`,
  0 AS `06_Version_Bump_During_Grace`,
  0 AS `07_Version_Bump_After_Grace`,
  0 AS `08_Stale_at_Submission`,
  0 AS `09_Unflagged`,
  0 AS `10_Anomaly_Should_Flag`,
  0 AS `11_Rejected_by_NCBI`,
  0 AS `12_Other_Unknown`
FROM totals
UNION ALL
-- Row 2: Breakdown - stacked segments (Total_Submitted = 0 so it doesn't add to bar)
SELECT
  2 AS sort_order,
  'Breakdown' AS label,
  0 AS `00_Total_Submitted`,
  flagged AS `01_Flagged`,
  reclassified AS `02_Reclassified`,
  removed AS `03_Removed`,
  substantive_changes AS `04_Substantive_Changes`,
  within_grace_pending AS `05_Within_Grace_Pending`,
  version_bump_during_grace AS `06_Version_Bump_During_Grace`,
  version_bump_after_grace AS `07_Version_Bump_After_Grace`,
  stale_at_submission AS `08_Stale_at_Submission`,
  unflagged AS `09_Unflagged`,
  anomaly_should_flag AS `10_Anomaly_Should_Flag`,
  rejected_by_ncbi AS `11_Rejected_by_NCBI`,
  other_unknown AS `12_Other_Unknown`
FROM totals
ORDER BY sort_order;


-- =============================================================================
-- Google Sheets View: Pie Chart - Flagging Candidate Outcome Breakdown
-- =============================================================================
--
-- Visualization: Pie Chart
-- Purpose: Shows proportion of each outcome category for all flagging candidates
--
-- Chart Setup in Google Sheets:
--   - Chart Type: Pie Chart
--   - Labels: category
--   - Values: count
--
-- =============================================================================

CREATE OR REPLACE VIEW `@@DATASET@@.sheets_flagging_candidate_pie`
AS
WITH
-- Identify stale submissions: submitted version was already outdated when batch was accepted
-- Now keyed by annotation_id to handle same SCV in multiple batches
stale_submissions AS (
  SELECT DISTINCT fco.annotation_id
  FROM `@@DATASET@@.cvc_flagging_candidate_outcomes` fco
  JOIN `@@DATASET@@.cvc_version_bumps` vb
    ON fco.scv_id = vb.scv_id
    AND vb.previous_version = fco.submitted_scv_ver
    AND vb.current_start_date < fco.batch_accepted_date
),
-- Flagging candidate submissions where CVC also submitted a "remove flagged submission"
-- for the same SCV (meaning CVC explicitly requested the flag be removed).
-- Queries source tables directly rather than cvc_remove_flagged_outcomes (materialized)
-- to avoid stale data issues.
remove_flagged_submissions AS (
  SELECT DISTINCT fco.annotation_id
  FROM `@@DATASET@@.cvc_flagging_candidate_outcomes` fco
  WHERE EXISTS (
    SELECT 1
    FROM `@@DATASET@@.cvc_annotations_view` a
    WHERE a.action = 'remove flagged submission'
      AND a.scv_id = fco.scv_id
      AND a.is_submitted = TRUE
  )
),
-- Each row in the intersection table represents a unique batch submission (annotation_id)
-- Aggregate version bump info per submission, not per SCV
submission_summary AS (
  SELECT
    fvi.annotation_id,
    fvi.scv_id,
    fvi.batch_id,
    fvi.current_outcome,
    fvi.submitted_scv_ver,
    fvi.current_version,
    fvi.grace_period_end_date,
    LOGICAL_OR(fvi.is_version_bump = TRUE AND fvi.bump_during_grace_period = TRUE) AS had_bump_during_grace,
    LOGICAL_OR(fvi.is_version_bump = TRUE AND fvi.bump_during_grace_period = FALSE) AS had_bump_after_grace,
    LOGICAL_OR(fvi.is_version_bump = FALSE AND fvi.bump_from_submitted_version = TRUE) AS had_substantive_change,
    LOGICAL_OR(fvi.scv_id IN (SELECT scv_id FROM `@@DATASET@@.cvc_rejected_scvs` WHERE batch_id = fvi.batch_id)) AS was_rejected,
    LOGICAL_OR(fvi.annotation_id IN (SELECT annotation_id FROM stale_submissions)) AS was_stale_at_submission,
    LOGICAL_OR(fvi.annotation_id IN (SELECT annotation_id FROM remove_flagged_submissions)) AS had_remove_flagged_submission
  FROM `@@DATASET@@.cvc_flagging_version_bump_intersection` fvi
  GROUP BY fvi.annotation_id, fvi.scv_id, fvi.batch_id, fvi.current_outcome,
           fvi.submitted_scv_ver, fvi.current_version, fvi.grace_period_end_date
),
-- Categorize each submission (not SCV) into exactly ONE mutually exclusive bucket
submission_categories AS (
  SELECT
    annotation_id,
    CASE
      WHEN was_rejected THEN 'Rejected by NCBI'
      -- CVC explicitly requested flag removal — supersedes other outcomes
      WHEN had_remove_flagged_submission THEN 'Unflagged'
      WHEN current_outcome = 'flagged' THEN 'Flagged'
      WHEN current_outcome = 'scv_reclassified' THEN 'Reclassified'
      WHEN current_outcome = 'scv_removed' THEN 'Removed'
      WHEN current_outcome = 'scv_updated_same_classification'
        AND had_bump_during_grace THEN 'Version Bump During Grace'
      WHEN current_outcome = 'scv_updated_same_classification'
        AND had_bump_after_grace THEN 'Version Bump After Grace'
      WHEN current_outcome = 'scv_updated_same_classification'
        AND had_substantive_change THEN 'Substantive Changes'
      WHEN current_outcome = 'scv_updated_same_classification'
        AND was_stale_at_submission THEN 'Stale at Submission'
      WHEN current_outcome = 'pending'
        AND CURRENT_DATE() > grace_period_end_date
        AND current_version = submitted_scv_ver THEN 'Anomaly - Should Flag'
      WHEN current_outcome = 'pending'
        AND CURRENT_DATE() <= grace_period_end_date THEN 'Within Grace Pending'
      ELSE 'Other/Unknown'
    END AS category
  FROM submission_summary
),
totals AS (
  SELECT COUNT(*) AS total FROM submission_categories
)
-- Order matches funnel_pivoted column order for consistent visualization
-- First aggregate by original category, then add numbering (zero-padded to 2 digits)
SELECT
  sort_order,
  CONCAT(FORMAT('%02d', sort_order), '. ', category) AS category,
  count,
  pct
FROM (
  SELECT
    CASE category
      WHEN 'Flagged' THEN 1
      WHEN 'Reclassified' THEN 2
      WHEN 'Removed' THEN 3
      WHEN 'Substantive Changes' THEN 4
      WHEN 'Within Grace Pending' THEN 5
      WHEN 'Version Bump During Grace' THEN 6
      WHEN 'Version Bump After Grace' THEN 7
      WHEN 'Stale at Submission' THEN 8
      WHEN 'Unflagged' THEN 9
      WHEN 'Anomaly - Should Flag' THEN 10
      WHEN 'Rejected by NCBI' THEN 11
      ELSE 12
    END AS sort_order,
    category,
    COUNT(*) AS count,
    ROUND(100.0 * COUNT(*) / (SELECT total FROM totals), 1) AS pct
  FROM submission_categories
  GROUP BY category
)
ORDER BY sort_order;


-- =============================================================================
-- Google Sheets View: Timeline - Version Bump Timing Distribution
-- =============================================================================
--
-- Visualization: Histogram or Line Chart
-- Purpose: Shows WHEN version bumps occur relative to the grace period
--          to detect if submitters are strategically timing bumps
--
-- Chart Setup in Google Sheets:
--   - Chart Type: Column/Bar Chart or Line Chart
--   - X-axis: days_bucket (categorical)
--   - Y-axis: bump_count
--   - Optional: Add a vertical reference line at "Day 60" bucket
--
-- =============================================================================

CREATE OR REPLACE VIEW `@@DATASET@@.sheets_version_bump_timing`
AS
WITH timing_data AS (
  SELECT
    CASE
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) < 0 THEN 0
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) BETWEEN 0 AND 14 THEN 1
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) BETWEEN 15 AND 30 THEN 2
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) BETWEEN 31 AND 45 THEN 3
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) BETWEEN 46 AND 60 THEN 4
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) BETWEEN 61 AND 90 THEN 5
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) BETWEEN 91 AND 180 THEN 6
      ELSE 7
    END AS sort_order,
    CASE
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) < 0 THEN 'Before Acceptance'
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) BETWEEN 0 AND 14 THEN 'Days 0-14'
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) BETWEEN 15 AND 30 THEN 'Days 15-30'
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) BETWEEN 31 AND 45 THEN 'Days 31-45'
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) BETWEEN 46 AND 60 THEN 'Days 46-60 (End of Grace)'
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) BETWEEN 61 AND 90 THEN 'Days 61-90'
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) BETWEEN 91 AND 180 THEN 'Days 91-180'
      ELSE 'Days 180+'
    END AS days_bucket_label,
    scv_id,
    is_version_bump
  FROM `@@DATASET@@.cvc_flagging_version_bump_intersection`
  WHERE bump_date IS NOT NULL
)
SELECT
  sort_order,
  CONCAT(FORMAT('%02d', sort_order), '. ', days_bucket_label) AS days_bucket,
  COUNT(*) AS bump_count,
  COUNT(DISTINCT scv_id) AS unique_scvs,
  COUNTIF(is_version_bump = TRUE) AS version_bumps_no_change,
  COUNTIF(is_version_bump = FALSE) AS version_changes_substantive
FROM timing_data
GROUP BY sort_order, days_bucket_label
ORDER BY sort_order;


-- =============================================================================
-- Google Sheets View: Timeline - Version Bump Timing Summary (Grace Period)
-- =============================================================================
--
-- Visualization: Simple 2-bar Column Chart
-- Purpose: Simplified view showing totals BEFORE vs AFTER the 60-day grace period
--          Makes summing easier for quick comparison
--
-- Chart Setup in Google Sheets:
--   - Chart Type: Column/Bar Chart
--   - X-axis: grace_period_status
--   - Series 1: version_bumps_no_change (red/orange)
--   - Series 2: version_changes_substantive (blue)
--
-- =============================================================================

CREATE OR REPLACE VIEW `@@DATASET@@.sheets_version_bump_timing_summary`
AS
WITH timing_data AS (
  SELECT
    CASE
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) < 0 THEN 'before_acceptance'
      WHEN DATE_DIFF(bump_date, batch_accepted_date, DAY) BETWEEN 0 AND 60 THEN 'within_grace'
      ELSE 'after_grace'
    END AS grace_period_status,
    scv_id,
    is_version_bump
  FROM `@@DATASET@@.cvc_flagging_version_bump_intersection`
  WHERE bump_date IS NOT NULL
)
SELECT
  CASE timing_data.grace_period_status
    WHEN 'within_grace' THEN 1
    WHEN 'after_grace' THEN 2
    ELSE 0
  END AS sort_order,
  CASE timing_data.grace_period_status
    WHEN 'within_grace' THEN 'Within Grace (0-60 days)'
    WHEN 'after_grace' THEN 'After Grace (61+ days)'
    ELSE 'Before Acceptance'
  END AS grace_period_label,
  COUNT(*) AS total_version_changes,
  COUNT(DISTINCT scv_id) AS unique_scvs,
  COUNTIF(is_version_bump = TRUE) AS version_bumps_no_change,
  COUNTIF(is_version_bump = FALSE) AS version_changes_substantive
FROM timing_data
WHERE timing_data.grace_period_status != 'before_acceptance'
GROUP BY timing_data.grace_period_status
ORDER BY sort_order;
