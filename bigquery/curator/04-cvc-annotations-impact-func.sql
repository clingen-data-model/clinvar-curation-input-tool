CREATE OR REPLACE TABLE FUNCTION `clinvar_curator.cvc_annotations_impact`()
AS (
  WITH
  last_submitted_annos AS (
    SELECT DISTINCT
      LAST_VALUE(
        STRUCT(
          a.variation_id,
          a.statement_type,
          a.proposition_type,
          a.rank,
          a.scv_id,
          a.scv_ver,
          a.annotated_date,
          a.annotation_release_date,
          rel.release_date
        )
      )
      OVER(
        PARTITION BY a.variation_id, a.scv_id
        ORDER BY a.variation_id, a.scv_id, a.annotated_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
      ) last
    FROM `clinvar_ingest.release_on`(CURRENT_DATE()) rel
    JOIN `clinvar_curator.cvc_annotations`("SUBMITTED") a
    ON
      a.batch_release_date <= rel.release_date
  ),
  anno_voi AS (
    SELECT
      last.variation_id,
      last.statement_type,
      last.proposition_type,
      last.rank,
      last.release_date
    FROM last_submitted_annos
    GROUP BY
      last.variation_id,
      last.statement_type,
      last.proposition_type,
      last.rank,
      last.release_date
  ),
  var_counts AS (
    SELECT
      av.variation_id,
      av.statement_type,
      av.proposition_type,
      av.rank,
      vs.classif_type,
      vs.clinsig_type,
      vsc.start_release_date,
      vsc.end_release_date,
      av.release_date,
      IF(
        count(DISTINCT IF(sa.last.variation_id is null, vs.id, null)) > 0,
        vs.classif_type,
        null
      ) as cvc_classif_type,
      IF(
        count(DISTINCT IF(sa.last.variation_id is null, vs.id, null)) > 0,
        (vs.classif_type||'('||(count(DISTINCT IF(sa.last.variation_id is null, vs.id, null)))||')'),
        null
      ) AS cvc_classif_type_w_count
    FROM anno_voi av
    JOIN `clinvar_ingest.clinvar_sum_variation_scv_change` vsc
    ON
      av.variation_id = vsc.variation_id
      AND
      av.release_date between vsc.start_release_date AND vsc.end_release_date
    JOIN `clinvar_ingest.clinvar_scvs` vs
    ON
      av.variation_id = vs.variation_id
      AND
      av.statement_type = vs.statement_type
      AND
      av.proposition_type = vs.proposition_type
      AND
      av.rank = vs.rank
      AND
      av.release_date between vs.start_release_date AND vs.end_release_date
    LEFT JOIN last_submitted_annos sa
    ON
      vs.id = sa.last.scv_id
      AND
      vs.version = sa.last.scv_ver
    GROUP BY
      av.variation_id,
      av.statement_type,
      av.proposition_type,
      av.rank,
      vs.classif_type,
      vs.clinsig_type,
      vsc.start_release_date,
      vsc.end_release_date,
      av.release_date
  )
  SELECT
    vc.start_release_date,
    vc.end_release_date,
    vc.variation_id,
    vc.statement_type,
    vc.proposition_type,
    vc.rank,
    vc.release_date,
    COUNT(DISTINCT IF(cvc.last.variation_id is null,vs.clinsig_type,null)) as cvc_unique_clinsig_type_count,
    SUM(DISTINCT IF(cvc.last.variation_id is null,IF(vs.clinsig_type=2,4,IF(vs.clinsig_type=1,2,1)),null)) as agg_cvc_sig_type,
    `clinvar_ingest.createSigType`(
      COUNT(DISTINCT IF(cvc.last.variation_id is null and vs.clinsig_type = 0, vs.submitter_id, NULL)),
      COUNT(DISTINCT IF(cvc.last.variation_id is null and vs.clinsig_type = 1, vs.submitter_id, NULL)),
      COUNT(DISTINCT IF(cvc.last.variation_id is null and vs.clinsig_type = 2, vs.submitter_id, NULL))
    ) as cvc_sig_type,
    count(DISTINCT IF(cvc.last.variation_id is null, vs.id, null)) as cvc_submission_count,
    count(DISTINCT if(cvc.last.variation_id is null,vs.submitter_id,null)) as cvc_submitter_count,
    count(DISTINCT IF(cvc.last.variation_id is not null, vs.id, null)) as cvc_flag_submission_count,
    count(DISTINCT if(cvc.last.variation_id is not null, vs.submitter_id, null)) as cvc_flag_submitter_count,
    string_agg(distinct vc.cvc_classif_type, '/' order by vc.cvc_classif_type) AS agg_cvc_classif,
    string_agg(distinct vc.cvc_classif_type_w_count, '/' order by vc.cvc_classif_type_w_count) AS agg_cvc_classif_w_count
  from var_counts as vc
  JOIN `clinvar_ingest.clinvar_scvs` vs
  ON
    vs.variation_id = vc.variation_id
    AND
    vs.statement_type = vc.statement_type
    AND
    vs.rank = vc.rank
    AND
    release_date BETWEEN vs.start_release_date AND vs.end_release_date
  LEFT JOIN last_submitted_annos cvc
  ON
    cvc.last.variation_id = vc.variation_id
    AND
    cvc.last.scv_id = vs.id
  group by
    vc.variation_id,
    vc.start_release_date,
    vc.end_release_date,
    vc.statement_type,
    vc.proposition_type,
    vc.rank,
    vc.release_date
);
