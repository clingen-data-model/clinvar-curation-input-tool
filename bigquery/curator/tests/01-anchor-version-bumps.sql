-- Parity anchor: pure-upstream tables must be byte-identical across lineages.
--
-- cvc_version_bumps / cvc_full_record_version_bumps (impact-SP tables #4/#5,
-- see bigquery/curator/README.md dependency map) are derived ONLY from
-- clinvar_ingest.clinvar_scvs — they do not read the annotations source at
-- all. Because both the legacy `clinvar_curator` and shadow `clinvar_curator_v4`
-- lineages are deployed against the SAME `clinvar_ingest` reference data
-- (spec §7.1), these two tables are annotation-independent and MUST match
-- exactly. A diff here indicates an environment/config problem (e.g. the SP
-- was run against different clinvar_ingest snapshots), not an adapter bug.
--
-- Two tables, two different schemas -> reported as two labeled diff columns
-- rather than one UNION (their row shapes don't match). Each sub-count must
-- be 0.
--
-- returns 0 rows on success
WITH vb AS (
  (SELECT * FROM `clingen-dev.clinvar_curator.cvc_version_bumps`
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_version_bumps`)
  UNION ALL
  (SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_version_bumps`
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator.cvc_version_bumps`)
),
frvb AS (
  (SELECT * FROM `clingen-dev.clinvar_curator.cvc_full_record_version_bumps`
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_full_record_version_bumps`)
  UNION ALL
  (SELECT * FROM `clingen-dev.clinvar_curator_v4.cvc_full_record_version_bumps`
   EXCEPT DISTINCT SELECT * FROM `clingen-dev.clinvar_curator.cvc_full_record_version_bumps`)
)
SELECT 'version_bumps' AS tbl, TO_JSON_STRING(vb) AS diff_row FROM vb
UNION ALL
SELECT 'full_record_version_bumps' AS tbl, TO_JSON_STRING(frvb) AS diff_row FROM frvb;
