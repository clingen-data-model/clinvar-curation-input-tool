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
| `03-flagged-scv-by-consequence.sql` | `clinvar_ingest.manuscript_flagged_scv_by_consequence_view` | Summary of pathogenicity-assessed variants grouped by variation type and molecular consequence category. Shows counts of all variants vs flagged variants across consequence groups (predicted LOF, missense, inframe indels, UTR/intronic, other). Includes SCV-level counts and an audit trail of consequence labels per group. |
| `04-conflict-resolution-outcomes.sql` | `clinvar_ingest.manuscript_figure4_variant_outcomes(as_of_date)`, `clinvar_ingest.manuscript_figure4_variant_outcomes_view`, `clinvar_ingest.manuscript_figure4a_outcomes_view`, `clinvar_ingest.manuscript_figure4a_outcome_detail_view`, `clinvar_ingest.manuscript_figure4b_flows_view`, `clinvar_ingest.manuscript_figure4b_final_classifications_view`, `clinvar_ingest.manuscript_figure4b_conflict_combinations_view`, `clinvar_ingest.manuscript_figure4_rank_group_transitions_view` | One row per variant reviewed by CvC, with its outcome and the top ranked group's state before and after flagging, at the point of submission to ClinVar. `generate_figure4.py` calls the table function and draws both panels. |

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

Script `03-flagged-scv-by-consequence.sql` produces data for two donut charts:

- **Figure 3a**: All pathogenicity-assessed variants by consequence group
- **Figure 3b**: Flagged pathogenicity-assessed variants by consequence group

### Consequence Groups

| Group | Description |
| --- | --- |
| predicted LOF | nonsense, frameshift variant, splice donor variant, splice acceptor variant |
| missense | missense variants |
| inframe indels | inframe insertion, inframe_insertion, inframe deletion, inframe_deletion, inframe indel, inframe_indel |
| UTR/intronic | 5 prime UTR variant, 3 prime UTR variant, intron variant |
| other | All other consequences and variants without MANE Select annotation |

```sql
-- Refresh the data
CALL `clinvar_ingest.refresh_flagged_scv_by_consequence`(NULL);

-- Query the view
SELECT * FROM `clinvar_ingest.manuscript_flagged_scv_by_consequence_view`;
```

---

## Figure 4: Outcomes of SCV Annotations

Script `04-conflict-resolution-outcomes.sql` creates a table function that returns one row per reviewed variant, and the views behind the sheet. `generate_figure4.py` calls the table function and draws both panels. Google Sheets has no Sankey chart, so the figures are pasted into the sheet as static images.

Figures and counts: [CvC Manuscript Figure 4 sheet](https://docs.google.com/spreadsheets/d/1qx6_90ZHtcu_xlVq0zU1DjkSnk0tHFJDA-GJMcvvkos/edit). The tab `About Figure 4` has the steps for refreshing the tables and re-pasting the images. Counts quoted below are for batches through 2026-10-24.

```bash
# Only when the SQL changes: deploy the table function and views
bq query --project_id=clingen-dev --use_legacy_sql=false < 04-conflict-resolution-outcomes.sql

# All batches. Requires the bq CLI; PNGs also require Chrome.
python3 generate_figure4.py --out figure4-output

# Limit to batches released by a date
python3 generate_figure4.py --as-of 2026-05-31 --out figure4-may2026
```

| Output | Contents |
| --- | --- |
| `figure4.svg`, `figure4a.svg`, `figure4b.svg` | Both panels, and each panel alone |
| `figure4b_non_medically_significant.svg` | The same Sankey for VUS vs B/LB conflicts |
| `figure4a_outcomes.csv`, `figure4a_outcome_detail.csv` | Panel A counts, and the finer outcomes behind each slice |
| `figure4b_flows.csv`, `figure4b_final_classifications.csv` | Panel B flows, and one row for each exact starting conflict and result, with variant and flagged SCV counts |
| `figure4b_conflict_combinations.csv` | Every medically significant label combination, its Panel B node and its state after flagging |
| `rank_group_transitions.csv` | Before and after state of every rank group that had a flagged SCV |
| `variant_outcomes.csv` | The query result |

### What the Figure Represents

Figure 4 shows what each batch's flagging candidates would do to the variant's aggregate classification **at the point they were submitted**, using the SCVs in ClinVar on the batch release. Only that batch's flagging candidates are removed. It does not show what happened later. A flag can still be contested, rejected or removed by a resubmission, so these are not counts of flags in ClinVar today.

ClinVar builds the aggregate from the highest ranked group of SCVs, so before and after are each read from their own top ranked group. Flags on lower groups do not change the outcome unless the whole top group is flagged.

### Panel A Outcomes

| Outcome | `outcome_detail` | Rule, using the top ranked group |
| --- | --- | --- |
| Conflict resolved | `conflict resolved` | Any conflict becomes a single tier |
| | `conflict resolved, no classification left` | Any conflict loses all of its SCVs |
| Conflict reduced | `significant conflict reduced` | P/LP vs VUS/B/LB becomes VUS vs B/LB |
| Incorrect record flagged | `non-conflict removed` | No conflict, and no contributing SCVs are left |
| Record modified | `other conflict modified` | Top group flagged, and the conflict remains at a level that is not reduced |
| | `non-conflict modified` | Top group flagged, no conflict before or after |
| | `non-conflict, classification changed at lower rank` | Top group fully flagged, and a lower group with a different tier takes over |
| | `conflict exposed at lower rank` | Top group fully flagged, and a lower group in conflict takes over |
| | `conflict, top rank not flagged` | Only lower groups flagged, and the top group is in conflict |
| | `non-conflict, top rank not flagged` | Only lower groups flagged, and the top group is not in conflict |
| No change | `no flagging candidate submitted` | Reviewed, with no valid flagging candidate in a batch |

The denominator is distinct variants with a final annotation in a batch on a path SCV.

### How to Interpret It

- **Direction describes what CvC flagged.** CvC selects outlier submissions, so a flow toward P/LP means VUS or B/LB outliers were flagged. It does not show which classification is correct.
- **Panel B reads the top ranked group only.** `lower_rank_conflict_resolved` and `rank_group_transitions.csv` report conflicts resolved in lower groups, including when the aggregate does not change.
- **A slash means either or both of its labels.** Panel B splits P vs LP in every two-tier starting conflict. B/LB in those node names means B, LB or both, and P/LP vs VUS vs B/LB groups every three-tier conflict. `figure4b_conflict_combinations.csv` has every combination, with related labels such as VUS-high counted with VUS.
- **P/LP after flagging means P, LP or both.** Of the 2,921 variants that move to P/LP, 1,988 are left with both P and LP, 551 with only P and 382 with only LP.
- **The most granular counts are in one view.** `clinvar_ingest.manuscript_figure4b_final_classifications_view` has one row for each `classification_to_start` and result after flagging, shown as a table under each Sankey in the sheet. For example, of the P + LP vs VUS variants, 1,931 ended as P + LP and 3 as VUS. Variants that stayed in conflict are not in this view. `conflict_combination` and `after_classif_group` have the same labels per variant. Its `flagged_scvs` column counts the flagging candidates of the variant's reported batch in the top ranked group, and in any lower group down to the one that takes over.
- **Variants flagged in several batches appear once.** 280 variants are in this group. Each batch is evaluated on its own flags, and the variant keeps its strongest outcome. An earlier flag that ClinVar has applied is rank -3 and already out of the batch release. An earlier flag that it has not applied still counts as a contributing SCV.
- **Retracted flags are still counted.** The figure reflects the point of submission, so 329 variants with a flag that was later retracted stay in their outcome: 185 Record modified, 121 Incorrect record flagged, 21 Conflict resolved and 2 Conflict reduced. `any_flag_retracted` identifies these variants.
- **Record modified includes lower ranked flags.** For 441 of the 915 variants, only lower ranked groups were flagged, so the top ranked group did not change: 115 are in conflict and 326 are not. `outcome_detail` identifies them as `conflict, top rank not flagged` and `non-conflict, top rank not flagged`. They are not in Panel B. 11 variants are in both this group and the retracted group.
- **Some classifications are counted together.** P includes pathogenic low penetrance (`p-lp`) and established risk allele (`era`). LP includes likely pathogenic low penetrance (`lp-lp`) and likely risk allele (`lra`). VUS includes VUS-high (`vus-h`), VUS-mid (`vus-m`), VUS-low (`vus-l`) and uncertain risk allele (`ura`). `after_classif` keeps the original labels.

### Excluded Non-Pathogenicity Flagging Candidates

CvC submitted flagging candidates on non-pathogenicity SCVs for 5 variants. Those candidates are excluded from this figure. The first three variants had no pathogenicity SCV reviewed, so they do not appear at all. The other two also had a pathogenicity SCV reviewed as no change, so they count as No change in Panel A.

| Variation | Proposition | Flagging candidate SCVs | Pathogenicity SCV reviewed as no change |
| --- | --- | --- | --- |
| [16873](https://www.ncbi.nlm.nih.gov/clinvar/variation/16873/) | risk factor | SCV000038650 | |
| [17801](https://www.ncbi.nlm.nih.gov/clinvar/variation/17801/) | risk factor | SCV000039669 | |
| [9393](https://www.ncbi.nlm.nih.gov/clinvar/variation/9393/) | risk factor | SCV000987620 | |
| [203643](https://www.ncbi.nlm.nih.gov/clinvar/variation/203643/) | other | SCV000700738 | SCV000676997 |
| [67509](https://www.ncbi.nlm.nih.gov/clinvar/variation/67509/) | risk factor | SCV000206987, SCV000987628 | SCV000696033 |

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
