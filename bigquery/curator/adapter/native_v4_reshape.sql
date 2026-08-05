CREATE OR REPLACE TABLE `clingen-dev.clinvar_curator.cvc_annotations_native_v4` AS
SELECT
  -- bq load --autodetect infers annotation_id as INT64 (all-numeric JSON
  -- strings), so cast to STRING before the fallback COALESCE to keep the
  -- contract's annotation_id type stable regardless of the raw load's
  -- autodetected type.
  COALESCE(CAST(annotation_id AS STRING), CAST(created_at_millis AS STRING)) AS annotation_id,
  CAST(created_at AS TIMESTAMP) AS annotation_date,
  vcv           AS vcv_id,
  scv           AS scv_id,
  variation_id  AS variation_id,
  submitter_id  AS submitter_id,
  action        AS action,
  user_email    AS curator_email,
  interp        AS interpretation,
  reason        AS reason,
  notes         AS notes,
  review_status AS review_status,
  FALSE         AS `ignore`
FROM `clingen-dev.clinvar_curator._annotations_v4_raw`;
