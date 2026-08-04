-- We want to be able to bring back any unreviewed annotations or annotations in the process of being reviewed.
-- to know whether a given annotation is unreviewed would mean that we need to compare it to all presisted reviewed annotations
-- We want to be able to bring back any unreviewed annotations or annotations in the process of being reviewed.
-- to know whether a given annotation is unreviewed would mean that we need to compare it to all presisted reviewed annotations
CREATE OR REPLACE TABLE FUNCTION `clinvar_curator.cvc_baseline_annotations`(
  scope STRING
)
AS
(
  WITH anno AS
  (
    SELECT
      av.annotation_id,
      av.vcv_axn,
      av.scv_id,
      av.scv_ver,
      av.variation_id,
      av.submitter_id,
      av.action,
      av.curator,
      av.annotated_on,
      av.annotated_date,
      av.annotation_release_date,
      av.reason,
      av.notes,
      av.vcv_id,
      av.vcv_ver,
      av.annotation_label,
      av.clinvar_review_status,
      av.reviewer,
      av.review_status,
      av.review_notes,
      av.batch_id,
      av.batch_date,
      av.batch_release_date,
      av.is_submitted,
      av.is_reviewed,
      av.is_latest,
      av.review_label,
      UPPER(scope) as result_set_scope
    FROM `clinvar_curator.cvc_annotations_view` av
    WHERE
      CASE UPPER(scope)
      WHEN "ALL" THEN
        TRUE -- return both reviewed and unreviewed annotations
      WHEN "REVIEWED" THEN
        (av.is_reviewed) -- return only reviewed annotations
      WHEN "UNREVIEWED" THEN
        (NOT av.is_reviewed) -- return only unreviewed annotations
      WHEN "SUBMITTED" THEN
        (av.is_submitted) -- return only submitted annotations
      WHEN "LATEST" THEN
        (av.is_latest) -- return only the latest annotations per SCV per batch
      ELSE
        FALSE
      END
    ),
    anno_history AS
    (
      SELECT
        a.annotation_id,
        (COUNTIF(a.scv_id = prior_a.scv_id) > 0) as has_prior_scv_id_annotation,
        (COUNTIF(a.scv_ver = prior_a.scv_ver) > 0) as has_prior_scv_ver_annotation,
        (COUNTIF(prior_a.is_submitted) > 0) as has_prior_submission_batch_id,
        STRING_AGG(
          FORMAT(
            'v%i %s %s',
            prior_a.scv_ver,
            prior_a.annotation_label,
            if(prior_a.review_label is not null, FORMAT('[ %s ]',prior_a.review_label), '')
          ),
          '\n'
          ORDER BY prior_a.annotated_date DESC
        ) as prior_scv_annotations

      FROM anno as a
      JOIN `clinvar_curator.cvc_annotations_view` as prior_a
      ON
        prior_a.scv_id = a.scv_id
        AND
        prior_a.annotation_id < a.annotation_id
      GROUP BY
        a.annotation_id
    )
    SELECT
      CURRENT_DATE() as as_of_date,
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
      a.submitter_id,
      a.annotation_label,
      a.is_latest,
      -- review and submission info
      a.reviewer,
      a.review_status,
      a.review_notes,
      a.review_label,
      a.is_reviewed,
      a.batch_id,
      a.batch_date,
      a.batch_release_date,
      a.is_submitted,
      -- anno history
      ah.has_prior_scv_id_annotation,
      ah.has_prior_scv_ver_annotation,
      ah.has_prior_submission_batch_id,
      ah.prior_scv_annotations,
      a.result_set_scope
    FROM anno as a
    LEFT JOIN anno_history ah
    ON
      ah.annotation_id = a.annotation_id
  );
