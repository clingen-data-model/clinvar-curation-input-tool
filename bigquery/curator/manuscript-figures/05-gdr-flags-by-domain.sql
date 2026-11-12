-- ============================================================================
-- Script: 05-gdr-flags-by-domain.sql
--
-- Description:
--   One row per SCV that CvC submitted as a flagging candidate with the reason
--   "P/LP classification for a variant in a gene with insufficient evidence for
--   a gene-disease relationship". This is the only input to Figure 5, which
--   shows the flags in ClinVar on one release by clinical domain and gene-disease
--   validity level.
--
--   Running this script creates the objects below. It reads ClinVar and CvC data
--   and changes neither. Deploy 00-excluded-scvs.sql first, because the table
--   function reads clinvar_ingest.manuscript_excluded_annotations.
--     bq query --use_legacy_sql=false < 05-gdr-flags-by-domain.sql
--   On the first deploy, or to load a newer export of the ClinGen tab, also run:
--     CALL `clinvar_ingest.refresh_manuscript_clingen_gene_validity`();
--   generate_figure5.py then calls the table function and draws the figure.
--
-- Table:
--   clinvar_ingest.manuscript_clingen_gene_validity
--   Copy of the ClinGen gene-disease validity export pasted into the
--   'Copy of Table 1' tab of the older manuscript figures sheet. The tab has no
--   export date. Its latest evaluation date is 2026-02-05.
--
-- Table function:
--   clinvar_ingest.manuscript_figure5_flags(as_of_date DATE)
--   Includes batches with batch_release_date <= as_of_date. NULL means all
--   batches.
--
-- Views (all batches, because a view cannot take a parameter):
--   clinvar_ingest.manuscript_figure5_panel_domain_view
--   clinvar_ingest.manuscript_figure5_flags_view
--   clinvar_ingest.manuscript_figure5_domain_level_view
--   clinvar_ingest.manuscript_figure5_gene_view
--   clinvar_ingest.manuscript_figure5_callouts_view
--
-- Method:
--   Flags come from CvC's own submissions, on path SCVs, matched on accession.
--   Every read of CvC submissions, for flags and for retractions, goes through
--   the submissions CTE, which:
--     - leaves out every annotation in clinvar_ingest.manuscript_excluded_annotations:
--       the discordance project's flags and removals on 233 SCVs, matched on
--       annotation_id. Other CvC annotations on those SCVs still count.
--     - ignores reviews with status Archive, which were corrected before
--       submission.
--     - keeps only each batch's latest annotation of the SCV (is_latest).
--
--   figure_level is the level the curator recorded in the note, since that was
--   the reason for the flag. ClinGen fills in a flag whose note has no level, when
--   the gene has low-evidence relationships at one level only. Otherwise it is
--   'Not recorded'.
--
--   clinical_domain comes from the expert panel of one of the gene's ClinGen
--   relationships, taken from the first of these that exists: relationships at
--   figure_level, other low-evidence relationships, any relationship. Within that
--   set, the most recently evaluated relationship wins. domain_source says which
--   applied, and all_domains lists every domain the gene has in that set.
--
--   A flag is 'retracted' when CvC submitted a remove flagged submission for that
--   SCV in a later batch by as_of_date. The discordance project's removals are
--   left out above, so this covers the other retractions, such as those made
--   because the gene-disease classification changed. Otherwise it is 'standing', meaning CvC has
--   not withdrawn it. clinvar_state says what ClinVar shows for the SCV on the
--   as_of release. The figure counts shown_in_figure: standing and flagged there.
--
-- Output Columns:
--   as_of_batch_release_date, variation_id, scv_id, scv_ver, gene_symbol, hgnc_id
--   batch_id, batch_release_date, annotated_date, notes
--   note_level           - Level parsed from the curator note, or NULL
--   clingen_low_levels   - The gene's low-evidence levels in the ClinGen export
--   figure_level         - Limited, Disputed, Refuted, No Known or Not recorded
--   level_source         - curator note, ClinGen, or none
--   note_level_in_clingen - The gene has a ClinGen relationship at note_level
--   clinical_domain      - Clinical domain working group, or Not in ClinGen export
--   domain_source        - matching level, other low-evidence, any relationship, none
--   domain_expert_panel  - Expert panel that gave clinical_domain
--   all_domains          - All domains in the set that domain_source names
--   gene_has_moderate_or_higher - The gene has a Moderate, Strong or Definitive
--                          relationship in the ClinGen export
--   flag_status          - standing or retracted
--   retraction_kind      - Classification changed, Other, or NULL. The
--                          discordance project's removals are left out above.
--   flagged_in_clinvar   - The SCV is a flagged submission on the as_of release
--   clinvar_state        - flagged, newer SCV version, not in release, or not
--                          flagged, same version
--   shown_in_figure      - Standing and flagged in ClinVar
-- ============================================================================

CREATE TABLE IF NOT EXISTS `clinvar_ingest.manuscript_clingen_gene_validity` (
  gene_symbol STRING,
  hgnc_id STRING,
  disease STRING,
  mondo_id STRING,
  moi STRING,
  expert_panel STRING,
  sop STRING,
  classification STRING,
  last_evaluated DATE
);

-- The export is held in a table so connected sheets don't need access to the
-- older sheet, and so editing that sheet can't change this figure unnoticed.
CREATE OR REPLACE PROCEDURE `clinvar_ingest.refresh_manuscript_clingen_gene_validity`()
BEGIN
  CREATE OR REPLACE EXTERNAL TABLE `clinvar_ingest._manuscript_clingen_gene_validity_sheet` (
    gene_raw STRING,
    disease_raw STRING,
    moi STRING,
    expert_panel STRING,
    sop STRING,
    classification_raw STRING,
    last_eval STRING
  )
  OPTIONS (
    format = 'GOOGLE_SHEETS',
    uris = ['https://docs.google.com/spreadsheets/d/1aLk5SB7e1DGtV2JvYp6jfW_iLKSqOV6Ys5g4c18iY8M'],
    sheet_range = "'Copy of Table 1'!A1:G3451",
    skip_leading_rows = 1
  );

  CREATE OR REPLACE TABLE `clinvar_ingest.manuscript_clingen_gene_validity` AS
  SELECT
    REGEXP_EXTRACT(gene_raw, r'^(.*?)\s*HGNC:') AS gene_symbol,
    REGEXP_EXTRACT(gene_raw, r'(HGNC:\d+)') AS hgnc_id,
    TRIM(REGEXP_REPLACE(disease_raw, r'\s*MONDO:\d+\s*$', '')) AS disease,
    REGEXP_EXTRACT(disease_raw, r'(MONDO:\d+)') AS mondo_id,
    moi,
    REGEXP_REPLACE(TRIM(expert_panel), r' Gene Curation Expert Panel$', '') AS expert_panel,
    sop,
    -- 'No Known Disease RelationshipAnimal Model Only' is a pasted badge.
    IF(STARTS_WITH(classification_raw, 'No Known'), 'No Known', TRIM(classification_raw)) AS classification,
    SAFE.PARSE_DATE('%m/%d/%Y', last_eval) AS last_evaluated
  FROM `clinvar_ingest._manuscript_clingen_gene_validity_sheet`
  WHERE gene_raw IS NOT NULL;

  DROP EXTERNAL TABLE `clinvar_ingest._manuscript_clingen_gene_validity_sheet`;
END;

-- Draft mapping for review. The ClinGen export has expert panels, not domains.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure5_panel_domain_view` AS
SELECT *
FROM UNNEST(ARRAY<STRUCT<expert_panel STRING, clinical_domain STRING, needs_review BOOL>>[
  ('Arrhythmogenic Right Ventricular Cardiomyopathy', 'Cardiovascular', FALSE),
  ('Brugada Syndrome', 'Cardiovascular', FALSE),
  ('Catecholaminergic Polymorphic Ventricular Tachycardia', 'Cardiovascular', FALSE),
  ('Congenital Heart Disease', 'Cardiovascular', FALSE),
  ('Dilated Cardiomyopathy', 'Cardiovascular', FALSE),
  ('Hereditary Cardiovascular Disease', 'Cardiovascular', FALSE),
  ('Heritable Thoracic Aortic Aneurysm and Dissection', 'Cardiovascular', FALSE),
  ('Hypertrophic Cardiomyopathy', 'Cardiovascular', FALSE),
  ('Long QT Syndrome', 'Cardiovascular', FALSE),
  ('Short QT Syndrome', 'Cardiovascular', FALSE),
  ('Hearing Loss', 'Hearing Loss', FALSE),
  ('Hemostasis/Thrombosis', 'Hemostasis/Thrombosis', FALSE),
  ('Breast/Ovarian Cancer', 'Hereditary Cancer', FALSE),
  ('Childhood, Adolescent and Young Adult Cancer Predisposition', 'Hereditary Cancer', FALSE),
  ('Colon Cancer', 'Hereditary Cancer', FALSE),
  ('Hereditary Cancer', 'Hereditary Cancer', FALSE),
  ('Antibody Deficiencies', 'Immunology', FALSE),
  ('Monogenic Autoinflammatory Diseases', 'Immunology', TRUE),
  ('Primary Immune Regulatory Disorders', 'Immunology', FALSE),
  ('SCID-CID', 'Immunology', FALSE),
  ('Aminoacidopathy', 'Inborn Errors of Metabolism', FALSE),
  ('Congenital Disorders of Glycosylation', 'Inborn Errors of Metabolism', FALSE),
  ('Fatty Acid Oxidation Disorders', 'Inborn Errors of Metabolism', FALSE),
  ('General Inborn Errors of Metabolism', 'Inborn Errors of Metabolism', FALSE),
  ('Lysosomal Diseases', 'Inborn Errors of Metabolism', FALSE),
  ('Mitochondrial Diseases', 'Inborn Errors of Metabolism', FALSE),
  ('Peroxisomal Disorders', 'Inborn Errors of Metabolism', FALSE),
  ('Complement-Mediated Kidney Diseases', 'Kidney Disease', FALSE),
  ('Congenital Anomalies of the Kidney and Urinary Tract', 'Kidney Disease', FALSE),
  ('Glomerulopathy', 'Kidney Disease', FALSE),
  ('Kidney Cystic and Ciliopathy Disorders', 'Kidney Disease', FALSE),
  ('Tubulopathy', 'Kidney Disease', FALSE),
  ('Brain Malformations', 'Neurodevelopmental Disorders', FALSE),
  ('Cerebral Palsy', 'Neurodevelopmental Disorders', FALSE),
  ('Epilepsy', 'Neurodevelopmental Disorders', FALSE),
  ('Intellectual Disability and Autism', 'Neurodevelopmental Disorders', FALSE),
  ('Rett and Angelman-like Disorders', 'Neurodevelopmental Disorders', FALSE),
  ('Syndromic Disorders', 'Neurodevelopmental Disorders', TRUE),
  ('Amyotrophic Lateral Sclerosis Spectrum Disorders', 'Neurological Disorders', FALSE),
  ('Cerebellar Ataxia', 'Neurological Disorders', FALSE),
  ('Charcot-Marie-Tooth Disease', 'Neurological Disorders', FALSE),
  ('Congenital Myopathies', 'Neurological Disorders', FALSE),
  ('Leukodystrophy and Leukoencephalopathy', 'Neurological Disorders', FALSE),
  ('Muscular Dystrophies and Myopathies', 'Neurological Disorders', FALSE),
  ('Neurovascular', 'Neurological Disorders', TRUE),
  ('Parkinson\'s Disease', 'Neurological Disorders', FALSE),
  ('Glaucoma and Neuro-Ophthalmology', 'Ocular', FALSE),
  ('Retina', 'Ocular', FALSE),
  ('General', 'Other', TRUE),
  ('Monogenic Diabetes', 'Other', TRUE),
  ('Prenatal', 'Other', TRUE),
  ('Interstitial Lung Disease', 'Pulmonary', FALSE),
  ('Motile Ciliopathy', 'Pulmonary', TRUE),
  ('Pulmonary Hypertension', 'Pulmonary', FALSE),
  ('RASopathy', 'RASopathy', FALSE),
  ('Monogenic Systemic and Incomplete Lupus Erythematosus', 'Rheumatologic Autoimmune Disease', FALSE),
  ('Craniofacial Malformations', 'Skeletal Disorders', TRUE),
  ('Skeletal Disorders', 'Skeletal Disorders', FALSE)
]);

CREATE OR REPLACE TABLE FUNCTION `clinvar_ingest.manuscript_figure5_flags`(as_of_date DATE) AS (

WITH cutoff AS (
  SELECT COALESCE(as_of_date, MAX(batch_release_date)) AS as_of
  FROM `clinvar_curator.cvc_clinvar_batches`
),

-- The only source of CvC submissions in this function. See Method above.
submissions AS (
  SELECT sa.*
  FROM `clinvar_curator.cvc_submitted_annotations_view` sa
  JOIN `clinvar_curator.cvc_annotations_view` av
    ON av.annotation_id = sa.annotation_id
  LEFT JOIN `clinvar_ingest.manuscript_excluded_annotations` x
    ON x.annotation_id = sa.annotation_id
  WHERE x.annotation_id IS NULL
    AND av.is_latest
    AND sa.review_status != 'Archive'
),

flags AS (
  SELECT
    sa.variation_id,
    sa.scv_id,
    sa.scv_ver,
    sa.batch_id,
    sa.batch_release_date,
    sa.annotated_date,
    sa.notes,
    CASE
      WHEN LOWER(sa.notes) LIKE '%limited%' THEN 'Limited'
      WHEN LOWER(sa.notes) LIKE '%disput%' THEN 'Disputed'
      WHEN LOWER(sa.notes) LIKE '%refut%' THEN 'Refuted'
      WHEN LOWER(sa.notes) LIKE '%no known%' THEN 'No Known'
    END AS note_level
  FROM submissions sa
  JOIN cutoff
    ON sa.batch_release_date <= cutoff.as_of
  JOIN `clinvar_ingest.clinvar_scvs` s
    ON s.id = sa.scv_id
    AND s.proposition_type = 'path'
    AND sa.batch_release_date BETWEEN s.start_release_date AND s.end_release_date
  WHERE sa.action = 'flagging candidate'
    AND sa.valid_submission
    AND sa.reason = 'P/LP classification for a variant in a gene with insufficient evidence for a gene-disease relationship'
),

variant_genes AS (
  SELECT variation_id, ARRAY_AGG(gene_id ORDER BY end_release_date DESC LIMIT 1)[OFFSET(0)] AS gene_id
  FROM `clinvar_ingest.clinvar_single_gene_variations`
  GROUP BY variation_id
),

genes AS (
  SELECT
    id,
    ARRAY_AGG(symbol ORDER BY end_release_date DESC LIMIT 1)[OFFSET(0)] AS symbol,
    ARRAY_AGG(hgnc_id IGNORE NULLS ORDER BY end_release_date DESC LIMIT 1)[SAFE_OFFSET(0)] AS hgnc_id
  FROM `clinvar_ingest.clinvar_genes`
  GROUP BY id
),

gdrs AS (
  SELECT
    g.*,
    pd.clinical_domain,
    IF(g.classification IN ('Limited', 'Disputed', 'Refuted', 'No Known'), g.classification, NULL) AS low_level
  FROM `clinvar_ingest.manuscript_clingen_gene_validity` g
  LEFT JOIN `clinvar_ingest.manuscript_figure5_panel_domain_view` pd
    USING (expert_panel)
),

gene_summary AS (
  SELECT
    hgnc_id,
    ARRAY_TO_STRING(ARRAY_AGG(DISTINCT low_level IGNORE NULLS ORDER BY low_level), '/') AS clingen_low_levels,
    COUNT(DISTINCT low_level) AS low_level_count,
    LOGICAL_OR(classification IN ('Moderate', 'Strong', 'Definitive')) AS gene_has_moderate_or_higher
  FROM gdrs
  GROUP BY hgnc_id
),

located AS (
  SELECT
    f.*,
    g.symbol AS gene_symbol,
    g.hgnc_id,
    gs.hgnc_id IS NOT NULL AS in_clingen,
    gs.clingen_low_levels,
    gs.gene_has_moderate_or_higher,
    COALESCE(
      f.note_level,
      IF(gs.low_level_count = 1, gs.clingen_low_levels, NULL),
      'Not recorded'
    ) AS figure_level,
    CASE
      WHEN f.note_level IS NOT NULL THEN 'curator note'
      WHEN gs.low_level_count = 1 THEN 'ClinGen'
      ELSE 'none'
    END AS level_source
  FROM flags f
  LEFT JOIN variant_genes vg USING (variation_id)
  LEFT JOIN genes g ON g.id = vg.gene_id
  LEFT JOIN gene_summary gs ON gs.hgnc_id = g.hgnc_id
),

-- Tier 1 is relationships at the flag's level, 2 is other low-evidence ones, 3 is
-- any. Only the lowest tier that exists for the gene is used.
candidates AS (
  SELECT
    l.scv_id,
    gd.clinical_domain,
    gd.expert_panel,
    gd.last_evaluated,
    CASE
      WHEN gd.classification = l.figure_level THEN 1
      WHEN gd.classification IN ('Limited', 'Disputed', 'Refuted', 'No Known') THEN 2
      ELSE 3
    END AS tier
  FROM located l
  JOIN gdrs gd ON gd.hgnc_id = l.hgnc_id
),

domain_choice AS (
  SELECT
    scv_id,
    ARRAY_AGG(STRUCT(clinical_domain, expert_panel, tier) ORDER BY tier, last_evaluated DESC, expert_panel LIMIT 1)[OFFSET(0)] AS chosen
  FROM candidates
  GROUP BY scv_id
),

domain_sets AS (
  SELECT c.scv_id, ARRAY_TO_STRING(ARRAY_AGG(DISTINCT c.clinical_domain IGNORE NULLS ORDER BY c.clinical_domain), ' | ') AS all_domains
  FROM candidates c
  JOIN domain_choice d ON d.scv_id = c.scv_id AND d.chosen.tier = c.tier
  GROUP BY c.scv_id
),

retractions AS (
  SELECT
    f.scv_id,
    ARRAY_AGG(
      CASE
        WHEN sa.reason LIKE 'Gene-disease relationship%' THEN 'Classification changed'
        ELSE 'Other'
      END
      ORDER BY sa.batch_release_date DESC LIMIT 1
    )[OFFSET(0)] AS retraction_kind
  FROM flags f
  JOIN submissions sa
    ON sa.scv_id = f.scv_id
    AND sa.action = 'remove flagged submission'
    AND sa.batch_release_date > f.batch_release_date
  JOIN cutoff
    ON sa.batch_release_date <= cutoff.as_of
  GROUP BY f.scv_id
),

release_scvs AS (
  SELECT s.id AS scv_id, s.version, s.review_status
  FROM `clinvar_ingest.clinvar_scvs` s
  JOIN cutoff
    ON cutoff.as_of BETWEEN s.start_release_date AND s.end_release_date
)

SELECT
  cutoff.as_of AS as_of_batch_release_date,
  l.variation_id,
  l.scv_id,
  l.scv_ver,
  l.gene_symbol,
  l.hgnc_id,
  l.batch_id,
  l.batch_release_date,
  l.annotated_date,
  l.note_level,
  l.clingen_low_levels,
  l.figure_level,
  l.level_source,
  l.note_level IS NOT NULL
    AND l.note_level IN UNNEST(SPLIT(IFNULL(l.clingen_low_levels, ''), '/')) AS note_level_in_clingen,
  COALESCE(d.chosen.clinical_domain, 'Not in ClinGen export') AS clinical_domain,
  CASE d.chosen.tier
    WHEN 1 THEN 'matching level'
    WHEN 2 THEN 'other low-evidence'
    WHEN 3 THEN 'any relationship'
    ELSE 'none'
  END AS domain_source,
  d.chosen.expert_panel AS domain_expert_panel,
  ds.all_domains,
  COALESCE(l.gene_has_moderate_or_higher, FALSE) AS gene_has_moderate_or_higher,
  IF(r.scv_id IS NULL, 'standing', 'retracted') AS flag_status,
  r.retraction_kind,
  COALESCE(rs.review_status = 'flagged submission', FALSE) AS flagged_in_clinvar,
  CASE
    WHEN rs.scv_id IS NULL THEN 'not in release'
    WHEN rs.review_status = 'flagged submission' THEN 'flagged'
    WHEN rs.version > l.scv_ver THEN 'newer SCV version'
    ELSE 'not flagged, same version'
  END AS clinvar_state,
  r.scv_id IS NULL AND COALESCE(rs.review_status = 'flagged submission', FALSE) AS shown_in_figure,
  l.notes
FROM located l
CROSS JOIN cutoff
LEFT JOIN domain_choice d USING (scv_id)
LEFT JOIN domain_sets ds USING (scv_id)
LEFT JOIN retractions r USING (scv_id)
LEFT JOIN release_scvs rs USING (scv_id)

);

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure5_flags_view` AS
SELECT *
FROM `clinvar_ingest.manuscript_figure5_flags`(NULL);

-- The table under the figure: one row per domain and level.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure5_domain_level_view` AS
SELECT
  as_of_batch_release_date,
  clinical_domain,
  figure_level,
  COUNTIF(shown_in_figure) AS flagged_scvs,
  COUNT(DISTINCT IF(shown_in_figure, variation_id, NULL)) AS flagged_variants,
  COUNT(DISTINCT IF(shown_in_figure, gene_symbol, NULL)) AS flagged_genes,
  COUNTIF(flag_status = 'standing' AND NOT flagged_in_clinvar) AS standing_not_flagged_scvs,
  COUNTIF(flag_status = 'retracted') AS retracted_scvs,
  COUNT(*) AS submitted_scvs
FROM `clinvar_ingest.manuscript_figure5_flags_view`
GROUP BY as_of_batch_release_date, clinical_domain, figure_level;

CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure5_gene_view` AS
SELECT
  as_of_batch_release_date,
  gene_symbol,
  ANY_VALUE(clingen_low_levels) AS clingen_low_levels,
  ANY_VALUE(gene_has_moderate_or_higher) AS gene_has_moderate_or_higher,
  ARRAY_TO_STRING(ARRAY_AGG(DISTINCT clinical_domain ORDER BY clinical_domain), ' | ') AS clinical_domains,
  ARRAY_TO_STRING(ARRAY_AGG(DISTINCT figure_level ORDER BY figure_level), ' | ') AS figure_levels,
  COUNTIF(shown_in_figure) AS flagged_scvs,
  COUNTIF(flag_status = 'standing' AND NOT flagged_in_clinvar) AS standing_not_flagged_scvs,
  COUNTIF(flag_status = 'retracted') AS retracted_scvs,
  COUNT(*) AS submitted_scvs
FROM `clinvar_ingest.manuscript_figure5_flags_view`
GROUP BY as_of_batch_release_date, gene_symbol;

-- Every count quoted in a call-out, so they can be checked against the data.
CREATE OR REPLACE VIEW `clinvar_ingest.manuscript_figure5_callouts_view` AS
-- The flags are read once and fanned out to each call-out they belong to, because
-- one UNION branch per call-out re-expands the table function past BigQuery's
-- query planning limit.
WITH f AS (SELECT * FROM `clinvar_ingest.manuscript_figure5_flags_view`),
callout_rows AS (
  SELECT 0 AS sort_order, CONCAT('Left out of every figure: ', exclusion) AS callout, scv_id, variation_id, CAST(NULL AS STRING) AS gene_symbol
  FROM `clinvar_ingest.manuscript_excluded_scvs`
  UNION ALL
  SELECT c.sort_order, c.callout, f.scv_id, f.variation_id, f.gene_symbol
  FROM f
  LEFT JOIN `clinvar_ingest.manuscript_figure5_panel_domain_view` pd
    ON pd.expert_panel = f.domain_expert_panel
  CROSS JOIN UNNEST([
    STRUCT(1 AS sort_order, 'Submitted flags' AS callout, TRUE AS hit),
    STRUCT(2, 'In the figure: standing and flagged in ClinVar', f.shown_in_figure),
    STRUCT(3, 'Retracted', f.flag_status = 'retracted'),
    STRUCT(4, CONCAT('Retracted: ', IFNULL(f.retraction_kind, '')), f.flag_status = 'retracted'),
    STRUCT(5, 'Retracted, still flagged in ClinVar', f.flag_status = 'retracted' AND f.flagged_in_clinvar),
    STRUCT(6, 'Standing, not flagged in ClinVar', f.flag_status = 'standing' AND NOT f.flagged_in_clinvar),
    STRUCT(7, CONCAT('Standing, not flagged: ', f.clinvar_state), f.flag_status = 'standing' AND NOT f.flagged_in_clinvar),
    STRUCT(8, 'Standing, not flagged: CAPN3, BRIP1, USH1C, PCDH15', f.flag_status = 'standing' AND NOT f.flagged_in_clinvar AND f.gene_symbol IN ('CAPN3', 'BRIP1', 'USH1C', 'PCDH15')),
    STRUCT(9, 'In the figure, gene has a Moderate or higher relationship', f.shown_in_figure AND f.gene_has_moderate_or_higher),
    STRUCT(10, 'In the figure, level filled in from ClinGen', f.shown_in_figure AND f.level_source = 'ClinGen'),
    STRUCT(11, 'In the figure, level not recorded', f.shown_in_figure AND f.level_source = 'none'),
    STRUCT(12, 'In the figure, note level not in ClinGen for the gene', f.shown_in_figure AND f.note_level IS NOT NULL AND NOT f.note_level_in_clingen),
    STRUCT(13, 'In the figure, domain not from a matching-level relationship', f.shown_in_figure AND f.domain_source <> 'matching level'),
    STRUCT(14, 'In the figure, gene has several domains in its set', f.shown_in_figure AND f.all_domains LIKE '%|%'),
    STRUCT(15, 'In the figure, domain mapping needs review', f.shown_in_figure AND COALESCE(pd.needs_review, FALSE))
  ]) c
  WHERE c.hit
)
SELECT
  callout,
  COUNT(DISTINCT scv_id) AS scvs,
  COUNT(DISTINCT variation_id) AS variants,
  COUNT(DISTINCT gene_symbol) AS genes
FROM callout_rows
GROUP BY sort_order, callout;
