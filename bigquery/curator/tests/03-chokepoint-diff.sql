-- Choke-point column diff — THE HEADLINE parity result.
--
-- `cvc_annotations_base_mv` is the true, singular choke point (spec §3.1):
-- the only object in either lineage that reads the annotations source
-- directly. Legacy `clinvar_curator.cvc_annotations_base_mv` (sheet-derived)
-- vs shadow `clinvar_curator_v4.cvc_annotations_base_mv` (v4-derived),
-- compared on the shared `annotation_id`s across every business + staging-
-- derived column base_mv adds: variation_id, vcv_id, scv_id, scv_ver,
-- action, reason, notes, curator, clinvar_review_status, is_reviewed,
-- is_submitted, batch_id.
--
-- Deliberately NOT anchored on the downstream `cvc_annotations("all")` TVF:
-- that TVF fans out via a release-date-range LEFT JOIN to
-- `clinvar_ingest.clinvar_scvs` (~45,647 v4 rows / ~45,737 legacy rows), a
-- PRE-EXISTING fan-out present on BOTH sides (not an adapter artifact) — see
-- 05-drift-enumeration.sql / the parity report. base_mv sits upstream of
-- that fan-out and is the exact, unambiguous choke point.
--
-- returns 0 rows on success
WITH leg AS (
  SELECT annotation_id, variation_id, vcv_id, scv_id, scv_ver, action, reason, notes,
         curator, clinvar_review_status, is_reviewed, is_submitted, batch_id
  FROM `clingen-dev.clinvar_curator.cvc_annotations_base_mv`
),
v4 AS (
  SELECT annotation_id, variation_id, vcv_id, scv_id, scv_ver, action, reason, notes,
         curator, clinvar_review_status, is_reviewed, is_submitted, batch_id
  FROM `clingen-dev.clinvar_curator_v4.cvc_annotations_base_mv`
),
shared AS (SELECT annotation_id FROM leg INTERSECT DISTINCT SELECT annotation_id FROM v4)
SELECT 'legacy_only_cols' AS side, * FROM (
  SELECT * FROM leg WHERE annotation_id IN (SELECT annotation_id FROM shared)
  EXCEPT DISTINCT
  SELECT * FROM v4 WHERE annotation_id IN (SELECT annotation_id FROM shared))
UNION ALL
SELECT 'v4_only_cols', * FROM (
  SELECT * FROM v4 WHERE annotation_id IN (SELECT annotation_id FROM shared)
  EXCEPT DISTINCT
  SELECT * FROM leg WHERE annotation_id IN (SELECT annotation_id FROM shared));
