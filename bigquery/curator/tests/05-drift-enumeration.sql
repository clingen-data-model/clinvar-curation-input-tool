-- Drift enumeration (informational — no pass/fail; excluded from
-- run-parity.sh's `0[1-4]*` glob).
--
-- Anchored on `cvc_annotations_base_mv` (the exact choke point, see
-- 03-chokepoint-diff.sql) rather than the downstream `cvc_annotations("all")`
-- TVF, which fans out via a release-date-range LEFT JOIN to
-- `clinvar_ingest.clinvar_scvs` on BOTH sides (~45k rows vs ~31.4k
-- annotations) — a pre-existing, annotation-count-inflating join, not
-- source drift. base_mv gives one row per annotation_id on each side, so
-- the diff below is a clean population-membership count.
--
-- Lists every annotation_id present on only one side, enriched with the
-- fields an auditor needs (annotated_date, action, curator, reason,
-- review/submission status, batch_id) so this doubles as the drift audit
-- log referenced by the parity report.
--
-- Known result at time of writing: legacy_only = 14 (all is_reviewed=true /
-- is_submitted=false, batches 104/105/112/123 — sheet-side review
-- edits/backfills not captured by the v4 extension); v4_only = 0.
SELECT
  'legacy_only' AS side,
  annotation_id,
  annotated_date,
  action,
  curator,
  reason,
  clinvar_review_status,
  is_reviewed,
  is_submitted,
  batch_id
FROM `clingen-dev.clinvar_curator.cvc_annotations_base_mv`
WHERE annotation_id IN (
  SELECT annotation_id FROM `clingen-dev.clinvar_curator.cvc_annotations_base_mv`
  EXCEPT DISTINCT
  SELECT annotation_id FROM `clingen-dev.clinvar_curator_v4.cvc_annotations_base_mv`
)
UNION ALL
SELECT
  'v4_only' AS side,
  annotation_id,
  annotated_date,
  action,
  curator,
  reason,
  clinvar_review_status,
  is_reviewed,
  is_submitted,
  batch_id
FROM `clingen-dev.clinvar_curator_v4.cvc_annotations_base_mv`
WHERE annotation_id IN (
  SELECT annotation_id FROM `clingen-dev.clinvar_curator_v4.cvc_annotations_base_mv`
  EXCEPT DISTINCT
  SELECT annotation_id FROM `clingen-dev.clinvar_curator.cvc_annotations_base_mv`
)
ORDER BY side, annotated_date;
