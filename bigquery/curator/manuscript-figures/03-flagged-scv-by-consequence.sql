-- ============================================================================
-- Script: 03-flagged-scv-by-consequence.sql
--
-- Description:
--   Produces a summary of pathogenicity-assessed variants grouped by variation_type
--   and molecular consequence category. Shows counts of all variants vs flagged
--   variants for Google Sheets data connector queries.
--
-- Scope:
--   Germline Variant Pathogenicity Classification Submission Data subset
--   (proposition_type = 'path' only).
--
-- Consequence Groups:
--   - predicted LOF: nonsense, frameshift variant, splice donor variant, splice acceptor variant
--   - missense: missense variant
--   - inframe indels: inframe insertion, inframe_insertion, inframe deletion, inframe_deletion, inframe indel, inframe_indel
--   - UTR/intronic: 5 prime UTR variant, 3 prime UTR variant, intron variant
--   - other: synonymous variant, stop lost, start lost, and all others
--
-- Output Columns:
--   release_date                - ClinVar release date used for this snapshot
--   variation_type              - Type of variation (from variation_identity)
--   consequence_group           - Categorized molecular consequence
--   all_variant_count           - Distinct pathogenicity-assessed variants
--   flagged_variant_count       - Distinct pathogenicity-assessed variants with flagged submission
--   all_scv_count               - Distinct pathogenicity SCVs
--   flagged_scv_count           - Distinct pathogenicity SCVs with flagged submission
--   consq_labels                - Sorted unique list of consequence labels in this group (for audit)
--
-- Usage in Google Sheets:
--   SELECT * FROM `clinvar_ingest.manuscript_flagged_scv_by_consequence_view`
--
-- To refresh the data, run:
--   CALL `clinvar_ingest.refresh_flagged_scv_by_consequence`();
-- ============================================================================

-- ============================================================================
-- Result Table
-- ============================================================================

CREATE OR REPLACE TABLE `clinvar_ingest.manuscript_flagged_scv_by_consequence` (
  release_date DATE,
  variation_type STRING,
  consequence_group STRING,
  all_variant_count INT64,
  flagged_variant_count INT64,
  all_scv_count INT64,
  flagged_scv_count INT64,
  consq_labels STRING,  -- Sorted unique list of consequence labels in this group
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- ============================================================================
-- Refresh Procedure
-- ============================================================================

CREATE OR REPLACE PROCEDURE `clinvar_ingest.refresh_flagged_scv_by_consequence`(
  in_date DATE
)
BEGIN
  DECLARE on_date DATE DEFAULT IFNULL(in_date, CURRENT_DATE());
  DECLARE rec STRUCT<schema_name STRING, release_date DATE, prev_release_date DATE, next_release_date DATE>;

  -- Consequence group mappings
  DECLARE lof_consequences ARRAY<STRING> DEFAULT [
    'nonsense',
    'frameshift variant',
    'splice donor variant',
    'splice acceptor variant'
  ];
  DECLARE missense_consequences ARRAY<STRING> DEFAULT [
    'missense variant'
  ];
  DECLARE inframe_consequences ARRAY<STRING> DEFAULT [
    'inframe insertion',
    'inframe_insertion',
    'inframe deletion',
    'inframe_deletion',
    'inframe indel',
    'inframe_indel'
  ];
  DECLARE utr_intronic_consequences ARRAY<STRING> DEFAULT [
    '5 prime UTR variant',
    '3 prime UTR variant',
    'intron variant'
  ];

  -- Get the schema for the given date
  SET rec = (
    SELECT AS STRUCT
      s.schema_name,
      s.release_date,
      s.prev_release_date,
      s.next_release_date
    FROM clinvar_ingest.schema_on(on_date) AS s
  );

  -- Clear existing data for this release
  DELETE FROM `clinvar_ingest.manuscript_flagged_scv_by_consequence`
  WHERE release_date = rec.release_date;

  -- Populate results
  EXECUTE IMMEDIATE FORMAT("""
    INSERT INTO `clinvar_ingest.manuscript_flagged_scv_by_consequence` (
      release_date,
      variation_type,
      consequence_group,
      all_variant_count,
      flagged_variant_count,
      all_scv_count,
      flagged_scv_count,
      consq_labels
    )
    WITH
    -- Get all pathogenicity SCVs with their variation details
    path_scvs AS (
      SELECT
        scv.id AS scv_id,
        scv.variation_id,
        vi.variation_type,
        vh.consq_label,
        scv.review_status
      FROM `clinvar_ingest.clinvar_scvs` scv
      JOIN `%s.variation_identity` vi
        ON vi.variation_id = scv.variation_id
      LEFT JOIN `%s.variation_hgvs` vh
        ON vh.variation_id = scv.variation_id
        AND vh.mane_select = TRUE
      WHERE
        scv.proposition_type = 'path'
        AND DATE'%t' BETWEEN scv.start_release_date AND IFNULL(scv.end_release_date, DATE'9999-01-01')
    ),

    -- Identify variations that have ANY flagged SCV
    flagged_variations AS (
      SELECT DISTINCT variation_id
      FROM path_scvs
      WHERE review_status = 'flagged submission'
    ),

    -- Map consequences to groups and flag variants with any flagged SCV
    -- For multi-consequence labels (comma-separated), use the first consequence only
    variants_with_groups AS (
      SELECT
        ps.scv_id,
        ps.variation_id,
        ps.variation_type,
        ps.consq_label,
        -- Extract first consequence from comma-separated list
        TRIM(SPLIT(IFNULL(ps.consq_label, ''), ',')[SAFE_OFFSET(0)]) AS first_consq,
        ps.review_status,
        (fv.variation_id IS NOT NULL) AS has_any_flagged_scv
      FROM path_scvs ps
      LEFT JOIN flagged_variations fv
        ON fv.variation_id = ps.variation_id
    ),

    -- Assign consequence groups based on first consequence only
    variants_with_consq_groups AS (
      SELECT
        vwg.*,
        -- Determine consequence group based on first consequence term
        CASE
          WHEN EXISTS (
            SELECT 1 FROM UNNEST(@lof_consequences) AS term
            WHERE LOWER(vwg.first_consq) LIKE '%%' || term || '%%'
          ) THEN 'predicted LOF'
          WHEN EXISTS (
            SELECT 1 FROM UNNEST(@missense_consequences) AS term
            WHERE LOWER(vwg.first_consq) LIKE '%%' || term || '%%'
          ) THEN 'missense'
          WHEN EXISTS (
            SELECT 1 FROM UNNEST(@inframe_consequences) AS term
            WHERE LOWER(vwg.first_consq) LIKE '%%' || term || '%%'
          ) THEN 'inframe indels'
          WHEN EXISTS (
            SELECT 1 FROM UNNEST(@utr_intronic_consequences) AS term
            WHERE LOWER(vwg.first_consq) LIKE '%%' || term || '%%'
          ) THEN 'UTR/intronic'
          ELSE 'other'
        END AS consequence_group
      FROM variants_with_groups vwg
    ),

    -- Count variants per first consequence label for audit trail
    -- Uses only the first consequence from MANE Select transcript (not full comma-separated list)
    label_counts AS (
      SELECT
        variation_type,
        consequence_group,
        IFNULL(NULLIF(first_consq, ''), '<no mane_select>') AS consq_label_display,
        COUNT(DISTINCT variation_id) AS label_variant_count
      FROM variants_with_consq_groups
      GROUP BY variation_type, consequence_group, first_consq
    ),

    -- Aggregate label counts into formatted string
    label_strings AS (
      SELECT
        variation_type,
        consequence_group,
        ARRAY_TO_STRING(
          ARRAY_AGG(
            consq_label_display || ' (' || CAST(label_variant_count AS STRING) || ')'
            ORDER BY consq_label_display
          ), ', '
        ) AS consq_labels
      FROM label_counts
      GROUP BY variation_type, consequence_group
    )

    SELECT
      DATE'%t' AS release_date,
      vwg.variation_type,
      vwg.consequence_group,
      COUNT(DISTINCT vwg.variation_id) AS all_variant_count,
      -- Variant is flagged if ANY of its SCVs has 'flagged submission' status
      COUNT(DISTINCT CASE WHEN vwg.has_any_flagged_scv THEN vwg.variation_id END) AS flagged_variant_count,
      COUNT(DISTINCT vwg.scv_id) AS all_scv_count,
      -- Individual SCV is flagged
      COUNT(DISTINCT CASE WHEN vwg.review_status = 'flagged submission' THEN vwg.scv_id END) AS flagged_scv_count,
      ls.consq_labels
    FROM variants_with_consq_groups vwg
    JOIN label_strings ls
      ON ls.variation_type = vwg.variation_type
      AND ls.consequence_group = vwg.consequence_group
    GROUP BY
      vwg.variation_type,
      vwg.consequence_group,
      ls.consq_labels
  """,
  rec.schema_name,
  rec.schema_name,
  rec.release_date,
  rec.release_date
  )
  USING
    lof_consequences AS lof_consequences,
    missense_consequences AS missense_consequences,
    inframe_consequences AS inframe_consequences,
    utr_intronic_consequences AS utr_intronic_consequences
  ;

END;

-- ============================================================================
-- View for Google Sheets Data Connector
-- Shows the latest release data
-- ============================================================================

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_flagged_scv_by_consequence_view`
AS
SELECT
  release_date,
  variation_type,
  consequence_group,
  all_variant_count,
  flagged_variant_count,
  all_scv_count,
  flagged_scv_count,
  consq_labels
FROM `clinvar_ingest.manuscript_flagged_scv_by_consequence`
WHERE release_date = (SELECT MAX(release_date) FROM `clinvar_ingest.manuscript_flagged_scv_by_consequence`)
ORDER BY
  variation_type,
  CASE consequence_group
    WHEN 'predicted LOF' THEN 1
    WHEN 'missense' THEN 2
    WHEN 'inframe indels' THEN 3
    WHEN 'UTR/intronic' THEN 4
    ELSE 5
  END;
