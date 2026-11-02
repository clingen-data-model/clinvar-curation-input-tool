# Manuscript Figures

This folder contains SQL scripts that produce the datasets and supporting data for figures included in the forthcoming manuscript describing the ClinVar Curation project.

## Background

The ClinVar Curation project systematically identifies and addresses conflicting variant classifications in ClinVar, with the goal of improving the consistency and clinical utility of submitted interpretations. This manuscript documents the project's methodology, scope, and measurable impact on ClinVar's classification landscape.

Each script in this folder generates a dataset that underpins a specific figure or table in the manuscript. Scripts are numbered in the order they appear in the manuscript.

## Scripts

| Script | View | Description |
| --- | --- | --- |
| `01-clinvar-landscape.sql` | `clinvar_ingest.manuscript_clinvar_landscape` | Per-gene summary of the ClinVar Germline Variant Pathogenicity Classification landscape for genes in the GenCC Definitive/Strong/Moderate (DSM) gene list. Produces total SCV and variant counts, clinically significant (P/LP) variant counts, and a breakdown of aggregate classification categories (concordant P/LP, P/LP vs B/LB, P/LP vs VUS, and three-way conflicts). |
| `02-submitter-landscape.sql` | `clinvar_ingest.manuscript_submitter_landscape` | Per-institution-type summary of ClinVar submitter organizations and their Germline Variant Pathogenicity Classification contributions. Shows submitter counts, SCV counts, and variant counts grouped by institution type (clinical testing, research, expert panel, etc.). |
| `03-flagged-scv-by-consequence.sql` | `clinvar_ingest.manuscript_cvc_vs_clinvar_consequence_bar_view`, `clinvar_ingest.manuscript_flag_source_combo_by_consequence_view`, `clinvar_ingest.manuscript_flagged_scv_by_consequence_view` | Molecular consequence of pathogenicity-assessed variants in ClinVar versus variants flagged through the CvC project, with flagged variant and SCV counts by flag source (ClinGen CvC, ClinGen non-CvC, NCBI) and their combinations. |

## Data Scope

All scripts operate on the **Germline Variant Pathogenicity Classification Submission Data** subset of ClinVar (`proposition_type = 'path'`). This excludes Somatic SCVs and other Germline SCVs that are not pathogenicity classifications (e.g., drug response, clinical impact).

## Dependencies

- **`clinvar_ingest` dataset** - Core ClinVar ingested and temporal tables
- **`clinvar_ingest.gencc_dsm_genes`** - GenCC gene list filtered to Definitive, Strong, and Moderate disease-gene validity classifications
- **`clinvar_ingest.clinvar_genes`** - ClinVar gene records with HGNC IDs, used to bridge `gencc_dsm_genes` (by `hgnc_id`) to `clinvar_single_gene_variations` (by `gene_id`)
- **`clinvar_ingest.clinvar_single_gene_variations`** - Variants mapped to a single gene (excludes multi-gene variants)

---

## Figure 1: ClinVar Landscape

Script `01-clinvar-landscape.sql` produces data for two scatter plots:

- **Figure 1a**: Conflict count - absolute number of clinically significant conflict variants per gene
- **Figure 1b**: Conflict rate - percentage of variants in clinically significant conflict per gene

| Column | Description |
| --- | --- |
| `gene_symbol` | Gene symbol (e.g., BRCA1) |
| `total_scvs` | All pathogenicity SCVs for this gene |
| `total_variants` | Distinct variants with pathogenicity SCVs |
| `total_clinsig_variants` | Variants with P/LP classifications |
| `total_clinsig_conflict_variants` | Variants with agg_sig_type >= 5 (clinically significant conflicts) |
| `concordant_clinsig_variants` | P/LP variants with concordant classifications |
| `clinsig_conflict_pct` | Percentage of variants in clinically significant conflict |

```sql
-- Query the view
SELECT * FROM `clinvar_ingest.manuscript_clinvar_landscape`;
```

---

## Figure 2: Submitter Landscape

Script `02-submitter-landscape.sql` produces data showing ClinVar contributions by institution type.

| Column | Description |
| --- | --- |
| `release_date` | ClinVar release date for this snapshot |
| `type` | Institution type (e.g., clinical testing, research, expert panel) |
| `submitter_count` | Count of distinct submitter organizations |
| `scv_count` | Count of pathogenicity SCVs from this institution type |
| `vcv_count` | Count of distinct variants with SCVs from this type |

```sql
-- Query the view
SELECT * FROM `clinvar_ingest.manuscript_submitter_landscape`;
```

---

## Figure 3: Variants by Molecular Consequence

Script `03-flagged-scv-by-consequence.sql` produces data for one bar chart comparing the consequence distribution of all pathogenicity-assessed variants in ClinVar with variants flagged through the CvC project. NCBI and ClinGen non-CvC flags are excluded from the CvC bars.

Chart and counts: [CvC Manuscript Figure 3 sheet](https://docs.google.com/spreadsheets/d/17wr65aFoU9xVD0eluNfLxOzbxpJbAv7jYoG4Ir4POyY/edit). Counts quoted below are for ClinVar release 2026-10-24.

### What the Figure Represents

Figure 3 asks: **do the variants currently flagged through CvC have a different mix of molecular consequences than ClinVar's pathogenicity-assessed variants overall?** It is a snapshot of one ClinVar release, counted in variants and shown as percentages, because the two groups differ about 2,000-fold in size.

| | All ClinVar variants (blue) | CvC-flagged variants (red) |
| --- | --- | --- |
| **Who is counted** | Every variant with at least one germline pathogenicity SCV (`proposition_type = 'path'`), of any variation type, flagged or not | The subset of those variants with at least one SCV that is flagged in this release, carries a ClinGen flag comment, and was submitted by CvC as a `flagging candidate` on or before the release |
| **Total (n)** | 4,434,878 | 2,027 |
| **Each bar is** | % of all variants in that group | % of CvC-flagged variants in that group |

Each group's percentages sum to about 100 (rounding can give 100.01). Compare a bar with its neighbor, not with bars in other groups.

### Where the Data Comes From

| Element | Source |
| --- | --- |
| Pathogenicity SCVs, flagged state (`rank = -3`) | `scv_summary` in the dataset for the release |
| Who requested the flag | `scv_summary.comments` rows with `type = 'FlaggedComment'`, from the ClinVar XML comment `DataSource` |
| CvC submissions | `clinvar_curator.cvc_submitted_annotations_view`, matched on SCV accession, not version |
| Molecular consequence | `variation_hgvs.consq_label` on MANE Select rows |
| Variation type | `variation_identity` |

### How to Interpret It

- **Currently flagged, not everything CvC requested.** Through this release CvC submitted 6,348 SCV accessions as flagging candidates. 5,609 are still in ClinVar and 5,600 of those are pathogenicity SCVs. Of those, 2,405 are flagged now and 3,195 are not. This figure does not explain why an SCV is not flagged. Four CvC-flagged SCVs are not pathogenicity SCVs and are excluded.
- **The groups overlap.** Red variants are also counted in blue, so they are not independent samples. No statistical test is included.
- **CvC variants are selected, not sampled.** CvC chooses what to review through its curation priorities, so a difference between bars describes what was flagged. It does not show that a consequence type causes flagging or submission errors.
- **"Flag source" applies to the flagged bars only.** Variants flagged only by NCBI or ClinGen non-CvC are left out of red but stay in blue, as ClinVar variants. 14 variants with both CvC and NCBI flags count in red. All 142 ClinGen non-CvC SCVs carry the reason "Conflict with ClinGen Gene Dosage Map".
- **"Other" is mostly synonymous variants.** Of its 900,194 variants, 756,083 are synonymous and 137,491 have no MANE Select annotation, including all 49,464 copy number variants. Stop lost (1,194) and initiator codon (3,783) variants are also here, not in predicted LOF.
- **"Predicted LOF" comes from the consequence label alone.** It does not include additional evidence, such as whether the transcript escapes nonsense-mediated decay.
- **Each variant has one consequence.** Only the first term of the MANE Select label is used. A variant with several MANE Select rows, such as one in overlapping genes, is counted once in its most severe group. 42,664 variants have MANE Select rows with differing consequences.

### Refreshing the Data

The chart legend shows the ClinVar release date and each group's n, using formulas on the sheet's `Figure 3 data` tab, so it always shows which release is displayed. Chart titles in Google Sheets are fixed text, so the date is not in the title.

After a new ClinVar release:

1. Update the BigQuery tables. Nothing in this repo or `clinvar-ingest-bq-tools` schedules this, so someone must run it:

   ```sql
   CALL `clinvar_ingest.refresh_flagged_scv_by_consequence`(NULL);
   ```

2. In the sheet, choose **Data > Data connectors > Refresh options > Refresh all**.

The views show only the latest release in the tables, so running the procedure for an older date does not change what the sheet shows unless that date is the latest loaded. Viewers need BigQuery access to `clingen-dev` to refresh the connected tabs.

### Consequence Groups

| Group | Description |
| --- | --- |
| predicted LOF | nonsense, frameshift variant, splice donor variant, splice acceptor variant |
| missense | missense variants |
| inframe indels | inframe insertion, inframe_insertion, inframe deletion, inframe_deletion, inframe indel, inframe_indel |
| UTR/intronic | 5 prime UTR variant, 3 prime UTR variant, intron variant |
| other | All other consequences and variants without MANE Select annotation |

A variant with more than one MANE Select row is counted once, in its most severe group, in the order listed above.

### Flag Sources

The source comes from `scv_summary.comments` rows with `type = 'FlaggedComment'`.

| Source | Definition |
| --- | --- |
| ClinGen CvC | ClinGen flag comment, and CvC submitted the SCV as a `flagging candidate` by this release |
| ClinGen non-CvC | ClinGen flag comment, and CvC did not submit the SCV (e.g. "Conflict with ClinGen Gene Dosage Map") |
| NCBI | NCBI flag comment |

An SCV or variant with more than one source is reported as a combination, e.g. `ClinGen CvC + NCBI`.

```sql
-- Refresh the data
CALL `clinvar_ingest.refresh_flagged_scv_by_consequence`(NULL);

-- Figure 3 bar chart
SELECT * FROM `clinvar_ingest.manuscript_cvc_vs_clinvar_consequence_bar_view`;

-- Exact flag source combinations (count_level = 'scv' or 'variant')
SELECT * FROM `clinvar_ingest.manuscript_flag_source_combo_by_consequence_view`;

-- Counts by variation type and consequence group
SELECT * FROM `clinvar_ingest.manuscript_flagged_scv_by_consequence_view`;
```

---

## TODO

[Manuscript Figures Spreadsheet](https://docs.google.com/spreadsheets/d/1aLk5SB7e1DGtV2JvYp6jfW_iLKSqOV6Ys5g4c18iY8M/edit?gid=225392840#gid=225392840)

Figure 2C. CvC Categories of Prioritizing variant conflicts
No. of SCVs in annotation workflow by source

- order of categories: community requests, interlab conflicts, clinsig outliers, discordance, vcep

Figure 3 Flagging Outcomes (additional sub-figures)

3.a (was 3.B)
3.b (was 3.C)
3.c (was 3.E)
3.d (was 3.A)
3.e (was 3.D)
