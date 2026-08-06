-- Round-trip fidelity: v4 native `annotation_id` (+ full payload) vs the legacy
-- Google-Sheet-sourced `clinvar_annotations_native`.
--
-- The v4 shadow is sourced from the Firestore capture, which was itself migrated
-- FROM the sheet (`clinvar-cvc/migration/source.sql`: `WHERE `ignore` IS NOT TRUE`,
-- `annotation_id = CAST(UNIX_MILLIS(annotation_date) AS STRING)`). This test
-- proves that migration -> Firestore -> BQ capture -> native reshape preserved
-- BOTH the `annotation_id` (millisecond timestamp) AND every core field, with
-- zero drift, on the migrated window.
--
-- Sheet <-> v4 set-diff, fully reconciled (verified dev shadow 2026-08-06:
-- 31,383 matched / 21 sheet-only / 1 v4-only):
--   * matched       — sheet rows (`ignore` IS NOT TRUE) whose id is in v4
--   * sheet-only A   — sheet rows with `ignore` = TRUE (curator-retracted;
--                      correctly EXCLUDED by the migration -> never in v4)
--   * sheet-only B   — sheet rows created AFTER the migration snapshot boundary
--                      (the legacy sheet is still live; legitimate forward drift)
--   * v4-only        — captures made in the v4 extension after the snapshot
--                      (e.g. dev test captures); not (yet) in the legacy sheet
--
-- Two labeled 0-rows-on-success assertions:
--   (1) payload_diff     — a matched `annotation_id` whose core fields disagree
--   (2) missing_eligible — a sheet row that is eligible (`ignore` IS NOT TRUE) AND
--                          created at/before the last matched row (i.e. inside the
--                          migrated window) yet absent from v4 -> a real drop.
--                          The boundary is self-computed (MAX matched
--                          annotation_date), so post-snapshot appends never
--                          false-fail this test.
--
-- @@ANNO_V4@@ = fully-qualified v4 native table. Run with sed substitution
-- (this file is NOT in run-parity.sh's pass/fail glob — run it separately, like
-- 05-drift-enumeration.sql):
--   sed 's/@@ANNO_V4@@/clingen-dev.clinvar_curator_v4_dev.cvc_annotations_native_v4/g' \
--     bigquery/curator/tests/06-annotation-id-roundtrip.sql \
--     | bq --project_id=clingen-dev --location=US query --use_legacy_sql=false
-- (prod shadow: clingen-dev.clinvar_curator.cvc_annotations_native_v4)
--
-- returns 0 rows on success
WITH sheet AS (
  SELECT CAST(UNIX_MILLIS(annotation_date) AS STRING) AS aid, annotation_date,
         scv_id, vcv_id, variation_id, submitter_id, action, curator_email,
         interpretation, reason, notes, review_status
  FROM `clingen-dev.clinvar_curator.clinvar_annotations_native`
  WHERE `ignore` IS NOT TRUE
),
v4 AS (
  SELECT annotation_id AS aid, scv_id, vcv_id, variation_id, submitter_id, action,
         curator_email, interpretation, reason, notes, review_status
  FROM `@@ANNO_V4@@`
),
boundary AS (
  SELECT MAX(s.annotation_date) AS max_matched
  FROM sheet s JOIN v4 v USING (aid)
),
payload_diff AS (
  SELECT 'payload_diff' AS check_name, s.aid
  FROM sheet s JOIN v4 v USING (aid)
  WHERE s.scv_id        IS DISTINCT FROM v.scv_id
     OR s.vcv_id        IS DISTINCT FROM v.vcv_id
     OR s.variation_id  IS DISTINCT FROM v.variation_id
     OR s.submitter_id  IS DISTINCT FROM v.submitter_id
     OR s.action        IS DISTINCT FROM v.action
     OR s.curator_email IS DISTINCT FROM v.curator_email
     OR s.interpretation IS DISTINCT FROM v.interpretation
     OR s.reason        IS DISTINCT FROM v.reason
     OR s.notes         IS DISTINCT FROM v.notes
     OR s.review_status IS DISTINCT FROM v.review_status
),
missing_eligible AS (
  SELECT 'missing_eligible' AS check_name, s.aid
  FROM sheet s, boundary b
  WHERE s.annotation_date <= b.max_matched
    AND s.aid NOT IN (SELECT aid FROM v4)
)
SELECT * FROM payload_diff
UNION ALL
SELECT * FROM missing_eligible;
