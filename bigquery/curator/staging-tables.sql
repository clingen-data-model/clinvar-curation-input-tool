-- Legacy-only bootstrap: the native storage tables backing the curation
-- workflow's staging state (reviews/submissions/batches). These are NOT part
-- of deploy.sh's numbered apply order (this file is not matched by the
-- `0*-*.sql` glob) because they are create-once, populated-in-place tables,
-- not idempotent CREATE OR REPLACE view/function definitions.
--
-- A shadow lineage (e.g. `clinvar_curator_v4`) does NOT re-run this file.
-- Instead it deploys plain passthrough VIEWS of the same names over these
-- same legacy tables (see `bigquery/curator/adapter/staging_passthrough_views.sql`),
-- so the shadow's `cvc_annotations_base_mv` (see `00-initialize-cvc-tables.sql`)
-- can join against the identical staging state without copying it.

CREATE TABLE `@@DATASET@@.cvc_clinvar_reviews`
(
  annotation_id STRING,
  date_added TIMESTAMP,
  status STRING,
  reviewer STRING,
  notes STRING,
  date_last_updated TIMESTAMP,
  batch_id STRING
)
;

CREATE TABLE `@@DATASET@@.cvc_clinvar_submissions`
(
  annotation_id STRING,
  scv_id STRING,
  scv_ver STRING,
  batch_id STRING
)
;

CREATE TABLE `@@DATASET@@.cvc_clinvar_batches`
(
  batch_id STRING,
  finalized_datetime TIMESTAMP
)
;
