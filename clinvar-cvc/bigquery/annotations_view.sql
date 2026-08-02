-- Flattened view of the POC annotations, mirroring the original Firestore
-- document shape (one typed column per field) instead of the single JSON `data`
-- column the Firestore->BigQuery extension writes.
--
-- The extension produces:
--   clinvar_cvc_ext.annotations_raw_changelog  (append-only change log)
--   clinvar_cvc_ext.annotations_raw_latest     (view: latest state per document)
-- Both keep the document body in a JSON string column named `data`.
--
-- This view parses `data` into columns matching the Firestore document, and
-- reads from `_raw_latest` so it always reflects the current state of each doc
-- (deletes drop out). It is live — no refresh needed. Run this once in the
-- BigQuery console for project clingen-cvc.
--
-- v4 annotation docs (clinvar-cvc/annotation.js buildAnnotation) add these
-- fields to `data`: vcv, name, submitter, submitter_id, interp,
-- review_status, and rename scv_id -> scv. This view surfaces the v4 fields
-- as typed columns and COALESCEs scv/scv_id into a single `scv` column so
-- both v4 and legacy POC rows populate it. The six new v4-only fields (vcv,
-- name, submitter, submitter_id, interp, review_status) are NULL for legacy
-- POC rows, since those rows predate those fields.
--
-- Applying this SQL: there is no migration tooling — run the whole file
-- against the target project, either by pasting it into the BigQuery console
-- or via `bq query --use_legacy_sql=false < annotations_view.sql`. The
-- project id is hardcoded below as the prod project `clingen-cvc`; for dev,
-- substitute `clingen-cvc-dev` before running (a follow-up could parameterize
-- this instead of hardcoding it).
--
-- Want a physical TABLE instead of a view? Replace "CREATE OR REPLACE VIEW"
-- with "CREATE OR REPLACE TABLE" for a one-time snapshot, or schedule it as a
-- scheduled query to refresh a table on a cadence.

CREATE OR REPLACE VIEW `clingen-cvc.clinvar_cvc_ext.annotations` AS
SELECT
  document_id,
  JSON_VALUE(data, '$.user_email')                        AS user_email,
  JSON_VALUE(data, '$.variation_id')                      AS variation_id,
  JSON_VALUE(data, '$.vcv')                               AS vcv,
  JSON_VALUE(data, '$.name')                              AS name,
  -- v4 docs use `scv`; legacy POC docs used `scv_id` — coalesce so one
  -- column serves both.
  COALESCE(JSON_VALUE(data, '$.scv'), JSON_VALUE(data, '$.scv_id')) AS scv,
  JSON_VALUE(data, '$.submitter')                         AS submitter,
  JSON_VALUE(data, '$.submitter_id')                      AS submitter_id,
  JSON_VALUE(data, '$.interp')                            AS interp,
  JSON_VALUE(data, '$.review_status')                     AS review_status,
  JSON_VALUE(data, '$.action')                            AS action,
  JSON_VALUE(data, '$.reason')                            AS reason,
  JSON_VALUE(data, '$.notes')                             AS notes,
  -- the extension serializes Firestore timestamps as {_seconds,_nanoseconds}
  TIMESTAMP_SECONDS(SAFE_CAST(JSON_VALUE(data, '$.created_at._seconds') AS INT64)) AS created_at,
  -- millis-since-epoch of the original curation timestamp. Sub-second precision
  -- comes from _nanoseconds (live extension saves); migrated historical rows are
  -- whole-second (annotation_date), so their _nanoseconds is 0.
  SAFE_CAST(JSON_VALUE(data, '$.created_at._seconds') AS INT64) * 1000
    + DIV(SAFE_CAST(JSON_VALUE(data, '$.created_at._nanoseconds') AS INT64), 1000000) AS created_at_millis,
  timestamp                                               AS synced_at
FROM `clingen-cvc.clinvar_cvc_ext.annotations_raw_latest`
WHERE data IS NOT NULL;   -- exclude tombstone rows for deleted documents
