CREATE OR REPLACE TABLE FUNCTION `clinvar_curator.cvc_annotations`(
  scope STRING
)
AS
(
  WITH anno AS
  (
    SELECT
      a.*,
      -- originally annotated scv id+ver assertion data
      cs.statement_type,
      cs.proposition_type,
      cs.rank,
      cs.classif_type,
      cs.clinsig_type,
      -- submitter from original annotation (should never change)
      cs.submitter_name,
      cs.submitter_abbrev
    FROM `clinvar_curator.cvc_baseline_annotations`(scope) a
    LEFT JOIN `clinvar_ingest.clinvar_scvs` cs
    ON
      cs.id = a.scv_id
      AND
      a.annotation_release_date between cs.start_release_date and cs.end_release_date
  )
  ,
  scv_latest AS
  (
    -- OPTIMIZED: Replaced the inefficient LAST_VALUE/DISTINCT pattern with QUALIFY.
    -- This efficiently finds the single latest SCV record for each batch/scv_id combination.
    SELECT
      a.batch_id,
      a.scv_id,
      cs.version,
      cs.variation_id,
      cs.classif_type,
      cs.rank,
      cs.start_release_date,
      cs.end_release_date,
      cs.deleted_release_date
    FROM anno a
    JOIN `clinvar_ingest.clinvar_scvs` cs
      ON a.scv_id = cs.id
    WHERE a.is_latest
    QUALIFY ROW_NUMBER() OVER(PARTITION BY a.batch_id, a.scv_id ORDER BY cs.end_release_date DESC, cs.version DESC) = 1
  )
  ,
  vcv_latest AS
  (
    -- OPTIMIZED: Replaced the inefficient LAST_VALUE/DISTINCT pattern with QUALIFY.
    -- This efficiently finds the single latest VCV record for each batch/vcv_id combination.
    SELECT
      a.batch_id,
      a.vcv_id,
      vs.version,
      vs.variation_id,
      vcs.agg_classification_description,
      vcs.rank,
      vcs.start_release_date,
      vcs.end_release_date,
      vcs.deleted_release_date
    FROM anno a
    JOIN `clinvar_ingest.clinvar_vcvs` vs
      ON a.vcv_id = vs.id
    JOIN `clinvar_ingest.clinvar_vcv_classifications` vcs
      ON a.vcv_id = vcs.vcv_id
      AND a.statement_type = vcs.statement_type
      AND vs.end_release_date BETWEEN vcs.start_release_date AND vcs.end_release_date
    WHERE a.is_latest
    QUALIFY ROW_NUMBER() OVER(PARTITION BY a.batch_id, a.vcv_id ORDER BY vcs.end_release_date DESC, vs.version DESC) = 1
  )
  SELECT
    a.as_of_date,
    a.annotation_release_date,
    a.annotation_id,
    -- variant and vcv
    a.variation_id,
    a.vcv_axn,
    a.vcv_id,
    a.vcv_ver,
    -- scv
    a.scv_id,
    a.scv_ver,
    a.clinvar_review_status,
    -- annotation assessment record
    a.curator,
    a.annotated_on,
    a.annotated_date,
    a.action,
    a.reason,
    a.notes,
    -- originally annotated scv id+ver assertion data
    a.statement_type,
    a.proposition_type,
    a.rank,
    a.classif_type,
    a.clinsig_type,
    -- submitter from original annotation (should never change)
    a.submitter_id,
    a.submitter_name,
    a.submitter_abbrev,
    a.annotation_label,
    a.has_prior_scv_id_annotation,
    a.has_prior_scv_ver_annotation,
    a.has_prior_submission_batch_id,
    a.prior_scv_annotations,
    -- review info
    a.reviewer,
    a.review_status,
    a.review_notes,
    a.review_label,
    a.batch_id,
    a.batch_date,
    a.batch_release_date,
    -- is this the annotation the latest for this scv id
    a.is_latest AS is_latest_annotation,
    a.is_submitted AS is_submitted_annotation,
    a.is_reviewed AS is_reviewed_annotation,
    -- latest scv info
    s.version AS latest_scv_ver,
    s.start_release_date AS latest_scv_release_date,
    s.rank as latest_scv_rank,
    s.classif_type as latest_scv_classification,
    -- latest vcv info
    v.version AS latest_vcv_ver,
    v.start_release_date AS latest_vcv_release_date,
    -- calculated fields
    (s.version > a.scv_ver OR s.variation_id <> a.variation_id) AS is_outdated_scv,
    (v.version > a.vcv_ver) AS is_outdated_vcv,
    (s.deleted_release_date IS NOT NULL AND s.deleted_release_date <= a.annotation_release_date) AS is_deleted_scv,
    s.deleted_release_date as deleted_scv_release_date,
    (s.variation_id <> a.variation_id ) AS is_moved_scv
  FROM anno as a
  LEFT JOIN scv_latest s
    ON s.scv_id = a.scv_id AND s.version > a.scv_ver
  LEFT JOIN vcv_latest v
    ON v.vcv_id = a.vcv_id AND v.version > a.vcv_ver
);
