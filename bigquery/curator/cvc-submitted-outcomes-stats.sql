-- submitted_outcomes_as_of connected sheet
SELECT
  *
FROM `clinvar_curator.cvc_submitted_outcomes_view` sov
ORDER BY
  sov.batch_id,
  sov.variation_id,
  sov.scv_id

-- batch_stats_as_of connected sheet
WITH batch_anno AS (
  SELECT
    bsa.batch_id,
    bsa.scv_id,
    ccb.submission.yymm as submission_date_yy_mm,
    ccb.submission.monyy as submission_date_month_year,
    av.action,
    av.variation_id,
    (ccs.annotation_id is not null) as submitted_flag
  FROM clinvar_curator.cvc_batch_scv_max_annotation_view bsa
  JOIN clinvar_curator.cvc_clinvar_batches ccb
  ON
    ccb.batch_id = bsa.batch_id
  JOIN `clinvar_curator.cvc_annotations_view` av
  ON
    av.annotation_id = bsa.annotation_id
  LEFT JOIN clinvar_curator.cvc_clinvar_submissions ccs
  on
    ccs.annotation_id = bsa.annotation_id
)
SELECT
  ba.submission_date_yy_mm,
  ba.submission_date_month_year,
  COUNT(DISTINCT IF(submitted_flag, variation_id, null)) submitted_var_count,
  COUNT(DISTINCT IF(submitted_flag, scv_id, null)) submitted_scv_count,
  count(distinct ba.variation_id) as all_var_count,
  count(distinct ba.scv_id) as all_scv_count,
  string_agg(DISTINCT ba.batch_id ORDER BY ba.batch_id) as batch_ids
FROM batch_anno ba
GROUP BY
  ba.submission_date_yy_mm,
  ba.submission_date_month_year

-- overall_as_of connected sheet comparing all annotations vs submitted annotations
select
  CURRENT_DATE() as snapshot_date,
  "All" as category,
  count(bsa.annotation_id) as anno_count,
  count(distinct bsa.scv_id) as scv_count,
  count(distinct av.variation_id) as var_count,
from `clinvar_curator.cvc_batch_scv_max_annotation_view` bsa
join `clinvar_curator.cvc_annotations_view` av
on
  av.annotation_id = bsa.annotation_id
UNION ALL
select
  CURRENT_DATE() as snapshot_date,
  "Submitted" as category,
  count(av.annotation_id) as anno_total,
  count(distinct av.scv_id) as scv_total,
  count(distinct av.variation_id) as var_total,
from `clinvar_curator.cvc_submitted_annotations_view` sa
join `clinvar_curator.cvc_annotations_view` av
on
  av.annotation_id = sa.annotation_id
ORDER BY 3 desc

-- impact_results_as_of connected sheet
WITH
submitted_outcomes AS (
  SELECT
    scv_id,
    batch_release_date,
    batch_id,
    submission_yy_mm,
    submission_month_year,
    variation_id,
    invalid_submission_reason
  FROM `clinvar_curator.cvc_submitted_outcomes_view`
),
flagged_vars AS (
  SELECT
    batch_release_date,
    batch_id,
    submission_yy_mm,
    submission_month_year,
    variation_id
  FROM submitted_outcomes sa
  WHERE sa.invalid_submission_reason is null
  GROUP BY
    batch_release_date,
    batch_id,
    submission_yy_mm,
    submission_month_year,
    variation_id
  ),
actual_scvs as (
  SELECT
    fv.batch_release_date,
    fv.batch_id,
    fv.submission_yy_mm,
    fv.submission_month_year,
    vs.variation_id,
    vs.statement_type,
    vs.proposition_type,
    vs.rank,
    vs.clinsig_type,
    vs.classif_type,
    vs.id,
    vs.version,
    vs.last_evaluated,
    vs.submitter_id,
    vs.submission_date
  FROM flagged_vars fv
  LEFT JOIN `clinvar_ingest.clinvar_scvs` vs
  ON
    fv.variation_id = vs.variation_id
    AND
    fv.batch_release_date BETWEEN vs.start_release_date AND vs.end_release_date
  )
  ,
derived_scvs as (
  SELECT
    fv.batch_release_date,
    fv.batch_id,
    fv.submission_yy_mm,
    fv.submission_month_year,
    vs.variation_id,
    vs.statement_type,
    vs.proposition_type,
    vs.rank,
    vs.clinsig_type,
    vs.classif_type,
    vs.id,
    vs.version,
    vs.last_evaluated,
    vs.submitter_id,
    vs.submission_date
  FROM flagged_vars fv
  LEFT JOIN `clinvar_ingest.clinvar_scvs` vs
  ON
    fv.variation_id = vs.variation_id
    AND
    fv.batch_release_date BETWEEN vs.start_release_date AND vs.end_release_date
  LEFT JOIN submitted_outcomes so
  ON
    fv.variation_id = so.variation_id
    AND
    fv.batch_id = so.batch_id
    AND
    vs.id = so.scv_id
  WHERE (so.scv_id IS NULL)
),
actual_groups AS (
  SELECT
    variation_id,
    batch_release_date,
    batch_id,
    submission_yy_mm,
    submission_month_year,
    statement_type,
    proposition_type,
    rank,
    clinsig_type,
    classif_type,
    (classif_type||'('||count(DISTINCT id)||')') as classif_type_w_count
  FROM actual_scvs
  GROUP BY
    variation_id,
    batch_release_date,
    batch_id,
    submission_yy_mm,
    submission_month_year,
    statement_type,
    proposition_type,
    rank,
    classif_type,
    clinsig_type
)
,
derived_groups AS (
  SELECT
    variation_id,
    batch_release_date,
    batch_id,
    submission_yy_mm,
    submission_month_year,
    statement_type,
    proposition_type,
    rank,
    clinsig_type,
    classif_type,
    (classif_type||'('||count(DISTINCT id)||')') as classif_type_w_count
  FROM derived_scvs
  GROUP BY
    variation_id,
    batch_release_date,
    batch_id,
    submission_yy_mm,
    submission_month_year,
    statement_type,
    proposition_type,
    rank,
    classif_type,
    clinsig_type
)
,
calculated_results AS (
  SELECT
    agrps.batch_release_date,
    agrps.batch_id,
    agrps.submission_yy_mm,
    agrps.submission_month_year,
    agrps.variation_id,
    agrps.statement_type,
    agrps.proposition_type,
    agrps.rank,
    -- actual scvs
    COUNT(DISTINCT agrps.clinsig_type) as actual_unique_clinsig_type_count,
    SUM(DISTINCT IF(agrps.clinsig_type=2,4,IF(agrps.clinsig_type=1,2,IF(agrps.clinsig_type IS NULL, 0,1)))) AS actual_agg_sig_type,
    `clinvar_ingest.createSigType`(
      COUNT(DISTINCT IF(agrps.clinsig_type = 0, ascvs.submitter_id, NULL)),
      COUNT(DISTINCT IF(agrps.clinsig_type = 1, ascvs.submitter_id, NULL)),
      COUNT(DISTINCT IF(agrps.clinsig_type = 2, ascvs.submitter_id, NULL))
    ) as actual_sig_type,
    (
      COUNT(DISTINCT IF(agrps.clinsig_type = 0, ascvs.submitter_id, NULL))+
      COUNT(DISTINCT IF(agrps.clinsig_type = 1, ascvs.submitter_id, NULL))+
      COUNT(DISTINCT IF(agrps.clinsig_type = 2, ascvs.submitter_id, NULL))
    ) as actual_contributing_count,
    MAX(ascvs.last_evaluated) as actual_max_last_evaluated,
    MAX(ascvs.submission_date) as actual_max_submission_date,
    COUNT(DISTINCT ascvs.id) as actual_submission_count,
    COUNT(DISTINCT ascvs.submitter_id) as actual_submitter_count,
    STRING_AGG(DISTINCT agrps.classif_type, '/' ORDER BY agrps.classif_type) AS actual_agg_classif,
    STRING_AGG(DISTINCT agrps.classif_type_w_count, '/' ORDER BY agrps.classif_type_w_count) AS actual_agg_classif_w_count,
    -- derived scvs
    COUNT(DISTINCT dgrps.clinsig_type) as derived_unique_clinsig_type_count,
    SUM(DISTINCT IF(dgrps.clinsig_type=2,4,IF(dgrps.clinsig_type=1,2,IF(dgrps.clinsig_type IS NULL, 0,1)))) AS derived_agg_sig_type,
    `clinvar_ingest.createSigType`(
      COUNT(DISTINCT IF(dgrps.clinsig_type = 0, dscvs.submitter_id, NULL)),
      COUNT(DISTINCT IF(dgrps.clinsig_type = 1, dscvs.submitter_id, NULL)),
      COUNT(DISTINCT IF(dgrps.clinsig_type = 2, dscvs.submitter_id, NULL))
    ) as derived_sig_type,
    (
      COUNT(DISTINCT IF(dgrps.clinsig_type = 0, dscvs.submitter_id, NULL))+
      COUNT(DISTINCT IF(dgrps.clinsig_type = 1, dscvs.submitter_id, NULL))+
      COUNT(DISTINCT IF(dgrps.clinsig_type = 2, dscvs.submitter_id, NULL))
    ) as derived_contributing_count,
    MAX(dscvs.last_evaluated) as derived_max_last_evaluated,
    MAX(dscvs.submission_date) as derived_max_submission_date,
    COUNT(DISTINCT dscvs.id) as derived_submission_count,
    COUNT(DISTINCT dscvs.submitter_id) as derived_submitter_count,
    STRING_AGG(DISTINCT dgrps.classif_type, '/' ORDER BY dgrps.classif_type) AS derived_agg_classif,
    STRING_AGG(DISTINCT dgrps.classif_type_w_count, '/' ORDER BY dgrps.classif_type_w_count) AS derived_agg_classif_w_count
  FROM actual_scvs ascvs
  JOIN actual_groups agrps
  ON
    agrps.variation_id = ascvs.variation_id
    AND
    agrps.batch_id = ascvs.batch_id
    AND
    agrps.statement_type = ascvs.statement_type
    AND
    agrps.proposition_type = ascvs.proposition_type
    AND
    agrps.rank = ascvs.rank
    AND
    agrps.clinsig_type = ascvs.clinsig_type
  LEFT JOIN derived_scvs dscvs
  ON
    dscvs.id = ascvs.id
    AND
    dscvs.batch_id = ascvs.batch_id
  LEFT JOIN derived_groups dgrps
  ON
    dgrps.variation_id = dscvs.variation_id
    AND
    dgrps.batch_id = dscvs.batch_id
    AND
    dgrps.statement_type = dscvs.statement_type
    AND
    dgrps.proposition_type = dscvs.proposition_type
    AND
    dgrps.rank = dscvs.rank
    AND
    dgrps.clinsig_type = dscvs.clinsig_type
  GROUP BY
    agrps.batch_release_date,
    agrps.batch_id,
    agrps.submission_yy_mm,
    agrps.submission_month_year,
    agrps.variation_id,
    agrps.statement_type,
    agrps.proposition_type,
    agrps.rank
),
group_results AS (
  SELECT
    (cr.rank = IF(cvc.rank=2,1,cvc.rank)) as is_top_rank,
    (cr.actual_agg_sig_type not in (1,2,4)) as actual_is_conflicting,
    (cr.derived_agg_sig_type not in (1,2,4)) as derived_is_conflicting,
    (cr.actual_submission_count != cr.derived_submission_count) as is_modified,
    (cr.derived_submission_count = 0) as is_removed,
    cr.batch_release_date,
    cr.batch_id,
    cr.submission_yy_mm,
    cr.submission_month_year,
    cr.variation_id,
    cr.statement_type,
    cr.proposition_type,
    cr.rank,
    cr.actual_agg_sig_type,
    cr.actual_agg_classif_w_count,
    cr.actual_unique_clinsig_type_count,
    cr.actual_submission_count,
    cr.actual_submitter_count,
    cr.actual_sig_type,
    (SELECT MIN(sig.percent) FROM UNNEST(cr.actual_sig_type) AS sig WHERE sig.count != 0) as actual_outlier_pct,
    cr.derived_agg_sig_type,
    cr.derived_agg_classif_w_count,
    cr.derived_unique_clinsig_type_count,
    cr.derived_submission_count,
    cr.derived_submitter_count,
    cr.derived_sig_type,
    (SELECT MIN(sig.percent) FROM UNNEST(cr.derived_sig_type) AS sig WHERE sig.count != 0) as derived_outlier_pct,
    cv.id,
    cv.version,
    cvc.rank as vcv_rank,
    cvc.agg_classification_description
  FROM calculated_results cr
  LEFT JOIN `clinvar_ingest.clinvar_vcvs` cv
  ON
    cv.variation_id = cr.variation_id
    AND
    cr.batch_release_date BETWEEN cv.start_release_date AND cv.end_release_date
  LEFT JOIN `clinvar_ingest.clinvar_vcv_classifications` cvc
  ON
    cvc.vcv_id = cv.id
    AND
    cvc.statement_type = cr.statement_type
    AND
    cr.batch_release_date BETWEEN cvc.start_release_date AND cvc.end_release_date

  ),
final_results AS (
  select
    batch_id,
    submission_yy_mm,
    submission_month_year,
    variation_id,
    statement_type,
    proposition_type,

    MAX(rank) as top_rank,
    MAX_BY(is_removed, rank) as top_is_removed,
    MAX_BY(actual_is_conflicting, rank) as top_actual_conflicting,
    MAX_BY(derived_is_conflicting, rank) as top_derived_conflicting,
    MAX_BY(actual_agg_classif_w_count, rank) as top_actual_agg_classif_w_count,

    MAX(IF(is_modified,rank,null)) as modified_rank,
    MAX_BY(is_removed,  IF(is_modified,rank,null)) as modified_is_removed,
    MAX_BY(actual_is_conflicting,  IF(is_modified,rank,null)) as modified_actual_conflicting,
    MAX_BY(derived_is_conflicting, IF(is_modified,rank,null)) as modified_derived_conflicting,
    MAX_BY(derived_agg_classif_w_count, IF(is_modified,rank,null)) as modified_derived_agg_classif_w_count
  from group_results gr
  group by
    batch_id,
    submission_yy_mm,
    submission_month_year,
    variation_id,
    statement_type,
    proposition_type
)
SELECT
  batch_id,
  submission_yy_mm,
  submission_month_year,
  variation_id,
  statement_type,
  proposition_type,
  top_rank,
  top_actual_agg_classif_w_count,
  CASE
  WHEN  (top_is_removed and NOT modified_is_removed) THEN
    -- top level scvs all flagged, some lower ranked scvs still exist, show impact
    IF((top_actual_conflicting),
      -- originally conflicting
      IF((modified_derived_conflicting),
        -- result is conflicting but lower rank
        "conflict modified, rank lowered",
        --  result is non-conflicting ... resolved lower rank
        "conflict resolved, rank lowered"
      ),
      -- originally non-conflicting
      IF((modified_derived_conflicting),
        -- result is conflicting ... exposed lower ranked conflict
        "conflict created, rank lowered",
        --  result is non-conflicting ... lower rank
        "non-conflict modified, rank lowered"
      )
    )
  WHEN (top_is_removed and modified_is_removed) THEN
    -- all top scvs flagged
    IF((top_actual_conflicting),
      -- originally conflicting
      "conflict removed",
      -- originally non-conflicting
      "non-conflict removed"
    )
  WHEN (top_rank != modified_rank) THEN
    -- top_rank is not modified
    IF((top_actual_conflicting),
      -- originally conflicting
      "conflict, no change",
      -- originally non-conflicting
      "non-conflict, no change"
    )
  WHEN (top_rank = modified_rank) THEN
    -- top-rank is modified
    IF((top_actual_conflicting),
      -- originally conflicting
      IF((top_derived_conflicting),
        -- result is conflicting ... modified (test if outlier pct increased or decreased?)
        "conflict modified",
        --  result is non-conflicting ... resolved
        "conflict resolved"
      ),
      -- originally non-conflicting
      IF((top_derived_conflicting),
        -- result is conflicting ... created conflict (should never happen)
        "conflict created",
        --  result is non-conflicting ... modified
        "non-conflict modified"
      )
    )
  END as primary_impact,
  modified_rank,
  modified_derived_agg_classif_w_count,
  IF ((top_rank != modified_rank and modified_rank is not null),
    -- some secondary impact exists?
    IF((modified_is_removed),
      -- all secondary scvs flagged
      IF((modified_actual_conflicting),
        -- originally conflicting
        "secondary conflict removed",
        -- originally non-conflicting
        "secondary non-conflict removed"
      ),
      -- modified rank
      IF((modified_actual_conflicting),
        -- originally conflicting
        IF((modified_derived_conflicting),
          -- result is conflicting ... modified (test if outlier pct increased or decreased?)
          "conflict modified",
          --  result is non-conflicting ... resolved
          "conflict resolved"
        ),
        -- originally non-conflicting
        IF((modified_derived_conflicting),
          -- result is conflicting ... created conflict (should never happen)
          "conflict created",
          --  result is non-conflicting ... modified
          "non-conflict modified"
        )
      )
    ),
    null
  ) as secondary_impact

FROM final_results
where modified_rank is not null

order by 1,8
