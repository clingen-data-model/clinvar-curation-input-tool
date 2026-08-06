-- Id-integrity: 0 orphans; stored annotation_id == computed annotation_id.
--
-- (a) Every staging annotation_id (cvc_clinvar_reviews / cvc_clinvar_submissions
--     — these are the SAME legacy-populated rows the shadow lineage reads
--     through its passthrough views, see adapter/staging_passthrough_views.sql)
--     must resolve directly to a row in cvc_annotations_native_v4. Because the
--     re-migration loads every historical record keyed by its own
--     annotation_id (no dedup, no crosswalk), this is 0 orphans by
--     construction FOR THE SHARED (non-drifted) population.
-- (b) The annotation_id stored on every v4 row must equal
--     CAST(UNIX_MILLIS(annotation_date) AS STRING) — i.e. the extension/
--     migration-computed id was never truncated or drifted from the formula
--     the legacy base_mv computes on the fly via @@ANNO_ID@@.
--
-- returns 0 rows for (b) always. For (a), KNOWN RESULT: 14 orphan rows —
-- these are exactly the 14 legacy-only rows enumerated in
-- 05-drift-enumeration.sql (verified 1:1 by annotation_id): sheet-side
-- review edits/backfills (all is_reviewed=true, is_submitted=false, batches
-- 104/105/112/123) that postdate the re-migration snapshot boundary. This is
-- the pre-existing sheet-vs-v4 source drift (spec §3.7), not an adapter
-- defect — see the parity report. A count other than exactly these 14 ids
-- would indicate a real regression.
SELECT s.annotation_id AS orphan_staging_id
FROM (
  SELECT annotation_id FROM `clingen-dev.clinvar_curator.cvc_clinvar_reviews` WHERE annotation_id IS NOT NULL
  UNION DISTINCT
  SELECT annotation_id FROM `clingen-dev.clinvar_curator.cvc_clinvar_submissions` WHERE annotation_id IS NOT NULL
) s
LEFT JOIN `clingen-dev.clinvar_curator.cvc_annotations_native_v4` n ON n.annotation_id = s.annotation_id
WHERE n.annotation_id IS NULL
UNION ALL
SELECT n.annotation_id
FROM `clingen-dev.clinvar_curator.cvc_annotations_native_v4` n
WHERE n.annotation_id != CAST(UNIX_MILLIS(n.annotation_date) AS STRING);
