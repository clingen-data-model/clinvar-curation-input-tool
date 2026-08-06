CREATE OR REPLACE TABLE `clingen-dev.@@CURATOR_DATASET@@.cvc_annotations_native_v4` AS
SELECT
  -- bq load --autodetect infers annotation_id as INT64 (all-numeric JSON
  -- strings), so cast to STRING before the fallback COALESCE to keep the
  -- contract's annotation_id type stable regardless of the raw load's
  -- autodetected type.
  COALESCE(CAST(annotation_id AS STRING), CAST(created_at_millis AS STRING)) AS annotation_id,
  CAST(created_at AS TIMESTAMP) AS annotation_date,
  vcv           AS vcv_id,
  scv           AS scv_id,
  -- CAST to STRING to match the legacy clinvar_annotations_native contract types
  -- (bq load --autodetect infers these all-numeric columns as INT64). base_mv
  -- casts them anyway, but this keeps native_v4 an exact-type drop-in.
  CAST(variation_id AS STRING) AS variation_id,
  CAST(submitter_id AS STRING) AS submitter_id,
  action        AS action,
  user_email    AS curator_email,
  interp        AS interpretation,
  reason        AS reason,
  notes         AS notes,
  review_status AS review_status,
  FALSE         AS `ignore`
FROM `clingen-dev.@@CURATOR_DATASET@@._annotations_v4_raw`;
