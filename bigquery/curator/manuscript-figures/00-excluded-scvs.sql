-- ============================================================================
-- Script: 00-excluded-scvs.sql
--
-- Description:
--   CvC annotations that every manuscript figure leaves out of its counts. Run
--   this before any figure script, because each figure's SQL reads these views:
--     bq query --use_legacy_sql=false < 00-excluded-scvs.sql
--
-- Views:
--   clinvar_ingest.manuscript_excluded_annotations
--   One row per left-out CvC annotation. Figures anti-join on annotation_id
--   wherever they read CvC annotations, reviews or submissions, so only these
--   annotations drop out. Other CvC work on the same SCVs still counts.
--
--   clinvar_ingest.manuscript_excluded_scvs
--   One row per SCV with a left-out annotation, for notes, call-outs and the
--   sheets' lists of left-out SCVs. Don't anti-join figures on it, because that
--   would also drop the SCV's other CvC annotations.
--
-- Exclusion:
--   Discordance project retraction - CvC submitted a remove flagged submission
--     for the SCV in batch 129 (annotated 2026-02-15, note "Discordance project
--     retraction", submitted 2026-02-20). The user asked on 2026-11-12 that the
--     project's flags and removals have no effect on any CvC count or figure.
--     233 SCVs on 231 variants, all on genes in the discordancy gene list.
--     Left out, for each of those SCVs, is every flagging candidate and every
--     remove flagged submission annotated on or before its batch 129 removal,
--     whatever its review status or batch:
--       - the flags it withdrew: the gene-disease relationship flags, plus one
--         earlier flag on SCV002507280 with a gene evidence note
--       - the batch 129 removal itself
--       - removals approved in May 2025 (batches 120 and 121, note "The GDR
--         needs to be re-curated by the ClinGen VCEP/GCEP") that were never
--         submitted, and archived duplicates of the batch 129 removal
--     No change annotations and anything annotated after the removal still
--     count, such as the batch 135 re-flag of SCV002318480 for insufficient
--     supporting evidence.
--
--   Other retracted flags are not left out. The user decided on 2026-11-12 that
--   the 88 other retracted gene-disease relationship flags (87 removed in batch
--   127 because the classification changed, 1 in batch 135) count as ordinary
--   retracted flags. Figures that count retractions say so in their own notes.
--
-- manuscript_excluded_annotations columns:
--   annotation_id, scv_id, scv_ver, variation_id, action, reason, notes,
--   annotated_date, review_status, batch_id, is_submitted
--   exclusion            - Which exclusion above applies
--   role                 - withdrawn flag, batch 129 removal, or earlier removal
--
-- manuscript_excluded_scvs columns:
--   scv_id               - SCV accession
--   variation_id         - ClinVar variation ID
--   exclusion            - Which exclusion above applies
--   flag_reason          - Reason on the latest withdrawn flag that was submitted
--   flag_batch_id        - Batch of that submission
--   flag_submission_date - Date of that submission
--   retraction_date      - Date the batch 129 removal was submitted
--   retraction_batch_id  - 129
--   excluded_annotations - How many of the SCV's annotations are left out
--   clinvar_url          - The variant's ClinVar page
-- ============================================================================

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_excluded_annotations` AS

WITH discordance_removal AS (
  SELECT
    scv_id,
    annotation_id,
    annotated_date
  FROM `clinvar_curator.cvc_submitted_annotations_view`
  WHERE action = 'remove flagged submission'
    AND CAST(batch_id AS STRING) = '129'
)

SELECT
  av.annotation_id,
  av.scv_id,
  av.scv_ver,
  av.variation_id,
  av.action,
  av.reason,
  av.notes,
  av.annotated_date,
  av.review_status,
  CAST(av.batch_id AS STRING) AS batch_id,
  av.is_submitted,
  'Discordance project retraction' AS exclusion,
  CASE
    WHEN av.annotation_id = r.annotation_id THEN 'batch 129 removal'
    WHEN av.action = 'flagging candidate' THEN 'withdrawn flag'
    ELSE 'earlier removal'
  END AS role
FROM `clinvar_curator.cvc_annotations_view` av
JOIN discordance_removal r
  ON r.scv_id = av.scv_id
  AND av.annotated_date <= r.annotated_date
WHERE av.action IN ('flagging candidate', 'remove flagged submission');

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_excluded_scvs` AS

WITH excluded AS (
  SELECT * FROM `clinvar_ingest.manuscript_excluded_annotations`
),

submitted AS (
  SELECT sa.*
  FROM `clinvar_curator.cvc_submitted_annotations_view` sa
  JOIN excluded e
    ON e.annotation_id = sa.annotation_id
)

SELECT
  e.scv_id,
  ANY_VALUE(e.variation_id) AS variation_id,
  ANY_VALUE(e.exclusion) AS exclusion,
  ARRAY_AGG(IF(s.action = 'flagging candidate', s.reason, NULL) IGNORE NULLS ORDER BY s.submission_date DESC LIMIT 1)[SAFE_OFFSET(0)] AS flag_reason,
  ARRAY_AGG(IF(s.action = 'flagging candidate', CAST(s.batch_id AS STRING), NULL) IGNORE NULLS ORDER BY s.submission_date DESC LIMIT 1)[SAFE_OFFSET(0)] AS flag_batch_id,
  MAX(IF(s.action = 'flagging candidate', s.submission_date, NULL)) AS flag_submission_date,
  MAX(IF(s.action = 'remove flagged submission' AND CAST(s.batch_id AS STRING) = '129', s.submission_date, NULL)) AS retraction_date,
  '129' AS retraction_batch_id,
  COUNT(DISTINCT e.annotation_id) AS excluded_annotations,
  CONCAT('https://www.ncbi.nlm.nih.gov/clinvar/variation/', ANY_VALUE(e.variation_id), '/') AS clinvar_url
FROM excluded e
LEFT JOIN submitted s
  ON s.annotation_id = e.annotation_id
GROUP BY e.scv_id;
