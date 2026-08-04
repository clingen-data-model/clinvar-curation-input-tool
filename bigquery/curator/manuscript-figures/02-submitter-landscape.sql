-- ============================================================================
-- Script: 02-submitter-landscape.sql
--
-- Description:
--   Produces a per-institution-type summary of ClinVar submitter organizations
--   and their Germline Variant Pathogenicity Classification contributions.
--   Shows how different institution types (clinical testing labs, research,
--   expert panels, etc.) contribute to the ClinVar pathogenicity landscape.
--
-- Scope:
--   Germline Variant Pathogenicity Classification Submission Data subset
--   (proposition_type = 'path' only). This excludes Somatic SCVs and
--   other Germline SCVs that are not pathogenicity classifications.
--
-- Data Sources:
--   - clinvar_ingest.submitter_organization - Organization metadata including
--     institution type (updated from ClinVar FTP organization_summary.txt)
--   - clinvar_ingest.clinvar_scvs - Temporal SCV data
--
-- Output Columns:
--   release_date    - ClinVar release date used for this snapshot
--   type            - Institution type (e.g., clinical testing, research, etc.)
--   submitter_count - Count of distinct submitter organizations
--   scv_count       - Count of distinct pathogenicity SCVs from this type
--   vcv_count       - Count of distinct variants with SCVs from this type
--
-- Output View:
--   clinvar_ingest.manuscript_submitter_landscape
-- ============================================================================

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_submitter_landscape` AS

SELECT
  rel.release_date,
  so.institution_type AS type,
  COUNT(DISTINCT so.id) AS submitter_count,
  COUNT(DISTINCT cs.id) AS scv_count,
  COUNT(DISTINCT cs.variation_id) AS vcv_count
FROM `clinvar_ingest.submitter_organization` so
JOIN clinvar_ingest.schema_on(CURRENT_DATE()) rel
  ON TRUE
JOIN `clinvar_ingest.clinvar_scvs` cs
  ON cs.submitter_id = so.id
  AND cs.proposition_type = 'path'
  AND rel.release_date BETWEEN cs.start_release_date AND IFNULL(cs.end_release_date, DATE'9999-01-01')
GROUP BY rel.release_date, so.institution_type
ORDER BY scv_count DESC
