-- ============================================================================
-- Script: 01-clinvar-landscape.sql
--
-- Description:
--   Produces a per-gene summary of the ClinVar Germline Variant Pathogenicity
--   Classification landscape for genes in the GenCC Definitive/Strong/Moderate
--   (DSM) gene list. For each gene, returns total SCVs, total variants,
--   clinically significant (P/LP) SCV and variant counts, and a breakdown of
--   variant-level aggregate classification into concordant and conflict
--   categories.
--
-- Scope:
--   Germline Variant Pathogenicity Classification Submission Data subset
--   (proposition_type = 'path' only). This excludes Somatic SCVs and
--   other Germline SCVs that are not pathogenicity classifications.
--
--   Only single-gene variants are included (via clinvar_single_gene_variations)
--   to avoid inflating counts from multi-gene variants (e.g., large deletions).
--
-- Gene Filter:
--   clinvar_ingest.gencc_dsm_genes - Genes with Definitive, Strong, or
--   Moderate disease-gene validity classifications from GenCC.
--   Joined via: gencc_dsm_genes.hgnc_id -> clinvar_genes.hgnc_id ->
--   clinvar_genes.id = clinvar_single_gene_variations.gene_id
--
-- agg_sig_type values (from clinvar_sum_vsp_rank_group):
--   4 = clinsig only (concordant P/LP, no conflict)
--   5 = non-clinsig + clinsig (P/LP vs B/LB conflict)
--   6 = uncertain + clinsig (P/LP vs VUS conflict)
--   7 = all three tiers (P/LP vs VUS + B/LB conflict)
--
-- Output Columns:
--   gene_symbol                  - Gene symbol
--   gene_id                      - NCBI Gene ID
--   total_scvs                   - All path SCVs for this gene
--   clinsig_scv_count            - P/LP SCVs only
--   total_variants               - All distinct path variants
--   total_clinsig_variants       - Variants with at least one P/LP SCV
--   concordant_clinsig_variants  - agg_sig_type = 4 (P/LP, no conflict)
--   plp_vs_blb_variants          - agg_sig_type = 5 (P/LP vs B/LB)
--   plp_vs_vus_variants          - agg_sig_type = 6 (P/LP vs VUS)
--   plp_vs_vus_blb_variants      - agg_sig_type = 7 (P/LP vs VUS + B/LB)
--   total_clinsig_conflict_variants - agg_sig_type >= 5 (all conflict types)
--   clinsig_conflict_pct         - total_clinsig_conflict_variants / total_variants * 100
--   release_date                 - ClinVar release date used for this snapshot
--
-- Output View:
--   clinvar_ingest.manuscript_clinvar_landscape
-- ============================================================================

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_clinvar_landscape` AS

WITH latest_release AS (
  SELECT MAX(release_date) AS release_date
  FROM `clinvar_ingest.all_schemas`()
),

-- Single-gene path variants for GenCC DSM genes
-- Join path: gencc_dsm_genes.hgnc_id -> clinvar_genes.hgnc_id -> clinvar_genes.id = sgv.gene_id
dsm_variants AS (
  SELECT
    dsm.symbol AS gene_symbol,
    cg.id AS gene_id,
    sgv.variation_id,
    lr.release_date
  FROM latest_release lr
  JOIN `clinvar_ingest.gencc_dsm_genes` dsm
    ON TRUE
  JOIN `clinvar_ingest.clinvar_genes` cg
    ON cg.hgnc_id = dsm.hgnc_id
    AND lr.release_date BETWEEN cg.start_release_date AND cg.end_release_date
  JOIN `clinvar_ingest.clinvar_single_gene_variations` sgv
    ON sgv.gene_id = cg.id
    AND lr.release_date BETWEEN sgv.start_release_date AND sgv.end_release_date
),

-- SCV-level counts per gene
scv_counts AS (
  SELECT
    dv.gene_symbol,
    dv.gene_id,
    COUNT(DISTINCT scv.id) AS total_scvs,
    COUNT(DISTINCT CASE WHEN scv.clinsig_type = 2 THEN scv.id END) AS clinsig_scv_count,
    COUNT(DISTINCT scv.variation_id) AS total_variants,
    -- Variants with at least one P/LP SCV
    COUNT(DISTINCT CASE WHEN scv.clinsig_type = 2 THEN scv.variation_id END) AS total_clinsig_variants,
    dv.release_date
  FROM dsm_variants dv
  JOIN `clinvar_ingest.clinvar_scvs` scv
    ON scv.variation_id = dv.variation_id
    AND scv.proposition_type = 'path'
    AND dv.release_date BETWEEN scv.start_release_date AND scv.end_release_date
  GROUP BY dv.gene_symbol, dv.gene_id, dv.release_date
),

-- Variant-level aggregate classification (at determining rank per variant)
variant_agg AS (
  SELECT
    dv.gene_symbol,
    dv.gene_id,
    dv.variation_id,
    vrg.agg_sig_type
  FROM dsm_variants dv
  JOIN `clinvar_ingest.clinvar_sum_vsp_rank_group` vrg
    ON vrg.variation_id = dv.variation_id
    AND vrg.proposition_type = 'path'
    AND dv.release_date BETWEEN vrg.start_release_date AND vrg.end_release_date
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY dv.variation_id
    ORDER BY vrg.rank DESC, vrg.agg_sig_type DESC
  ) = 1
),

-- Aggregate variant-level classification counts per gene
variant_counts AS (
  SELECT
    gene_symbol,
    gene_id,
    COUNTIF(agg_sig_type = 4) AS concordant_clinsig_variants,
    COUNTIF(agg_sig_type = 5) AS plp_vs_blb_variants,
    COUNTIF(agg_sig_type = 6) AS plp_vs_vus_variants,
    COUNTIF(agg_sig_type = 7) AS plp_vs_vus_blb_variants,
    COUNTIF(agg_sig_type >= 5) AS total_clinsig_conflict_variants
  FROM variant_agg
  GROUP BY gene_symbol, gene_id
)

SELECT
  sc.gene_symbol,
  sc.gene_id,
  sc.total_scvs,
  sc.clinsig_scv_count,
  sc.total_variants,
  sc.total_clinsig_variants,
  COALESCE(vc.concordant_clinsig_variants, 0) AS concordant_clinsig_variants,
  COALESCE(vc.plp_vs_blb_variants, 0) AS plp_vs_blb_variants,
  COALESCE(vc.plp_vs_vus_variants, 0) AS plp_vs_vus_variants,
  COALESCE(vc.plp_vs_vus_blb_variants, 0) AS plp_vs_vus_blb_variants,
  COALESCE(vc.total_clinsig_conflict_variants, 0) AS total_clinsig_conflict_variants,
  ROUND(SAFE_DIVIDE(vc.total_clinsig_conflict_variants, sc.total_variants) * 100, 2) AS clinsig_conflict_pct,
  sc.release_date
FROM scv_counts sc
LEFT JOIN variant_counts vc
  USING (gene_symbol, gene_id)
WHERE sc.clinsig_scv_count >= 1
ORDER BY sc.clinsig_scv_count DESC
