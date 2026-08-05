-- End-to-end batch parity for a pre-drift, fully-settled finalized batch
-- (default $BATCH=132, finalized 2026-04-29 — see run-parity.sh; well clear
-- of the 14 known legacy-only drift rows, whose only touched batches are
-- 104/105/112/123, and confirmed to have 0 orphan staging ids against
-- cvc_annotations_native_v4).
--
-- Symmetric EXCEPT DISTINCT (both directions), full rows, on the two
-- batch-scoped impact tables that most directly encode curation-visible
-- outcomes (#8 flagging/version-bump intersection = reflag detection, #9
-- resubmission candidates), plus a whole-table diff of the top-level
-- rollup (#11 impact summary). annotation_id now matches directly on both
-- sides (no crosswalk / no EXCEPT(annotation_id) needed).
--
-- returns 0 rows on success
WITH d8 AS (
  (SELECT * FROM `clingen-dev.clinvar_curator.cvc_flagging_version_bump_intersection` WHERE batch_id=@batch
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_flagging_version_bump_intersection` WHERE batch_id=@batch)
  UNION ALL
  (SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_flagging_version_bump_intersection` WHERE batch_id=@batch
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator.cvc_flagging_version_bump_intersection` WHERE batch_id=@batch)
),
d9 AS (
  (SELECT * FROM `clingen-dev.clinvar_curator.cvc_resubmission_candidates` WHERE batch_id=@batch
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_resubmission_candidates` WHERE batch_id=@batch)
  UNION ALL
  (SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_resubmission_candidates` WHERE batch_id=@batch
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator.cvc_resubmission_candidates` WHERE batch_id=@batch)
),
d11 AS (
  (SELECT * FROM `clingen-dev.clinvar_curator.cvc_impact_summary`
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_impact_summary`)
  UNION ALL
  (SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_impact_summary`
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator.cvc_impact_summary`)
)
SELECT 'flag_vbump' t, TO_JSON_STRING(d8) row FROM d8
UNION ALL SELECT 'resubmission', TO_JSON_STRING(d9) FROM d9
UNION ALL SELECT 'impact_summary', TO_JSON_STRING(d11) FROM d11;
