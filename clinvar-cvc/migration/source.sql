-- Historical CvC annotations → v4-shaped rows for migration.
-- Run: bq --project_id=clingen-dev query --use_legacy_sql=false --format=json --max_rows=100000 \
--        "$(cat clinvar-cvc/migration/source.sql)" > /tmp/cvc-history.json
SELECT
  variation_id,
  vcv_id,
  variation_name,
  scv_id,
  submitter_name,
  submitter_id,
  interpretation,
  review_status,
  action,
  reason,
  notes,
  curator_email,
  CAST(UNIX_MILLIS(TIMESTAMP(annotation_date)) AS STRING) AS annotation_id,
  FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', TIMESTAMP(annotation_date), 'UTC') AS annotation_date
FROM `clingen-dev.clinvar_curator.clinvar_annotations_native`
WHERE `ignore` IS NOT TRUE
