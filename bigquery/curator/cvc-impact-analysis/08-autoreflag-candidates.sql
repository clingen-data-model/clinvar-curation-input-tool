-- =============================================================================
-- Auto-Reflag Candidates: Flagging Candidate SCVs Needing Re-Flagging
-- =============================================================================
--
-- Purpose:
--   Identifies SCVs that were submitted as CVC flagging candidates but are
--   currently NOT flagged, and where the submitter resubmitted with NO changes
--   to classification, evidence summary (classification_comment), or condition
--   name (trait_set_id).
--
--   This includes SCVs that:
--   - Were flagged (rank = -3) and then lost the flag via version bump
--   - Were NEVER flagged because the submitter bumped the version during
--     the 60-90 day grace period, preventing the flag from being applied
--
--   These are candidates for automatic re-flagging because the submitter
--   effectively "bumped" the version without addressing the underlying issue.
--
-- Scope:
--   Limited to 7 labs known to exhibit this pattern:
--     1. LabCorp Genetics (Laboratory Corporation of America)
--     2. CeGaT GmbH
--     3. Revvity (formerly PerkinElmer Genomics)
--     4. OMIM
--     5. Baylor Genetics
--     6. Counsyl
--     7. Eurofins Clinical Genetics
--
-- Criteria for auto-reflagging:
--   1. SCV was submitted as a CVC flagging candidate (not rejected)
--   2. Only the MOST RECENT flagging candidate submission per SCV is considered
--      (avoids double-counting historically outdated submissions)
--   3. No "remove flagged submission" was accepted AFTER the most recent
--      flagging candidate submission for that SCV
--   4. SCV is currently NOT flagged (current rank != -3)
--   5. SCV is not removed (still exists in current release)
--   6. A version change occurred after the flagging candidate was submitted
--   7. The version change did NOT alter any of the 5 substantive fields
--      (same fields used by version bump detection in 05):
--      - Classification (classif_type)
--      - Submitted classification text (submitted_classification)
--      - Last evaluated date (last_evaluated)
--      - Condition/trait (trait_set_id)
--      - PubMed citations (pmids)
--      - Evidence summary (classification_comment)
--   8. SCV belongs to one of the 7 target labs
--
-- Related:
--   - Prior work documented in clingen-data-model/clinvar-curation-reporting#37
--   - Complements 07-resubmission-candidates.sql (which covers all labs)
--
-- Dependencies:
--   - clinvar_curator.cvc_flagging_candidate_outcomes
--   - clinvar_curator.cvc_remove_flagged_outcomes
--   - clinvar_ingest.clinvar_scvs
--   - clinvar_ingest.clinvar_submitters
--
-- Output:
--   - clinvar_curator.cvc_autoreflag_candidates
--   - clinvar_curator.cvc_autoreflag_summary
--   - clinvar_curator.sheets_autoreflag_actionable (Google Sheets view)
--   - clinvar_curator.sheets_autoreflag_by_submitter (Google Sheets view)
--
-- =============================================================================


-- =============================================================================
-- Target Labs for Auto-Reflagging
-- =============================================================================
--
-- These 7 labs have been identified as having SCVs that were submitted as
-- flagging candidates, then resubmitted with no meaningful changes, preventing
-- or removing the flag. Auto-reflagging is approved for these submitters only.
--
-- NOTE: Submitter name matching uses LIKE patterns to handle variations in
-- naming (e.g., "LabCorp Genetics" vs "Laboratory Corporation of America,
-- LabCorp Genetics"). If a lab is not matching, check the current_name in
-- clinvar_ingest.clinvar_submitters and update the pattern below.
--
-- =============================================================================

CREATE OR REPLACE TABLE `clinvar_curator.cvc_autoreflag_candidates`
AS
WITH
-- Define the 7 target labs by name pattern
-- Using LIKE patterns to handle name variations in clinvar_submitters
target_labs AS (
  SELECT submitter_id, submitter_label
  FROM UNNEST([
    STRUCT('LabCorp' AS submitter_label),
    STRUCT('CeGaT'),
    STRUCT('Revvity'),
    STRUCT('OMIM'),
    STRUCT('Baylor Genetics'),
    STRUCT('Counsyl'),
    STRUCT('Eurofins')
  ]) lab
  JOIN (
    SELECT DISTINCT id AS submitter_id, current_name
    FROM `clinvar_ingest.clinvar_submitters`
    WHERE deleted_release_date IS NULL
  ) sub
    ON sub.current_name LIKE CONCAT('%', lab.submitter_label, '%')
),

-- Get all CVC flagging candidates that are not currently flagged and not removed
-- This includes SCVs that were never flagged (grace period bump) AND
-- SCVs that were flagged then lost the flag (post-flag bump)
-- Only keep the MOST RECENT flagging candidate submission per SCV
all_flagging_candidates AS (
  SELECT
    fco.scv_id,
    fco.annotation_id,
    fco.batch_id,
    fco.variation_id,
    fco.vcv_id,
    fco.submitter_id,
    fco.submitted_scv_ver,
    fco.reason AS flagging_reason,
    fco.batch_accepted_date,
    fco.grace_period_end_date,
    fco.outcome,
    fco.date_flagged
  FROM `clinvar_curator.cvc_flagging_candidate_outcomes` fco
  WHERE fco.outcome != 'flagged'           -- Not currently flagged
    AND fco.outcome != 'scv_removed'       -- Not removed (can't re-submit)
    AND fco.current_rank IS NOT NULL       -- SCV still exists
    AND fco.current_rank != -3             -- Double-check not flagged
),

-- Deduplicate to only the most recent flagging candidate per SCV
-- This prevents double-counting when an SCV was submitted in multiple batches
cvc_flagging_candidates AS (
  SELECT *
  FROM all_flagging_candidates
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY scv_id
    ORDER BY batch_accepted_date DESC
  ) = 1
),

-- Get the most recent "remove flagged submission" per SCV
-- Used to exclude SCVs where we explicitly requested flag removal
-- AFTER the most recent flagging candidate submission
latest_remove_flagged AS (
  SELECT
    rfo.scv_id,
    MAX(rfo.batch_accepted_date) AS latest_remove_date
  FROM `clinvar_curator.cvc_remove_flagged_outcomes` rfo
  GROUP BY rfo.scv_id
),

-- Get the SCV state at time of submission (the version we submitted as flagging candidate)
-- This is the baseline for comparison — what did the SCV look like when we flagged it?
submitted_versions AS (
  SELECT
    fc.annotation_id,
    fc.scv_id,
    fc.submitted_scv_ver,
    -- The 6 substantive fields (must match 05-version-bump-detection.sql)
    scv.classif_type AS submitted_classif_type,
    scv.submitted_classification AS submitted_submitted_classification,
    scv.last_evaluated AS submitted_last_evaluated,
    scv.trait_set_id AS submitted_trait_set_id,
    scv.pmids AS submitted_pmids,
    scv.classification_comment AS submitted_classification_comment,
    -- Additional fields for context (not part of substantive check)
    scv.classification_abbrev AS submitted_classification
  FROM cvc_flagging_candidates fc
  JOIN `clinvar_ingest.clinvar_scvs` scv
    ON fc.scv_id = scv.id
    AND fc.submitted_scv_ver = scv.version
  -- Take one row per (annotation_id, scv_id) — earliest start_release_date
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY fc.annotation_id
    ORDER BY scv.start_release_date ASC
  ) = 1
),

-- Get the current state of each SCV
current_scvs AS (
  SELECT
    scv.id AS scv_id,
    scv.version AS current_version,
    scv.rank AS current_rank,
    -- The 6 substantive fields (must match 05-version-bump-detection.sql)
    scv.classif_type AS current_classif_type,
    scv.submitted_classification AS current_submitted_classification,
    scv.last_evaluated AS current_last_evaluated,
    scv.trait_set_id AS current_trait_set_id,
    scv.pmids AS current_pmids,
    scv.classification_comment AS current_classification_comment,
    -- Additional fields for context
    scv.classification_abbrev AS current_classification
  FROM `clinvar_ingest.clinvar_scvs` scv
  CROSS JOIN (
    SELECT release_date FROM `clinvar_ingest.schema_on`(CURRENT_DATE())
  ) latest
  WHERE latest.release_date BETWEEN scv.start_release_date AND scv.end_release_date
    AND scv.deleted_release_date IS NULL
),

-- Check if SCV was ever flagged (rank = -3) — for informational purposes
ever_flagged AS (
  SELECT
    scv.id AS scv_id,
    MIN(scv.start_release_date) AS first_flagged_date,
    MAX(scv.end_release_date) AS last_flagged_date
  FROM `clinvar_ingest.clinvar_scvs` scv
  WHERE scv.rank = -3
  GROUP BY scv.id
),

-- Join everything together and apply autoreflag criteria
autoreflag_base AS (
  SELECT
    fc.scv_id,
    fc.annotation_id,
    fc.batch_id,
    fc.variation_id,
    fc.vcv_id,
    fc.submitter_id,
    fc.flagging_reason,
    fc.batch_accepted_date,
    fc.grace_period_end_date,
    fc.outcome,
    tl.submitter_label AS target_lab_label,

    -- Submitted state (the version we submitted as flagging candidate)
    sv.submitted_scv_ver,
    sv.submitted_classif_type,
    sv.submitted_submitted_classification,
    sv.submitted_last_evaluated,
    sv.submitted_trait_set_id,
    sv.submitted_pmids,
    sv.submitted_classification,
    sv.submitted_classification_comment,

    -- Current state
    cs.current_version,
    cs.current_rank,
    cs.current_classif_type,
    cs.current_submitted_classification,
    cs.current_last_evaluated,
    cs.current_trait_set_id,
    cs.current_pmids,
    cs.current_classification,
    cs.current_classification_comment,

    -- Was this SCV ever flagged?
    (ef.scv_id IS NOT NULL) AS was_ever_flagged,
    ef.first_flagged_date,
    ef.last_flagged_date,

    -- Field-level comparison (NULL-safe: both NULL = unchanged)
    -- These are the 6 substantive fields — must match 05-version-bump-detection.sql
    (sv.submitted_classif_type IS NOT DISTINCT FROM cs.current_classif_type)
      AS classif_type_unchanged,
    (COALESCE(sv.submitted_submitted_classification, '') = COALESCE(cs.current_submitted_classification, ''))
      AS submitted_classification_unchanged,
    (sv.submitted_last_evaluated IS NOT DISTINCT FROM cs.current_last_evaluated)
      AS last_evaluated_unchanged,
    (sv.submitted_trait_set_id IS NOT DISTINCT FROM cs.current_trait_set_id)
      AS trait_set_id_unchanged,
    (sv.submitted_pmids IS NOT DISTINCT FROM cs.current_pmids)
      AS pmids_unchanged,
    (sv.submitted_classification_comment IS NOT DISTINCT FROM cs.current_classification_comment)
      AS classification_comment_unchanged

  FROM cvc_flagging_candidates fc
  -- Must be a target lab
  JOIN target_labs tl
    ON fc.submitter_id = tl.submitter_id
  -- Must have submitted version field values
  JOIN submitted_versions sv
    ON fc.annotation_id = sv.annotation_id
  -- Must have a current version (not deleted)
  JOIN current_scvs cs
    ON fc.scv_id = cs.scv_id
  -- Check if ever flagged (LEFT JOIN — not required)
  LEFT JOIN ever_flagged ef
    ON fc.scv_id = ef.scv_id
  -- Check for "remove flagged submission" after this flagging candidate
  LEFT JOIN latest_remove_flagged lrf
    ON fc.scv_id = lrf.scv_id
  -- Must have a version change after submission
  WHERE cs.current_version > sv.submitted_scv_ver
    -- Exclude SCVs where a "remove flagged submission" was accepted
    -- AFTER the most recent flagging candidate submission
    AND (lrf.scv_id IS NULL OR lrf.latest_remove_date < fc.batch_accepted_date)
)

-- Final output
SELECT
  ab.*,
  sub.current_name AS submitter_name,

  -- Summary flag: all 6 substantive fields unchanged = auto-reflag candidate
  -- (same definition as is_version_bump in 05-version-bump-detection.sql)
  (ab.classif_type_unchanged
   AND ab.submitted_classification_unchanged
   AND ab.last_evaluated_unchanged
   AND ab.trait_set_id_unchanged
   AND ab.pmids_unchanged
   AND ab.classification_comment_unchanged) AS is_autoreflag_candidate,

  -- What changed (if anything) - for SCVs that DON'T qualify
  CASE
    WHEN ab.classif_type_unchanged
     AND ab.submitted_classification_unchanged
     AND ab.last_evaluated_unchanged
     AND ab.trait_set_id_unchanged
     AND ab.pmids_unchanged
     AND ab.classification_comment_unchanged
    THEN 'no_changes'
    ELSE ARRAY_TO_STRING(ARRAY_CONCAT(
      IF(NOT ab.classif_type_unchanged, ['classification'], []),
      IF(NOT ab.submitted_classification_unchanged, ['submitted_classification'], []),
      IF(NOT ab.last_evaluated_unchanged, ['last_evaluated'], []),
      IF(NOT ab.trait_set_id_unchanged, ['trait_set_id'], []),
      IF(NOT ab.pmids_unchanged, ['pmids'], []),
      IF(NOT ab.classification_comment_unchanged, ['classification_comment'], [])
    ), ', ')
  END AS changes_detected,

  -- Version bump count between submitted and current
  (ab.current_version - ab.submitted_scv_ver) AS versions_since_submitted

FROM autoreflag_base ab
LEFT JOIN `clinvar_ingest.clinvar_submitters` sub
  ON ab.submitter_id = sub.id
  AND sub.deleted_release_date IS NULL
ORDER BY
  ab.target_lab_label,
  ab.scv_id;


-- =============================================================================
-- Summary View: Auto-Reflag Candidates by Submitter
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.cvc_autoreflag_summary`
AS
SELECT
  submitter_name,
  submitter_id,
  target_lab_label,
  COUNT(*) AS total_candidates,
  COUNTIF(is_autoreflag_candidate) AS autoreflag_candidates,
  COUNTIF(NOT is_autoreflag_candidate) AS excluded_has_changes,
  -- Was ever flagged vs never flagged
  COUNTIF(was_ever_flagged) AS previously_flagged,
  COUNTIF(NOT was_ever_flagged) AS never_flagged,
  -- Breakdown of what changed for excluded SCVs (the 6 substantive fields)
  COUNTIF(NOT classif_type_unchanged) AS classif_type_changed,
  COUNTIF(NOT submitted_classification_unchanged) AS submitted_classification_changed,
  COUNTIF(NOT last_evaluated_unchanged) AS last_evaluated_changed,
  COUNTIF(NOT trait_set_id_unchanged) AS trait_set_id_changed,
  COUNTIF(NOT pmids_unchanged) AS pmids_changed,
  COUNTIF(NOT classification_comment_unchanged) AS classification_comment_changed,
  -- Additional context
  COUNT(DISTINCT variation_id) AS unique_variants,
  COUNT(DISTINCT batch_id) AS batches_affected
FROM `clinvar_curator.cvc_autoreflag_candidates`
GROUP BY submitter_name, submitter_id, target_lab_label
ORDER BY autoreflag_candidates DESC;


-- =============================================================================
-- Export View: Auto-Reflag List for Submission
-- =============================================================================
--
-- Simplified view for direct export to submission workflow.
-- Only includes SCVs that qualify for auto-reflagging (all 6 substantive fields unchanged).
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.cvc_autoreflag_export`
AS
SELECT
  scv_id,
  current_version AS scv_ver,
  variation_id,
  vcv_id,
  submitter_id,
  submitter_name,
  flagging_reason,
  target_lab_label,
  was_ever_flagged
FROM `clinvar_curator.cvc_autoreflag_candidates`
WHERE is_autoreflag_candidate = TRUE
ORDER BY target_lab_label, scv_id;


-- =============================================================================
-- Google Sheets View: Actionable Auto-Reflag List
-- =============================================================================
--
-- Purpose: Main list of SCVs that should be auto-reflagged.
--          Includes SCVs that were previously flagged AND SCVs that were
--          never flagged due to grace-period version bumps.
--
-- For non-technical users:
--   These submissions were submitted as flagging candidates by CVC, but the
--   submitter resubmitted without changing their classification, evidence
--   summary, or condition name — either preventing the flag from being
--   applied or removing an existing flag. These should be re-flagged.
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.sheets_autoreflag_actionable`
AS
SELECT
  -- Identifiers with ClinVar links
  scv_id AS `SCV ID`,
  CONCAT('https://www.ncbi.nlm.nih.gov/clinvar/variation/', variation_id) AS `ClinVar VCV Link`,
  variation_id AS `Variation ID`,

  -- Submitter info
  submitter_name AS `Submitter Name`,
  target_lab_label AS `Target Lab`,

  -- Original flagging context
  annotation_id AS `Annotation ID`,
  flagging_reason AS `Original Flagging Reason`,
  batch_id AS `Original Batch ID`,
  batch_accepted_date AS `Original Submission Date`,
  outcome AS `Current Outcome`,

  -- Was this SCV ever flagged?
  CASE
    WHEN was_ever_flagged THEN 'Yes'
    ELSE 'No — Grace period bump'
  END AS `Was Ever Flagged`,
  first_flagged_date AS `Date Flag Applied`,
  last_flagged_date AS `Date Flag Removed`,

  -- Version info
  submitted_scv_ver AS `Submitted SCV Version`,
  current_version AS `Current SCV Version`,
  versions_since_submitted AS `Version Bumps Since Submitted`,

  -- Current classification
  current_classification AS `Current Classification`,
  current_classif_type AS `Current Classification Type`,

  -- What changed (for all SCVs, not just candidates)
  CASE
    WHEN is_autoreflag_candidate THEN 'None — Ready to Re-Flag'
    ELSE changes_detected
  END AS `Changes Since Submission`,

  -- Auto-reflag status
  CASE
    WHEN is_autoreflag_candidate THEN 'Auto-Reflag'
    ELSE 'Review Needed'
  END AS `Action`

FROM `clinvar_curator.cvc_autoreflag_candidates`
ORDER BY
  CASE WHEN is_autoreflag_candidate THEN 0 ELSE 1 END,
  submitter_name,
  scv_id;


-- =============================================================================
-- Google Sheets View: Auto-Reflag Summary by Submitter
-- =============================================================================
--
-- Purpose: Shows which of the 7 target labs have the most SCVs needing
--          auto-reflagging, including those never flagged.
--
-- For non-technical users:
--   This shows how many flagging candidate SCVs from each target lab
--   need re-flagging, whether they were previously flagged or never
--   flagged due to grace-period version bumps.
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.sheets_autoreflag_by_submitter`
AS
SELECT
  submitter_name AS `Submitter Name`,
  COUNTIF(is_autoreflag_candidate) AS `Ready to Auto-Reflag`,
  COUNTIF(NOT is_autoreflag_candidate) AS `Excluded - Has Changes`,
  COUNT(*) AS `Total Candidates`,
  -- Flagging status breakdown
  COUNTIF(was_ever_flagged) AS `Previously Flagged`,
  COUNTIF(NOT was_ever_flagged) AS `Never Flagged - Grace Period Bump`,
  -- Breakdown of changes for excluded SCVs (the 6 substantive fields)
  COUNTIF(NOT classif_type_unchanged) AS `Classification Changed`,
  COUNTIF(NOT submitted_classification_unchanged) AS `Submitted Classification Changed`,
  COUNTIF(NOT last_evaluated_unchanged) AS `Last Evaluated Changed`,
  COUNTIF(NOT trait_set_id_unchanged) AS `Condition Changed`,
  COUNTIF(NOT pmids_unchanged) AS `PMIDs Changed`,
  COUNTIF(NOT classification_comment_unchanged) AS `Evidence Summary Changed`,
  -- Percentage eligible
  ROUND(
    COUNTIF(is_autoreflag_candidate) * 100.0 / NULLIF(COUNT(*), 0), 1
  ) AS `% Eligible for Auto-Reflag`,
  COUNT(DISTINCT variation_id) AS `Unique Variants`
FROM `clinvar_curator.cvc_autoreflag_candidates`
GROUP BY submitter_name
ORDER BY COUNTIF(is_autoreflag_candidate) DESC;


-- =============================================================================
-- Google Sheets View: Auto-Reflag Glossary
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.sheets_autoreflag_glossary`
AS
SELECT * FROM UNNEST([
  STRUCT(
    'Auto-Reflag' AS `Term`,
    'Automatically re-submitting a flagging request for an SCV that was submitted as a flagging candidate but is not currently flagged, and the submitter resubmitted with no meaningful changes.' AS `Definition`
  ),
  STRUCT(
    'Classification',
    'The clinical significance type (e.g., Pathogenic, Likely pathogenic, VUS). Stored as classif_type in BigQuery. If this changed, the submitter may have addressed the issue.'
  ),
  STRUCT(
    'Evidence Summary',
    'The interpretation description or classification comment provided by the submitter. Stored as classification_comment in BigQuery. Changes here may indicate new evidence was added.'
  ),
  STRUCT(
    'Condition Name',
    'The disease/condition associated with the SCV, identified by trait_set_id. A change here means the submitter associated the variant with a different condition.'
  ),
  STRUCT(
    'Target Labs',
    'The 7 labs approved for auto-reflagging: LabCorp Genetics, CeGaT, Revvity, OMIM, Baylor Genetics, Counsyl, and Eurofins. Other labs require manual review before re-flagging.'
  ),
  STRUCT(
    'Was Ever Flagged',
    'Whether the SCV had rank = -3 at any point. "Yes" means ClinVar applied the flag but it was later removed. "No" means the submitter bumped the version during the grace period, preventing the flag from ever being applied.'
  ),
  STRUCT(
    'Grace Period Bump',
    'When a submitter resubmits their SCV during the 60-90 day grace period after CVC submits a flagging candidate, it can prevent the flag from being applied. These SCVs were never flagged but should have been.'
  ),
  STRUCT(
    'Version Bumps Since Submitted',
    'The number of version increments between the submitted version and the current version. A bump with no meaningful changes suggests the submitter is avoiding the flag.'
  )
]);
