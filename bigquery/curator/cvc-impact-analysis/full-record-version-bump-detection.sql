-- =============================================================================
-- Full Record Version Bump Detection
-- =============================================================================
--
-- Purpose:
--   Compares the ENTIRE SCV record between consecutive versions to categorize
--   version changes into three types:
--
--   1. DUPLICATE BUMP: ALL 19 fields identical - the submission is a duplicate
--      of the prior version and should not have had a version bump at all.
--
--   2. NON-SUBSTANTIVE CHANGE BUMP: The 6 key classification fields are the same
--      (classif_type, submitted_classification, last_evaluated, trait_set_id,
--       pmids, classification_comment) but other fields changed.
--      Detected by the standard 6-field check in cvc_version_bumps.
--
--   3. SUBSTANTIVE CHANGE BUMP: Real changes were made to classification-relevant
--      fields - this is a legitimate version update.
--
-- Fields compared (all fields except version, submission_date, and temporal tracking):
--   - statement_type
--   - proposition_type
--   - clinical_impact_assertion_type
--   - clinical_impact_clinical_significance
--   - rank
--   - review_status
--   - last_evaluated
--   - local_key
--   - classif_type
--   - clinsig_type
--   - classification_label
--   - classification_abbrev
--   - submitted_classification
--   - classification_comment
--   - pmids
--   - origin
--   - affected_status
--   - method_type
--   - trait_set_id
--
-- Fields intentionally excluded from comparison:
--   - id (grouping key)
--   - full_scv_id (contains version number)
--   - version (expected to change)
--   - submission_date (expected to change with resubmission)
--   - variation_id (should never change for an SCV)
--   - submitter_id (should never change for an SCV)
--   - submitter_name/abbrev (can change if org renames, not submitter action)
--   - rcv_accession_id (can change due to RCV reassignment, not submitter action)
--   - start_release_date, end_release_date, deleted_release_date (temporal tracking)
--
-- Output Tables/Views:
--   - clinvar_curator.cvc_full_record_version_bumps (base table with is_duplicate_bump flag)
--   - clinvar_curator.cvc_duplicate_bumps_by_scv (SCVs with duplicate bumps)
--   - clinvar_curator.cvc_duplicate_bumps_by_submitter (submitter analysis)
--   - clinvar_curator.cvc_duplicate_bumps_by_release (release analysis)
--
-- =============================================================================


-- =============================================================================
-- Base Table: All Version Changes with Full Record Comparison
-- =============================================================================

CREATE OR REPLACE TABLE `clinvar_curator.cvc_full_record_version_bumps`
AS
WITH
-- Get one row per (scv_id, version) with the earliest start_release_date
scv_versions AS (
  SELECT
    id AS scv_id,
    version,
    MIN(start_release_date) AS start_release_date,
    -- Fields to compare (use ANY_VALUE since they should be consistent within a version)
    ANY_VALUE(statement_type) AS statement_type,
    ANY_VALUE(proposition_type) AS proposition_type,
    ANY_VALUE(clinical_impact_assertion_type) AS clinical_impact_assertion_type,
    ANY_VALUE(clinical_impact_clinical_significance) AS clinical_impact_clinical_significance,
    ANY_VALUE(rank) AS rank,
    ANY_VALUE(review_status) AS review_status,
    ANY_VALUE(last_evaluated) AS last_evaluated,
    ANY_VALUE(local_key) AS local_key,
    ANY_VALUE(classif_type) AS classif_type,
    ANY_VALUE(clinsig_type) AS clinsig_type,
    ANY_VALUE(classification_label) AS classification_label,
    ANY_VALUE(classification_abbrev) AS classification_abbrev,
    ANY_VALUE(submitted_classification) AS submitted_classification,
    ANY_VALUE(classification_comment) AS classification_comment,
    ANY_VALUE(pmids) AS pmids,
    ANY_VALUE(origin) AS origin,
    ANY_VALUE(affected_status) AS affected_status,
    ANY_VALUE(method_type) AS method_type,
    ANY_VALUE(trait_set_id) AS trait_set_id,
    -- Reference fields (not compared but useful for output)
    ANY_VALUE(submitter_id) AS submitter_id,
    ANY_VALUE(variation_id) AS variation_id,
    ANY_VALUE(submission_date) AS submission_date
  FROM `clinvar_ingest.clinvar_scvs`
  GROUP BY id, version
),

-- Compare consecutive versions
version_comparisons AS (
  SELECT
    curr.scv_id,
    prev.version AS previous_version,
    curr.version AS current_version,
    prev.start_release_date AS previous_start_date,
    curr.start_release_date AS current_start_date,
    prev.submission_date AS previous_submission_date,
    curr.submission_date AS current_submission_date,
    curr.submitter_id,
    curr.variation_id,

    -- Compare each field using NULL-safe IS NOT DISTINCT FROM
    -- TRUE means the field is the same, FALSE means it changed
    (curr.statement_type IS NOT DISTINCT FROM prev.statement_type) AS statement_type_same,
    (curr.proposition_type IS NOT DISTINCT FROM prev.proposition_type) AS proposition_type_same,
    (curr.clinical_impact_assertion_type IS NOT DISTINCT FROM prev.clinical_impact_assertion_type) AS clinical_impact_assertion_type_same,
    (curr.clinical_impact_clinical_significance IS NOT DISTINCT FROM prev.clinical_impact_clinical_significance) AS clinical_impact_clinical_significance_same,
    (curr.rank IS NOT DISTINCT FROM prev.rank) AS rank_same,
    (curr.review_status IS NOT DISTINCT FROM prev.review_status) AS review_status_same,
    (curr.last_evaluated IS NOT DISTINCT FROM prev.last_evaluated) AS last_evaluated_same,
    (curr.local_key IS NOT DISTINCT FROM prev.local_key) AS local_key_same,
    (curr.classif_type IS NOT DISTINCT FROM prev.classif_type) AS classif_type_same,
    (curr.clinsig_type IS NOT DISTINCT FROM prev.clinsig_type) AS clinsig_type_same,
    (curr.classification_label IS NOT DISTINCT FROM prev.classification_label) AS classification_label_same,
    (curr.classification_abbrev IS NOT DISTINCT FROM prev.classification_abbrev) AS classification_abbrev_same,
    (curr.submitted_classification IS NOT DISTINCT FROM prev.submitted_classification) AS submitted_classification_same,
    (curr.classification_comment IS NOT DISTINCT FROM prev.classification_comment) AS classification_comment_same,
    (curr.pmids IS NOT DISTINCT FROM prev.pmids) AS pmids_same,
    (curr.origin IS NOT DISTINCT FROM prev.origin) AS origin_same,
    (curr.affected_status IS NOT DISTINCT FROM prev.affected_status) AS affected_status_same,
    (curr.method_type IS NOT DISTINCT FROM prev.method_type) AS method_type_same,
    (curr.trait_set_id IS NOT DISTINCT FROM prev.trait_set_id) AS trait_set_id_same

  FROM scv_versions curr
  JOIN scv_versions prev
    ON curr.scv_id = prev.scv_id
    AND curr.version = prev.version + 1  -- Consecutive versions only
)

SELECT
  scv_id,
  previous_version,
  current_version,
  previous_start_date,
  current_start_date,
  previous_submission_date,
  current_submission_date,
  submitter_id,
  variation_id,

  -- Is this a DUPLICATE BUMP? (ALL fields identical except version/submission_date)
  -- A duplicate bump means the submission is identical to the prior version
  -- and should not have had a version increment at all.
  (statement_type_same
   AND proposition_type_same
   AND clinical_impact_assertion_type_same
   AND clinical_impact_clinical_significance_same
   AND rank_same
   AND review_status_same
   AND last_evaluated_same
   AND local_key_same
   AND classif_type_same
   AND clinsig_type_same
   AND classification_label_same
   AND classification_abbrev_same
   AND submitted_classification_same
   AND classification_comment_same
   AND pmids_same
   AND origin_same
   AND affected_status_same
   AND method_type_same
   AND trait_set_id_same) AS is_duplicate_bump,

  -- Count how many fields changed
  (CASE WHEN NOT statement_type_same THEN 1 ELSE 0 END
   + CASE WHEN NOT proposition_type_same THEN 1 ELSE 0 END
   + CASE WHEN NOT clinical_impact_assertion_type_same THEN 1 ELSE 0 END
   + CASE WHEN NOT clinical_impact_clinical_significance_same THEN 1 ELSE 0 END
   + CASE WHEN NOT rank_same THEN 1 ELSE 0 END
   + CASE WHEN NOT review_status_same THEN 1 ELSE 0 END
   + CASE WHEN NOT last_evaluated_same THEN 1 ELSE 0 END
   + CASE WHEN NOT local_key_same THEN 1 ELSE 0 END
   + CASE WHEN NOT classif_type_same THEN 1 ELSE 0 END
   + CASE WHEN NOT clinsig_type_same THEN 1 ELSE 0 END
   + CASE WHEN NOT classification_label_same THEN 1 ELSE 0 END
   + CASE WHEN NOT classification_abbrev_same THEN 1 ELSE 0 END
   + CASE WHEN NOT submitted_classification_same THEN 1 ELSE 0 END
   + CASE WHEN NOT classification_comment_same THEN 1 ELSE 0 END
   + CASE WHEN NOT pmids_same THEN 1 ELSE 0 END
   + CASE WHEN NOT origin_same THEN 1 ELSE 0 END
   + CASE WHEN NOT affected_status_same THEN 1 ELSE 0 END
   + CASE WHEN NOT method_type_same THEN 1 ELSE 0 END
   + CASE WHEN NOT trait_set_id_same THEN 1 ELSE 0 END) AS fields_changed_count,

  -- List which fields changed
  ARRAY_TO_STRING(ARRAY_CONCAT(
    IF(NOT statement_type_same, ['statement_type'], []),
    IF(NOT proposition_type_same, ['proposition_type'], []),
    IF(NOT clinical_impact_assertion_type_same, ['clinical_impact_assertion_type'], []),
    IF(NOT clinical_impact_clinical_significance_same, ['clinical_impact_clinical_significance'], []),
    IF(NOT rank_same, ['rank'], []),
    IF(NOT review_status_same, ['review_status'], []),
    IF(NOT last_evaluated_same, ['last_evaluated'], []),
    IF(NOT local_key_same, ['local_key'], []),
    IF(NOT classif_type_same, ['classif_type'], []),
    IF(NOT clinsig_type_same, ['clinsig_type'], []),
    IF(NOT classification_label_same, ['classification_label'], []),
    IF(NOT classification_abbrev_same, ['classification_abbrev'], []),
    IF(NOT submitted_classification_same, ['submitted_classification'], []),
    IF(NOT classification_comment_same, ['classification_comment'], []),
    IF(NOT pmids_same, ['pmids'], []),
    IF(NOT origin_same, ['origin'], []),
    IF(NOT affected_status_same, ['affected_status'], []),
    IF(NOT method_type_same, ['method_type'], []),
    IF(NOT trait_set_id_same, ['trait_set_id'], [])
  ), ', ') AS fields_changed

FROM version_comparisons;


-- =============================================================================
-- Analysis View: Duplicate Bumps by SCV
-- =============================================================================
--
-- Shows SCVs that have had duplicate bumps (identical resubmissions)
--
-- Columns:
--   scv_id                    - The SCV identifier
--   submitter_id              - Submitter who owns this SCV
--   submitter_name            - Current name of the submitter
--   total_version_changes     - Total number of version changes for this SCV
--   duplicate_bumps           - Number of duplicate bumps (no field changes at all)
--   substantive_changes       - Number of version changes with actual changes
--   duplicate_bump_pct        - Percentage of changes that were duplicate bumps
--   first_duplicate_bump_date - First time this SCV had a duplicate bump
--   last_duplicate_bump_date  - Most recent duplicate bump
--   latest_version            - Current version of the SCV
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.cvc_duplicate_bumps_by_scv`
AS
SELECT
  vb.scv_id,
  vb.submitter_id,
  sub.current_name AS submitter_name,
  -- Count unique version transitions (by current_version) to prevent double-counting
  COUNT(DISTINCT vb.current_version) AS total_version_changes,
  COUNT(DISTINCT CASE WHEN vb.is_duplicate_bump THEN vb.current_version END) AS duplicate_bumps,
  COUNT(DISTINCT CASE WHEN NOT vb.is_duplicate_bump THEN vb.current_version END) AS substantive_changes,
  ROUND(
    COUNT(DISTINCT CASE WHEN vb.is_duplicate_bump THEN vb.current_version END) * 100.0 /
    NULLIF(COUNT(DISTINCT vb.current_version), 0), 1
  ) AS duplicate_bump_pct,
  MIN(CASE WHEN vb.is_duplicate_bump THEN vb.current_start_date END) AS first_duplicate_bump_date,
  MAX(CASE WHEN vb.is_duplicate_bump THEN vb.current_start_date END) AS last_duplicate_bump_date,
  MAX(vb.current_version) AS latest_version
FROM `clinvar_curator.cvc_full_record_version_bumps` vb
LEFT JOIN `clinvar_ingest.clinvar_submitters` sub
  ON vb.submitter_id = sub.id
  AND sub.deleted_release_date IS NULL
GROUP BY vb.scv_id, vb.submitter_id, sub.current_name
HAVING COUNT(DISTINCT CASE WHEN vb.is_duplicate_bump THEN vb.current_version END) > 0
ORDER BY duplicate_bumps DESC, scv_id;


-- =============================================================================
-- Analysis View: Duplicate Bumps by Submitter
-- =============================================================================
--
-- Shows which submitters have the most duplicate bumps across all their SCVs
--
-- Columns:
--   submitter_id              - Submitter identifier
--   submitter_name            - Current name of the submitter
--   unique_scvs_with_bumps    - Number of distinct SCVs with at least one duplicate bump
--   total_version_changes     - Total version changes across all submitter's SCVs
--   duplicate_bumps           - Total duplicate bumps (identical resubmissions)
--   substantive_changes       - Total version changes with actual changes
--   duplicate_bump_pct        - Percentage of changes that were duplicate bumps
--   avg_bumps_per_scv         - Average duplicate bumps per SCV (for SCVs with bumps)
--   first_duplicate_bump_date - First duplicate bump by this submitter
--   last_duplicate_bump_date  - Most recent duplicate bump
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.cvc_duplicate_bumps_by_submitter`
AS
WITH versioned_data AS (
  SELECT
    vb.submitter_id,
    vb.scv_id,
    vb.current_version,
    vb.current_start_date,
    vb.is_duplicate_bump,
    -- Create unique key for each version transition to prevent double-counting
    CONCAT(vb.scv_id, '-', CAST(vb.current_version AS STRING)) AS version_transition_key
  FROM `clinvar_curator.cvc_full_record_version_bumps` vb
)
SELECT
  vd.submitter_id,
  sub.current_name AS submitter_name,
  COUNT(DISTINCT CASE WHEN vd.is_duplicate_bump THEN vd.scv_id END) AS unique_scvs_with_bumps,
  -- Count unique version transitions (scv_id + version), not rows
  COUNT(DISTINCT vd.version_transition_key) AS total_version_changes,
  COUNT(DISTINCT CASE WHEN vd.is_duplicate_bump THEN vd.version_transition_key END) AS duplicate_bumps,
  COUNT(DISTINCT CASE WHEN NOT vd.is_duplicate_bump THEN vd.version_transition_key END) AS substantive_changes,
  ROUND(
    COUNT(DISTINCT CASE WHEN vd.is_duplicate_bump THEN vd.version_transition_key END) * 100.0 /
    NULLIF(COUNT(DISTINCT vd.version_transition_key), 0), 1
  ) AS duplicate_bump_pct,
  ROUND(
    COUNT(DISTINCT CASE WHEN vd.is_duplicate_bump THEN vd.version_transition_key END) * 1.0 /
    NULLIF(COUNT(DISTINCT CASE WHEN vd.is_duplicate_bump THEN vd.scv_id END), 0),
    2
  ) AS avg_bumps_per_scv,
  MIN(CASE WHEN vd.is_duplicate_bump THEN vd.current_start_date END) AS first_duplicate_bump_date,
  MAX(CASE WHEN vd.is_duplicate_bump THEN vd.current_start_date END) AS last_duplicate_bump_date
FROM versioned_data vd
LEFT JOIN `clinvar_ingest.clinvar_submitters` sub
  ON vd.submitter_id = sub.id
  AND sub.deleted_release_date IS NULL
GROUP BY vd.submitter_id, sub.current_name
HAVING COUNT(DISTINCT CASE WHEN vd.is_duplicate_bump THEN vd.version_transition_key END) > 0
ORDER BY duplicate_bumps DESC;


-- =============================================================================
-- Analysis View: Version Bump Categories by Month
-- =============================================================================
--
-- Shows monthly aggregation of version bump types for trend analysis
-- Aggregates by the first day of each month for consistency with other charts
--
-- Categories:
--   - Duplicate Bump: ALL 19 fields identical (submission is a duplicate)
--   - Non-substantive Change Bump: 6 key fields same, but minor fields changed
--   - Substantive Change Bump: Real changes to classification-relevant fields
--
-- Columns:
--   release_month             - First day of the month (for sorting/joining)
--   month_label               - Human-readable month label (e.g., "Jan 2024")
--   total_version_changes     - Total version changes in this month
--   duplicate_bumps           - Identical resubmissions (19-field match)
--   nonsubstantive_bumps      - 6 key fields same, minor fields changed
--   duplicate_also_nonsubstantive - Duplicate bumps detected by both methods
--   duplicate_only            - Duplicate bumps NOT detected by 6-field check (should be 0)
--   nonsubstantive_only       - Non-substantive bumps that aren't duplicates
--   substantive_changes       - Real changes to classification-relevant fields
--   duplicate_bump_pct        - Percentage that were duplicate bumps
--   unique_scvs_bumped        - Distinct SCVs with duplicate bumps in this month
--   unique_submitters_bumping - Distinct submitters with duplicate bumps
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.cvc_duplicate_bumps_by_release`
AS
WITH
-- Join duplicate (19-field) and non-substantive (6-field) version bump data
-- Include current_version to create unique version transition key
combined_data AS (
  SELECT
    DATE_TRUNC(frb.current_start_date, MONTH) AS release_month,
    frb.scv_id,
    frb.current_version,
    frb.submitter_id,
    frb.is_duplicate_bump,
    COALESCE(std.is_version_bump, FALSE) AS is_nonsubstantive_bump,
    -- Create unique key for each version transition to prevent double-counting
    CONCAT(frb.scv_id, '-', CAST(frb.current_version AS STRING)) AS version_transition_key
  FROM `clinvar_curator.cvc_full_record_version_bumps` frb
  LEFT JOIN `clinvar_curator.cvc_version_bumps` std
    ON frb.scv_id = std.scv_id
    AND frb.current_version = std.current_version
)
SELECT
  release_month,
  FORMAT_DATE('%b %Y', release_month) AS month_label,
  -- Count unique version transitions (scv_id + version), not rows
  COUNT(DISTINCT version_transition_key) AS total_version_changes,
  -- Duplicate bumps (strictest - 20 fields identical)
  COUNT(DISTINCT CASE WHEN is_duplicate_bump THEN version_transition_key END) AS duplicate_bumps,
  -- Non-substantive bumps (6 key fields same)
  COUNT(DISTINCT CASE WHEN is_nonsubstantive_bump THEN version_transition_key END) AS nonsubstantive_bumps,
  -- Overlap analysis
  COUNT(DISTINCT CASE WHEN is_duplicate_bump AND is_nonsubstantive_bump THEN version_transition_key END) AS duplicate_also_nonsubstantive,
  COUNT(DISTINCT CASE WHEN is_duplicate_bump AND NOT is_nonsubstantive_bump THEN version_transition_key END) AS duplicate_only,
  COUNT(DISTINCT CASE WHEN NOT is_duplicate_bump AND is_nonsubstantive_bump THEN version_transition_key END) AS nonsubstantive_only,
  -- Substantive changes (neither duplicate nor non-substantive bump)
  COUNT(DISTINCT CASE WHEN NOT is_duplicate_bump AND NOT is_nonsubstantive_bump THEN version_transition_key END) AS substantive_changes,
  -- Percentages (based on unique transitions)
  ROUND(
    COUNT(DISTINCT CASE WHEN is_duplicate_bump THEN version_transition_key END) * 100.0 /
    NULLIF(COUNT(DISTINCT version_transition_key), 0), 1
  ) AS duplicate_bump_pct,
  ROUND(
    COUNT(DISTINCT CASE WHEN is_nonsubstantive_bump THEN version_transition_key END) * 100.0 /
    NULLIF(COUNT(DISTINCT version_transition_key), 0), 1
  ) AS nonsubstantive_bump_pct,
  -- Unique counts
  COUNT(DISTINCT CASE WHEN is_duplicate_bump THEN scv_id END) AS unique_scvs_duplicate_bumped,
  COUNT(DISTINCT CASE WHEN is_nonsubstantive_bump THEN scv_id END) AS unique_scvs_nonsubstantive_bumped,
  COUNT(DISTINCT CASE WHEN is_duplicate_bump THEN submitter_id END) AS unique_submitters_bumping
FROM combined_data
GROUP BY release_month
ORDER BY release_month DESC;


-- =============================================================================
-- Google Sheets View: Version Bump Categories by Month
-- =============================================================================
--
-- Optimized for Google Sheets charting with consistent column naming
-- Shows the three categories of version changes:
--   - Duplicate Bumps: Identical resubmissions (most concerning)
--   - Non-substantive Change Bumps: 6 key fields same, minor changes only
--   - Substantive Changes: Real updates (legitimate)
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.sheets_duplicate_bumps_by_month`
AS
SELECT
  release_month,
  month_label,
  total_version_changes,
  -- For stacked chart showing bump breakdown
  duplicate_bumps AS Duplicate_Bumps,
  nonsubstantive_only AS Nonsubstantive_Change_Bumps,
  substantive_changes AS Substantive_Change_Bumps,
  -- Overlap metrics
  duplicate_also_nonsubstantive,
  duplicate_only,
  -- Percentages
  duplicate_bump_pct,
  nonsubstantive_bump_pct,
  -- Show what % of non-substantive bumps are also duplicates
  ROUND(duplicate_also_nonsubstantive * 100.0 / NULLIF(nonsubstantive_bumps, 0), 1) AS pct_nonsubstantive_that_are_duplicate,
  -- Unique counts
  unique_scvs_duplicate_bumped,
  unique_scvs_nonsubstantive_bumped,
  unique_submitters_bumping
FROM `clinvar_curator.cvc_duplicate_bumps_by_release`
ORDER BY release_month;


-- =============================================================================
-- Summary View: Overall Version Bump Statistics
-- =============================================================================
--
-- High-level summary comparing:
--   - Duplicate Bumps: Identical resubmissions (19 fields same)
--   - Non-substantive Change Bumps: 6 key fields same
--   - Substantive Changes: Real updates
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.cvc_duplicate_bumps_summary`
AS
WITH combined AS (
  SELECT
    frb.scv_id,
    frb.current_version,
    frb.submitter_id,
    frb.current_start_date,
    frb.is_duplicate_bump,
    COALESCE(std.is_version_bump, FALSE) AS is_nonsubstantive_bump,
    -- Create unique key for each version transition to prevent double-counting
    CONCAT(frb.scv_id, '-', CAST(frb.current_version AS STRING)) AS version_transition_key
  FROM `clinvar_curator.cvc_full_record_version_bumps` frb
  LEFT JOIN `clinvar_curator.cvc_version_bumps` std
    ON frb.scv_id = std.scv_id
    AND frb.current_version = std.current_version
)
SELECT
  -- Count unique version transitions (scv_id + version), not rows
  COUNT(DISTINCT version_transition_key) AS total_version_changes,
  -- Duplicate bumps (19-field identical)
  COUNT(DISTINCT CASE WHEN is_duplicate_bump THEN version_transition_key END) AS total_duplicate_bumps,
  -- Non-substantive bumps (6-field same)
  COUNT(DISTINCT CASE WHEN is_nonsubstantive_bump THEN version_transition_key END) AS total_nonsubstantive_bumps,
  -- Overlap
  COUNT(DISTINCT CASE WHEN is_duplicate_bump AND is_nonsubstantive_bump THEN version_transition_key END) AS duplicate_also_nonsubstantive,
  COUNT(DISTINCT CASE WHEN is_duplicate_bump AND NOT is_nonsubstantive_bump THEN version_transition_key END) AS duplicate_only,
  COUNT(DISTINCT CASE WHEN NOT is_duplicate_bump AND is_nonsubstantive_bump THEN version_transition_key END) AS nonsubstantive_only,
  -- Substantive changes
  COUNT(DISTINCT CASE WHEN NOT is_duplicate_bump AND NOT is_nonsubstantive_bump THEN version_transition_key END) AS total_substantive_changes,
  -- Percentages
  ROUND(
    COUNT(DISTINCT CASE WHEN is_duplicate_bump THEN version_transition_key END) * 100.0 /
    NULLIF(COUNT(DISTINCT version_transition_key), 0), 1
  ) AS overall_duplicate_bump_pct,
  ROUND(
    COUNT(DISTINCT CASE WHEN is_nonsubstantive_bump THEN version_transition_key END) * 100.0 /
    NULLIF(COUNT(DISTINCT version_transition_key), 0), 1
  ) AS overall_nonsubstantive_bump_pct,
  ROUND(
    COUNT(DISTINCT CASE WHEN is_duplicate_bump AND is_nonsubstantive_bump THEN version_transition_key END) * 100.0 /
    NULLIF(COUNT(DISTINCT CASE WHEN is_nonsubstantive_bump THEN version_transition_key END), 0), 1
  ) AS pct_nonsubstantive_that_are_duplicate,
  -- Unique counts
  COUNT(DISTINCT scv_id) AS unique_scvs_with_version_changes,
  COUNT(DISTINCT CASE WHEN is_duplicate_bump THEN scv_id END) AS unique_scvs_with_duplicate_bumps,
  COUNT(DISTINCT CASE WHEN is_nonsubstantive_bump THEN scv_id END) AS unique_scvs_with_nonsubstantive_bumps,
  COUNT(DISTINCT submitter_id) AS unique_submitters_with_version_changes,
  COUNT(DISTINCT CASE WHEN is_duplicate_bump THEN submitter_id END) AS unique_submitters_with_duplicate_bumps,
  MIN(current_start_date) AS earliest_version_change,
  MAX(current_start_date) AS latest_version_change
FROM combined;


-- =============================================================================
-- Google Sheets View: Version Bump Summary as Data Table
-- =============================================================================
--
-- Purpose: Unpivots the single-row summary into a two-column (metric, value)
--          table for display as a data table in Google Sheets.
--
-- =============================================================================

CREATE OR REPLACE VIEW `clinvar_curator.sheets_duplicate_bumps_summary`
AS
SELECT *
FROM (
  SELECT
    CAST(total_version_changes AS STRING) AS total_version_changes,
    CAST(total_duplicate_bumps AS STRING) AS total_duplicate_bumps,
    CAST(total_nonsubstantive_bumps AS STRING) AS total_nonsubstantive_bumps,
    CAST(duplicate_also_nonsubstantive AS STRING) AS duplicate_also_nonsubstantive,
    CAST(duplicate_only AS STRING) AS duplicate_only,
    CAST(nonsubstantive_only AS STRING) AS nonsubstantive_only,
    CAST(total_substantive_changes AS STRING) AS total_substantive_changes,
    CAST(overall_duplicate_bump_pct AS STRING) AS overall_duplicate_bump_pct,
    CAST(overall_nonsubstantive_bump_pct AS STRING) AS overall_nonsubstantive_bump_pct,
    CAST(pct_nonsubstantive_that_are_duplicate AS STRING) AS pct_nonsubstantive_that_are_duplicate,
    CAST(unique_scvs_with_version_changes AS STRING) AS unique_scvs_with_version_changes,
    CAST(unique_scvs_with_duplicate_bumps AS STRING) AS unique_scvs_with_duplicate_bumps,
    CAST(unique_scvs_with_nonsubstantive_bumps AS STRING) AS unique_scvs_with_nonsubstantive_bumps,
    CAST(unique_submitters_with_version_changes AS STRING) AS unique_submitters_with_version_changes,
    CAST(unique_submitters_with_duplicate_bumps AS STRING) AS unique_submitters_with_duplicate_bumps,
    CAST(earliest_version_change AS STRING) AS earliest_version_change,
    CAST(latest_version_change AS STRING) AS latest_version_change
  FROM `clinvar_curator.cvc_duplicate_bumps_summary`
)
UNPIVOT (value FOR metric IN (
  total_version_changes,
  total_duplicate_bumps,
  total_nonsubstantive_bumps,
  duplicate_also_nonsubstantive,
  duplicate_only,
  nonsubstantive_only,
  total_substantive_changes,
  overall_duplicate_bump_pct,
  overall_nonsubstantive_bump_pct,
  pct_nonsubstantive_that_are_duplicate,
  unique_scvs_with_version_changes,
  unique_scvs_with_duplicate_bumps,
  unique_scvs_with_nonsubstantive_bumps,
  unique_submitters_with_version_changes,
  unique_submitters_with_duplicate_bumps,
  earliest_version_change,
  latest_version_change
));
