# Manuscript Figures

This folder contains SQL scripts that produce the datasets and supporting data for figures included in the forthcoming manuscript describing the ClinVar Curation project.

## Background

The ClinVar Curation project systematically identifies and addresses conflicting variant classifications in ClinVar, with the goal of improving the consistency and clinical utility of submitted interpretations. This manuscript documents the project's methodology, scope, and measurable impact on ClinVar's classification landscape.

Each script in this folder generates a dataset that underpins a specific figure or table in the manuscript. Scripts are numbered in the order they appear in the manuscript.

## Scripts

| Script | View | Description |
| --- | --- | --- |
| `00-excluded-scvs.sql` | `clinvar_ingest.manuscript_excluded_scvs` | SCVs every figure leaves out of its counts: the 321 SCVs (319 variants) whose flag CvC later retracted, 233 of them in the batch 129 discordance project retraction. Run it before any figure script, because their SQL reads this view. |
| `01-clinvar-landscape.sql` | `clinvar_ingest.manuscript_figure1_variant_states_core(release, left_out)`, `clinvar_ingest.manuscript_figure1_variant_states(release)`, `clinvar_ingest.manuscript_figure1a_final_classifications(release)`, `clinvar_ingest.manuscript_figure1b_gene_rates(release)`, `clinvar_ingest.manuscript_figure1_callouts(release)`, `clinvar_ingest.manuscript_figure1_variant_states_view`, `clinvar_ingest.manuscript_figure1a_states_view`, `clinvar_ingest.manuscript_figure1a_conflict_types_view`, `clinvar_ingest.manuscript_figure1a_final_classifications_view`, `clinvar_ingest.manuscript_clinvar_landscape`, `clinvar_ingest.manuscript_figure1_callouts_view`, `clinvar_ingest.manuscript_figure1_all_flagged_variants_view`, `clinvar_ingest.manuscript_figure1_retracted_flag_scvs(release)`, `clinvar_ingest.manuscript_figure1_retracted_flag_scvs_view` | The state of ClinVar's pathogenicity-classified variants in one release, read from each variant's top ranked group, and the per-gene rate of medically significant conflicts in GenCC Definitive/Strong/Moderate genes. `generate_figure1.py` calls the table functions and draws both panels. |
| `02-submitter-landscape.sql` | `clinvar_ingest.manuscript_submitter_landscape` | Per-institution-type summary of ClinVar submitter organizations and their Germline Variant Pathogenicity Classification contributions. Shows submitter counts, SCV counts, and variant counts grouped by institution type (clinical testing, research, expert panel, etc.). |
| `03-flagged-scv-by-consequence.sql` | `clinvar_ingest.manuscript_cvc_vs_clinvar_consequence_bar_view`, `clinvar_ingest.manuscript_flag_source_combo_by_consequence_view`, `clinvar_ingest.manuscript_flagged_scv_by_consequence_view` | Molecular consequence of pathogenicity-assessed variants in ClinVar versus variants flagged through the CvC project, with flagged variant and SCV counts by flag source (ClinGen CvC, ClinGen non-CvC, NCBI) and their combinations. `generate_figure3.py` reads the first view, calculates the statistics and draws the figures. |
| `04-conflict-resolution-outcomes.sql` | `clinvar_ingest.manuscript_figure4_variant_outcomes(as_of_date)`, `clinvar_ingest.manuscript_figure4_variant_outcomes_view`, `clinvar_ingest.manuscript_figure4a_outcomes_view`, `clinvar_ingest.manuscript_figure4a_outcome_detail_view`, `clinvar_ingest.manuscript_figure4b_flows_view`, `clinvar_ingest.manuscript_figure4b_final_classifications_view`, `clinvar_ingest.manuscript_figure4b_conflict_combinations_view`, `clinvar_ingest.manuscript_figure4_rank_group_transitions_view` | One row per variant reviewed by CvC, with its outcome and the top ranked group's state before and after flagging, at the point of submission to ClinVar. `generate_figure4.py` calls the table function and draws both panels. |

## SCVs Left Out of Every Figure

`clinvar_ingest.manuscript_excluded_scvs` lists SCVs that no figure counts. Each figure's SQL anti-joins on the SCV accession, so every version is left out, along with every CvC flagging candidate submission and remove flagged submission for it. Neither the flag nor its removal counts in any figure or statistic. The `exclusion` column says which rule applies; an SCV that meets both gets the first.

- **Discordance project retraction** (set by the user on 2026-11-12). CvC submitted a remove flagged submission for the SCV in batch 129, annotated 2026-02-15 with the note "Discordance project retraction" and submitted 2026-02-20. There are 233 SCVs on 231 variants. Their original flags were submitted in batches 107 to 125 (2024-05-06 to 2025-09-30), all for the gene-disease relationship reason.
- **Retracted gene-disease relationship flag** (set by the user on 2026-11-09). CvC's most recent valid flagging candidate for the SCV gave the reason "P/LP classification for a variant in a gene with insufficient evidence for a gene-disease relationship", and CvC later submitted a remove flagged submission. 321 SCVs on 319 variants meet this rule: the 233 above, plus 88 more (87 retracted in batch 127 on 2025-12-18, 1 in batch 135 on 2026-08-04).

Together they leave out 321 SCVs on 319 variants. Other retracted flags are not in this list.

Figure 1 is the exception: it counts ClinVar submissions, not CvC work, and reads no CvC annotations, reviews or submissions. So these SCVs stay in it as ClinVar submissions, as they do in the All ClinVar baseline of Figure 3C. See [SCVs Whose Flag CvC Later Retracted](#scvs-whose-flag-cvc-later-retracted) for what leaving them out would change.

## Data Scope

All scripts operate on the **Germline Variant Pathogenicity Classification Submission Data** subset of ClinVar (`proposition_type = 'path'`). This excludes Somatic SCVs and other Germline SCVs that are not pathogenicity classifications (e.g., drug response, clinical impact).

## Dependencies

- **`clinvar_ingest` dataset** - Core ClinVar ingested and temporal tables
- **`clinvar_ingest.gencc_dsm_genes`** - GenCC gene list filtered to Definitive, Strong, and Moderate disease-gene validity classifications
- **`clinvar_ingest.clinvar_genes`** - ClinVar gene records with HGNC IDs, used to bridge `gencc_dsm_genes` (by `hgnc_id`) to `clinvar_single_gene_variations` (by `gene_id`)
- **`clinvar_ingest.clinvar_single_gene_variations`** - Variants mapped to a single gene (excludes multi-gene variants)

---

## Figure 1: ClinVar Landscape

Script `01-clinvar-landscape.sql` creates table functions and the views behind the sheet. `generate_figure1.py` calls the table functions and draws both panels. Figures are pasted into the sheet as static images, as Figures 3 and 4 are. Colors, type and sizes come from `figure_style.py`, as [STYLE.md](STYLE.md) assigns them to Figure 1. Panel A's breakdown bars are all `medsig`, the red of the slice they break down.

Figures and counts: [CvC Manuscript Figure 1 sheet](https://docs.google.com/spreadsheets/d/1-FDjXcju6jdWi05D0nvPKxj7f-xZQ80V4rPgLFKL3co/edit). The tab `About Figure 1` has the steps for refreshing the tables and re-pasting the images. Counts quoted below are for ClinVar release 2026-11-08, the latest loaded when the figure was last regenerated.

```bash
# Only when the SQL changes: deploy the table functions and views
bq query --project_id=clingen-dev --use_legacy_sql=false < 01-clinvar-landscape.sql

# Requires the bq CLI; PNGs also require Chrome.
python3 generate_figure1.py --out output/figure1

# Another release, or redraw from saved query results
python3 generate_figure1.py --as-of 2026-10-31 --out output/figure1-oct31
python3 generate_figure1.py --input output/figure1 --out output/figure1
```

| Output | Contents |
| --- | --- |
| `figure1A.svg`, `figure1A.png` | Panel A, with the medically significant conflicts as bars |
| `figure1B.svg`, `figure1B.png` | Panel B |
| `figure1a_states.csv`, `figure1a_conflict_types.csv` | The counts behind Panel A and its breakdown |
| `figure1a_final_classifications.csv` | One row per variant state, exact starting classifications and top rank, with variant and SCV counts |
| `figure1b_gene_rates.csv`, `figure1b_labeled_genes.csv` | One row per gene, and the labeled genes with why each is labeled |
| `figure1_callouts.csv` | The counts quoted as call-outs |
| `figure1_retracted_flag_scvs.csv` | One row per SCV whose flag CvC later retracted: where it sits in the release, its variant's state as counted, and that state if all 321 were left out |

### What the Figure Represents

Panel A asks: **what share of ClinVar's variants with a germline pathogenicity classification has one submission, concordant submissions or each kind of conflict?** Panel B asks: **across GenCC Definitive/Strong/Moderate genes, what percentage of a gene's variants is in medically significant conflict, compared with the number of pathogenicity SCVs in that gene?** Both are a snapshot of one release, counted in variants. No groups are compared, so there are no statistics.

ClinVar builds the aggregate from the highest ranked group of SCVs, so each variant is read from its top ranked group. Flagged SCVs (rank -3) do not contribute.

| Variant state | Rule, using the top ranked group | Variants | Share |
| --- | --- | ---: | ---: |
| 1 submission | One SCV | 3,490,066 | 78.3% |
| 2 or more concordant submissions | Two or more SCVs, one classification group | 650,948 | 14.6% |
| Confidence conflict | P + LP, or B + LB, and no other tier | 130,367 | 2.9% |
| VUS vs B/LB | VUS with B, LB or both | 152,875 | 3.4% |
| P/LP vs VUS/B/LB | P or LP with VUS, B, LB or any of them | 31,385 | 0.7% |
| **Total** | | **4,455,641** | |

| Medically significant conflict | Variants | Share of 31,385 |
| --- | ---: | ---: |
| LP vs VUS | 19,172 | 61.1% |
| P + LP vs VUS | 5,732 | 18.3% |
| P vs VUS | 5,170 | 16.5% |
| P/LP vs VUS vs B/LB | 934 | 3.0% |
| LP vs B/LB | 227 | 0.7% |
| P vs B/LB | 110 | 0.4% |
| P + LP vs B/LB | 40 | 0.1% |

Panel B plots 4,218 of the 4,311 genes in `gencc_dsm_genes`: those with at least one non-flagged P/LP SCV on a single-gene variant. They hold 3,165,169 variants and 30,918 of the 31,385 medically significant conflicts. Rates run from 0 to 14.29%, 1,210 genes have no such conflict, and 2,513 genes have 100 to 1,000 SCVs.

### How to Interpret It

- **1 submission means one SCV in the top ranked group.** 73,160 of these variants also have lower ranked SCVs, such as a single expert panel SCV above other submissions.
- **Lower ranked disagreements are left out of the conflict counts.** 10,730 variants have a medically significant disagreement across all their non-flagged SCVs but not in the top ranked group. 2,865 of them sit below an expert panel or practice guideline group, and 6,639 are also in the 73,160. Counting all SCVs would give 42,115 medically significant conflicts instead of 31,385. `all_scvs_mask` in `manuscript_figure1_variant_states_view` identifies them.
- **Counts are after flags in this release.** 2,739 variants in the figure have a flagged SCV and are read from their other SCVs.
- **A slash means either or both of its labels. A plus means both together.** P vs VUS is split from LP vs VUS and P + LP vs VUS instead of using a +/- grouping, in the same conflict types as Figure 4B.
- **Rates in small genes are unstable.** The two highest rates are ATP5MK (2 of 14 variants) and MICOS13 (3 of 34). The curved lower edge of Panel B is genes with exactly one conflict variant.
- **Panel B labels follow a rule.** BRCA1, BRCA2 and TP53 are labeled as notable genes, then the 3 genes with the most conflict variants (TTN, NF1, MYH7), the 3 highest rates among genes with at least 1,000 SCVs (ALPL, KCNJ11, BTD) and the 2 highest rates overall.
- **Column names keep the older wording.** In `manuscript_clinvar_landscape`, `clinsig_conflict` means a medically significant conflict.
- **Some classifications are counted together.** P includes pathogenic low penetrance (`p-lp`) and established risk allele (`era`). LP includes likely pathogenic low penetrance (`lp-lp`) and likely risk allele (`lra`). VUS includes VUS-high (`vus-h`), VUS-mid (`vus-m`), VUS-low (`vus-l`) and uncertain risk allele (`ura`). `classif_types` keeps the original codes. `p/lp` (8 SCVs) and `b/lb` (194 SCVs) are single SCVs submitted as both labels, so they count as both. Only [variation 32255](https://www.ncbi.nlm.nih.gov/clinvar/variation/32255/) is in a conflict because of this, counted as P + LP vs VUS.

### Excluded Variants

281 variants whose pathogenicity SCVs are all flagged have no aggregate, so they do not appear. `manuscript_figure1_all_flagged_variants_view` lists them with links to their ClinVar pages.

### SCVs Whose Flag CvC Later Retracted

Figure 1 counts ClinVar submissions, not CvC work. Every view behind it reads only ClinVar tables (`clinvar_scvs`, `clinvar_genes`, `clinvar_single_gene_variations`, `gencc_dsm_genes`) and no CvC annotations, reviews or submissions, so there is nothing for CvC's own work to anti-join. The 321 SCVs in `manuscript_excluded_scvs` (233 `Discordance project retraction`, 88 `Retracted gene-disease relationship flag`) are ClinVar submissions again once their flag is removed, so they stay in the figure as part of ClinVar, as in the All ClinVar baseline of Figure 3C. The user chose this on 2026-11-12. Both images say so in a footnote.

At release 2026-11-08, 320 of the 321 contribute (1 is flagged again), 283 of them in their variant's top ranked group, on 318 variants. Leaving all 321 out would change these counts and no others:

| Count | As counted | With the 321 left out |
| --- | ---: | ---: |
| Variants in Panel A | 4,455,641 | 4,455,542 |
| 1 submission | 3,490,066 | 3,490,032 |
| 2 or more concordant submissions | 650,948 | 650,916 |
| Confidence conflict | 130,367 | 130,343 |
| VUS vs B/LB | 152,875 | 152,874 |
| P/LP vs VUS/B/LB | 31,385 | 31,377 |
| LP vs VUS | 19,172 | 19,171 |
| P + LP vs VUS | 5,732 | 5,729 |
| P vs VUS | 5,170 | 5,166 |
| Medically significant across all SCVs | 42,115 | 42,105 |
| Of those, not in the top ranked group | 10,730 | 10,728 |
| One top SCV with lower ranked SCVs | 73,160 | 73,155 |
| Variants with a flagged SCV still in the figure | 2,739 | 2,738 |
| Panel B variants | 3,165,169 | 3,165,070 |
| Panel B pathogenicity SCVs | 5,460,430 | 5,460,110 |
| Panel B conflict variants | 30,918 | 30,910 |

Panel B keeps all 4,218 genes, the 1,210 at 0%, the 0 to 14.29% range and all 11 labels. Counts change in 26 genes, and the rate in 6 of them, by at most 0.08 points (FIG4, 1.28% to 1.20%).

`manuscript_figure1_retracted_flag_scvs_view` has one row per SCV, so analysts can check each one: `exclusion`, whether it is in the release and flagged, its rank and whether it is in the top ranked group, the variant's `variant_state` and `conflict_type` as counted, `variant_state_left_out` and `conflict_type_left_out` (NULL when the variant would leave the figure), `in_figure_1b` and the ClinVar link. It is the only Figure 1 object that reads CvC data. It calls `manuscript_figure1_variant_states_core` with the 321 accessions, the same logic the figure uses with an empty list.

### Refreshing the Data

The views are pinned to one release, so the sheet's tables match the images until the figure is moved on purpose. Row 1 of each figure tab says OUT OF DATE if its table moves to another release.

1. Run `00-excluded-scvs.sql` if it changed. In `01-clinvar-landscape.sql`, change the `DATE` literal in the four pinned views, and `FIGURE_RELEASE` in `generate_figure1.py`. Run the script with `bq query`.
2. In the sheet, choose **Data > Data connectors > Refresh options > Refresh all**. Viewers need BigQuery access to `clingen-dev` to refresh the connected tabs.
3. From this folder, run `python3 generate_figure1.py --out output/figure1`.
4. On each figure tab, delete the old image and choose **Insert > Image > Insert image over cells**. Use `figure1A.png` and `figure1B.png`.
5. Update the date in the row 1 formula of each figure tab, line 2 of the `About Figure 1` tab, the counts on that tab, row 2 and the labeled-gene counts on the figure tabs, and the counts in this section, including the retracted-flag table.

```sql
-- Figure 1A at its most granular
SELECT * FROM `clinvar_ingest.manuscript_figure1a_final_classifications_view`;

-- Figure 1B
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

Figure 3 compares the consequence distribution of all pathogenicity-assessed variants in ClinVar with variants flagged through the CvC project. NCBI and ClinGen non-CvC flags are excluded from the CvC bars.

Script `03-flagged-scv-by-consequence.sql` creates the result tables, the refresh procedure and the views behind the sheet. `generate_figure3.py` reads the chart view, calculates the statistics and draws both versions of the figure. Native Google Sheets charts can't draw forest plots or labeled confidence intervals, so the figures are pasted into the sheet as static images, as Figure 4's are.

Figures and counts: [CvC Manuscript Figure 3 sheet](https://docs.google.com/spreadsheets/d/17wr65aFoU9xVD0eluNfLxOzbxpJbAv7jYoG4Ir4POyY/edit). The tab `About Figure 3` has the steps for refreshing the tables and re-pasting the images. Counts quoted below are for ClinVar release 2026-10-24.

```bash
# Requires the bq CLI; PNGs also require Chrome.
python3 generate_figure3.py --out output/figure3

# Redraw from a saved query result
python3 generate_figure3.py --input output/figure3/consequence_counts.csv --out output/figure3
```

| Output | Contents |
| --- | --- |
| `figure3_bars.svg`, `figure3_bars.png` | Paired bars of the percentages beside a forest plot of the odds ratios |
| `figure3_stacked.svg`, `figure3_stacked.png` | Each group's whole consequence mix, above a table of each group's change from the baseline |
| `figure3_statistics.csv` | Per-group statistics, for all five groups and without `other` |
| `figure3_overall_tests.csv` | The overall chi-square tests, for all five groups and without `other` |
| `consequence_counts.csv` | The query result |

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
- **The groups overlap.** Red variants are also counted in blue. The odds ratios therefore compare red with all other ClinVar variants (blue minus red), which keeps the two groups separate. The change in points treats the All ClinVar percentages as a fixed baseline.
- **CvC variants are selected, not sampled.** CvC chooses what to review through its curation priorities, so a difference between bars describes what was flagged. It does not show that a consequence type causes flagging or submission errors. The p values share this limit, and variants in the same gene or curation list are not independent, so they may overstate certainty.
- **"Flag source" applies to the flagged bars only.** Variants flagged only by NCBI or ClinGen non-CvC are left out of red but stay in blue, as ClinVar variants. 14 variants with both CvC and NCBI flags count in red. All 142 ClinGen non-CvC SCVs carry the reason "Conflict with ClinGen Gene Dosage Map".
- **"Other" is mostly synonymous variants.** Of its 900,194 variants, 756,083 are synonymous and 137,491 have no MANE Select annotation, including all 49,464 copy number variants. Stop lost (1,194) and initiator codon (3,783) variants are also here, not in predicted LOF.
- **"Predicted LOF" comes from the consequence label alone.** It does not include additional evidence, such as whether the transcript escapes nonsense-mediated decay.
- **Each variant has one consequence.** Only the first term of the MANE Select label is used. A variant with several MANE Select rows, such as one in overlapping genes, is counted once in its most severe group. 42,664 variants have MANE Select rows with differing consequences.

### Statistics

Both versions of the figure compare the same counts, in two ways. The sheet's `Figure 3 statistics` tab calculates the same values with formulas, and also shows them without the `other` group.

| | Figure 3 tab (`figure3_bars`) | Figure 3 (stacked) tab (`figure3_stacked`) |
| --- | --- | --- |
| **Compares flagged variants with** | Not flagged variants (blue minus red) | The All ClinVar percentage, as a fixed baseline |
| **Size of the difference** | Odds ratio with a Wald 95% CI | Change in percentage points with a Wilson 95% CI, and the ratio to the baseline |
| **Per-group p value** | Two-sided Fisher's exact test | Two-sided exact binomial test |
| **Overall p value** | Chi-square test of independence | Chi-square goodness-of-fit test |

Per-group p values are Holm-adjusted across the groups.

| Group | All ClinVar | Flagged | Odds ratio (95% CI) | Change, points (95% CI) | Ratio to baseline |
| --- | ---: | ---: | ---: | ---: | ---: |
| predicted LOF | 7.45% | 17.71% | 2.68 (2.39-3.00) | +10.27 (+8.67 to +11.99) | 2.38 |
| missense | 56.19% | 68.28% | 1.68 (1.53-1.84) | +12.09 (+10.03 to +14.08) | 1.22 |
| inframe indels | 0.71% | 2.22% | 3.20 (2.38-4.30) | +1.51 (+0.96 to +2.25) | 3.15 |
| UTR/intronic | 15.36% | 6.41% | 0.38 (0.32-0.45) | -8.95 (-9.93 to -7.80) | 0.42 |
| other | 20.30% | 5.38% | 0.22 (0.18-0.27) | -14.92 (-15.82 to -13.85) | 0.26 |

All five per-group p values are below 0.001 in both tests. Overall, the test of independence gives a chi-square of 733.9 and the goodness-of-fit test 733.5, each with 4 degrees of freedom and p below 1e-150.

- **Read the size of the difference as well as the p value.** With counts this large, even small differences can reach p < 0.001.
- **An odds ratio is not a ratio of percentages.** For common groups the odds ratio looks larger: missense has an odds ratio of 1.68, but its share only rises from 56% to 68%, a ratio of 1.22.
- **The missense result depends on the `other` group.** Without `other`, missense is 72.16% of flagged variants and 70.50% of ClinVar (+1.66 points, 95% CI -0.39 to +3.62; odds ratio 1.08, 95% CI 0.98-1.20; Holm-adjusted p = 0.115), so it is no longer significant. The other groups stay below p = 0.001.

### Refreshing the Data

The table under each figure is a connector extract of `manuscript_cvc_vs_clinvar_consequence_bar_view`, and the `Figure 3 statistics` tab recalculates from the same counts, so both update on refresh. The figures are static images. Row 1 of each figure tab says when its image no longer matches the data.

After a new ClinVar release:

1. Update the BigQuery tables. Nothing in this repo or `clinvar-ingest-bq-tools` schedules this, so someone must run it:

   ```sql
   CALL `clinvar_ingest.refresh_flagged_scv_by_consequence`(NULL);
   ```

2. In the sheet, choose **Data > Data connectors > Refresh options > Refresh all**.
3. From this folder, run `python3 generate_figure3.py --out output/figure3`.
4. On each figure tab, delete the old image and choose **Insert > Image > Insert image over cells**. Use `figure3_bars.png` on the `Figure 3` tab and `figure3_stacked.png` on the `Figure 3 (stacked)` tab.
5. Update the release date in row 1 of each figure tab and line 2 of the `About Figure 3` tab, and the counts quoted on that tab.

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

Variant and SCV combination counts do not correlate directly. A variant shows a combination when two or more of its SCVs have different individual sources, even if no single SCV has more than one source. An SCV shows a combination only when multiple sources flagged that same SCV. Example: variant 2423950 has SCV003792454 flagged by NCBI and SCV003794881 flagged by ClinGen non-CvC. It counts as 1 ClinGen non-CvC + NCBI variant, while its SCVs count as 1 NCBI and 1 ClinGen non-CvC, with 0 ClinGen non-CvC + NCBI.

`manuscript_flag_source_combo_by_consequence_view` lists up to the first 5 SCV accessions or variation ids behind each `item_count` in `first_item_ids`, in order. Each view row is one combination of variation type, consequence group, count level and flag source.

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
