-- Discordance Retraction Analysis Queries
-- Find annotations where notes contain specific phrases indicating discordance/retraction reasons
-- Limited to genes in the gci_discordancy_gene_list

-- Query 1: Separate columns for each matched phrase
SELECT
  g.id,
  g.symbol,
  hg.hgnc_id,
  hg.entrez_id,
  ca.vcv_id,
  ca.scv_id,
  ca.annotation_date,
  ca.curator_email,
  ca.action,
  ca.reason,
  ca.notes,
  -- Indicate which phrase(s) matched
  CASE WHEN LOWER(ca.notes) LIKE '%discordance project%' THEN 'discordance project' END AS matched_discordance_project,
  CASE WHEN LOWER(ca.notes) LIKE '%multiple disease relationships%' THEN 'multiple disease relationships' END AS matched_multiple_disease_relationships,
  CASE WHEN LOWER(ca.notes) LIKE '%multiple disease assertion%' THEN 'multiple disease assertion' END AS matched_multiple_disease_assertion,
  CASE WHEN LOWER(ca.notes) LIKE '%ignore%' THEN 'ignore' END AS matched_ignore

FROM `clinvar_curator.clinvar_annotations` ca
LEFT JOIN `clinvar_ingest.clinvar_single_gene_variations` sgv
ON
  DATE(ca.annotation_date) BETWEEN sgv.start_release_date AND sgv.end_release_date
  AND sgv.variation_id = ca.variation_id
LEFT JOIN `clinvar_ingest.clinvar_genes` g
ON
  DATE(ca.annotation_date) BETWEEN g.start_release_date AND g.end_release_date
  AND g.id = sgv.gene_id
JOIN `clinvar_curator.gci_discordancy_gene_list` gdgl
ON
  gdgl.symbol = g.symbol
LEFT JOIN `clinvar_ingest.hgnc_gene` hg
ON
  hg.symbol = gdgl.symbol

WHERE
  action = 'No Change'
  AND (
    LOWER(ca.notes) LIKE '%discordance project%'
    OR LOWER(ca.notes) LIKE '%multiple disease relationships%'
    OR LOWER(ca.notes) LIKE '%multiple disease assertion%'
    OR LOWER(ca.notes) LIKE '%ignore%'
  );


-- Query 2: Single column with all matched phrases concatenated
SELECT
  g.id,
  g.symbol,
  hg.hgnc_id,
  hg.entrez_id,
  ca.vcv_id,
  ca.scv_id,
  ca.annotation_date,
  ca.curator_email,
  ca.action,
  ca.reason,
  ca.notes,
  -- Single column with all matched phrases
  ARRAY_TO_STRING(ARRAY_CONCAT(
    IF(LOWER(ca.notes) LIKE '%discordance project%', ['discordance project'], []),
    IF(LOWER(ca.notes) LIKE '%multiple disease relationships%', ['multiple disease relationships'], []),
    IF(LOWER(ca.notes) LIKE '%multiple disease assertion%', ['multiple disease assertion'], []),
    IF(LOWER(ca.notes) LIKE '%ignore%', ['ignore'], [])
  ), ', ') AS matched_phrases

FROM `clinvar_curator.clinvar_annotations` ca
LEFT JOIN `clinvar_ingest.clinvar_single_gene_variations` sgv
ON
  DATE(ca.annotation_date) BETWEEN sgv.start_release_date AND sgv.end_release_date
  AND sgv.variation_id = ca.variation_id
LEFT JOIN `clinvar_ingest.clinvar_genes` g
ON
  DATE(ca.annotation_date) BETWEEN g.start_release_date AND g.end_release_date
  AND g.id = sgv.gene_id
JOIN `clinvar_curator.gci_discordancy_gene_list` gdgl
ON
  gdgl.symbol = g.symbol
LEFT JOIN `clinvar_ingest.hgnc_gene` hg
ON
  hg.symbol = gdgl.symbol

WHERE
  action = 'No Change'
  AND (
    LOWER(ca.notes) LIKE '%discordance project%'
    OR LOWER(ca.notes) LIKE '%multiple disease relationships%'
    OR LOWER(ca.notes) LIKE '%multiple disease assertion%'
    OR LOWER(ca.notes) LIKE '%ignore%'
  );


-- Query 3: Flagging Candidates for insufficient gene-disease evidence (retraction candidates)
SELECT
  g.id,
  g.symbol,
  hg.hgnc_id,
  hg.entrez_id,
  ca.vcv_id,
  ca.scv_id,
  ca.annotation_date,
  ca.curator_email,
  ca.action,
  ca.reason,
  ca.notes

FROM `clinvar_curator.clinvar_annotations` ca
LEFT JOIN `clinvar_ingest.clinvar_single_gene_variations` sgv
ON
  DATE(ca.annotation_date) BETWEEN sgv.start_release_date AND sgv.end_release_date
  AND sgv.variation_id = ca.variation_id
LEFT JOIN `clinvar_ingest.clinvar_genes` g
ON
  DATE(ca.annotation_date) BETWEEN g.start_release_date AND g.end_release_date
  AND g.id = sgv.gene_id
JOIN `clinvar_curator.gci_discordancy_gene_list` gdgl
ON
  gdgl.symbol = g.symbol
LEFT JOIN `clinvar_ingest.hgnc_gene` hg
ON
  hg.symbol = gdgl.symbol

WHERE
  action = 'Flagging Candidate'
  AND reason = 'P/LP classification for a variant in a gene with insufficient evidence for a gene-disease relationship';


-- Query 4: Remove Flagged Submission records to append to Data Capture sheet to correct previous discordance flagged submissions
SELECT
  cv.full_vcv_id as `VCV ID`,
  ca.variation_name AS `Variant`,
  cs.full_scv_id as `SCV ID`,
  ca.submitter_name as `Submitter`,
  ca.interpretation as `Interpretation`,
  'Remove Flagged Submission' as `Action`,
  'Other' as `Reason`,
  'Discordance project retraction' as `Notes`,
  FORMAT_TIMESTAMP(
    '%Y-%m-%dT%H:%M:%S.',
    TIMESTAMP_ADD(
      TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), MINUTE),
      INTERVAL ROW_NUMBER() OVER (ORDER BY ca.scv_id) MILLISECOND
    )
  ) || LPAD(CAST(ROW_NUMBER() OVER (ORDER BY ca.scv_id) AS STRING), 3, '0') || 'Z' as `Timestamp`,
  ca.submitter_id as `Submitter ID`,
  ca.variation_id as `Variation ID`,
  'lbabb@broadinstitute.org' as `Curator Email`,
  'Remove Flagged Submission' as `Review Status`

FROM `clinvar_curator.clinvar_annotations` ca
LEFT JOIN `clinvar_ingest.clinvar_single_gene_variations` sgv
ON
  DATE(ca.annotation_date) BETWEEN sgv.start_release_date AND sgv.end_release_date
  AND sgv.variation_id = ca.variation_id
LEFT JOIN `clinvar_ingest.clinvar_genes` g
ON
  DATE(ca.annotation_date) BETWEEN g.start_release_date AND g.end_release_date
  AND g.id = sgv.gene_id
JOIN `clinvar_curator.gci_discordancy_gene_list` gdgl
ON
  gdgl.symbol = g.symbol
LEFT JOIN `clinvar_ingest.hgnc_gene` hg
ON
  hg.symbol = gdgl.symbol
LEFT JOIN `clinvar_ingest.clinvar_scvs` cs
ON
  DATE'2026-02-08' = cs.end_release_date
  AND
  cs.id = LEFT(ca.scv_id, INSTR(ca.scv_id,'.')-1)
LEFT JOIN `clinvar_ingest.clinvar_vcvs` cv
ON
  DATE'2026-02-08' = cv.end_release_date
  AND
  cv.id = LEFT(ca.vcv_id, INSTR(ca.vcv_id,'.')-1)
LEFT JOIN `clingen-dev.clinvar_curator.cvc_clinvar_submissions` ccs
ON
  ccs.scv_id = LEFT(ca.scv_id, INSTR(ca.scv_id,'.')-1)
WHERE
  action = 'Flagging Candidate'
  AND reason = 'P/LP classification for a variant in a gene with insufficient evidence for a gene-disease relationship'
  AND cs.review_status = 'flagged submission'
