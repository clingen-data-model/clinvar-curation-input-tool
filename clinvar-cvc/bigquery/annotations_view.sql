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
-- Want a physical TABLE instead of a view? Replace "CREATE OR REPLACE VIEW"
-- with "CREATE OR REPLACE TABLE" for a one-time snapshot, or schedule it as a
-- scheduled query to refresh a table on a cadence.

CREATE OR REPLACE VIEW `clingen-cvc.clinvar_cvc_ext.annotations` AS
SELECT
  document_id,
  JSON_VALUE(data, '$.user_email')                        AS user_email,
  JSON_VALUE(data, '$.variation_id')                      AS variation_id,
  JSON_VALUE(data, '$.scv_id')                            AS scv_id,
  JSON_VALUE(data, '$.action')                            AS action,
  JSON_VALUE(data, '$.reason')                            AS reason,
  JSON_VALUE(data, '$.notes')                             AS notes,
  -- the extension serializes Firestore timestamps as {_seconds,_nanoseconds}
  TIMESTAMP_SECONDS(SAFE_CAST(JSON_VALUE(data, '$.created_at._seconds') AS INT64)) AS created_at,
  timestamp                                               AS synced_at
FROM `clingen-cvc.clinvar_cvc_ext.annotations_raw_latest`
WHERE data IS NOT NULL;   -- exclude tombstone rows for deleted documents
