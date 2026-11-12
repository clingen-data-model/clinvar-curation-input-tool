-- ============================================================================
-- Script: 00-excluded-scvs.sql
--
-- Description:
--   SCVs that every manuscript figure leaves out of its counts. Run this before
--   any figure script, because each figure's SQL reads this view:
--     bq query --use_legacy_sql=false < 00-excluded-scvs.sql
--
-- View:
--   clinvar_ingest.manuscript_excluded_scvs
--   One row per SCV accession. Figures anti-join on scv_id (accession, not
--   version), so every version of an excluded SCV is left out.
--
-- Exclusions (an SCV in both gets the first):
--   Discordance project retraction - CvC submitted a remove flagged submission
--     for the SCV in batch 129 (annotated 2026-02-15, note "Discordance project
--     retraction", submitted 2026-02-20). The user asked on 2026-11-12 that both
--     the SCV's original flagging candidate submissions and the removal stay out
--     of every figure and every statistic. 233 SCVs on 231 variants. All of them
--     also meet the next rule.
--
--   Retracted gene-disease relationship flag - CvC's most recent valid flagging
--     candidate submission for the SCV gave the reason "P/LP classification for
--     a variant in a gene with insufficient evidence for a gene-disease
--     relationship", and CvC later submitted a remove flagged submission for it.
--     The user asked on 2026-11-09 that these stay out of every figure. There
--     were 321 SCVs on 319 variants, all retracted between 2025-12-18 and
--     2026-08-04: the 233 above, and 88 more (87 retracted in batch 127, 1 in
--     batch 135).
--
--   Other retracted flags are not excluded. Figures that count retractions say
--   so in their own notes.
--
-- Output columns:
--   scv_id               - SCV accession
--   variation_id         - ClinVar variation ID
--   exclusion            - Which exclusion above applies
--   flag_reason          - Reason on the retracted flagging candidate submission
--   flag_batch_id        - Batch of that submission
--   flag_submission_date - Date of that submission
--   retraction_date      - Date of the latest remove flagged submission
--   retraction_batch_id  - Batch of that remove flagged submission
--   clinvar_url          - The variant's ClinVar page
-- ============================================================================

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_excluded_scvs` AS

WITH last_candidate AS (
  SELECT
    scv_id,
    variation_id,
    reason,
    batch_id,
    submission_date
  FROM `clinvar_curator.cvc_submitted_annotations_view`
  WHERE action = 'flagging candidate'
    AND valid_submission
  QUALIFY ROW_NUMBER() OVER (PARTITION BY scv_id ORDER BY submission_date DESC, annotated_date DESC, annotation_id DESC) = 1
),

retractions AS (
  SELECT
    scv_id,
    ANY_VALUE(variation_id) AS variation_id,
    MAX(submission_date) AS retraction_date,
    ARRAY_AGG(CAST(batch_id AS STRING) ORDER BY submission_date DESC LIMIT 1)[OFFSET(0)] AS retraction_batch_id,
    LOGICAL_OR(CAST(batch_id AS STRING) = '129') AS in_discordance_project
  FROM `clinvar_curator.cvc_submitted_annotations_view`
  WHERE action = 'remove flagged submission'
  GROUP BY scv_id
)

SELECT
  r.scv_id,
  COALESCE(c.variation_id, r.variation_id) AS variation_id,
  IF(r.in_discordance_project, 'Discordance project retraction', 'Retracted gene-disease relationship flag') AS exclusion,
  c.reason AS flag_reason,
  c.batch_id AS flag_batch_id,
  c.submission_date AS flag_submission_date,
  r.retraction_date,
  r.retraction_batch_id,
  CONCAT('https://www.ncbi.nlm.nih.gov/clinvar/variation/', COALESCE(c.variation_id, r.variation_id), '/') AS clinvar_url
FROM retractions r
LEFT JOIN last_candidate c
  ON c.scv_id = r.scv_id
WHERE r.in_discordance_project
  OR (
    c.reason = 'P/LP classification for a variant in a gene with insufficient evidence for a gene-disease relationship'
    AND r.retraction_date >= c.submission_date
  );
