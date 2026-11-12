-- ============================================================================
-- Script: 03-flagged-scv-by-consequence.sql
--
-- Description:
--   Produces the data for Figure 3: the molecular consequence of pathogenicity-
--   assessed variants in ClinVar versus those flagged through the CvC project,
--   plus counts of flagged variants and SCVs by flag source, for Google Sheets
--   data connector queries.
--
-- Scope:
--   Germline Variant Pathogenicity Classification Submission Data subset
--   (proposition_type = 'path' only).
--   CvC annotations listed in clinvar_ingest.manuscript_excluded_annotations
--   (00-excluded-scvs.sql) are not counted as CvC flagging candidates: the
--   discordance project retraction's flags and removals (batch 129), 597
--   annotations on 233 SCVs. An SCV still counts as CvC-flagged through any
--   other CvC flagging candidate submission. All the SCVs stay in the All ClinVar
--   counts, because they are still ClinVar submissions. A flagged SCV whose only
--   CvC submissions are left out counts as flagged with no source, not as
--   ClinGen non-CvC. Run that script first. Other retracted flags count as
--   ordinary CvC submissions.
--
-- Consequence Groups:
--   - predicted LOF: nonsense, frameshift variant, splice donor variant, splice acceptor variant
--   - missense: missense variant
--   - inframe indels: inframe insertion, inframe_insertion, inframe deletion, inframe_deletion, inframe indel, inframe_indel
--   - UTR/intronic: 5 prime UTR variant, 3 prime UTR variant, intron variant
--   - other: synonymous variant, stop lost, start lost, all others, and no MANE Select
--
--   Each MANE Select row is assigned using the first term of its consequence
--   label. A variant with more than one MANE Select row (e.g. overlapping genes)
--   is counted once, in its most severe group, in the order listed above.
--
-- Flag Sources (flagged = rank -3, source from scv_summary.comments rows with
-- type = 'FlaggedComment'):
--   - NCBI            : has a flag comment with source 'NCBI'
--   - ClinGen CvC     : has a flag comment with source 'ClinGen', and CvC submitted
--                       the SCV as a 'flagging candidate' by this release
--   - ClinGen non-CvC : has a flag comment with source 'ClinGen', and CvC did not
--                       (e.g. 'Conflict with ClinGen Gene Dosage Map')
--   An SCV can have more than one source, e.g. 'ClinGen CvC + NCBI'. An SCV can
--   not be both ClinGen CvC and ClinGen non-CvC, but a variant can, through
--   different SCVs. A flagged SCV with no recognized source is 'unattributed'.
--
-- Output Columns (manuscript_flagged_scv_by_consequence_view):
--   release_date                - ClinVar release date used for this snapshot
--   variation_type              - Type of variation (from variation_identity)
--   consequence_group           - Categorized molecular consequence
--   all_variant_count           - Distinct pathogenicity-assessed variants
--   flagged_variant_count       - Variants with a flagged SCV from ANY source
--   all_scv_count               - Distinct pathogenicity SCVs
--   flagged_scv_count           - Flagged SCVs from ANY source
--   consq_labels                - Sorted unique list of consequence labels in this group (for audit)
--   cvc_flagged_variant_count             - Variants with a ClinGen CvC flagged SCV
--   ncbi_flagged_variant_count            - Variants with an NCBI flagged SCV
--   clingen_non_cvc_flagged_variant_count - Variants with a ClinGen non-CvC flagged SCV
--   cvc_flagged_scv_count                 - SCVs flagged by ClinGen CvC
--   ncbi_flagged_scv_count                - SCVs flagged by NCBI
--   clingen_non_cvc_flagged_scv_count     - SCVs flagged by ClinGen non-CvC
--   The per-source counts overlap when a variant or SCV has more than one source.
--
-- Output Columns (manuscript_flag_source_combo_by_consequence_view):
--   release_date, variation_type, consequence_group
--   count_level                 - 'scv' or 'variant'
--   flag_source_combo           - Exact source combination, e.g. 'ClinGen CvC + NCBI'
--   item_count                  - SCVs or variants with exactly this combination
--   first_item_ids              - Up to the first 5 of those SCV accessions or variation ids, in order
--   These rows do not overlap, so they sum to the flagged totals.
--
-- Output Columns (manuscript_cvc_vs_clinvar_consequence_bar_view, Figure 3 chart):
--   release_date, consequence_group
--   all_variant_count           - All pathogenicity-assessed variants
--   cvc_flagged_variant_count   - Variants flagged through the CvC project
--   all_variant_pct             - Percent of all variants in this group
--   cvc_flagged_variant_pct     - Percent of CvC flagged variants in this group
--
-- Usage in Google Sheets:
--   SELECT * FROM `clinvar_ingest.manuscript_cvc_vs_clinvar_consequence_bar_view`
--   SELECT * FROM `clinvar_ingest.manuscript_flag_source_combo_by_consequence_view`
--   SELECT * FROM `clinvar_ingest.manuscript_flagged_scv_by_consequence_view`
--
-- To refresh the data, run:
--   CALL `clinvar_ingest.refresh_flagged_scv_by_consequence`(NULL);
-- ============================================================================

-- ============================================================================
-- Result Tables
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
  cvc_flagged_variant_count INT64,
  ncbi_flagged_variant_count INT64,
  clingen_non_cvc_flagged_variant_count INT64,
  cvc_flagged_scv_count INT64,
  ncbi_flagged_scv_count INT64,
  clingen_non_cvc_flagged_scv_count INT64,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE `clinvar_ingest.manuscript_flag_source_combo_by_consequence` (
  release_date DATE,
  variation_type STRING,
  consequence_group STRING,
  count_level STRING,  -- 'scv' or 'variant'
  flag_source_combo STRING,
  item_count INT64,
  first_item_ids STRING,  -- Up to the first 5 SCV accessions or variation ids, in order
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

  DELETE FROM `clinvar_ingest.manuscript_flag_source_combo_by_consequence`
  WHERE release_date = rec.release_date;

  -- One row per pathogenicity SCV with its consequence group and flag sources
  EXECUTE IMMEDIATE FORMAT("""
    CREATE TEMP TABLE path_scvs AS
    WITH
    -- Consequence group mappings, in order of severity
    consequence_terms AS (
      SELECT term, consequence_group, severity
      FROM UNNEST([
        STRUCT('nonsense' AS term, 'predicted LOF' AS consequence_group, 1 AS severity),
        ('frameshift variant', 'predicted LOF', 1),
        ('splice donor variant', 'predicted LOF', 1),
        ('splice acceptor variant', 'predicted LOF', 1),
        ('missense variant', 'missense', 2),
        ('inframe insertion', 'inframe indels', 3),
        ('inframe_insertion', 'inframe indels', 3),
        ('inframe deletion', 'inframe indels', 3),
        ('inframe_deletion', 'inframe indels', 3),
        ('inframe indel', 'inframe indels', 3),
        ('inframe_indel', 'inframe indels', 3),
        ('5 prime utr variant', 'UTR/intronic', 4),
        ('3 prime utr variant', 'UTR/intronic', 4),
        ('intron variant', 'UTR/intronic', 4)
      ])
    ),

    -- For multi-consequence labels (comma-separated), use the first consequence only
    mane_consequences AS (
      SELECT
        vh.variation_id,
        TRIM(SPLIT(IFNULL(vh.consq_label, ''), ',')[SAFE_OFFSET(0)]) AS first_consq
      FROM `%s.variation_hgvs` vh
      WHERE vh.mane_select = TRUE
    ),

    -- One consequence per variant: the most severe of its MANE Select rows
    variant_consequences AS (
      SELECT
        mc.variation_id,
        mc.first_consq,
        IFNULL(ct.consequence_group, 'other') AS consequence_group
      FROM mane_consequences mc
      LEFT JOIN consequence_terms ct
        ON ct.term = LOWER(mc.first_consq)
      QUALIFY ROW_NUMBER() OVER (
        PARTITION BY mc.variation_id
        ORDER BY IFNULL(ct.severity, 5), mc.first_consq = '', mc.first_consq
      ) = 1
    ),

    -- SCVs the CvC project had submitted as flagging candidates by this release
    -- (without the left-out annotations in manuscript_excluded_annotations)
    cvc_flagging_scvs AS (
      SELECT DISTINCT sa.scv_id
      FROM `clinvar_curator.cvc_submitted_annotations_view` sa
      LEFT JOIN `clinvar_ingest.manuscript_excluded_annotations` xa
        ON xa.annotation_id = sa.annotation_id
      WHERE sa.action = 'flagging candidate'
        AND sa.submission_date <= DATE'%t'
        AND xa.annotation_id IS NULL
    ),

    -- SCVs with a left-out CvC flagging candidate submission by this release
    cvc_excluded_scvs AS (
      SELECT DISTINCT sa.scv_id
      FROM `clinvar_curator.cvc_submitted_annotations_view` sa
      JOIN `clinvar_ingest.manuscript_excluded_annotations` xa
        ON xa.annotation_id = sa.annotation_id
      WHERE sa.action = 'flagging candidate'
        AND sa.submission_date <= DATE'%t'
    ),

    scvs AS (
      SELECT
        scv.id AS scv_id,
        scv.variation_id,
        vi.variation_type,
        IFNULL(vc.first_consq, '') AS first_consq,
        IFNULL(vc.consequence_group, 'other') AS consequence_group,
        IFNULL(scv.rank = -3, FALSE) AS is_flagged,
        EXISTS (
          SELECT 1 FROM UNNEST(scv.comments) AS c
          WHERE c.type = 'FlaggedComment' AND c.source = 'NCBI'
        ) AS has_ncbi_comment,
        EXISTS (
          SELECT 1 FROM UNNEST(scv.comments) AS c
          WHERE c.type = 'FlaggedComment' AND c.source = 'ClinGen'
        ) AS has_clingen_comment,
        (cvc.scv_id IS NOT NULL) AS cvc_submitted,
        (excluded.scv_id IS NOT NULL AND cvc.scv_id IS NULL) AS cvc_excluded_only
      FROM `%s.scv_summary` scv
      JOIN `%s.variation_identity` vi
        ON vi.variation_id = scv.variation_id
      LEFT JOIN variant_consequences vc
        ON vc.variation_id = scv.variation_id
      LEFT JOIN cvc_flagging_scvs cvc
        ON cvc.scv_id = scv.id
      LEFT JOIN cvc_excluded_scvs excluded
        ON excluded.scv_id = scv.id
      WHERE scv.proposition_type = 'path'
    )

    SELECT
      scv_id,
      variation_id,
      variation_type,
      first_consq,
      consequence_group,
      is_flagged,
      is_flagged AND has_clingen_comment AND cvc_submitted AS is_cvc,
      is_flagged AND has_ncbi_comment AS is_ncbi,
      is_flagged AND has_clingen_comment AND NOT cvc_submitted AND NOT cvc_excluded_only AS is_clingen_non_cvc
    FROM scvs
  """,
  rec.schema_name,
  rec.release_date,
  rec.release_date,
  rec.schema_name,
  rec.schema_name
  );

  -- Populate the per-source counts
  EXECUTE IMMEDIATE FORMAT("""
    INSERT INTO `clinvar_ingest.manuscript_flagged_scv_by_consequence` (
      release_date,
      variation_type,
      consequence_group,
      all_variant_count,
      flagged_variant_count,
      all_scv_count,
      flagged_scv_count,
      consq_labels,
      cvc_flagged_variant_count,
      ncbi_flagged_variant_count,
      clingen_non_cvc_flagged_variant_count,
      cvc_flagged_scv_count,
      ncbi_flagged_scv_count,
      clingen_non_cvc_flagged_scv_count
    )
    WITH
    -- Count variants per first consequence label for audit trail
    label_counts AS (
      SELECT
        variation_type,
        consequence_group,
        IFNULL(NULLIF(first_consq, ''), '<no mane_select>') AS consq_label_display,
        COUNT(DISTINCT variation_id) AS label_variant_count
      FROM path_scvs
      GROUP BY variation_type, consequence_group, consq_label_display
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
      ps.variation_type,
      ps.consequence_group,
      COUNT(DISTINCT ps.variation_id) AS all_variant_count,
      COUNT(DISTINCT IF(ps.is_flagged, ps.variation_id, NULL)) AS flagged_variant_count,
      COUNT(DISTINCT ps.scv_id) AS all_scv_count,
      COUNT(DISTINCT IF(ps.is_flagged, ps.scv_id, NULL)) AS flagged_scv_count,
      ls.consq_labels,
      COUNT(DISTINCT IF(ps.is_cvc, ps.variation_id, NULL)) AS cvc_flagged_variant_count,
      COUNT(DISTINCT IF(ps.is_ncbi, ps.variation_id, NULL)) AS ncbi_flagged_variant_count,
      COUNT(DISTINCT IF(ps.is_clingen_non_cvc, ps.variation_id, NULL)) AS clingen_non_cvc_flagged_variant_count,
      COUNT(DISTINCT IF(ps.is_cvc, ps.scv_id, NULL)) AS cvc_flagged_scv_count,
      COUNT(DISTINCT IF(ps.is_ncbi, ps.scv_id, NULL)) AS ncbi_flagged_scv_count,
      COUNT(DISTINCT IF(ps.is_clingen_non_cvc, ps.scv_id, NULL)) AS clingen_non_cvc_flagged_scv_count
    FROM path_scvs ps
    JOIN label_strings ls
      ON ls.variation_type = ps.variation_type
      AND ls.consequence_group = ps.consequence_group
    GROUP BY
      ps.variation_type,
      ps.consequence_group,
      ls.consq_labels
  """,
  rec.release_date
  );

  -- Populate the exact source combinations, per SCV and per variant
  EXECUTE IMMEDIATE FORMAT("""
    INSERT INTO `clinvar_ingest.manuscript_flag_source_combo_by_consequence` (
      release_date,
      variation_type,
      consequence_group,
      count_level,
      flag_source_combo,
      item_count,
      first_item_ids
    )
    WITH
    flagged_items AS (
      SELECT
        'scv' AS count_level,
        variation_type,
        consequence_group,
        scv_id AS item_id,
        is_cvc,
        is_ncbi,
        is_clingen_non_cvc
      FROM path_scvs
      WHERE is_flagged

      UNION ALL

      SELECT
        'variant' AS count_level,
        variation_type,
        consequence_group,
        CAST(variation_id AS STRING) AS item_id,
        LOGICAL_OR(is_cvc),
        LOGICAL_OR(is_ncbi),
        LOGICAL_OR(is_clingen_non_cvc)
      FROM path_scvs
      WHERE is_flagged
      GROUP BY variation_type, consequence_group, variation_id
    )

    SELECT
      DATE'%t' AS release_date,
      variation_type,
      consequence_group,
      count_level,
      IFNULL(
        NULLIF(
          ARRAY_TO_STRING([
            IF(is_cvc, 'ClinGen CvC', NULL),
            IF(is_clingen_non_cvc, 'ClinGen non-CvC', NULL),
            IF(is_ncbi, 'NCBI', NULL)
          ], ' + '),
          ''
        ),
        'unattributed'
      ) AS flag_source_combo,
      COUNT(*) AS item_count,
      -- Variation ids sort numerically; SCV accessions do not cast, so they sort as text
      ARRAY_TO_STRING(
        ARRAY_AGG(item_id ORDER BY SAFE_CAST(item_id AS INT64), item_id LIMIT 5),
        ', '
      ) AS first_item_ids
    FROM flagged_items
    GROUP BY variation_type, consequence_group, count_level, flag_source_combo
  """,
  rec.release_date
  );

  DROP TABLE path_scvs;

END;

-- ============================================================================
-- Views for Google Sheets Data Connector
-- Each shows the latest release data
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
  consq_labels,
  cvc_flagged_variant_count,
  ncbi_flagged_variant_count,
  clingen_non_cvc_flagged_variant_count,
  cvc_flagged_scv_count,
  ncbi_flagged_scv_count,
  clingen_non_cvc_flagged_scv_count
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

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_flag_source_combo_by_consequence_view`
AS
SELECT
  release_date,
  variation_type,
  consequence_group,
  count_level,
  flag_source_combo,
  item_count,
  first_item_ids
FROM `clinvar_ingest.manuscript_flag_source_combo_by_consequence`
WHERE release_date = (SELECT MAX(release_date) FROM `clinvar_ingest.manuscript_flag_source_combo_by_consequence`)
ORDER BY
  count_level,
  flag_source_combo,
  variation_type,
  CASE consequence_group
    WHEN 'predicted LOF' THEN 1
    WHEN 'missense' THEN 2
    WHEN 'inframe indels' THEN 3
    WHEN 'UTR/intronic' THEN 4
    ELSE 5
  END;

-- Figure 3 bar chart: consequence distribution of all ClinVar variants vs CvC
-- flagged variants. NCBI and ClinGen non-CvC flags are excluded from the CvC bars.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_cvc_vs_clinvar_consequence_bar_view`
AS
SELECT
  release_date,
  consequence_group,
  SUM(all_variant_count) AS all_variant_count,
  SUM(cvc_flagged_variant_count) AS cvc_flagged_variant_count,
  ROUND(SAFE_DIVIDE(SUM(all_variant_count), SUM(SUM(all_variant_count)) OVER ()) * 100, 2) AS all_variant_pct,
  ROUND(SAFE_DIVIDE(SUM(cvc_flagged_variant_count), SUM(SUM(cvc_flagged_variant_count)) OVER ()) * 100, 2) AS cvc_flagged_variant_pct
FROM `clinvar_ingest.manuscript_flagged_scv_by_consequence_view`
GROUP BY release_date, consequence_group
ORDER BY
  CASE consequence_group
    WHEN 'predicted LOF' THEN 1
    WHEN 'missense' THEN 2
    WHEN 'inframe indels' THEN 3
    WHEN 'UTR/intronic' THEN 4
    ELSE 5
  END;
