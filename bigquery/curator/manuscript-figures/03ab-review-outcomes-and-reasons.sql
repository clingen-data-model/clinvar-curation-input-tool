-- ============================================================================
-- Script: 03ab-review-outcomes-and-reasons.sql
--
-- Description:
--   What CvC decided about each SCV it reviewed, the input to manuscript
--   Figures 3A and 3B:
--     Figure 3A - SCVs and variants reviewed, by outcome
--     Figure 3B - SCVs submitted to ClinVar as flagging candidates, by reason
--
--   Running this script creates a table function and the views behind the
--   Figure 3 sheet. It reads ClinVar and CvC data and changes none of it.
--     bq query --use_legacy_sql=false < 03ab-review-outcomes-and-reasons.sql
--   generate_figure3ab.py then calls the table function and draws both panels.
--
-- Table function (NULL means through the latest batch):
--   clinvar_ingest.manuscript_figure3ab_scv_outcomes(as_of_date DATE)
--   Includes batches finalized on or before as_of_date, the same submission date
--   rule Figure 3C uses.
--
-- Views, pinned to the date of Figure 3C because a view cannot take a parameter.
-- To move the figure to a new date, change the DATE literal in
-- manuscript_figure3ab_scv_outcomes_view and rerun this script:
--   clinvar_ingest.manuscript_figure3ab_scv_outcomes_view (pinned)
--   clinvar_ingest.manuscript_figure3a_outcomes_view
--   clinvar_ingest.manuscript_figure3a_detail_view
--   clinvar_ingest.manuscript_figure3b_reasons_view
--   clinvar_ingest.manuscript_figure3ab_excluded_scvs_view
--
-- Scope:
--   Germline pathogenicity SCVs only (proposition_type = 'path'), read from the
--   annotated version of the SCV, or from any version of the SCV when the
--   annotated version is missing from ClinVar's history.
--   CvC annotations listed in clinvar_ingest.manuscript_excluded_annotations
--   (00-excluded-scvs.sql) are left out wherever CvC annotations, reviews or
--   submissions are read: the discordance project retraction's flags and
--   removals (batch 129), 597 annotations on 233 SCVs. Only those annotations
--   drop out. The same SCVs' other annotations, such as no change reviews in
--   other batches, still count, and an SCV with nothing else reviewed does not
--   appear. Run that script first. Other retracted flags, including the 88
--   other gene-disease relationship flags, count as ordinary retracted flags.
--   Reviews with status Archive are ignored: an archived annotation was
--   corrected before submission, so it is not a valid flagging candidate or
--   no change decision. An SCV whose only reviews are archived is left out.
--   Left-out SCVs have in_scope = FALSE, say why in exclusion, and are listed in
--   the excluded view, which also lists every SCV with a left-out discordance
--   project annotation and what happened to it.
--
-- Method:
--   Everything is counted once per SCV accession across all batches. A batch's
--   decision on an SCV is its latest annotation in that batch, and the SCV's
--   final review is its latest batch decision that is not archived.
--     Flagging candidate submitted - at least one valid flagging candidate
--       submission to ClinVar. This stays true if the flag was later retracted or
--       the SCV was later reviewed as no change, because the submission happened.
--     No change - no valid submission, and the SCV's final reviewed action is no
--       change. This includes SCVs first marked as candidates and then changed.
--     Flagging candidate not submitted - no valid submission, and the SCV's final
--       reviewed action is flagging candidate, approved as OK or Fixed. These
--       should not exist once their batch is submitted, so each one is an issue
--       to raise with the CvC team.
--   A variant takes the first of these outcomes that any of its SCVs has, so
--   variant counts add up to the number of distinct variants reviewed.
--
--   This counts submissions, not flags that are live in ClinVar. status_in_release
--   gives each SCV's state in the release at the cutoff.
-- ============================================================================

CREATE OR REPLACE TABLE FUNCTION `clinvar_ingest.manuscript_figure3ab_scv_outcomes`(as_of_date DATE) AS (

WITH cutoff AS (
  SELECT COALESCE(as_of_date, MAX(batch_end_date)) AS as_of
  FROM `clinvar_curator.cvc_clinvar_batches`
),

release AS (
  SELECT MAX(s.start_release_date) AS release_date
  FROM `clinvar_ingest.clinvar_scvs` s
  JOIN cutoff
    ON s.start_release_date <= cutoff.as_of
),

-- The SCV's final decision in a finalized batch. Each batch decides with its
-- latest annotation of the SCV. Left-out annotations are dropped first, so a
-- batch whose decision was one of them has no decision on the SCV; an earlier,
-- superseded annotation in that batch does not take its place. Archived decisions were corrected before
-- submission, so the latest decision that is not archived wins. When every
-- decision is archived, a row is kept only so the SCV can be listed as left out.
final_review AS (
  SELECT
    av.scv_id,
    av.scv_ver,
    av.variation_id,
    av.submitter_id,
    av.action AS final_action,
    av.review_status AS final_review_status,
    av.batch_id AS final_batch_id,
    av.annotation_id AS final_annotation_id,
    av.annotation_release_date,
    av.is_latest AND av.review_status != 'Archive' AS is_decision
  FROM `clinvar_curator.cvc_annotations_view` av
  JOIN cutoff
    ON av.batch_date <= cutoff.as_of
  LEFT JOIN `clinvar_ingest.manuscript_excluded_annotations` xa
    ON xa.annotation_id = av.annotation_id
  WHERE av.is_reviewed
    AND xa.annotation_id IS NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY av.scv_id
    ORDER BY av.is_latest AND av.review_status != 'Archive' DESC, av.batch_date DESC, av.is_latest DESC, av.annotated_on DESC, av.annotation_id DESC
  ) = 1
),

-- Submissions through the cutoff, without the left-out annotations.
submissions AS (
  SELECT sa.*
  FROM `clinvar_curator.cvc_submitted_annotations_view` sa
  JOIN cutoff
    ON sa.submission_date <= cutoff.as_of
  LEFT JOIN `clinvar_ingest.manuscript_excluded_annotations` xa
    ON xa.annotation_id = sa.annotation_id
  WHERE xa.annotation_id IS NULL
),

-- Flagging candidate submissions that count. The submissions view marks a
-- re-flag "submitted in prior batch" when the SCV had an earlier flag. When that
-- earlier flag is a left-out annotation, the re-flag is the SCV's first counted
-- submission, so it counts as valid (SCV002318480's batch 135 re-flag).
candidate_submissions AS (
  SELECT
    s.*,
    s.valid_submission OR (
      s.invalid_submission_reason = 'submitted in prior batch'
      AND s.scv_id IN (SELECT scv_id FROM `clinvar_ingest.manuscript_excluded_annotations`)
      AND ROW_NUMBER() OVER (PARTITION BY s.scv_id ORDER BY s.submission_date, s.annotation_id) = 1
    ) AS counts
  FROM submissions s
  WHERE s.action = 'flagging candidate'
    AND (s.valid_submission OR s.invalid_submission_reason = 'submitted in prior batch')
),

-- One row per SCV: its most recent valid flagging candidate submission.
valid_candidates AS (
  SELECT
    scv_id,
    reason,
    batch_id AS last_candidate_batch_id,
    submission_date AS last_candidate_date,
    annotation_id AS last_candidate_annotation_id,
    COUNT(*) OVER (PARTITION BY scv_id) AS candidate_submissions
  FROM candidate_submissions
  WHERE counts
  QUALIFY ROW_NUMBER() OVER (PARTITION BY scv_id ORDER BY submission_date DESC, annotated_date DESC, annotation_id DESC) = 1
),

invalid_candidates AS (
  SELECT scv_id, ANY_VALUE(invalid_submission_reason) AS invalid_reason
  FROM submissions
  WHERE action = 'flagging candidate'
    AND NOT valid_submission
  GROUP BY scv_id
),

retractions AS (
  SELECT
    scv_id,
    MAX(submission_date) AS last_retraction_date,
    ARRAY_AGG(annotation_id ORDER BY submission_date DESC, annotation_id DESC LIMIT 1)[OFFSET(0)] AS last_retraction_annotation_id
  FROM submissions
  WHERE action = 'remove flagged submission'
  GROUP BY scv_id
),

any_version AS (
  SELECT
    id,
    ARRAY_AGG(proposition_type ORDER BY end_release_date DESC LIMIT 1)[OFFSET(0)] AS proposition_type,
    ARRAY_AGG(variation_id ORDER BY end_release_date DESC LIMIT 1)[OFFSET(0)] AS variation_id
  FROM `clinvar_ingest.clinvar_scvs`
  GROUP BY id
),

scvs AS (
  SELECT
    r.* EXCEPT (variation_id),
    COALESCE(r.variation_id, any_version.variation_id) AS variation_id,
    COALESCE(annotated.proposition_type, any_version.proposition_type) AS proposition_type,
    v.reason AS submitted_reason,
    v.last_candidate_batch_id,
    v.last_candidate_date,
    v.last_candidate_annotation_id,
    v.candidate_submissions,
    i.invalid_reason,
    x.last_retraction_annotation_id,
    IFNULL(x.last_retraction_date >= v.last_candidate_date, FALSE) AS later_retracted,
    CASE
      WHEN v.scv_id IS NOT NULL THEN 'Flagging candidate submitted'
      WHEN r.final_action = 'no change' THEN 'No change'
      WHEN r.final_action = 'flagging candidate' THEN 'Flagging candidate not submitted'
      ELSE 'Other final action'
    END AS outcome,
    CASE
      WHEN current_scv.id IS NULL THEN 'not in ClinVar'
      WHEN current_scv.rank = -3 THEN 'flagged'
      ELSE 'not flagged'
    END AS status_in_release
  FROM final_review r
  CROSS JOIN release
  LEFT JOIN `clinvar_ingest.clinvar_scvs` annotated
    ON annotated.id = r.scv_id
    AND r.annotation_release_date BETWEEN annotated.start_release_date AND annotated.end_release_date
  LEFT JOIN any_version
    ON any_version.id = r.scv_id
  LEFT JOIN valid_candidates v
    ON v.scv_id = r.scv_id
  LEFT JOIN invalid_candidates i
    ON i.scv_id = r.scv_id
  LEFT JOIN retractions x
    ON x.scv_id = r.scv_id
  LEFT JOIN `clinvar_ingest.clinvar_scvs` current_scv
    ON current_scv.id = r.scv_id
    AND release.release_date BETWEEN current_scv.start_release_date AND current_scv.end_release_date
),

-- Why an SCV is left out of both figures, or NULL when it is counted.
exclusions AS (
  SELECT
    s.scv_id,
    CASE
      WHEN IFNULL(s.proposition_type != 'path', TRUE) THEN 'Not a germline pathogenicity SCV'
      WHEN NOT s.is_decision THEN 'Only archived reviews (corrected before submission)'
    END AS exclusion
  FROM scvs s
)

SELECT
  cutoff.as_of AS as_of_date,
  release.release_date,
  s.scv_id,
  s.scv_ver,
  s.variation_id,
  s.submitter_id,
  s.proposition_type,
  e.exclusion IS NULL AS in_scope,
  e.exclusion,
  s.outcome,
  s.final_action,
  s.final_review_status,
  s.final_batch_id,
  IFNULL(s.submitted_reason, IF(s.outcome = 'Flagging candidate submitted', 'Other', NULL)) AS submitted_reason,
  s.last_candidate_batch_id,
  s.last_candidate_date,
  s.candidate_submissions,
  s.later_retracted,
  s.final_annotation_id,
  s.last_candidate_annotation_id,
  IF(s.later_retracted, s.last_retraction_annotation_id, NULL) AS last_retraction_annotation_id,
  s.status_in_release,
  IF(s.outcome = 'Flagging candidate not submitted', COALESCE(s.invalid_reason, 'not included in a submission'), NULL) AS not_submitted_detail
FROM scvs s
JOIN exclusions e
  USING (scv_id)
CROSS JOIN cutoff
CROSS JOIN release
);


CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure3ab_scv_outcomes_view` AS
SELECT *
FROM `clinvar_ingest.manuscript_figure3ab_scv_outcomes`(DATE '2026-11-08');


-- One row per outcome, with SCV and variant counts. Figure 3A plots these.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure3a_outcomes_view` AS
WITH scvs AS (
  SELECT * FROM `clinvar_ingest.manuscript_figure3ab_scv_outcomes_view` WHERE in_scope
),
variants AS (
  SELECT
    variation_id,
    CASE
      WHEN LOGICAL_OR(outcome = 'Flagging candidate submitted') THEN 'Flagging candidate submitted'
      WHEN LOGICAL_OR(outcome = 'No change') THEN 'No change'
      ELSE 'Flagging candidate not submitted'
    END AS outcome
  FROM scvs
  GROUP BY variation_id
),
scv_counts AS (
  SELECT as_of_date, release_date, outcome, COUNT(*) AS scvs
  FROM scvs
  GROUP BY as_of_date, release_date, outcome
),
variant_counts AS (
  SELECT outcome, COUNT(*) AS variants
  FROM variants
  GROUP BY outcome
)
SELECT
  s.as_of_date,
  s.release_date,
  s.outcome,
  s.scvs,
  ROUND(100 * s.scvs / SUM(s.scvs) OVER (), 2) AS scv_pct,
  IFNULL(v.variants, 0) AS variants,
  ROUND(100 * IFNULL(v.variants, 0) / SUM(v.variants) OVER (), 2) AS variant_pct
FROM scv_counts s
LEFT JOIN variant_counts v
  USING (outcome);


-- The most granular Figure 3A breakdown. A variant can appear in several rows, so
-- the variants column does not add up to the total. Use the outcomes view for that.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure3a_detail_view` AS
SELECT
  as_of_date,
  release_date,
  outcome,
  final_action,
  final_review_status,
  later_retracted,
  status_in_release,
  not_submitted_detail,
  COUNT(*) AS scvs,
  COUNT(DISTINCT variation_id) AS variants
FROM `clinvar_ingest.manuscript_figure3ab_scv_outcomes_view`
WHERE in_scope
GROUP BY as_of_date, release_date, outcome, final_action, final_review_status, later_retracted, status_in_release, not_submitted_detail;


-- One row per reason. Figure 3B plots scvs. Each SCV has the reason from its most
-- recent valid submission, so scvs adds up to the Figure 3A count. A variant or
-- submitter can have several reasons, so those columns do not add up to a total.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure3b_reasons_view` AS
SELECT
  as_of_date,
  release_date,
  submitted_reason AS reason,
  COUNT(*) AS scvs,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS scv_pct,
  COUNT(DISTINCT variation_id) AS variants,
  COUNT(DISTINCT submitter_id) AS submitters,
  COUNTIF(status_in_release = 'flagged') AS scvs_flagged_in_release,
  COUNTIF(status_in_release = 'not flagged') AS scvs_not_flagged_in_release,
  COUNTIF(status_in_release = 'not in ClinVar') AS scvs_not_in_clinvar,
  COUNTIF(later_retracted) AS scvs_later_retracted
FROM `clinvar_ingest.manuscript_figure3ab_scv_outcomes_view`
WHERE in_scope
  AND outcome = 'Flagging candidate submitted'
GROUP BY as_of_date, release_date, submitted_reason;


-- SCVs the figures leave out, or count without some of their annotations:
--   - reviewed SCVs left out of both figures (in_scope = FALSE), with the reason
--   - every SCV with a left-out discordance project annotation. Its other
--     annotations still count, so effect says whether it is in the figures and
--     with which outcome. One row per SCV: these take the discordance label even
--     when they are also out of scope for another reason, which effect gives.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure3ab_excluded_scvs_view` AS
WITH outcomes AS (
  SELECT * FROM `clinvar_ingest.manuscript_figure3ab_scv_outcomes_view`
),
as_of AS (
  SELECT ANY_VALUE(as_of_date) AS as_of_date FROM outcomes
)
SELECT
  o.as_of_date,
  o.exclusion,
  o.scv_id,
  o.variation_id,
  o.proposition_type,
  o.final_action,
  o.outcome,
  o.later_retracted,
  CAST(NULL AS INT64) AS excluded_annotations,
  'Not in either figure' AS effect,
  CONCAT('https://www.ncbi.nlm.nih.gov/clinvar/variation/', o.variation_id, '/') AS clinvar_url
FROM outcomes o
WHERE NOT o.in_scope
  AND o.scv_id NOT IN (SELECT scv_id FROM `clinvar_ingest.manuscript_excluded_scvs`)
UNION ALL
SELECT
  as_of.as_of_date,
  x.exclusion,
  x.scv_id,
  x.variation_id,
  o.proposition_type,
  o.final_action,
  o.outcome,
  o.later_retracted,
  x.excluded_annotations,
  CASE
    WHEN o.scv_id IS NULL THEN 'Not in either figure: it has no other reviewed annotation'
    WHEN NOT o.in_scope THEN CONCAT('Not in either figure: ', o.exclusion)
    ELSE CONCAT('Counts as ', o.outcome, ' from its other annotations')
  END AS effect,
  x.clinvar_url
FROM `clinvar_ingest.manuscript_excluded_scvs` x
CROSS JOIN as_of
LEFT JOIN outcomes o
  ON o.scv_id = x.scv_id;
