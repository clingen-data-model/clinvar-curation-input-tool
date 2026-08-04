-- Restored-records audit: lists the historical annotations that the OLD
-- content-hash dedup (annotationDocId, keyed on content) would have dropped
-- as intra-source duplicates (content-identical, distinct timestamps) — now
-- ALL loaded under the no-dedup / annotation_id-keyed re-migration (Chunk 3).
-- Action-segmented (flagging candidate / remove flagged submission first),
-- joined to any downstream review/submission the record produced.
-- Persisted as a NEW table — read-derived from clinvar_annotations_native,
-- non-destructive to any existing object.
CREATE OR REPLACE TABLE `clingen-dev.clinvar_curator.cvc_restored_records_audit` AS
WITH base AS (
  SELECT
    TO_JSON_STRING([
      COALESCE(CAST(variation_id AS STRING),''), COALESCE(CAST(vcv_id AS STRING),''),
      COALESCE(CAST(scv_id AS STRING),''), COALESCE(CAST(submitter_name AS STRING),''),
      COALESCE(CAST(submitter_id AS STRING),''), COALESCE(CAST(interpretation AS STRING),''),
      COALESCE(CAST(review_status AS STRING),''), COALESCE(CAST(action AS STRING),''),
      COALESCE(CAST(reason AS STRING),''), COALESCE(CAST(notes AS STRING),''),
      COALESCE(CAST(curator_email AS STRING),'')
    ]) AS content_key,
    LOWER(action) AS action, scv_id, curator_email,
    CAST(annotation_date AS TIMESTAMP) AS annotated_on,
    CAST(UNIX_MILLIS(CAST(annotation_date AS TIMESTAMP)) AS STRING) AS annotation_id
  FROM `clingen-dev.clinvar_curator.clinvar_annotations_native`
  WHERE `ignore` IS NOT TRUE
),
dup_content AS (   -- content keys with >1 row = would have been collapsed by content-hash dedup
  SELECT content_key FROM base GROUP BY content_key HAVING COUNT(*) > 1
)
SELECT
  b.annotation_id, b.action, b.scv_id, b.curator_email, b.annotated_on,
  r.batch_id AS impacted_review_batch_id,
  s.batch_id AS impacted_submission_batch_id
FROM base b
JOIN dup_content d USING (content_key)
LEFT JOIN `clingen-dev.clinvar_curator.cvc_clinvar_reviews`     r ON r.annotation_id = b.annotation_id
LEFT JOIN `clingen-dev.clinvar_curator.cvc_clinvar_submissions` s ON s.annotation_id = b.annotation_id
ORDER BY
  CASE b.action WHEN 'flagging candidate' THEN 0 WHEN 'remove flagged submission' THEN 1 ELSE 2 END,
  b.scv_id, b.annotated_on;
