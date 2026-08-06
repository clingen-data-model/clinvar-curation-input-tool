-- =============================================================================
-- Report: CVC Annotation History for a List of Variation IDs
--
-- Description:
--   Produces a report showing the full history of CVC annotations made against
--   a provided list of variation IDs. For each annotation, shows the date,
--   action, curator, SCV details, and whether the annotation was part of a
--   workflow that resulted in a change to the top-level VCV classification.
--
-- Prerequisites:
--   Load VariationID.txt into a table (e.g. clinvar_curator.variation_id_list)
--   with a single STRING column named `variation_id`, or replace the table
--   reference below with your own source.
--
-- Usage:
--   Replace `clinvar_curator.variation_id_list` with your variation ID table.
-- =============================================================================

WITH
-- Annotation history for the requested variation IDs
annotations AS (
  SELECT DISTINCT
    a.variation_id,
    a.vcv_id,
    a.vcv_ver,
    a.scv_id,
    a.scv_ver,
    a.annotated_date,
    a.annotation_release_date,
    a.action,
    a.reason,
    a.curator,
    a.statement_type,
    a.gks_proposition_type,
    a.rank,
    a.classif_type,
    a.clinsig_type,
    a.submitter_name,
    a.submitter_abbrev,
    -- review and submission status
    a.is_reviewed_annotation,
    a.review_status,
    a.reviewer,
    a.batch_id,
    a.batch_date,
    a.batch_release_date,
    a.is_submitted_annotation,
    -- latest SCV state
    a.latest_scv_ver,
    a.latest_scv_classification,
    a.is_outdated_scv,
    a.is_deleted_scv,
    a.is_moved_scv,
    -- latest VCV state
    a.latest_vcv_ver
  FROM `clinvar_curator.cvc_annotations`("ALL") a
  JOIN `clinvar_curator.variation_id_list` vl
    ON vl.variation_id = a.variation_id
),

-- VCV classification at the time of each annotation
vcv_at_annotation AS (
  SELECT
    a.variation_id,
    a.annotated_date,
    a.annotation_release_date,
    a.statement_type,
    vcs.agg_classification_description AS vcv_classif_at_annotation,
    vcs.review_status AS vcv_review_status_at_annotation,
    vcs.num_submitters AS vcv_num_submitters_at_annotation,
    vcs.num_submissions AS vcv_num_submissions_at_annotation
  FROM annotations a
  JOIN `clinvar_ingest.clinvar_vcv_classifications` vcs
    ON vcs.variation_id = a.variation_id
    AND vcs.statement_type = a.statement_type
    AND a.annotation_release_date BETWEEN vcs.start_release_date AND vcs.end_release_date
),

-- Current VCV classification (as of latest release)
vcv_current AS (
  SELECT
    vcs.variation_id,
    vcs.statement_type,
    vcs.agg_classification_description AS vcv_classif_current,
    vcs.review_status AS vcv_review_status_current,
    vcs.num_submitters AS vcv_num_submitters_current,
    vcs.num_submissions AS vcv_num_submissions_current
  FROM `clinvar_ingest.release_on`(CURRENT_DATE()) rel
  JOIN `clinvar_ingest.clinvar_vcv_classifications` vcs
    ON rel.release_date BETWEEN vcs.start_release_date AND vcs.end_release_date
  WHERE vcs.variation_id IN (SELECT variation_id FROM `clinvar_curator.variation_id_list`)
),

-- Detect top-level classification changes between annotation time and now
detail AS (
  SELECT
    a.*,
    va.vcv_classif_at_annotation,
    va.vcv_review_status_at_annotation,
    va.vcv_num_submitters_at_annotation,
    va.vcv_num_submissions_at_annotation,
    vc.vcv_classif_current,
    vc.vcv_review_status_current,
    vc.vcv_num_submitters_current,
    vc.vcv_num_submissions_current,
    (
      va.vcv_classif_at_annotation IS NOT NULL
      AND vc.vcv_classif_current IS NOT NULL
      AND va.vcv_classif_at_annotation <> vc.vcv_classif_current
    ) AS top_level_classif_changed
  FROM annotations a
  LEFT JOIN vcv_at_annotation va
    ON va.variation_id = a.variation_id
    AND va.annotated_date = a.annotated_date
    AND va.annotation_release_date = a.annotation_release_date
    AND va.statement_type = a.statement_type
  LEFT JOIN vcv_current vc
    ON vc.variation_id = a.variation_id
    AND vc.statement_type = a.statement_type
)

-- ===========================================================================
-- Final report: one row per annotation, ordered by variation then date
-- ===========================================================================
SELECT DISTINCT
  d.variation_id,
  d.vcv_id,
  d.vcv_ver,
  d.statement_type,
  d.annotated_date,
  d.action,
  d.reason,
  d.curator,
  -- SCV details
  d.scv_id,
  d.scv_ver,
  d.classif_type AS scv_classif_at_annotation,
  d.submitter_abbrev,
  -- review/submission workflow
  d.is_reviewed_annotation,
  d.review_status,
  d.reviewer,
  d.batch_id,
  d.batch_date,
  d.is_submitted_annotation,
  d.batch_release_date,
  -- SCV outcome
  d.latest_scv_ver,
  d.latest_scv_classification,
  d.is_outdated_scv,
  d.is_deleted_scv,
  d.is_moved_scv,
  -- VCV version
  d.latest_vcv_ver,
  -- top-level VCV classification comparison
  d.vcv_classif_at_annotation,
  d.vcv_classif_current,
  d.top_level_classif_changed,
  d.vcv_review_status_at_annotation,
  d.vcv_review_status_current,
  d.vcv_num_submitters_at_annotation,
  d.vcv_num_submitters_current
FROM detail d
ORDER BY
  d.variation_id,
  d.statement_type,
  d.annotated_date,
  d.scv_id
;
