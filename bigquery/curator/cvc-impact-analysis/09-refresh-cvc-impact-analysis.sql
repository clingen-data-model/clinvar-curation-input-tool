-- =============================================================================
-- CVC Impact Analysis Refresh Procedure
-- =============================================================================
--
-- Purpose:
--   Rebuilds all 11 materialized tables in the CVC Impact Analysis pipeline
--   in dependency order.
--
--   Designed to be called from Google Apps Script after batch finalization,
--   or manually via BigQuery console.
--
--   NOTE: The cvc_batches_enriched VIEW must be deployed separately
--   (via 00-cvc-batch-enriched-view.sql). It reads batch_end_date from
--   cvc_clinvar_batches live, so no refresh is needed here.
--
-- Usage:
--   CALL `clinvar_curator.refresh_cvc_impact_analysis`();
--
-- Dependency Order:
--   Phase 1 (independent):
--     - 01: cvc_submitted_variants
--     - 04: cvc_flagging_candidate_outcomes, cvc_remove_flagged_outcomes
--     - 05: cvc_version_bumps
--     - 05f: cvc_full_record_version_bumps
--
--   Phase 2 (depends on Phase 1):
--     - 02: cvc_variant_conflict_history, cvc_resolution_attribution
--     - 06: cvc_flagging_version_bump_intersection
--     - 07: cvc_resubmission_candidates
--     - 08: cvc_autoreflag_candidates
--
--   Phase 3 (depends on Phase 2):
--     - 03: cvc_impact_summary
--
--   Not included (managed separately in 03-cvc-impact-analytics.sql):
--     - cvc_batch_effectiveness (VIEW - live aggregation)
--     - cvc_reason_effectiveness (VIEW - live aggregation)
--     - cvc_bulk_downgrade_exclusions (static table - only changes when new bulk events discovered)
--
-- =============================================================================

CREATE OR REPLACE PROCEDURE `clinvar_curator.refresh_cvc_impact_analysis`()
BEGIN

  -- =========================================================================
  -- Phase 1: Independent tables
  -- =========================================================================

  -- Step 01: cvc_submitted_variants
  CREATE OR REPLACE TABLE `clinvar_curator.cvc_submitted_variants`
  AS
  WITH
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
      (sov.invalid_submission_reason IS NULL) AS valid_submission,
      sov.invalid_submission_reason,
      sov.outcome,
      sov.report_release_date,
      DATE_ADD(sov.submission_date, INTERVAL 60 DAY) AS expected_flag_date,
      CASE
        WHEN sov.outcome = 'flagged' THEN 'cvc_flagged'
        WHEN sov.outcome = 'deleted' THEN 'submitter_deleted'
        WHEN sov.outcome = 'resubmitted, reclassified' THEN 'submitter_reclassified'
        WHEN sov.outcome = 'resubmitted, same classification' THEN 'submitter_updated_no_change'
        WHEN sov.outcome = 'pending (or rejected)' THEN 'pending'
        WHEN sov.outcome = 'invalid submission' THEN 'invalid'
        ELSE 'unknown'
      END AS outcome_category,
      CASE
        WHEN sov.outcome IN ('flagged', 'deleted', 'resubmitted, reclassified') THEN TRUE
        ELSE FALSE
      END AS is_resolution_candidate
    FROM `clinvar_curator.cvc_submitted_outcomes_view` sov
  ),

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

  -- Step 04a: cvc_flagging_candidate_outcomes
  CREATE OR REPLACE TABLE `clinvar_curator.cvc_flagging_candidate_outcomes`
  AS
  WITH
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

  -- Step 04b: cvc_remove_flagged_outcomes
  CREATE OR REPLACE TABLE `clinvar_curator.cvc_remove_flagged_outcomes`
  AS
  WITH
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

  -- Step 05: cvc_version_bumps
  CREATE OR REPLACE TABLE `clinvar_curator.cvc_version_bumps`
  AS
  WITH
  scv_versions AS (
    SELECT
      id AS scv_id,
      version,
      MIN(start_release_date) AS start_release_date,
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

  -- Step 05f: cvc_full_record_version_bumps
  CREATE OR REPLACE TABLE `clinvar_curator.cvc_full_record_version_bumps`
  AS
  WITH
  scv_versions AS (
    SELECT
      id AS scv_id,
      version,
      MIN(start_release_date) AS start_release_date,
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
      ANY_VALUE(submitter_id) AS submitter_id,
      ANY_VALUE(variation_id) AS variation_id,
      ANY_VALUE(submission_date) AS submission_date
    FROM `clinvar_ingest.clinvar_scvs`
    GROUP BY id, version
  ),

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

  -- =========================================================================
  -- Phase 2: Tables depending on Phase 1
  -- =========================================================================

  -- Step 02a: cvc_variant_conflict_history
  CREATE OR REPLACE TABLE `clinvar_curator.cvc_variant_conflict_history`
  AS
  WITH
  cvc_variants AS (
    SELECT DISTINCT
      variation_id,
      vcv_id,
      MIN(submission_date) AS first_cvc_submission_date,
      DATE_TRUNC(MIN(submission_date), MONTH) AS first_cvc_month
    FROM `clinvar_curator.cvc_submitted_variants`
    WHERE valid_submission = TRUE
    GROUP BY variation_id, vcv_id
  ),

  variant_snapshots AS (
    SELECT
      cv.variation_id,
      cv.vcv_id,
      cv.first_cvc_submission_date,
      ms.snapshot_release_date,
      ms.clinsig_conflict,
      ms.has_outlier,
      CASE
        WHEN ms.rank = 0 THEN '0-star'
        WHEN ms.rank = 1 THEN '1-star'
        WHEN ms.rank IN (3, 4) THEN '3-4-star'
        ELSE CAST(ms.rank AS STRING) || '-star'
      END AS conflict_rank_tier,
      ms.agg_sig_type,
      DATE_DIFF(ms.snapshot_release_date, cv.first_cvc_submission_date, MONTH) AS months_since_cvc_submission,
      ROW_NUMBER() OVER (
        PARTITION BY cv.variation_id
        ORDER BY ms.snapshot_release_date
      ) = 1 AS is_first_post_cvc_snapshot
    FROM cvc_variants cv
    LEFT JOIN `clinvar_ingest.monthly_conflict_snapshots` ms
      ON ms.variation_id = cv.variation_id
      AND ms.snapshot_release_date >= cv.first_cvc_submission_date
  ),

  baseline_snapshots AS (
    SELECT
      cv.variation_id,
      cv.vcv_id,
      cv.first_cvc_submission_date,
      ms.snapshot_release_date,
      ms.clinsig_conflict,
      ms.has_outlier,
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

  -- Step 02b: cvc_resolution_attribution
  CREATE OR REPLACE TABLE `clinvar_curator.cvc_resolution_attribution`
  AS
  WITH
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
      (crc.scv_ver = rsd.prev_scv_version) AS version_matches,
      CASE
        WHEN rsd.is_first_time_flagged = TRUE
          AND crc.outcome = 'flagged'
          AND crc.scv_ver = rsd.prev_scv_version
          AND rsd.snapshot_release_date >= crc.expected_flag_date
          THEN 'cvc_flagged'
        WHEN rsd.scv_change_status = 'removed'
          AND crc.outcome = 'deleted'
          AND crc.scv_ver = rsd.prev_scv_version
          AND rsd.snapshot_release_date >= crc.submission_date
          THEN 'cvc_prompted_deletion'
        WHEN rsd.has_classification_change = TRUE
          AND crc.outcome = 'resubmitted, reclassified'
          AND crc.scv_ver = rsd.prev_scv_version
          AND rsd.snapshot_release_date >= crc.submission_date
          THEN 'cvc_prompted_reclassification'
        WHEN crc.scv_id IS NOT NULL
          THEN 'cvc_submitted_but_organic'
        ELSE 'organic'
      END AS attribution_type
    FROM resolved_scv_details rsd
    LEFT JOIN cvc_resolution_candidates crc
      ON crc.scv_id = rsd.scv_id
      AND crc.submission_date <= rsd.snapshot_release_date
  ),

  variant_attribution AS (
    SELECT
      snapshot_release_date,
      variation_id,
      COUNTIF(attribution_type = 'cvc_flagged') AS cvc_flagged_scvs,
      COUNTIF(attribution_type = 'cvc_prompted_deletion') AS cvc_prompted_deletion_scvs,
      COUNTIF(attribution_type = 'cvc_prompted_reclassification') AS cvc_prompted_reclassification_scvs,
      COUNTIF(attribution_type = 'cvc_submitted_but_organic') AS cvc_submitted_organic_scvs,
      COUNTIF(attribution_type = 'organic') AS organic_scvs,
      ARRAY_AGG(DISTINCT cvc_batch_id IGNORE NULLS ORDER BY cvc_batch_id) AS cvc_batch_ids,
      ARRAY_AGG(DISTINCT cvc_curation_reason IGNORE NULLS ORDER BY cvc_curation_reason) AS cvc_curation_reasons,
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
    CASE
      WHEN va.cvc_flagged_scvs > 0
        OR va.cvc_prompted_deletion_scvs > 0
        OR va.cvc_prompted_reclassification_scvs > 0
        THEN 'cvc_attributed'
      WHEN va.cvc_submitted_organic_scvs > 0
        THEN 'cvc_submitted_organic'
      ELSE 'organic'
    END AS variant_attribution,
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

  -- Step 06: cvc_flagging_version_bump_intersection
  CREATE OR REPLACE TABLE `clinvar_curator.cvc_flagging_version_bump_intersection`
  AS
  WITH
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
    FROM `clinvar_curator.cvc_flagging_candidate_outcomes` fco
  ),

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
      (vb.current_start_date BETWEEN fc.batch_accepted_date AND fc.grace_period_end_date) AS bump_during_grace_period,
      (vb.previous_version = fc.submitted_scv_ver) AS bump_from_submitted_version
    FROM flagging_candidates fc
    JOIN `clinvar_curator.cvc_version_bumps` vb
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
      FROM `clinvar_curator.cvc_version_bumps` vb2
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

  -- Step 07: cvc_resubmission_candidates
  CREATE OR REPLACE TABLE `clinvar_curator.cvc_resubmission_candidates`
  AS
  WITH
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
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY uc.annotation_id
      ORDER BY vcv.version DESC NULLS LAST
    ) = 1
  ),

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
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY uc.annotation_id
      ORDER BY vcv.version DESC NULLS LAST
    ) = 1
  ),

  version_bump_summary AS (
    SELECT
      uc.annotation_id,
      uc.scv_id,
      LOGICAL_OR(vb.is_version_bump = TRUE) AS had_version_bump,
      COUNTIF(vb.is_version_bump = TRUE) AS version_bump_count,
      MIN(CASE WHEN vb.is_version_bump = TRUE THEN vb.current_start_date END) AS first_bump_date,
      MAX(CASE WHEN vb.is_version_bump = TRUE THEN vb.current_start_date END) AS latest_bump_date
    FROM unflagged_candidates uc
    LEFT JOIN `clinvar_curator.cvc_version_bumps` vb
      ON uc.scv_id = vb.scv_id
      AND vb.current_start_date >= uc.batch_accepted_date  -- Bump after batch acceptance
    GROUP BY uc.annotation_id, uc.scv_id
  ),

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
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY uc.annotation_id
      ORDER BY rfo.batch_accepted_date DESC
    ) = 1
  ),

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
    WHERE COALESCE(vbs.had_version_bump, FALSE) = TRUE
       OR uc.is_past_grace_period = TRUE
  )

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

  -- Step 08: cvc_autoreflag_candidates
  CREATE OR REPLACE TABLE `clinvar_curator.cvc_autoreflag_candidates`
  AS
  WITH
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

  cvc_flagging_candidates AS (
    SELECT *
    FROM all_flagging_candidates
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY scv_id
      ORDER BY batch_accepted_date DESC
    ) = 1
  ),

  latest_remove_flagged AS (
    SELECT
      rfo.scv_id,
      MAX(rfo.batch_accepted_date) AS latest_remove_date
    FROM `clinvar_curator.cvc_remove_flagged_outcomes` rfo
    GROUP BY rfo.scv_id
  ),

  submitted_versions AS (
    SELECT
      fc.annotation_id,
      fc.scv_id,
      fc.submitted_scv_ver,
      scv.classif_type AS submitted_classif_type,
      scv.submitted_classification AS submitted_submitted_classification,
      scv.last_evaluated AS submitted_last_evaluated,
      scv.trait_set_id AS submitted_trait_set_id,
      scv.pmids AS submitted_pmids,
      scv.classification_comment AS submitted_classification_comment,
      scv.classification_abbrev AS submitted_classification
    FROM cvc_flagging_candidates fc
    JOIN `clinvar_ingest.clinvar_scvs` scv
      ON fc.scv_id = scv.id
      AND fc.submitted_scv_ver = scv.version
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY fc.annotation_id
      ORDER BY scv.start_release_date ASC
    ) = 1
  ),

  current_scvs AS (
    SELECT
      scv.id AS scv_id,
      scv.version AS current_version,
      scv.rank AS current_rank,
      scv.classif_type AS current_classif_type,
      scv.submitted_classification AS current_submitted_classification,
      scv.last_evaluated AS current_last_evaluated,
      scv.trait_set_id AS current_trait_set_id,
      scv.pmids AS current_pmids,
      scv.classification_comment AS current_classification_comment,
      scv.classification_abbrev AS current_classification
    FROM `clinvar_ingest.clinvar_scvs` scv
    CROSS JOIN (
      SELECT release_date FROM `clinvar_ingest.schema_on`(CURRENT_DATE())
    ) latest
    WHERE latest.release_date BETWEEN scv.start_release_date AND scv.end_release_date
      AND scv.deleted_release_date IS NULL
  ),

  ever_flagged AS (
    SELECT
      scv.id AS scv_id,
      MIN(scv.start_release_date) AS first_flagged_date,
      MAX(scv.end_release_date) AS last_flagged_date
    FROM `clinvar_ingest.clinvar_scvs` scv
    WHERE scv.rank = -3
    GROUP BY scv.id
  ),

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

  SELECT
    ab.*,
    sub.current_name AS submitter_name,

    -- Summary flag: all 6 substantive fields unchanged = auto-reflag candidate
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

  -- =========================================================================
  -- Phase 3: Tables depending on Phase 2
  -- =========================================================================

  -- Step 03a: cvc_impact_summary
  CREATE OR REPLACE TABLE `clinvar_curator.cvc_impact_summary`
  AS
  WITH
  monthly_conflicts AS (
    SELECT
      snapshot_release_date,
      COUNT(*) AS total_conflicts,
      COUNTIF(clinsig_conflict) AS clinsig_conflicts,
      COUNTIF(NOT clinsig_conflict) AS nonclinsig_conflicts,
      COUNTIF(has_outlier) AS conflicts_with_outlier
    FROM `clinvar_ingest.monthly_conflict_snapshots`
    GROUP BY snapshot_release_date
  ),

  monthly_resolutions AS (
    SELECT
      snapshot_release_date,
      COUNT(*) AS total_resolutions,
      COUNTIF(conflict_type = 'Clinsig') AS clinsig_resolutions,
      COUNTIF(conflict_type = 'Non-clinsig') AS nonclinsig_resolutions,
      COUNTIF(outlier_status = 'With Outlier') AS outlier_resolutions
    FROM `clinvar_ingest.conflict_vcv_change_detail`
    WHERE vcv_change_status = 'resolved'
    GROUP BY snapshot_release_date
  ),

  cvc_attribution AS (
    SELECT
      snapshot_release_date,
      COUNTIF(variant_attribution = 'cvc_attributed') AS cvc_attributed_resolutions,
      COUNTIF(primary_attribution = 'cvc_flagged') AS cvc_flagged_resolutions,
      COUNTIF(primary_attribution = 'cvc_prompted_deletion') AS cvc_prompted_deletion,
      COUNTIF(primary_attribution = 'cvc_prompted_reclassification') AS cvc_prompted_reclassification,
      COUNTIF(variant_attribution = 'organic') AS organic_resolutions,
      COUNTIF(variant_attribution = 'cvc_submitted_organic') AS cvc_submitted_organic
    FROM `clinvar_curator.cvc_resolution_attribution`
    GROUP BY snapshot_release_date
  ),

  cvc_submissions AS (
    SELECT
      DATE_TRUNC(submission_date, MONTH) AS submission_month,
      COUNT(DISTINCT batch_id) AS batches_submitted,
      COUNT(*) AS scvs_submitted,
      COUNT(DISTINCT variation_id) AS variants_targeted,
      COUNTIF(outcome = 'flagged') AS scvs_flagged,
      COUNTIF(outcome = 'deleted') AS scvs_deleted,
      COUNTIF(outcome = 'resubmitted, reclassified') AS scvs_reclassified
    FROM `clinvar_curator.cvc_submitted_variants`
    WHERE valid_submission = TRUE
    GROUP BY DATE_TRUNC(submission_date, MONTH)
  ),

  cumulative_at_submission AS (
    SELECT
      submission_month,
      SUM(scvs_submitted) OVER (ORDER BY submission_month) AS cumulative_scvs_submitted,
      SUM(variants_targeted) OVER (ORDER BY submission_month) AS cumulative_variants_targeted,
      SUM(scvs_flagged) OVER (ORDER BY submission_month) AS cumulative_scvs_flagged
    FROM cvc_submissions
  ),

  all_months AS (
    SELECT DISTINCT DATE_TRUNC(snapshot_release_date, MONTH) AS month
    FROM `clinvar_ingest.monthly_conflict_snapshots`
    WHERE snapshot_release_date >= '2023-09-01'
  ),

  cumulative_cvc AS (
    SELECT
      am.month AS submission_month,
      LAST_VALUE(cas.cumulative_scvs_submitted IGNORE NULLS) OVER (
        ORDER BY am.month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS cumulative_scvs_submitted,
      LAST_VALUE(cas.cumulative_variants_targeted IGNORE NULLS) OVER (
        ORDER BY am.month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS cumulative_variants_targeted,
      LAST_VALUE(cas.cumulative_scvs_flagged IGNORE NULLS) OVER (
        ORDER BY am.month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS cumulative_scvs_flagged
    FROM all_months am
    LEFT JOIN cumulative_at_submission cas
      ON am.month = cas.submission_month
  )

  SELECT
    mc.snapshot_release_date,
    -- Overall conflict status
    mc.total_conflicts,
    mc.clinsig_conflicts,
    mc.nonclinsig_conflicts,
    mc.conflicts_with_outlier,
    -- Resolution counts
    COALESCE(mr.total_resolutions, 0) AS total_resolutions,
    COALESCE(mr.clinsig_resolutions, 0) AS clinsig_resolutions,
    COALESCE(mr.nonclinsig_resolutions, 0) AS nonclinsig_resolutions,
    COALESCE(mr.outlier_resolutions, 0) AS outlier_resolutions,
    -- CVC attribution
    COALESCE(ca.cvc_attributed_resolutions, 0) AS cvc_attributed_resolutions,
    COALESCE(ca.cvc_flagged_resolutions, 0) AS cvc_flagged_resolutions,
    COALESCE(ca.cvc_prompted_deletion, 0) AS cvc_prompted_deletion,
    COALESCE(ca.cvc_prompted_reclassification, 0) AS cvc_prompted_reclassification,
    COALESCE(ca.organic_resolutions, 0) AS organic_resolutions,
    COALESCE(ca.cvc_submitted_organic, 0) AS cvc_submitted_organic,
    -- CVC submission activity (for the month the snapshot represents)
    COALESCE(cs.batches_submitted, 0) AS batches_submitted_this_month,
    COALESCE(cs.scvs_submitted, 0) AS scvs_submitted_this_month,
    COALESCE(cs.variants_targeted, 0) AS variants_targeted_this_month,
    -- Cumulative CVC statistics
    COALESCE(cc.cumulative_scvs_submitted, 0) AS cumulative_scvs_submitted,
    COALESCE(cc.cumulative_variants_targeted, 0) AS cumulative_variants_targeted,
    COALESCE(cc.cumulative_scvs_flagged, 0) AS cumulative_scvs_flagged,
    -- Attribution rates
    CASE
      WHEN mr.total_resolutions > 0
      THEN ROUND(100.0 * COALESCE(ca.cvc_attributed_resolutions, 0) / mr.total_resolutions, 1)
      ELSE 0
    END AS cvc_attribution_rate_pct,
    CASE
      WHEN mr.total_resolutions > 0
      THEN ROUND(100.0 * COALESCE(ca.organic_resolutions, 0) / mr.total_resolutions, 1)
      ELSE 0
    END AS organic_rate_pct,
    -- Resolution rate (resolutions as % of conflicts)
    CASE
      WHEN mc.total_conflicts > 0
      THEN ROUND(100.0 * COALESCE(mr.total_resolutions, 0) / mc.total_conflicts, 2)
      ELSE 0
    END AS resolution_rate_pct
  FROM monthly_conflicts mc
  LEFT JOIN monthly_resolutions mr ON mr.snapshot_release_date = mc.snapshot_release_date
  LEFT JOIN cvc_attribution ca ON ca.snapshot_release_date = mc.snapshot_release_date
  LEFT JOIN cvc_submissions cs ON cs.submission_month = DATE_TRUNC(mc.snapshot_release_date, MONTH)
  LEFT JOIN cumulative_cvc cc ON cc.submission_month = DATE_TRUNC(mc.snapshot_release_date, MONTH)
  WHERE mc.snapshot_release_date >= '2023-09-01'  -- Start from first CVC batch
  ORDER BY mc.snapshot_release_date
  ;

  -- NOTE: cvc_batch_effectiveness, cvc_reason_effectiveness are now VIEWS
  -- (defined in 03-cvc-impact-analytics.sql), not materialized tables.
  -- They query cvc_submitted_variants and cvc_resolution_attribution live.
  --
  -- NOTE: cvc_bulk_downgrade_exclusions is a static table with hardcoded
  -- bulk downgrade events. It does not depend on CVC tables and only needs
  -- updating when a new bulk event is discovered. Managed separately in
  -- 03-cvc-impact-analytics.sql.

END;
