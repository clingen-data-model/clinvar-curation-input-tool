CREATE OR REPLACE TABLE FUNCTION `clinvar_curator.cvc_outlier_clinsig`()
AS
WITH
scvs AS
  (
    SELECT
      css.variation_id,
      css.statement_type,
      css.proposition_type,
      vtop.top_rank,
      css.id as scv_id,
      css.version as scv_ver,
      css.outlier_pct,
      crg.agg_classif_w_count,
      crg.agg_sig_type,
      rel.release_date
    FROM `clinvar_ingest.release_on`(CURRENT_DATE()) rel
    JOIN `clinvar_ingest.clinvar_sum_scvs` css
    ON
      css.outlier_pct <= 0.333
      AND
      rel.release_date BETWEEN css.start_release_date AND css.end_release_date
    JOIN `clinvar_ingest.clinvar_sum_vsp_top_rank_group_change` vtop
    ON
      vtop.variation_id = css.variation_id
      AND
      vtop.statement_type = css.statement_type
      AND
      vtop.proposition_type = css.proposition_type
      AND
      vtop.top_rank = css.rank
      AND
      rel.release_date BETWEEN vtop.start_release_date AND vtop.end_release_date
    JOIN `clinvar_ingest.clinvar_sum_vsp_rank_group` crg
    ON
      crg.variation_id = vtop.variation_id
      AND
      crg.rank = vtop.top_rank
      AND
      crg.statement_type = vtop.statement_type
      AND
      crg.proposition_type = vtop.proposition_type
      AND
      rel.release_date between crg.start_release_date and crg.end_release_date
      AND
      crg.agg_sig_type > 4
  ),
  gene_vcep_status AS (
    SELECT
      gene_symbol,
      ARRAY_AGG(vcep_gene_spec_status ORDER BY
        CASE vcep_gene_spec_status
          WHEN 'approved' THEN 1
          WHEN 'in progress' THEN 2
          WHEN 'not started' THEN 3
          WHEN 'not applicable' THEN 4
          ELSE 5
        END
      LIMIT 1)[OFFSET(0)] as vcep_gene_spec_status
    FROM `variation_tracker.report_gene`
    GROUP BY gene_symbol
  ),
  vars AS (
    SELECT
      scvs.variation_id,
      scvs.statement_type,
      scvs.proposition_type,
      scvs.top_rank,
      vcv.full_vcv_id,
      vcv.id as vcv_id,
      vcv.version as vcv_ver,
      var.name,
      var.gene_id,
      var.symbol as gene_symbol,
      gvs.vcep_gene_spec_status,
      scvs.release_date
    FROM scvs
    JOIN `clingen-dev.clinvar_ingest.clinvar_variations` var
    ON
      var.id = scvs.variation_id
      AND
      scvs.release_date between var.start_release_date and var.end_release_date
    JOIN `clinvar_ingest.clinvar_vcvs` vcv
    ON
      vcv.variation_id = scvs.variation_id
      AND
      scvs.release_date between vcv.start_release_date and vcv.end_release_date
    LEFT JOIN gene_vcep_status gvs
    ON
      gvs.gene_symbol = var.symbol
    GROUP BY
      scvs.variation_id,
      scvs.statement_type,
      scvs.proposition_type,
      scvs.top_rank,
      vcv.full_vcv_id,
      vcv.id,
      vcv.version,
      var.name,
      var.gene_id,
      var.symbol,
      gvs.vcep_gene_spec_status,
      scvs.release_date
  ),
  last_reviewed_scv_anno AS (
    SELECT DISTINCT
      LAST_VALUE(
        STRUCT(
          a.variation_id,
          a.statement_type,
          a.proposition_type,
          a.scv_id,
          a.scv_ver,
          a.rank,
          a.action,
          a.curator,
          a.annotated_date
        )
      )
      OVER (
        PARTiTION BY scv_id
        ORDER BY scv_id, annotation_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
      ) as last
    FROM vars
    JOIN `clinvar_curator.cvc_annotations`("REVIEWED") a
    ON
      a.is_latest_annotation
      AND
      NOT a.is_deleted_scv
      AND
      a.variation_id = vars.variation_id
      AND
      a.rank = vars.top_rank
  ),
  latest_variation_anno AS (
    select
      lrsa.last.variation_id,
      lrsa.last.statement_type,
      lrsa.last.proposition_type,
      lrsa.last.rank,
      COUNTIF(lrsa.last.action='flagging candidate') as flagging_candidate_cnt,
      COUNTIF(lrsa.last.action = "no change") as no_change_cnt
    from last_reviewed_scv_anno lrsa
    group by
      lrsa.last.variation_id,
      lrsa.last.statement_type,
      lrsa.last.proposition_type,
      lrsa.last.rank
  )
  SELECT
    vars.variation_id,   --
    vars.full_vcv_id,  --
    vars.name,         --
    vars.gene_symbol,   --
    vars.vcep_gene_spec_status,
    vars.top_rank,
    vars.statement_type,
    vars.proposition_type,
    vars.vcv_id,
    vars.vcv_ver,
    cs.full_scv_id,    --
    cs.classification_label,
    cs.classification_abbrev,   --
    cs.submitter_id,
    cs.submitter_name,          --
    cs.clinsig_type,        --
    scvs.outlier_pct,         --
    scvs.agg_classif_w_count,   --
    scvs.agg_sig_type,          --
    ci.cvc_sig_type[OFFSET(cs.clinsig_type)].percent as cvc_outlier_pct,   --
    ci.agg_cvc_classif_w_count,    --
    ci.agg_cvc_sig_type,           --
    anno.last.action,              --
    anno.last.annotated_date,      --
    CASE
    WHEN IFNULL(ci.agg_cvc_sig_type,0) IN (1,2,4) THEN
      STRUCT("fully resolved" as name, 4 as index)
    WHEN var_anno.variation_id is NULL THEN
      STRUCT("no annotations" as name, 1 as index)
    WHEN IFNULL(var_anno.flagging_candidate_cnt, 0) > 0 THEN
      STRUCT("partially resolved" as name, 2 as index)
    ELSE
      STRUCT("no change only" as name, 3 as index)
    END as annotation_status,     --
    anno.last.curator            --
  FROM scvs
  JOIN `clinvar_ingest.clinvar_scvs` cs
  ON
    cs.id = scvs.scv_id
    AND
    cs.version = scvs.scv_ver
    AND
    scvs.release_date between cs.start_release_date and cs.end_release_date
  JOIN vars
  ON
    vars.variation_id = scvs.variation_id
    AND
    vars.statement_type = scvs.statement_type
    AND
    vars.proposition_type = scvs.proposition_type
  LEFT JOIN last_reviewed_scv_anno anno
  ON
    anno.last.scv_id = scvs.scv_id
    AND
    anno.last.scv_ver = scvs.scv_ver
  LEFT JOIN latest_variation_anno var_anno
  ON
    var_anno.variation_id = vars.variation_id
    AND
    var_anno.statement_type= vars.statement_type
    AND
    var_anno.proposition_type = vars.proposition_type
    AND
    var_anno.rank = vars.top_rank
  LEFT JOIN `clinvar_curator.cvc_annotations_impact`() ci
  ON
    ci.variation_id = vars.variation_id
    AND
    ci.statement_type = vars.statement_type
    AND
    ci.proposition_type = vars.proposition_type
    AND
    ci.rank = vars.top_rank
