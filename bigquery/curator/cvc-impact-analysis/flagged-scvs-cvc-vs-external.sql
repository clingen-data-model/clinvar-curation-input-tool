-- =============================================================================
-- Flagged SCVs: CvC project vs. external (all of ClinVar)
-- =============================================================================
--
-- Purpose:
--   Compare the SCVs currently FLAGGED in ClinVar against the subset that the
--   CvC project caused to be flagged, and list the flagged SCVs that are NOT
--   attributable to the CvC project (i.e. flagged by ClinVar / other parties).
--
-- Definitions:
--   - "flagged" (ClinVar)      : clinvar_ingest.clinvar_scvs.rank = -3, for the
--                                row active at the current (latest) release.
--   - "flagged by CvC"         : the SCV accession (scv_id) appears in a CvC
--                                submission batch with action = 'flagging candidate'
--                                (clinvar_curator.cvc_submitted_annotations_view).
--   - "external (non-CvC)"     : currently flagged, but the accession was never
--                                submitted by CvC as a flagging candidate.
--
-- Attribution grain:
--   Matched on SCV accession (scv_id), NOT accession+version. A ClinVar flag
--   is matched to any CvC flagging candidate for that accession, whichever
--   version CvC submitted. This does not use the requester ClinVar records on
--   the flag: scv_summary.comments has type = 'FlaggedComment' with a source of
--   'NCBI' or 'ClinGen'. Note 'ClinGen' is not the same as CvC; it also covers
--   flags with the reason 'Conflict with ClinGen Gene Dosage Map'.
--
-- Dataset notes:
--   clinvar_curator = live (sheet-sourced) curator dataset. For the dev shadow
--   lineage substitute clinvar_curator_v4_dev; for prod shadow clinvar_curator_v4.
--   clinvar_ingest  = shared ClinVar temporal dataset (same project).
--
-- Dependencies:
--   - clinvar_ingest.clinvar_scvs
--   - clinvar_ingest.schema_on(DATE)
--   - clinvar_curator.cvc_submitted_annotations_view
-- =============================================================================


-- NOTE: Run QUERY 1 or QUERY 2 individually (highlight + run). Each query
-- repeats the CTEs so it is self-contained.


-- =============================================================================
-- QUERY 1 — Summary: CvC vs external vs all flagged (counts)
-- =============================================================================
WITH
-- Current (latest) release date
current_release AS (
  SELECT release_date
  FROM `clinvar_ingest.schema_on`(CURRENT_DATE())
),

-- Accessions CvC submitted to ClinVar as flagging candidates
cvc_flagging_scvs AS (
  SELECT DISTINCT scv_id
  FROM `clinvar_curator.cvc_submitted_annotations_view`
  WHERE action = 'flagging candidate'
),

-- Every SCV currently flagged in ClinVar (rank = -3 at the latest release)
current_flagged AS (
  SELECT
    scv.id            AS scv_id,
    scv.version       AS scv_ver,
    scv.variation_id,
    scv.submitter_id,
    scv.submitter_name,
    scv.classification_label,
    scv.classif_type,
    scv.review_status,
    scv.last_evaluated,
    scv.start_release_date AS current_row_start_release
  FROM `clinvar_ingest.clinvar_scvs` scv
  JOIN current_release rel
    ON rel.release_date BETWEEN scv.start_release_date AND scv.end_release_date
  WHERE scv.rank = -3
),

classified AS (
  SELECT
    cf.*,
    (cvc.scv_id IS NOT NULL) AS flagged_by_cvc,
    IF(cvc.scv_id IS NOT NULL, 'CvC', 'external (non-CvC)') AS flag_source
  FROM current_flagged cf
  LEFT JOIN cvc_flagging_scvs cvc USING (scv_id)
)

SELECT
  IFNULL(flag_source, 'ALL FLAGGED (total)') AS flag_source_label,
  COUNT(DISTINCT scv_id)       AS flagged_scv_count,
  COUNT(DISTINCT variation_id) AS flagged_variation_count,
  COUNT(DISTINCT submitter_id) AS flagged_submitter_count
FROM classified
GROUP BY ROLLUP (flag_source)
ORDER BY (flag_source IS NULL), flagged_scv_count DESC;


-- =============================================================================
-- QUERY 2 — Detail: flagged SCVs NOT from the CvC project
-- =============================================================================
-- Flip `WHERE NOT flagged_by_cvc` to `WHERE flagged_by_cvc` to list the
-- CvC-attributed flags instead, or drop the WHERE clause for the full universe
-- with a flag_source column.
WITH
current_release AS (
  SELECT release_date
  FROM `clinvar_ingest.schema_on`(CURRENT_DATE())
),

cvc_flagging_scvs AS (
  SELECT DISTINCT scv_id
  FROM `clinvar_curator.cvc_submitted_annotations_view`
  WHERE action = 'flagging candidate'
),

current_flagged AS (
  SELECT
    scv.id            AS scv_id,
    scv.full_scv_id,
    scv.version       AS scv_ver,
    scv.variation_id,
    scv.submitter_id,
    scv.submitter_name,
    scv.classification_label,
    scv.classif_type,
    scv.review_status,
    scv.last_evaluated,
    scv.start_release_date AS current_row_start_release
  FROM `clinvar_ingest.clinvar_scvs` scv
  JOIN current_release rel
    ON rel.release_date BETWEEN scv.start_release_date AND scv.end_release_date
  WHERE scv.rank = -3
),

classified AS (
  SELECT
    cf.*,
    (cvc.scv_id IS NOT NULL) AS flagged_by_cvc
  FROM current_flagged cf
  LEFT JOIN cvc_flagging_scvs cvc USING (scv_id)
)

SELECT
  scv_id,
  full_scv_id,
  scv_ver,
  variation_id,
  submitter_id,
  submitter_name,
  classification_label,
  classif_type,
  review_status,
  last_evaluated,
  current_row_start_release
FROM classified
WHERE NOT flagged_by_cvc          -- flagged in ClinVar, but not requested by CvC
ORDER BY submitter_name, variation_id, scv_id;
