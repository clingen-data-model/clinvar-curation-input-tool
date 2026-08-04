-- =============================================================================
-- Resubmission Candidates: Unflagged Flagging Candidates
-- =============================================================================
--
-- Purpose:
--   Identifies SCVs submitted as flagging candidates that should be re-submitted
--   to ClinVar because they are not currently flagged despite meeting criteria:
--
--   1. Past the 60-day grace period with no version change, OR
--   2. Had a version bump (resubmission with no substantive changes)
--
--   This produces an actionable list for re-submission to ClinVar.
--
-- Inclusion Criteria:
--   - Was submitted as a flagging candidate
--   - NOT rejected by ClinVar
--   - NOT currently flagged (rank != -3)
--   - NOT removed (can't re-submit removed SCVs)
--   - AND either:
--     - Had a version bump after batch acceptance → reason: 'version_bump'
--     - OR past grace period with no version change → reason: 'grace_period_expired'
--
-- Exclusions:
--   - Within grace period AND no version bump (still waiting)
--
-- Special Markers:
--   - was_reclassified: submitter changed classification (may need review)
--   - has_remove_flagged_submission: a "remove flagged submission" was submitted
--
-- Dependencies:
--   - clinvar_curator.cvc_flagging_candidate_outcomes
--   - clinvar_curator.cvc_version_bumps
--   - clinvar_curator.cvc_remove_flagged_outcomes
--   - clinvar_curator.cvc_batches_enriched
--   - clinvar_ingest.clinvar_submitters
--
-- Output:
--   - clinvar_curator.cvc_resubmission_candidates
--
-- =============================================================================

CREATE OR REPLACE TABLE `clinvar_curator.cvc_resubmission_candidates`
AS
WITH
-- Get all flagging candidates that are NOT currently flagged and NOT removed
unflagged_candidates AS (
  SELECT
    fco.batch_id,
    fco.annotation_id,
    fco.scv_id,
    fco.submitted_scv_ver,
    fco.variation_id,
    fco.vcv_id,
    fco.submitter_id,
    fco.reason AS flagging_reason,
    fco.batch_accepted_date,
    fco.grace_period_end_date,
    fco.first_release_after_grace_period,
    -- Submitted state
    fco.submitted_classif_type,
    fco.submitted_classification,
    fco.submitted_rank,
    -- Current state
    fco.current_version AS current_scv_ver,
    fco.current_classif_type,
    fco.current_classification,
    fco.current_rank,
    fco.outcome,
    -- Is past grace period?
    (CURRENT_DATE() > fco.grace_period_end_date) AS is_past_grace_period,
    -- Was reclassified? (classification type changed)
    (fco.current_classif_type IS NOT NULL
     AND fco.current_classif_type != fco.submitted_classif_type) AS was_reclassified,
    -- Rank changed?
    (fco.current_rank IS NOT NULL
     AND fco.submitted_rank IS NOT NULL
     AND fco.current_rank != fco.submitted_rank) AS rank_changed
  FROM `clinvar_curator.cvc_flagging_candidate_outcomes` fco
  WHERE fco.outcome != 'flagged'           -- Not currently flagged
    AND fco.outcome != 'scv_removed'       -- Not removed (can't re-submit)
    AND fco.current_rank IS NOT NULL       -- SCV still exists
    AND fco.current_rank != -3             -- Double-check not flagged
),

-- Get VCV version at time of submission
vcv_at_submission AS (
  SELECT
    uc.annotation_id,
    uc.variation_id,
    vcv.version AS submitted_vcv_ver
  FROM unflagged_candidates uc
  JOIN `clinvar_curator.cvc_annotations_view` a
    ON uc.annotation_id = a.annotation_id
  LEFT JOIN `clinvar_ingest.clinvar_vcvs` vcv
    ON uc.variation_id = vcv.variation_id
    AND a.annotation_release_date BETWEEN vcv.start_release_date AND vcv.end_release_date
  -- Ensure one VCV per annotation_id (take latest version if multiple match)
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY uc.annotation_id
    ORDER BY vcv.version DESC NULLS LAST
  ) = 1
),

-- Get current VCV version
vcv_current AS (
  SELECT
    uc.annotation_id,
    uc.variation_id,
    vcv.version AS current_vcv_ver
  FROM unflagged_candidates uc
  CROSS JOIN (
    SELECT release_date FROM `clinvar_ingest.schema_on`(CURRENT_DATE())
  ) latest
  LEFT JOIN `clinvar_ingest.clinvar_vcvs` vcv
    ON uc.variation_id = vcv.variation_id
    AND latest.release_date BETWEEN vcv.start_release_date AND vcv.end_release_date
  -- Ensure one VCV per annotation_id (take latest version if multiple match)
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY uc.annotation_id
    ORDER BY vcv.version DESC NULLS LAST
  ) = 1
),

-- Aggregate version bump info for each flagging candidate
version_bump_summary AS (
  SELECT
    uc.annotation_id,
    uc.scv_id,
    -- Did this SCV have any version bump after batch acceptance?
    LOGICAL_OR(vb.is_version_bump = TRUE) AS had_version_bump,
    -- Count of version bumps
    COUNTIF(vb.is_version_bump = TRUE) AS version_bump_count,
    -- First and latest bump dates
    MIN(CASE WHEN vb.is_version_bump = TRUE THEN vb.current_start_date END) AS first_bump_date,
    MAX(CASE WHEN vb.is_version_bump = TRUE THEN vb.current_start_date END) AS latest_bump_date
  FROM unflagged_candidates uc
  LEFT JOIN `clinvar_curator.cvc_version_bumps` vb
    ON uc.scv_id = vb.scv_id
    AND vb.current_start_date >= uc.batch_accepted_date  -- Bump after batch acceptance
  GROUP BY uc.annotation_id, uc.scv_id
),

-- Get "remove flagged submission" details if any exist for these SCVs
remove_flagged_details AS (
  SELECT
    uc.annotation_id,
    uc.scv_id,
    rfo.batch_id AS remove_batch_id,
    rfo.batch_accepted_date AS remove_batch_accepted_date,
    rfo.outcome AS remove_outcome
  FROM unflagged_candidates uc
  JOIN `clinvar_curator.cvc_remove_flagged_outcomes` rfo
    ON uc.scv_id = rfo.scv_id
  -- Take the most recent remove flagged submission if multiple exist
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY uc.annotation_id
    ORDER BY rfo.batch_accepted_date DESC
  ) = 1
),

-- Combine all data and apply final filtering
candidates_with_details AS (
  SELECT
    uc.*,
    -- VCV version info
    vcv_sub.submitted_vcv_ver,
    vcv_cur.current_vcv_ver,
    (vcv_sub.submitted_vcv_ver IS NOT NULL
     AND vcv_cur.current_vcv_ver IS NOT NULL
     AND vcv_sub.submitted_vcv_ver != vcv_cur.current_vcv_ver) AS vcv_version_changed,
    -- Version bump details
    COALESCE(vbs.had_version_bump, FALSE) AS had_version_bump,
    COALESCE(vbs.version_bump_count, 0) AS version_bump_count,
    vbs.first_bump_date,
    vbs.latest_bump_date,
    -- Remove flagged submission details
    (rfd.remove_batch_id IS NOT NULL) AS has_remove_flagged_submission,
    rfd.remove_batch_id,
    rfd.remove_batch_accepted_date,
    rfd.remove_outcome,
    -- Determine resubmission reason
    CASE
      WHEN COALESCE(vbs.had_version_bump, FALSE) AND uc.is_past_grace_period THEN 'both'
      WHEN COALESCE(vbs.had_version_bump, FALSE) THEN 'version_bump'
      WHEN uc.is_past_grace_period THEN 'grace_period_expired'
      ELSE NULL  -- Should not happen given our filtering, but safety net
    END AS resubmission_reason
  FROM unflagged_candidates uc
  LEFT JOIN vcv_at_submission vcv_sub
    ON uc.annotation_id = vcv_sub.annotation_id
  LEFT JOIN vcv_current vcv_cur
    ON uc.annotation_id = vcv_cur.annotation_id
  LEFT JOIN version_bump_summary vbs
    ON uc.annotation_id = vbs.annotation_id
  LEFT JOIN remove_flagged_details rfd
    ON uc.annotation_id = rfd.annotation_id
  -- Apply final filter: must have version bump OR be past grace period
  WHERE COALESCE(vbs.had_version_bump, FALSE) = TRUE
     OR uc.is_past_grace_period = TRUE
)

-- Final output with submitter name
SELECT
  -- Core identification
  c.scv_id,
  c.variation_id,
  c.vcv_id,
  c.submitter_id,
  sub.current_name AS submitter_name,

  -- Original submission context
  c.batch_id,
  c.annotation_id,
  c.batch_accepted_date,
  c.grace_period_end_date,
  c.submitted_scv_ver,
  c.submitted_classification,
  c.submitted_classif_type,
  c.submitted_rank,
  c.flagging_reason,

  -- Current state
  c.current_scv_ver,
  c.current_classification,
  c.current_classif_type,
  c.current_rank,
  c.outcome,

  -- Rank comparison
  c.rank_changed,

  -- VCV version comparison
  c.submitted_vcv_ver,
  c.current_vcv_ver,
  c.vcv_version_changed,

  -- Resubmission flags
  c.resubmission_reason,
  c.is_past_grace_period,
  c.had_version_bump,
  c.was_reclassified,

  -- Version bump details
  c.version_bump_count,
  c.first_bump_date,
  c.latest_bump_date,

  -- Remove flagged submission details
  c.has_remove_flagged_submission,
  c.remove_batch_id,
  c.remove_batch_accepted_date,
  c.remove_outcome

FROM candidates_with_details c
LEFT JOIN `clinvar_ingest.clinvar_submitters` sub
  ON c.submitter_id = sub.id
  AND sub.deleted_release_date IS NULL
ORDER BY
  c.resubmission_reason,
  c.batch_id,
  c.scv_id;


-- =============================================================================
-- Summary View: Resubmission Candidates by Reason
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.cvc_resubmission_summary`
AS
SELECT
  resubmission_reason,
  COUNT(*) AS total_candidates,
  COUNTIF(was_reclassified) AS reclassified_count,
  COUNTIF(has_remove_flagged_submission) AS with_remove_request,
  COUNT(DISTINCT scv_id) AS unique_scvs,
  COUNT(DISTINCT variation_id) AS unique_variants,
  COUNT(DISTINCT submitter_id) AS unique_submitters
FROM `clinvar_curator.cvc_resubmission_candidates`
GROUP BY resubmission_reason
ORDER BY
  CASE resubmission_reason
    WHEN 'both' THEN 1
    WHEN 'version_bump' THEN 2
    WHEN 'grace_period_expired' THEN 3
    ELSE 4
  END;


-- =============================================================================
-- Summary View: Resubmission Candidates by Batch
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.cvc_resubmission_by_batch`
AS
SELECT
  batch_id,
  batch_accepted_date,
  grace_period_end_date,
  COUNT(*) AS total_candidates,
  COUNTIF(resubmission_reason = 'version_bump') AS version_bump_only,
  COUNTIF(resubmission_reason = 'grace_period_expired') AS grace_expired_only,
  COUNTIF(resubmission_reason = 'both') AS both_reasons,
  COUNTIF(was_reclassified) AS reclassified_count,
  COUNTIF(has_remove_flagged_submission) AS with_remove_request,
  COUNT(DISTINCT scv_id) AS unique_scvs
FROM `clinvar_curator.cvc_resubmission_candidates`
GROUP BY batch_id, batch_accepted_date, grace_period_end_date
ORDER BY batch_id;


-- =============================================================================
-- Summary View: Resubmission Candidates by Submitter
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.cvc_resubmission_by_submitter`
AS
SELECT
  submitter_id,
  submitter_name,
  COUNT(*) AS total_candidates,
  COUNTIF(resubmission_reason = 'version_bump') AS version_bump_only,
  COUNTIF(resubmission_reason = 'grace_period_expired') AS grace_expired_only,
  COUNTIF(resubmission_reason = 'both') AS both_reasons,
  COUNTIF(was_reclassified) AS reclassified_count,
  COUNTIF(has_remove_flagged_submission) AS with_remove_request,
  COUNT(DISTINCT scv_id) AS unique_scvs,
  COUNT(DISTINCT variation_id) AS unique_variants
FROM `clinvar_curator.cvc_resubmission_candidates`
GROUP BY submitter_id, submitter_name
ORDER BY total_candidates DESC;


-- =============================================================================
-- Export View: Minimal Resubmission List
-- =============================================================================
--
-- Simplified view for direct export to submission workflow.
-- Excludes reclassified SCVs by default (may need manual review).
--

CREATE OR REPLACE VIEW `clinvar_curator.cvc_resubmission_export`
AS
SELECT
  scv_id,
  current_scv_ver AS scv_ver,
  variation_id,
  vcv_id,
  submitter_id,
  submitter_name,
  flagging_reason,
  resubmission_reason,
  has_remove_flagged_submission,
  was_reclassified
FROM `clinvar_curator.cvc_resubmission_candidates`
WHERE was_reclassified = FALSE  -- Exclude reclassified for direct resubmission
ORDER BY resubmission_reason, scv_id;


-- =============================================================================
-- Review View: Reclassified SCVs Needing Manual Review
-- =============================================================================
--
-- SCVs that were reclassified by submitter - may or may not still need flagging.
-- These require manual review before resubmission.
--

CREATE OR REPLACE VIEW `clinvar_curator.cvc_resubmission_review_reclassified`
AS
SELECT
  scv_id,
  variation_id,
  vcv_id,
  submitter_id,
  submitter_name,
  flagging_reason,
  -- Original vs current classification
  submitted_classif_type AS original_classif_type,
  submitted_classification AS original_classification,
  current_classif_type,
  current_classification,
  -- Context
  resubmission_reason,
  batch_id,
  batch_accepted_date,
  has_remove_flagged_submission,
  remove_batch_id,
  remove_outcome
FROM `clinvar_curator.cvc_resubmission_candidates`
WHERE was_reclassified = TRUE
ORDER BY submitter_name, scv_id;


-- =============================================================================
-- Google Sheets Views: Human-Readable for Data Connector
-- =============================================================================
--
-- These views are designed for Google Sheets Connected Sheets with:
--   - Clear, descriptive column names
--   - Human-readable values (not codes)
--   - Sorted for logical grouping
--
-- =============================================================================


-- =============================================================================
-- Google Sheets View: Actionable Resubmission List
-- =============================================================================
--
-- Purpose: Main list of SCVs that need to be resubmitted to ClinVar.
--          Excludes reclassified SCVs (those need separate review).
--
-- For non-technical users:
--   This is the list of submissions that should have resulted in a flag
--   being applied to the SCV, but the flag was never applied. These need
--   to be resubmitted to ClinVar.
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.sheets_resubmission_actionable`
AS
SELECT
  -- Identifiers with ClinVar links
  scv_id AS `SCV ID`,
  CONCAT('https://www.ncbi.nlm.nih.gov/clinvar/variation/', variation_id) AS `ClinVar VCV Link`,
  variation_id AS `Variation ID`,

  -- Submitter info
  submitter_name AS `Submitter Name`,
  submitter_id AS `Submitter ID`,

  -- Why does this need resubmission?
  CASE resubmission_reason
    WHEN 'version_bump' THEN 'Version bump without changes'
    WHEN 'grace_period_expired' THEN 'Grace period expired'
    WHEN 'both' THEN 'Both: Version bump + Grace period expired'
    ELSE resubmission_reason
  END AS `Why Resubmission Needed`,

  -- Original flagging reason
  flagging_reason AS `Original Flagging Reason`,

  -- Timeline
  batch_accepted_date AS `Date ClinVar Accepted Submission`,
  grace_period_end_date AS `60-Day Grace Period Ended`,
  DATE_DIFF(CURRENT_DATE(), grace_period_end_date, DAY) AS `Days Past Grace Period`,

  -- Current state
  current_scv_ver AS `Current SCV Version`,
  current_classification AS `Current Classification`,

  -- Rank comparison
  submitted_rank AS `Submitted SCV Rank`,
  current_rank AS `Current SCV Rank`,
  CASE
    WHEN rank_changed THEN CONCAT(CAST(submitted_rank AS STRING), ' → ', CAST(current_rank AS STRING))
    ELSE 'No change'
  END AS `SCV Rank Change`,

  -- VCV version comparison
  submitted_vcv_ver AS `Submitted VCV Version`,
  current_vcv_ver AS `Current VCV Version`,
  CASE
    WHEN vcv_version_changed THEN CONCAT('v', CAST(submitted_vcv_ver AS STRING), ' → v', CAST(current_vcv_ver AS STRING))
    ELSE 'No change'
  END AS `VCV Version Change`,

  -- Version bump details
  CASE
    WHEN had_version_bump THEN CONCAT('Yes (', CAST(version_bump_count AS STRING), ' bump(s))')
    ELSE 'No'
  END AS `Had Version Bump`,
  latest_bump_date AS `Last Version Bump Date`,

  -- Remove flagged submission info
  CASE
    WHEN has_remove_flagged_submission THEN CONCAT('Yes (', remove_outcome, ')')
    ELSE 'No'
  END AS `Remove Flag Requested`,
  remove_batch_accepted_date AS `Remove Request Date`,

  -- For sorting/filtering
  batch_id AS `Batch ID`

FROM `clinvar_curator.cvc_resubmission_candidates`
WHERE was_reclassified = FALSE
ORDER BY
  CASE resubmission_reason
    WHEN 'both' THEN 1
    WHEN 'version_bump' THEN 2
    WHEN 'grace_period_expired' THEN 3
    ELSE 4
  END,
  submitter_name,
  scv_id;


-- =============================================================================
-- Google Sheets View: Reclassified SCVs for Review
-- =============================================================================
--
-- Purpose: SCVs where the submitter changed their classification after
--          we submitted them as flagging candidates. These need manual
--          review to determine if the new classification still warrants
--          flagging.
--
-- For non-technical users:
--   These submissions were made for SCVs that the submitter has since
--   changed. Review the original vs. current classification to decide
--   if flagging is still appropriate.
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.sheets_resubmission_needs_review`
AS
SELECT
  -- Identifiers
  scv_id AS `SCV ID`,
  CONCAT('https://www.ncbi.nlm.nih.gov/clinvar/variation/', variation_id) AS `ClinVar VCV Link`,

  -- Submitter info
  submitter_name AS `Submitter Name`,

  -- Classification comparison
  submitted_classification AS `Original Classification - When Submitted`,
  current_classification AS `Current Classification - Now`,
  CONCAT(submitted_classif_type, ' → ', current_classif_type) AS `Classification Type Change`,

  -- Rank comparison
  CASE
    WHEN rank_changed THEN CONCAT(CAST(submitted_rank AS STRING), ' → ', CAST(current_rank AS STRING))
    ELSE 'No change'
  END AS `SCV Rank Change`,

  -- VCV version comparison
  CASE
    WHEN vcv_version_changed THEN CONCAT('v', CAST(submitted_vcv_ver AS STRING), ' → v', CAST(current_vcv_ver AS STRING))
    ELSE 'No change'
  END AS `VCV Version Change`,

  -- Why does this need resubmission?
  CASE resubmission_reason
    WHEN 'version_bump' THEN 'Version bump without changes'
    WHEN 'grace_period_expired' THEN 'Grace period expired'
    WHEN 'both' THEN 'Both: Version bump + Grace period expired'
    ELSE resubmission_reason
  END AS `Why Resubmission Would Be Needed`,

  -- Original flagging reason
  flagging_reason AS `Original Flagging Reason`,

  -- Remove flag info (important context for reclassified)
  CASE
    WHEN has_remove_flagged_submission THEN 'Yes'
    ELSE 'No'
  END AS `Remove Flag Was Requested`,
  remove_outcome AS `Remove Request Outcome`,

  -- Timeline
  batch_accepted_date AS `Original Submission Date`,

  -- Action needed
  'Review if new classification still warrants flagging' AS `Action Needed`

FROM `clinvar_curator.cvc_resubmission_candidates`
WHERE was_reclassified = TRUE
ORDER BY submitter_name, scv_id;


-- =============================================================================
-- Google Sheets View: Summary Dashboard
-- =============================================================================
--
-- Purpose: High-level summary for dashboard/overview.
--          Shows counts by reason with human-readable labels.
--
-- For non-technical users:
--   This shows a summary of how many SCVs need attention and why.
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.sheets_resubmission_summary`
AS
SELECT
  CASE resubmission_reason
    WHEN 'version_bump' THEN '1. Version Bump - No Real Changes'
    WHEN 'grace_period_expired' THEN '2. Grace Period Expired'
    WHEN 'both' THEN '3. Both Reasons'
    ELSE '4. Other'
  END AS `Reason for Resubmission`,

  COUNT(*) AS `Total SCVs`,
  COUNTIF(was_reclassified = FALSE) AS `Ready to Resubmit`,
  COUNTIF(was_reclassified = TRUE) AS `Needs Review - Reclassified`,
  COUNTIF(vcv_version_changed) AS `VCV Version Changed`,
  COUNTIF(rank_changed) AS `SCV Rank Changed`,
  COUNTIF(has_remove_flagged_submission) AS `Had Remove Flag Request`,
  COUNT(DISTINCT submitter_id) AS `Unique Submitters`,
  COUNT(DISTINCT variation_id) AS `Unique Variants`

FROM `clinvar_curator.cvc_resubmission_candidates`
GROUP BY resubmission_reason
ORDER BY
  CASE resubmission_reason
    WHEN 'both' THEN 1
    WHEN 'version_bump' THEN 2
    WHEN 'grace_period_expired' THEN 3
    ELSE 4
  END;


-- =============================================================================
-- Google Sheets View: By Submitter Summary
-- =============================================================================
--
-- Purpose: Shows which submitters have the most SCVs needing resubmission.
--          Useful for identifying patterns or prioritizing outreach.
--
-- For non-technical users:
--   This shows which labs/submitters have SCVs that escaped flagging,
--   sorted by the number of affected submissions.
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.sheets_resubmission_by_submitter`
AS
SELECT
  submitter_name AS `Submitter Name`,
  COUNT(*) AS `Total SCVs Needing Action`,
  COUNTIF(was_reclassified = FALSE) AS `Ready to Resubmit`,
  COUNTIF(was_reclassified = TRUE) AS `Needs Review`,
  COUNTIF(resubmission_reason = 'version_bump') AS `Due to Version Bump`,
  COUNTIF(resubmission_reason = 'grace_period_expired') AS `Due to Expired Grace Period`,
  COUNTIF(resubmission_reason = 'both') AS `Due to Both Reasons`,
  COUNTIF(vcv_version_changed) AS `VCV Version Changed`,
  COUNTIF(rank_changed) AS `SCV Rank Changed`,
  COUNTIF(has_remove_flagged_submission) AS `Had Remove Flag Request`,
  COUNT(DISTINCT variation_id) AS `Unique Variants Affected`

FROM `clinvar_curator.cvc_resubmission_candidates`
GROUP BY submitter_name
HAVING COUNT(*) > 0
ORDER BY COUNT(*) DESC;


-- =============================================================================
-- Google Sheets View: Glossary/Legend
-- =============================================================================
--
-- Purpose: Provides definitions for non-technical users.
--          Can be placed on a separate tab in the Google Sheet.
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.sheets_resubmission_glossary`
AS
SELECT * FROM UNNEST([
  STRUCT(
    'SCV' AS `Term`,
    'Submission Accession - A unique identifier for each submission to ClinVar (e.g., SCV000123456)' AS `Definition`
  ),
  STRUCT(
    'VCV',
    'Variant Accession - The ClinVar ID for a variant that may have multiple submissions (e.g., VCV000012345)'
  ),
  STRUCT(
    'VCV Version',
    'ClinVar increments the VCV version when there are meaningful changes to the variant record (e.g., new submissions, aggregate classification change). A VCV version change indicates the variant record has been updated.'
  ),
  STRUCT(
    'SCV Rank',
    'A numeric value indicating the clinical significance tier of an SCV. Higher numbers = stronger assertions (e.g., Pathogenic). Rank -3 means the SCV is flagged. A rank change may indicate the submitter updated their assertion strength.'
  ),
  STRUCT(
    'Flagging Candidate',
    'An SCV that CVC submitted to ClinVar to be flagged as potentially incorrect or conflicting'
  ),
  STRUCT(
    'Version Bump',
    'When a submitter resubmits their SCV without making real changes (same classification, same evidence). This can prevent flags from being applied.'
  ),
  STRUCT(
    'Grace Period',
    'ClinVar gives submitters 60 days to respond to flagging requests before applying the flag. After this period, the flag should be applied.'
  ),
  STRUCT(
    'Remove Flag Request',
    'A separate submission CVC made to remove a flag from an SCV. If present, the SCV may have been unflagged intentionally.'
  ),
  STRUCT(
    'Reclassified',
    'The submitter changed their classification (e.g., Pathogenic to VUS). These need manual review to determine if flagging is still appropriate.'
  ),
  STRUCT(
    'Ready to Resubmit',
    'SCVs that can be immediately resubmitted as flagging candidates - no manual review needed'
  ),
  STRUCT(
    'Needs Review',
    'SCVs where the submitter changed their classification - requires manual review before deciding to resubmit'
  )
]);
