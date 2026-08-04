CREATE OR REPLACE TABLE FUNCTION `clinvar_curator.cvc_submitter_annotations`() AS
(
  WITH reviewed_annos AS (
    SELECT
      a.submitter_id,
      LAST_VALUE(a.submitter_name)
      OVER (
        PARTITION BY a.submitter_id
        ORDER BY a.annotated_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
      ) as latest_submitter_name,
      a.action,
      a.is_outdated_scv,
      a.as_of_date
    FROM `clinvar_curator.cvc_annotations`("REVIEWED") a
    WHERE
      a.is_latest_annotation
      AND
      NOT a.is_deleted_scv
  ),
  submitter_counts AS (
    SELECT
      a.submitter_id,
      a.latest_submitter_name,
      a.as_of_date,
      COUNTIF(a.action="flagging candidate") AS flagging_candidate_count,
      COUNTIF(
        (a.action="flagging candidate")
        AND
        a.is_outdated_scv
      ) AS outdated_flagging_candidate_count,
      COUNTIF(a.action="no change") AS nochange_count,
      COUNTIF(
        a.action="no change"
        AND
        a.is_outdated_scv
      ) AS outdated_nochange_count,
      COUNTIF(a.action="remove flagged submission" ) AS remove_flagged_submission_count,
      COUNTIF(
        (a.action="remove flagged submission")
        AND
        a.is_outdated_scv
      ) AS outdated_remove_flagged_submission_count
    FROM reviewed_annos a
    GROUP BY
      a.submitter_id,
      a.latest_submitter_name,
      a.as_of_date
  )
  SELECT
    x.submitter_id as id,
    IF(LENGTH(x.latest_submitter_name) > 30, FORMAT("%s...",LEFT(x.latest_submitter_name,30)), x.latest_submitter_name) as submitter,
    COUNT(scv.id) AS submission_count,
    COUNT(DISTINCT scv.variation_id) AS variation_count,
    x.flagging_candidate_count,
    x.outdated_flagging_candidate_count,
    x.nochange_count,
    x.outdated_nochange_count,
    x.remove_flagged_submission_count,
    x.outdated_remove_flagged_submission_count,
    MAX(scv.submission_date) as latest_submission_date,
    IF(COUNT(scv.id) = 0, 0, x.flagging_candidate_count/COUNT(scv.id)) as pct_flagging,
    x.as_of_date
  FROM submitter_counts x
  LEFT JOIN `clinvar_ingest.clinvar_scvs` scv
  ON
    scv.submitter_id = x.submitter_id
    AND
    scv.deleted_release_date is NULL
  GROUP BY
    x.submitter_id,
    x.latest_submitter_name,
    x.flagging_candidate_count,
    x.outdated_flagging_candidate_count,
    x.nochange_count,
    x.outdated_nochange_count,
    x.remove_flagged_submission_count,
    x.outdated_remove_flagged_submission_count,
    x.as_of_date
);
