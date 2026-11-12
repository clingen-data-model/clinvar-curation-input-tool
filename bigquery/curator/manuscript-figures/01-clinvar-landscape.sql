-- ============================================================================
-- Script: 01-clinvar-landscape.sql
--
-- Description:
--   The state of ClinVar's pathogenicity-classified variants in one release, the
--   input to Figure 1:
--     Figure 1A - share of variants by the state of their top ranked group, and
--                 the medically significant conflicts by type
--     Figure 1B - per gene, % of variants in medically significant conflict
--                 against the number of pathogenicity SCVs, for genes in the
--                 GenCC Definitive/Strong/Moderate (DSM) gene list
--
--   Running this script creates table functions and the views behind the Figure 1
--   sheet. It reads ClinVar data and changes none of it.
--     bq query --use_legacy_sql=false < 01-clinvar-landscape.sql
--   generate_figure1.py then calls the table functions and draws both panels.
--
-- Table functions (NULL means the latest loaded release):
--   clinvar_ingest.manuscript_figure1_variant_states_core(release DATE, left_out ARRAY<STRING>)
--   clinvar_ingest.manuscript_figure1_variant_states(release DATE)
--   clinvar_ingest.manuscript_figure1a_final_classifications(release DATE)
--   clinvar_ingest.manuscript_figure1b_gene_rates(release DATE)
--   clinvar_ingest.manuscript_figure1_callouts(release DATE)
--   clinvar_ingest.manuscript_figure1_retracted_flag_scvs(release DATE)
--
-- Views, pinned to the figure's release because a view cannot take a parameter.
-- To move the figure to a new release, change the DATE literal in the four
-- pinned views below and rerun this script (run 00-excluded-scvs.sql first):
--   clinvar_ingest.manuscript_figure1_variant_states_view (pinned)
--   clinvar_ingest.manuscript_clinvar_landscape (pinned)
--   clinvar_ingest.manuscript_figure1_callouts_view (pinned)
--   clinvar_ingest.manuscript_figure1_retracted_flag_scvs_view (pinned)
--   clinvar_ingest.manuscript_figure1a_states_view
--   clinvar_ingest.manuscript_figure1a_conflict_types_view
--   clinvar_ingest.manuscript_figure1a_final_classifications_view
--   clinvar_ingest.manuscript_figure1_all_flagged_variants_view
--
-- Scope:
--   Germline pathogenicity SCVs only (proposition_type = 'path'), which excludes
--   somatic SCVs and other germline SCVs such as drug response.
--
-- Method:
--   ClinVar builds the aggregate from the highest ranked group of SCVs, so each
--   variant's state is read from its top ranked group. Flagged SCVs (rank -3) do
--   not contribute. A variant whose SCVs are all flagged has no aggregate, so it
--   is left out and listed in manuscript_figure1_all_flagged_variants_view. Ranks
--   in path SCVs are 4 (practice guideline), 3 (expert panel), 1 (criteria
--   provided) and 0 (no criteria).
--
-- Variant state, from the top ranked group:
--   1 submission                   One SCV in the group
--   >=2 concordant submissions     Two or more SCVs, one classification group
--   Confidence conflict            P + LP, or B + LB, and no other tier
--   VUS vs B/LB                    VUS with B, LB or both
--   P/LP vs VUS/B/LB               P or LP with VUS, B, LB or any of them
--   A slash means either or both of its labels. A plus means both together.
--
-- State mask (same encoding as clinvar_sum_vsp_rank_group.agg_sig_type):
--   B/LB = 1, VUS = 2, P/LP = 4, summed over the distinct tiers in the group.
--   Tier comes from clinsig_type.
--
-- Classification groups, for the labels within a tier:
--   P = p, p-lp (pathogenic, low penetrance), era (established risk allele)
--   LP = lp, lp-lp (likely pathogenic, low penetrance), lra (likely risk allele)
--   VUS = vus, vus-h, vus-m, vus-l, ura (uncertain risk allele)
--   LB = lb. B = b.
--   p/lp and b/lb are single SCVs submitted as both labels, so they count as both.
--
-- SCVs whose flag CvC later retracted (clinvar_ingest.manuscript_excluded_scvs):
--   Figure 1 counts ClinVar submissions, not CvC work, and reads no CvC
--   annotations, reviews or submissions. Those 321 SCVs (233 "Discordance project
--   retraction", 88 "Retracted gene-disease relationship flag") are live ClinVar
--   submissions again once the flag is removed, so they stay in Figure 1 as part
--   of ClinVar, as in the All ClinVar baseline of Figure 3C. The user chose this
--   on 2026-11-12. manuscript_figure1_retracted_flag_scvs lists each one with its
--   variant's state as counted, and its state with all 321 left out, so analysts
--   can assess the effect. It is the only Figure 1 object that reads CvC data.
--
-- Gene filter (Figure 1B only):
--   Single-gene variants only, via clinvar_single_gene_variations, to avoid
--   inflating counts from multi-gene variants such as large deletions.
--   gencc_dsm_genes.hgnc_id -> clinvar_genes.hgnc_id ->
--   clinvar_genes.id = clinvar_single_gene_variations.gene_id
--   Genes with no contributing P/LP SCV are left out.
--
-- Output Columns, manuscript_figure1_variant_states:
--   release_date, variation_id
--   top_rank                 - Rank of the top ranked group
--   top_group_scvs           - Contributing SCVs in that group
--   contributing_scvs        - Contributing SCVs in all groups
--   flagged_scvs             - Flagged SCVs, which do not contribute
--   top_mask, all_scvs_mask  - State mask of the top group, and of all groups
--   variant_state            - State shown in Figure 1A
--   conflict_type            - Type shown in the Figure 1A inset, or NULL
--   classification_to_start  - Exact labels in the top group, e.g. P + LP vs VUS
--   classif_types            - Original codes in the top group, e.g. lp, p, vus
--
-- Output Columns, manuscript_clinvar_landscape (Figure 1B):
--   gene_symbol, gene_id
--   total_scvs               - Contributing path SCVs for this gene
--   flagged_scvs             - Flagged path SCVs for this gene, not in total_scvs
--   clinsig_scv_count        - Contributing P/LP SCVs
--   total_variants           - Variants with a contributing path SCV
--   total_clinsig_variants   - Variants with a contributing P/LP SCV
--   concordant_clinsig_variants - Top group mask 4 (P/LP only)
--   plp_vs_blb_variants      - Top group mask 5
--   plp_vs_vus_variants      - Top group mask 6
--   plp_vs_vus_blb_variants  - Top group mask 7
--   total_clinsig_conflict_variants - Top group mask 5, 6 or 7, the medically
--                              significant conflicts
--   clinsig_conflict_pct     - total_clinsig_conflict_variants / total_variants * 100
--   release_date
-- ============================================================================

-- left_out lists SCV accessions to drop before reading each variant's state. The
-- figure passes an empty list; manuscript_figure1_retracted_flag_scvs passes the
-- retracted-flag SCVs to measure what they change.
CREATE OR REPLACE TABLE FUNCTION `clinvar_ingest.manuscript_figure1_variant_states_core`(release DATE, left_out ARRAY<STRING>) AS (

WITH cutoff AS (
  SELECT COALESCE(release, MAX(release_date)) AS release_date
  FROM `clinvar_ingest.all_schemas`()
),

scvs AS (
  SELECT
    cutoff.release_date,
    s.variation_id,
    s.id AS scv_id,
    s.rank,
    s.rank = -3 AS is_flagged,
    s.classif_type,
    CASE s.clinsig_type WHEN 2 THEN 4 WHEN 1 THEN 2 WHEN 0 THEN 1 END AS tier_bit,
    s.classif_type IN ('p', 'p-lp', 'era', 'p/lp') AS is_p,
    s.classif_type IN ('lp', 'lp-lp', 'lra', 'p/lp') AS is_lp,
    s.classif_type IN ('vus', 'vus-h', 'vus-m', 'vus-l', 'ura') AS is_vus,
    s.classif_type IN ('lb', 'b/lb') AS is_lb,
    s.classif_type IN ('b', 'b/lb') AS is_b
  FROM cutoff
  JOIN `clinvar_ingest.clinvar_scvs` s
    ON s.proposition_type = 'path'
    AND cutoff.release_date BETWEEN s.start_release_date AND s.end_release_date
  WHERE s.id NOT IN UNNEST(left_out)
),

-- One row per variant, over every contributing SCV.
variants AS (
  SELECT
    release_date,
    variation_id,
    MAX(IF(is_flagged, NULL, rank)) AS top_rank,
    COUNT(DISTINCT IF(is_flagged, NULL, scv_id)) AS contributing_scvs,
    COUNT(DISTINCT IF(is_flagged, scv_id, NULL)) AS flagged_scvs,
    BIT_OR(IF(is_flagged, 0, tier_bit)) AS all_scvs_mask
  FROM scvs
  GROUP BY release_date, variation_id
  HAVING contributing_scvs > 0
),

top_group AS (
  SELECT
    v.release_date,
    v.variation_id,
    v.top_rank,
    v.contributing_scvs,
    v.flagged_scvs,
    v.all_scvs_mask,
    COUNT(DISTINCT s.scv_id) AS top_group_scvs,
    BIT_OR(s.tier_bit) AS top_mask,
    LOGICAL_OR(s.is_p) AS has_p,
    LOGICAL_OR(s.is_lp) AS has_lp,
    LOGICAL_OR(s.is_vus) AS has_vus,
    LOGICAL_OR(s.is_lb) AS has_lb,
    LOGICAL_OR(s.is_b) AS has_b,
    STRING_AGG(DISTINCT s.classif_type, ', ' ORDER BY s.classif_type) AS classif_types
  FROM variants v
  JOIN scvs s
    ON s.variation_id = v.variation_id
    AND s.rank = v.top_rank
    AND NOT s.is_flagged
  GROUP BY
    v.release_date, v.variation_id, v.top_rank, v.contributing_scvs, v.flagged_scvs, v.all_scvs_mask
)

SELECT
  release_date,
  variation_id,
  top_rank,
  top_group_scvs,
  contributing_scvs,
  flagged_scvs,
  top_mask,
  all_scvs_mask,
  CASE
    WHEN top_group_scvs = 1 THEN '1 submission'
    WHEN top_mask IN (5, 6, 7) THEN 'P/LP vs VUS/B/LB'
    WHEN top_mask = 3 THEN 'VUS vs B/LB'
    WHEN (has_p AND has_lp) OR (has_b AND has_lb) THEN 'Confidence conflict'
    ELSE '>=2 concordant submissions'
  END AS variant_state,
  -- P vs LP is kept apart except in three-tier conflicts, as in Figure 4B.
  CASE top_mask
    WHEN 7 THEN 'P/LP vs VUS vs B/LB'
    WHEN 6 THEN IF(has_p AND has_lp, 'P + LP vs VUS', IF(has_p, 'P vs VUS', 'LP vs VUS'))
    WHEN 5 THEN IF(has_p AND has_lp, 'P + LP vs B/LB', IF(has_p, 'P vs B/LB', 'LP vs B/LB'))
  END AS conflict_type,
  IF(top_mask IN (3, 5, 6, 7),
    CONCAT(
      IF(top_mask = 3, 'VUS', ARRAY_TO_STRING([IF(has_p, 'P', NULL), IF(has_lp, 'LP', NULL)], ' + ')),
      ' vs ',
      ARRAY_TO_STRING([
        IF(has_vus AND top_mask != 3, 'VUS', NULL),
        IF(has_lb, 'LB', NULL),
        IF(has_b, 'B', NULL)
      ], ' + ')
    ),
    ARRAY_TO_STRING([
      IF(has_p, 'P', NULL), IF(has_lp, 'LP', NULL), IF(has_vus, 'VUS', NULL),
      IF(has_lb, 'LB', NULL), IF(has_b, 'B', NULL)
    ], ' + ')
  ) AS classification_to_start,
  classif_types
FROM top_group
);

-- The figure's variant states: every path SCV in the release, nothing left out.
CREATE OR REPLACE TABLE FUNCTION `clinvar_ingest.manuscript_figure1_variant_states`(release DATE) AS (
  SELECT * FROM `clinvar_ingest.manuscript_figure1_variant_states_core`(release, CAST([] AS ARRAY<STRING>))
);

-- Figure 1A at its most granular: one row per variant state, exact starting labels
-- and top rank, so the rows can be collated into any grouping.
CREATE OR REPLACE TABLE FUNCTION `clinvar_ingest.manuscript_figure1a_final_classifications`(release DATE) AS (
  SELECT
    release_date,
    variant_state,
    conflict_type,
    classification_to_start,
    top_rank,
    COUNT(*) AS variants,
    SUM(top_group_scvs) AS top_group_scvs,
    SUM(contributing_scvs) AS contributing_scvs,
    SUM(flagged_scvs) AS flagged_scvs
  FROM `clinvar_ingest.manuscript_figure1_variant_states`(release)
  GROUP BY release_date, variant_state, conflict_type, classification_to_start, top_rank
);

CREATE OR REPLACE TABLE FUNCTION `clinvar_ingest.manuscript_figure1b_gene_rates`(release DATE) AS (

WITH cutoff AS (
  SELECT COALESCE(release, MAX(release_date)) AS release_date
  FROM `clinvar_ingest.all_schemas`()
),

dsm_variants AS (
  SELECT
    dsm.symbol AS gene_symbol,
    cg.id AS gene_id,
    sgv.variation_id,
    cutoff.release_date
  FROM cutoff
  JOIN `clinvar_ingest.gencc_dsm_genes` dsm
    ON TRUE
  JOIN `clinvar_ingest.clinvar_genes` cg
    ON cg.hgnc_id = dsm.hgnc_id
    AND cutoff.release_date BETWEEN cg.start_release_date AND cg.end_release_date
  JOIN `clinvar_ingest.clinvar_single_gene_variations` sgv
    ON sgv.gene_id = cg.id
    AND cutoff.release_date BETWEEN sgv.start_release_date AND sgv.end_release_date
),

scv_counts AS (
  SELECT
    dv.gene_symbol,
    dv.gene_id,
    dv.release_date,
    COUNT(DISTINCT IF(s.rank != -3, s.id, NULL)) AS total_scvs,
    COUNT(DISTINCT IF(s.rank = -3, s.id, NULL)) AS flagged_scvs,
    COUNT(DISTINCT IF(s.rank != -3 AND s.clinsig_type = 2, s.id, NULL)) AS clinsig_scv_count,
    COUNT(DISTINCT IF(s.rank != -3, s.variation_id, NULL)) AS total_variants,
    COUNT(DISTINCT IF(s.rank != -3 AND s.clinsig_type = 2, s.variation_id, NULL)) AS total_clinsig_variants
  FROM dsm_variants dv
  JOIN `clinvar_ingest.clinvar_scvs` s
    ON s.variation_id = dv.variation_id
    AND s.proposition_type = 'path'
    AND dv.release_date BETWEEN s.start_release_date AND s.end_release_date
  GROUP BY dv.gene_symbol, dv.gene_id, dv.release_date
),

variant_counts AS (
  SELECT
    dv.gene_symbol,
    dv.gene_id,
    COUNTIF(vs.top_mask = 4) AS concordant_clinsig_variants,
    COUNTIF(vs.top_mask = 5) AS plp_vs_blb_variants,
    COUNTIF(vs.top_mask = 6) AS plp_vs_vus_variants,
    COUNTIF(vs.top_mask = 7) AS plp_vs_vus_blb_variants,
    COUNTIF(vs.top_mask >= 5) AS total_clinsig_conflict_variants
  FROM dsm_variants dv
  JOIN `clinvar_ingest.manuscript_figure1_variant_states`(release) vs
    USING (variation_id)
  GROUP BY dv.gene_symbol, dv.gene_id
)

SELECT
  sc.gene_symbol,
  sc.gene_id,
  sc.total_scvs,
  sc.flagged_scvs,
  sc.clinsig_scv_count,
  sc.total_variants,
  sc.total_clinsig_variants,
  COALESCE(vc.concordant_clinsig_variants, 0) AS concordant_clinsig_variants,
  COALESCE(vc.plp_vs_blb_variants, 0) AS plp_vs_blb_variants,
  COALESCE(vc.plp_vs_vus_variants, 0) AS plp_vs_vus_variants,
  COALESCE(vc.plp_vs_vus_blb_variants, 0) AS plp_vs_vus_blb_variants,
  COALESCE(vc.total_clinsig_conflict_variants, 0) AS total_clinsig_conflict_variants,
  ROUND(COALESCE(SAFE_DIVIDE(vc.total_clinsig_conflict_variants, sc.total_variants), 0) * 100, 2) AS clinsig_conflict_pct,
  sc.release_date
FROM scv_counts sc
LEFT JOIN variant_counts vc
  USING (gene_symbol, gene_id)
WHERE sc.clinsig_scv_count >= 1
);

-- The counts quoted as call-outs on the About tab and in the README, so each can
-- be confirmed by a query. Group sizes overlap unless a note says otherwise.
CREATE OR REPLACE TABLE FUNCTION `clinvar_ingest.manuscript_figure1_callouts`(release DATE) AS (

WITH cutoff AS (
  SELECT COALESCE(release, MAX(release_date)) AS release_date
  FROM `clinvar_ingest.all_schemas`()
),

states AS (
  SELECT * FROM `clinvar_ingest.manuscript_figure1_variant_states`(release)
),

all_flagged AS (
  SELECT COUNT(*) AS variants
  FROM (
    SELECT s.variation_id
    FROM cutoff
    JOIN `clinvar_ingest.clinvar_scvs` s
      ON s.proposition_type = 'path'
      AND cutoff.release_date BETWEEN s.start_release_date AND s.end_release_date
    GROUP BY s.variation_id
    HAVING COUNTIF(s.rank != -3) = 0
  )
)

SELECT 1 AS sort_order, 'variants_in_figure' AS callout, COUNT(*) AS variants FROM states
UNION ALL SELECT 2, 'excluded_all_scvs_flagged', variants FROM all_flagged
UNION ALL SELECT 3, 'one_top_scv_with_lower_ranked_scvs', COUNTIF(top_group_scvs = 1 AND contributing_scvs > 1) FROM states
UNION ALL SELECT 4, 'medsig_top_group', COUNTIF(top_mask >= 5) FROM states
UNION ALL SELECT 5, 'medsig_all_scvs', COUNTIF(all_scvs_mask >= 5) FROM states
UNION ALL SELECT 6, 'medsig_all_scvs_not_top_group', COUNTIF(all_scvs_mask >= 5 AND top_mask < 5) FROM states
UNION ALL SELECT 7, 'with_flagged_scvs_still_in_figure', COUNTIF(flagged_scvs > 0) FROM states
UNION ALL SELECT 8, 'medsig_top_group_with_expert_panel', COUNTIF(top_mask >= 5 AND top_rank >= 3) FROM states
UNION ALL SELECT 9, 'p_slash_lp_in_conflict', COUNTIF(top_mask >= 5 AND REGEXP_CONTAINS(classif_types, r'(^|, )p/lp(,|$)')) FROM states
);

-- One row per SCV in manuscript_excluded_scvs: where it sits in this release, the
-- state its variant is counted in, and that variant's state if all 321 SCVs were
-- left out (NULL variant_state_left_out means the variant would leave the figure).
-- in_figure_1b marks variants in a Figure 1B gene.
CREATE OR REPLACE TABLE FUNCTION `clinvar_ingest.manuscript_figure1_retracted_flag_scvs`(release DATE) AS (

WITH cutoff AS (
  SELECT COALESCE(release, MAX(release_date)) AS release_date
  FROM `clinvar_ingest.all_schemas`()
),

excluded AS (
  SELECT * FROM `clinvar_ingest.manuscript_excluded_scvs`
),

scvs AS (
  SELECT s.id AS scv_id, s.rank, s.classif_type
  FROM cutoff
  JOIN `clinvar_ingest.clinvar_scvs` s
    ON s.proposition_type = 'path'
    AND cutoff.release_date BETWEEN s.start_release_date AND s.end_release_date
),

counted AS (
  SELECT * FROM `clinvar_ingest.manuscript_figure1_variant_states`(release)
),

left_out AS (
  SELECT * FROM `clinvar_ingest.manuscript_figure1_variant_states_core`(release, ARRAY(SELECT scv_id FROM `clinvar_ingest.manuscript_excluded_scvs`))
),

figure_1b_variants AS (
  SELECT DISTINCT sgv.variation_id
  FROM cutoff
  JOIN `clinvar_ingest.gencc_dsm_genes` dsm
    ON TRUE
  JOIN `clinvar_ingest.clinvar_genes` cg
    ON cg.hgnc_id = dsm.hgnc_id
    AND cutoff.release_date BETWEEN cg.start_release_date AND cg.end_release_date
  JOIN `clinvar_ingest.clinvar_single_gene_variations` sgv
    ON sgv.gene_id = cg.id
    AND cutoff.release_date BETWEEN sgv.start_release_date AND sgv.end_release_date
  JOIN `clinvar_ingest.manuscript_figure1b_gene_rates`(release) gr
    ON gr.gene_id = cg.id
)

SELECT
  cutoff.release_date,
  x.scv_id,
  x.variation_id,
  x.exclusion,
  s.scv_id IS NOT NULL AS scv_in_release,
  s.rank = -3 AS scv_flagged_in_release,
  s.rank AS scv_rank,
  s.classif_type,
  c.top_rank,
  s.rank = c.top_rank AS scv_in_top_group,
  c.variant_state,
  c.conflict_type,
  l.variant_state AS variant_state_left_out,
  l.conflict_type AS conflict_type_left_out,
  b.variation_id IS NOT NULL AS in_figure_1b,
  x.clinvar_url
FROM excluded x
CROSS JOIN cutoff
LEFT JOIN scvs s
  ON s.scv_id = x.scv_id
LEFT JOIN counted c
  ON c.variation_id = x.variation_id
LEFT JOIN left_out l
  ON l.variation_id = x.variation_id
LEFT JOIN figure_1b_variants b
  ON b.variation_id = x.variation_id
);

-- Pinned views. Change these DATE literals to move the figure to a new release.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure1_variant_states_view` AS
SELECT * FROM `clinvar_ingest.manuscript_figure1_variant_states`(DATE '2026-11-08');

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_clinvar_landscape` AS
SELECT * FROM `clinvar_ingest.manuscript_figure1b_gene_rates`(DATE '2026-11-08')
ORDER BY clinsig_scv_count DESC;

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure1_callouts_view` AS
SELECT * FROM `clinvar_ingest.manuscript_figure1_callouts`(DATE '2026-11-08')
ORDER BY sort_order;

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure1_retracted_flag_scvs_view` AS
SELECT * FROM `clinvar_ingest.manuscript_figure1_retracted_flag_scvs`(DATE '2026-11-08')
ORDER BY exclusion, variation_id, scv_id;

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure1a_states_view` AS
SELECT
  release_date,
  variant_state,
  COUNT(*) AS variants,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS percent_of_variants
FROM `clinvar_ingest.manuscript_figure1_variant_states_view`
GROUP BY release_date, variant_state
ORDER BY variants DESC;

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure1a_conflict_types_view` AS
SELECT
  release_date,
  conflict_type,
  COUNT(*) AS variants,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS percent_of_medically_significant
FROM `clinvar_ingest.manuscript_figure1_variant_states_view`
WHERE conflict_type IS NOT NULL
GROUP BY release_date, conflict_type
ORDER BY variants DESC;

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure1a_final_classifications_view` AS
SELECT
  release_date,
  variant_state,
  conflict_type,
  classification_to_start,
  top_rank,
  COUNT(*) AS variants,
  SUM(top_group_scvs) AS top_group_scvs,
  SUM(contributing_scvs) AS contributing_scvs,
  SUM(flagged_scvs) AS flagged_scvs
FROM `clinvar_ingest.manuscript_figure1_variant_states_view`
GROUP BY release_date, variant_state, conflict_type, classification_to_start, top_rank
ORDER BY variant_state, variants DESC;

-- Variants left out of the figure because every path SCV is flagged.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure1_all_flagged_variants_view` AS
WITH pinned AS (
  SELECT DISTINCT release_date FROM `clinvar_ingest.manuscript_figure1_variant_states_view`
)
SELECT
  pinned.release_date,
  s.variation_id,
  CONCAT('https://www.ncbi.nlm.nih.gov/clinvar/variation/', s.variation_id, '/') AS clinvar_url,
  COUNT(DISTINCT s.id) AS flagged_scvs,
  STRING_AGG(DISTINCT s.classif_type, ', ' ORDER BY s.classif_type) AS classif_types
FROM pinned
JOIN `clinvar_ingest.clinvar_scvs` s
  ON s.proposition_type = 'path'
  AND pinned.release_date BETWEEN s.start_release_date AND s.end_release_date
GROUP BY pinned.release_date, s.variation_id
HAVING COUNTIF(s.rank != -3) = 0
ORDER BY s.variation_id;
