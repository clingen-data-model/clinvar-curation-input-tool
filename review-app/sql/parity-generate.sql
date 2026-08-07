-- parity-generate.sql — file-level generate parity for a finalized batch:
-- legacy vs the v4 shadow, over the exact 13-field submission projection
-- (SUBMISSION_FILE_SPEC.md). Reads legacy `clinvar_curator` directly (a READ —
-- the app's write-path guard does not apply to the parity harness). Joins the
-- batch's submissions to cvc_annotations and diffs the TO_JSON_STRING rows.
--
-- Run:  bq query --use_legacy_sql=false --parameter=batch:STRING:132 < parity-generate.sql
-- 0 legacy_only + 0 v4_only  ==  byte-identical submission file for that batch.
WITH proj AS (
  SELECT 'legacy' AS src, TO_JSON_STRING(x) AS js FROM (
    SELECT
      cvc.variation_id AS `Variation ID`, cvc.vcv_id AS VCV,
      cvc.scv_id||'.'||cvc.scv_ver AS `SCV ID`, cvc.submitter_id AS `Submitter ID`,
      cvc.action AS Action, cvc.reason AS Reason, REPLACE(cvc.notes, '\n', ' ') AS Notes,
      FORMAT_TIMESTAMP('%FT%TZ', cvc.annotated_on) AS `Timestamp`,
      cvc.as_of_date AS `Date Created`, cvc.annotation_release_date AS `ClinVar Release Date`,
      cvc.is_outdated_scv AS `Is Annotation Outdated`, cvc.is_deleted_scv AS `Is Annotated SCV Deleted`,
      cvc.deleted_scv_release_date AS `SCV Deleted Release Date`
    FROM `clingen-dev.clinvar_curator.cvc_annotations`("submitted") cvc
    JOIN `clingen-dev.clinvar_curator.cvc_clinvar_submissions` s ON s.annotation_id = cvc.annotation_id
    WHERE s.batch_id = @batch) x
  UNION ALL
  SELECT 'v4' AS src, TO_JSON_STRING(x) AS js FROM (
    SELECT
      cvc.variation_id AS `Variation ID`, cvc.vcv_id AS VCV,
      cvc.scv_id||'.'||cvc.scv_ver AS `SCV ID`, cvc.submitter_id AS `Submitter ID`,
      cvc.action AS Action, cvc.reason AS Reason, REPLACE(cvc.notes, '\n', ' ') AS Notes,
      FORMAT_TIMESTAMP('%FT%TZ', cvc.annotated_on) AS `Timestamp`,
      cvc.as_of_date AS `Date Created`, cvc.annotation_release_date AS `ClinVar Release Date`,
      cvc.is_outdated_scv AS `Is Annotation Outdated`, cvc.is_deleted_scv AS `Is Annotated SCV Deleted`,
      cvc.deleted_scv_release_date AS `SCV Deleted Release Date`
    FROM `clingen-dev.clinvar_curator_v4_dev.cvc_annotations`("submitted") cvc
    JOIN `clingen-dev.clinvar_curator_v4_dev.cvc_clinvar_submissions` s ON s.annotation_id = cvc.annotation_id
    WHERE s.batch_id = @batch) x
)
SELECT
  COUNTIF(src = 'legacy') AS legacy_rows,
  COUNTIF(src = 'v4') AS v4_rows,
  (SELECT COUNT(*) FROM (SELECT js FROM proj WHERE src='legacy' EXCEPT DISTINCT SELECT js FROM proj WHERE src='v4')) AS legacy_only,
  (SELECT COUNT(*) FROM (SELECT js FROM proj WHERE src='v4' EXCEPT DISTINCT SELECT js FROM proj WHERE src='legacy')) AS v4_only
FROM proj;
