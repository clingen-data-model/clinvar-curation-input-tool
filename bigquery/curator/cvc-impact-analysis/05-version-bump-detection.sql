-- =============================================================================
-- Version Bump Detection
-- =============================================================================
--
-- Purpose:
--   Detects SCVs where submitters have resubmitted without making substantive
--   changes - essentially creating a "version bump" that only increments the
--   version number without changing:
--   - classification (classif_type)
--   - submitted_classification text
--   - last_evaluated date
--   - trait_set_id
--   - pmids (ordered list of PubMed citation IDs)
--   - classification_comment (evidence summary / interpretation text)
--
--   This is important because version bumps may be used to:
--   1. Reset the 60-day grace period on pending flagging candidates
--   2. Avoid having a flag applied
--
-- Dependencies:
--   - clinvar_ingest.clinvar_scvs
--   - clinvar_ingest.clinvar_releases
--
-- Output:
--   - clinvar_curator.cvc_version_bumps
--   - clinvar_curator.cvc_version_bump_summary
--
-- =============================================================================

CREATE OR REPLACE TABLE `clinvar_curator.cvc_version_bumps`
AS
WITH
-- Get all SCV versions, deduplicated to one row per (scv_id, version)
-- Takes the earliest start_release_date when duplicates exist
scv_versions AS (
  SELECT
    id AS scv_id,
    version,
    MIN(start_release_date) AS start_release_date,
    -- Use ANY_VALUE for fields that should be consistent within a version
    ANY_VALUE(classif_type) AS classif_type,
    ANY_VALUE(classification_abbrev) AS classification_abbrev,
    ANY_VALUE(submitted_classification) AS submitted_classification,
    ANY_VALUE(last_evaluated) AS last_evaluated,
    ANY_VALUE(submitter_id) AS submitter_id,
    ANY_VALUE(variation_id) AS variation_id,
    ANY_VALUE(trait_set_id) AS trait_set_id,
    ANY_VALUE(pmids) AS pmids,
    ANY_VALUE(classification_comment) AS classification_comment
  FROM `clinvar_ingest.clinvar_scvs`
  GROUP BY id, version
),

-- Self-join to compare consecutive versions
version_comparisons AS (
  SELECT
    curr.scv_id,
    curr.version AS current_version,
    prev.version AS previous_version,
    curr.start_release_date AS current_start_date,
    prev.start_release_date AS previous_start_date,
    curr.submitter_id,
    curr.variation_id,
    -- Current version values
    curr.classif_type AS current_classif_type,
    curr.classification_abbrev AS current_classification,
    curr.submitted_classification AS current_submitted_classification,
    curr.last_evaluated AS current_last_evaluated,
    -- Previous version values
    prev.classif_type AS previous_classif_type,
    prev.classification_abbrev AS previous_classification,
    prev.submitted_classification AS previous_submitted_classification,
    prev.last_evaluated AS previous_last_evaluated,
    prev.trait_set_id AS previous_trait_set_id,
    prev.pmids AS previous_pmids,
    -- Determine what changed (NULL-safe comparisons: NULL=NULL is TRUE, NULL vs non-NULL is FALSE)
    (curr.classif_type != prev.classif_type) AS classif_type_changed,
    (COALESCE(curr.submitted_classification, '') != COALESCE(prev.submitted_classification, '')) AS submitted_classification_changed,
    -- NULL-safe comparison for last_evaluated: both NULL = no change, one NULL = change
    NOT (curr.last_evaluated IS NOT DISTINCT FROM prev.last_evaluated) AS last_evaluated_changed,
    -- NULL-safe comparison for trait_set_id: both NULL = no change, one NULL = change
    NOT (curr.trait_set_id IS NOT DISTINCT FROM prev.trait_set_id) AS trait_set_id_changed,
    -- NULL-safe comparison for pmids: both NULL = no change, one NULL = change
    NOT (curr.pmids IS NOT DISTINCT FROM prev.pmids) AS pmids_changed,
    -- NULL-safe comparison for classification_comment
    NOT (curr.classification_comment IS NOT DISTINCT FROM prev.classification_comment) AS classification_comment_changed
  FROM scv_versions curr
  JOIN scv_versions prev
    ON curr.scv_id = prev.scv_id
    AND curr.version = prev.version + 1  -- Consecutive versions
)

SELECT
  scv_id,
  previous_version,
  current_version,
  previous_start_date,
  current_start_date,
  submitter_id,
  variation_id,
  -- Classification info
  current_classif_type,
  current_classification,
  -- Change flags
  classif_type_changed,
  submitted_classification_changed,
  last_evaluated_changed,
  trait_set_id_changed,
  pmids_changed,
  classification_comment_changed,
  -- Is this a version bump? (no substantive changes)
  (NOT classif_type_changed
   AND NOT submitted_classification_changed
   AND NOT last_evaluated_changed
   AND NOT trait_set_id_changed
   AND NOT pmids_changed
   AND NOT classification_comment_changed) AS is_version_bump,
  -- What changed (if anything)
  CASE
    WHEN NOT classif_type_changed
     AND NOT submitted_classification_changed
     AND NOT last_evaluated_changed
     AND NOT trait_set_id_changed
     AND NOT pmids_changed
     AND NOT classification_comment_changed THEN 'no_change_version_bump'
    ELSE ARRAY_TO_STRING(ARRAY_CONCAT(
      IF(classif_type_changed, ['classification'], []),
      IF(submitted_classification_changed, ['submitted_classification'], []),
      IF(last_evaluated_changed, ['last_evaluated'], []),
      IF(trait_set_id_changed, ['trait_set_id'], []),
      IF(pmids_changed, ['pmids'], []),
      IF(classification_comment_changed, ['classification_comment'], [])
    ), ', ')
  END AS changes_made
FROM version_comparisons
ORDER BY current_start_date DESC, scv_id, current_version;


-- =============================================================================
-- Summary View: Version Bumps by Release
-- =============================================================================
--
-- Columns:
--   release_date                      - ClinVar release date when version changes occurred
--   total_version_changes             - Total count of version changes across all SCVs
--   version_bumps                     - Count of version changes with no substantive changes
--   substantive_changes               - Count of version changes with actual content changes
--   version_bump_pct                  - Percentage of changes that were version bumps
--   classification_changes            - Count of changes where classif_type changed
--   submitted_classification_changes  - Count of changes where submitted_classification text changed
--   last_evaluated_changes            - Count of changes where last_evaluated date changed
--   trait_set_id_changes              - Count of changes where trait_set_id changed
--   pmids_changes                     - Count of changes where pmids changed
--   classification_comment_changes    - Count of changes where classification_comment changed
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.cvc_version_bump_summary`
AS
WITH versioned_data AS (
  SELECT
    scv_id,
    current_version,
    current_start_date,
    is_version_bump,
    classif_type_changed,
    submitted_classification_changed,
    last_evaluated_changed,
    trait_set_id_changed,
    pmids_changed,
    classification_comment_changed,
    -- Create unique key for each version transition to prevent double-counting
    CONCAT(scv_id, '-', CAST(current_version AS STRING)) AS version_transition_key
  FROM `clinvar_curator.cvc_version_bumps`
)
SELECT
  current_start_date AS release_date,
  -- Count unique version transitions (scv_id + version), not rows
  COUNT(DISTINCT version_transition_key) AS total_version_changes,
  COUNT(DISTINCT CASE WHEN is_version_bump THEN version_transition_key END) AS version_bumps,
  COUNT(DISTINCT CASE WHEN NOT is_version_bump THEN version_transition_key END) AS substantive_changes,
  ROUND(
    COUNT(DISTINCT CASE WHEN is_version_bump THEN version_transition_key END) * 100.0 /
    NULLIF(COUNT(DISTINCT version_transition_key), 0), 1
  ) AS version_bump_pct,
  -- Breakdown of changes (unique transitions where each type changed)
  COUNT(DISTINCT CASE WHEN classif_type_changed THEN version_transition_key END) AS classification_changes,
  COUNT(DISTINCT CASE WHEN submitted_classification_changed THEN version_transition_key END) AS submitted_classification_changes,
  COUNT(DISTINCT CASE WHEN last_evaluated_changed THEN version_transition_key END) AS last_evaluated_changes,
  COUNT(DISTINCT CASE WHEN trait_set_id_changed THEN version_transition_key END) AS trait_set_id_changes,
  COUNT(DISTINCT CASE WHEN pmids_changed THEN version_transition_key END) AS pmids_changes,
  COUNT(DISTINCT CASE WHEN classification_comment_changed THEN version_transition_key END) AS classification_comment_changes
FROM versioned_data
GROUP BY current_start_date
ORDER BY current_start_date DESC;


-- =============================================================================
-- Version Bumps by Submitter
-- =============================================================================
--
-- Columns:
--   submitter_id            - ClinVar submitter ID
--   submitter_name          - Current name of the submitter organization
--   unique_scv_ids          - Count of distinct SCVs with version changes
--   total_version_changes   - Total count of version changes for this submitter
--   version_bumps           - Count of version changes with no substantive changes
--   avg_bumps_per_scv       - Average number of version bumps per unique SCV
--   substantive_changes     - Count of version changes with actual content changes
--   version_bump_pct        - Percentage of changes that were version bumps
--   first_version_bump_date - Earliest date a version bump was detected
--   last_version_bump_date  - Most recent date a version bump was detected
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.cvc_version_bumps_by_submitter`
AS
WITH versioned_data AS (
  SELECT
    scv_id,
    current_version,
    submitter_id,
    current_start_date,
    is_version_bump,
    -- Create unique key for each version transition to prevent double-counting
    CONCAT(scv_id, '-', CAST(current_version AS STRING)) AS version_transition_key
  FROM `clinvar_curator.cvc_version_bumps`
)
SELECT
  vd.submitter_id,
  sub.current_name AS submitter_name,
  COUNT(DISTINCT vd.scv_id) AS unique_scv_ids,
  -- Count unique version transitions (scv_id + version), not rows
  COUNT(DISTINCT vd.version_transition_key) AS total_version_changes,
  COUNT(DISTINCT CASE WHEN vd.is_version_bump THEN vd.version_transition_key END) AS version_bumps,
  ROUND(
    COUNT(DISTINCT CASE WHEN vd.is_version_bump THEN vd.version_transition_key END) * 1.0 /
    NULLIF(COUNT(DISTINCT vd.scv_id), 0), 2
  ) AS avg_bumps_per_scv,
  COUNT(DISTINCT CASE WHEN NOT vd.is_version_bump THEN vd.version_transition_key END) AS substantive_changes,
  ROUND(
    COUNT(DISTINCT CASE WHEN vd.is_version_bump THEN vd.version_transition_key END) * 100.0 /
    NULLIF(COUNT(DISTINCT vd.version_transition_key), 0), 1
  ) AS version_bump_pct,
  MIN(CASE WHEN vd.is_version_bump THEN vd.current_start_date END) AS first_version_bump_date,
  MAX(CASE WHEN vd.is_version_bump THEN vd.current_start_date END) AS last_version_bump_date
FROM versioned_data vd
LEFT JOIN `clinvar_ingest.clinvar_submitters` sub
  ON vd.submitter_id = sub.id
  AND sub.deleted_release_date IS NULL
GROUP BY vd.submitter_id, sub.current_name
HAVING COUNT(DISTINCT CASE WHEN vd.is_version_bump THEN vd.version_transition_key END) > 0
ORDER BY version_bumps DESC;
