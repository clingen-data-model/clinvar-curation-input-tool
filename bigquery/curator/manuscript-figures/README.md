# Manuscript Figures

This folder contains SQL scripts that produce the datasets and supporting data for figures included in the forthcoming manuscript describing the ClinVar Curation project.

## Background

The ClinVar Curation project systematically identifies and addresses conflicting variant classifications in ClinVar, with the goal of improving the consistency and clinical utility of submitted interpretations. This manuscript documents the project's methodology, scope, and measurable impact on ClinVar's classification landscape.

Each script in this folder generates a dataset that underpins a specific figure or table in the manuscript. Scripts are numbered in the order they appear in the manuscript.

## Scripts

| Script | View | Description |
| --- | --- | --- |
| `00-excluded-scvs.sql` | `clinvar_ingest.manuscript_excluded_annotations`, `clinvar_ingest.manuscript_excluded_scvs` | CvC annotations every figure leaves out of its counts: the discordance project's flags and removals (batch 129 retraction) on 233 SCVs. Figures anti-join the annotations view on `annotation_id`; the SCV view is for notes and lists. Run it before any figure script, because their SQL reads these views. |
| `01-clinvar-landscape.sql` | `clinvar_ingest.manuscript_clinvar_landscape` | Per-gene summary of the ClinVar Germline Variant Pathogenicity Classification landscape for genes in the GenCC Definitive/Strong/Moderate (DSM) gene list. Produces total SCV and variant counts, clinically significant (P/LP) variant counts, and a breakdown of aggregate classification categories (concordant P/LP, P/LP vs B/LB, P/LP vs VUS, and three-way conflicts). |
| `02-submitter-landscape.sql` | `clinvar_ingest.manuscript_submitter_landscape` | Per-institution-type summary of ClinVar submitter organizations and their Germline Variant Pathogenicity Classification contributions. Shows submitter counts, SCV counts, and variant counts grouped by institution type (clinical testing, research, expert panel, etc.). |
| `03-flagged-scv-by-consequence.sql` | `clinvar_ingest.manuscript_cvc_vs_clinvar_consequence_bar_view`, `clinvar_ingest.manuscript_flag_source_combo_by_consequence_view`, `clinvar_ingest.manuscript_flagged_scv_by_consequence_view` | Molecular consequence of pathogenicity-assessed variants in ClinVar versus variants flagged through the CvC project, with flagged variant and SCV counts by flag source (ClinGen CvC, ClinGen non-CvC, NCBI) and their combinations. `generate_figure3.py` reads the first view, calculates the statistics and draws the figures. |
| `03ab-review-outcomes-and-reasons.sql` | `clinvar_ingest.manuscript_figure3ab_scv_outcomes(as_of_date)`, `clinvar_ingest.manuscript_figure3ab_scv_outcomes_view`, `clinvar_ingest.manuscript_figure3a_outcomes_view`, `clinvar_ingest.manuscript_figure3a_detail_view`, `clinvar_ingest.manuscript_figure3b_reasons_view`, `clinvar_ingest.manuscript_figure3ab_excluded_scvs_view` | One row per SCV reviewed by CvC, with its outcome, its reason if submitted, and its state in the release at the cutoff. `generate_figure3ab.py` calls the table function and draws Figures 3A and 3B. |
| `figure_style.py`, `STYLE.md` | none | The palette, type sizes, layout values and drawing helpers every generator imports. STYLE.md says what each color means and which colors each figure uses. Change a color there, never in a generator. |
| `04-conflict-resolution-outcomes.sql` | `clinvar_ingest.manuscript_figure4_variant_outcomes(as_of_date)`, `clinvar_ingest.manuscript_figure4_variant_outcomes_view`, `clinvar_ingest.manuscript_figure4a_outcomes_view`, `clinvar_ingest.manuscript_figure4a_outcome_detail_view`, `clinvar_ingest.manuscript_figure4b_flows_view`, `clinvar_ingest.manuscript_figure4b_final_classifications_view`, `clinvar_ingest.manuscript_figure4b_conflict_combinations_view`, `clinvar_ingest.manuscript_figure4_rank_group_transitions_view` | One row per variant reviewed by CvC, with its outcome and the top ranked group's state before and after flagging, at the point of submission to ClinVar. `generate_figure4.py` calls the table function and draws both panels. |
| `05-gdr-flags-by-domain.sql` | `clinvar_ingest.manuscript_clingen_gene_validity`, `clinvar_ingest.manuscript_figure5_flags(as_of_date)`, `clinvar_ingest.manuscript_figure5_flags_view`, `clinvar_ingest.manuscript_figure5_domain_level_view`, `clinvar_ingest.manuscript_figure5_gene_view`, `clinvar_ingest.manuscript_figure5_callouts_view`, `clinvar_ingest.manuscript_figure5_panel_domain_view` | One row per SCV that CvC submitted as a flagging candidate for insufficient gene-disease evidence, with its validity level, clinical domain, retraction status and state in ClinVar. `generate_figure5.py` calls the table function and draws the figure. |
| `06-conflict-resolution-reasons.sql` | `clinvar_ingest.manuscript_figure6_resolution_events(as_of_date)`, `clinvar_ingest.manuscript_figure6_resolution_events_view`, `clinvar_ingest.manuscript_figure6a_reason_totals_view`, `clinvar_ingest.manuscript_figure6b_monthly_view`, `clinvar_ingest.manuscript_figure6_granular_view`, `clinvar_ingest.manuscript_figure6_submitter_concentration_view` | One row per time a ClinVar conflict resolved, with the reason. Covers all of ClinVar, not only variants CvC reviewed. `generate_figure6.py` calls the table function and draws both figures as separate titled images. |

## Annotations Left Out of Every Figure

`clinvar_ingest.manuscript_excluded_annotations` lists CvC annotations that no figure counts. Each figure's SQL anti-joins on `annotation_id` wherever it reads CvC annotations, reviews or submissions, so only these annotations drop out and other CvC work on the same SCVs still counts. `clinvar_ingest.manuscript_excluded_scvs` has one row per affected SCV, for notes, call-outs and lists; don't anti-join figures on it.

- **Discordance project retraction** (set by the user on 2026-11-12). CvC submitted a remove flagged submission for 233 SCVs on 231 variants in batch 129, annotated 2026-02-15 with the note "Discordance project retraction" and submitted 2026-02-20. All are on genes in the discordancy gene list. For each SCV, every flagging candidate and every remove flagged submission annotated on or before that removal is left out, whatever its review status or batch: 597 annotations in all.
  - 237 withdrawn flags: the gene-disease relationship flags (submitted in batches 107 to 125), and one earlier flag on SCV002507280 with a gene evidence note.
  - The 233 batch 129 removals.
  - 124 removals approved in May 2025 (batches 120 and 121, note "The GDR needs to be re-curated by the ClinGen VCEP/GCEP") that were never submitted, and 3 archived duplicates of the batch 129 removal.
- **Still counted on those SCVs:** no change annotations, and anything annotated after the removal, such as the batch 135 re-flag of SCV002318480 (ACTC1) for insufficient supporting evidence.
- **Other retracted flags are not left out.** The user decided on 2026-11-12 that the 88 other retracted gene-disease relationship flags count as ordinary retracted flags: 87 on CAPN3, removed in batch 127 because the classification changed, and 1 on BAZ2B, removed in batch 135. Figures that count retractions say so in their own notes.

Until Figures 3A, 3B, 3C, 4 and 6 are regenerated, their sections below, images and sheets still describe the earlier rule, which left out 321 whole SCVs. Their deployed SQL now reads the 233-SCV view, so their connector tabs show neither rule exactly until each switches to the annotations view.

How each figure applies it:

| Figure | Effect |
| --- | --- |
| 1 | None. Figure 1 uses no CvC data. |
| 3A, 3B | Left out of the reviewed SCVs' decisions. `03ab-review-outcomes-and-reasons.sql` still anti-joins `manuscript_excluded_scvs` on `scv_id` and must switch to the annotations view. |
| 3C | Not counted as CvC flags. They stay in All ClinVar, because they are still ClinVar submissions. `03-flagged-scv-by-consequence.sql` must switch to the annotations view. |
| 4 | Treated as never reviewed. `04-conflict-resolution-outcomes.sql` must switch to the annotations view. |
| 5 | Left out of the submitted flags and retractions, by `annotation_id`. The footnote names the group, with counts read from `manuscript_excluded_scvs`. |
| 6 | Resolution events caused only by these flags are left out. Their branch must switch to the annotations view. |

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

## Figures 3A and 3B: CvC Reviews and Flagging Reasons

Figure 3A asks: **of the SCVs and variants CvC reviewed, how many did it submit to ClinVar as flagging candidates?** Figure 3B asks: **for the SCVs submitted, what reason did CvC give?** Both are cumulative counts of CvC's work, not a snapshot of what is flagged in ClinVar. The section below covers Figure 3C, which is that snapshot. Each panel is a separate image file on its own tab of the [Figure 3 sheet](https://docs.google.com/spreadsheets/d/17wr65aFoU9xVD0eluNfLxOzbxpJbAv7jYoG4Ir4POyY/edit). Each image has a title, row 3 of each figure tab states its question, and the `About Figure 3` tab lists the open questions with their choices and recommendations.

```bash
# Requires the bq CLI; PNGs also require Chrome.
python3 generate_figure3ab.py --out output/figure3

# A different cutoff
python3 generate_figure3ab.py --as-of 2026-05-27 --out output/figure3-may

# Redraw from a saved query result
python3 generate_figure3ab.py --input output/figure3/scv_outcomes.csv --out output/figure3
```

| Output | Contents |
| --- | --- |
| `figure3a.svg`, `figure3a.png` | Stacked bars of SCVs and variants by outcome |
| `figure3b.svg`, `figure3b.png` | Bars of submitted SCVs by reason |
| `figure3a_outcomes.csv`, `figure3b_reasons.csv` | The numbers behind each panel |
| `figure3ab_excluded_scvs.csv` | Reviewed SCVs left out of both figures, with the reason |
| `scv_outcomes.csv` | The query result, one row per SCV |

### Who Is Counted

Germline pathogenicity SCVs (`proposition_type = 'path'`) with a reviewed annotation in a finalized batch through the cutoff, each counted once by accession. Counts quoted here are through 2026-11-08: batches 101 to 138, submitted 2023-09-07 to 2026-10-30.

| Outcome | Rule | SCVs | Variants |
| --- | --- | ---: | ---: |
| Flagging candidate submitted | At least one valid flagging candidate submission | 6,060 (21.7%) | 4,843 (23.3%) |
| No change | No valid submission, and the final reviewed action is no change | 21,858 (78.3%) | 15,959 (76.7%) |
| Flagging candidate not submitted | No valid submission, and the final reviewed action is flagging candidate, approved as OK or Fixed | 0 | 0 |
| **Total** | | **27,918** | **20,802** |

The final reviewed action is the SCV's latest batch decision (its latest annotation in a batch) whose review status is not Archive. A variant takes the first of these outcomes that any of its SCVs has, so it is never counted twice. In Figure 3B, each SCV has the reason from its most recent valid submission, so the reasons add up to 6,060.

### How to Interpret Figures 3A and 3B

- **Submitted does not mean flagged now.** In release 2026-11-08, 2,397 of the 6,060 are flagged, 2,961 are not, and 702 are no longer in ClinVar. The 2,397 flagged SCVs are the 2,019 variants in Figure 3C.
- **Retracted flags are left out.** The 321 SCVs (319 variants) whose flag CvC later retracted are in neither figure, as in every manuscript figure (`00-excluded-scvs.sql`): 233 in the discordance project retraction and 88 other gene-disease relationship flags. They are listed on the `Figure 3A-B excluded SCVs` tab with `exclusion` = `Discordance project retraction` or `Retracted gene-disease relationship flag`. Leaving them out takes 321 SCVs from Submitted and from that reason in Figure 3B (684 to 363), and 280 variants from the total. 14 of their variants still count, as No change, through other SCVs.
- **Other later changes stay counted as submitted.** 11 SCVs (10 variants) were later retracted by CvC for other reasons, and 123 were later reviewed as no change. Filter on `later_retracted` and `final_action`.
- **Archived reviews are ignored.** An archived annotation was corrected before submission, so it is not a valid flagging candidate or no change decision. 73 SCVs (63 variants) whose only decisions are archived are left out, with `exclusion` = `Only archived reviews (corrected before submission)`. 36 of them are SCVs deleted from ClinVar before CvC's submission; on 2026-11-11 their review status was changed from OK to Archive (backup `clinvar_curator.cvc_clinvar_reviews_backup_20261111_archive36` and `_archive3`).
- **Flagging candidate not submitted should be empty.** An approved flagging candidate that is missing from its batch's submission is an issue to raise with the CvC team. Through 2026-11-08 there are none, and Figure 3A drops the segment and its legend entry when it is empty. On 2026-11-12, SCV001251707 (batch 114) was changed to No Change in the source annotation sheet, and SCV000366772 (batch 102) and SCV001334605 (batch 114) were changed from Fixed to Archive (backup `clinvar_curator.cvc_clinvar_reviews_backup_20261112_archive2`). The 105 approved candidates from batches 109 and 129 that were never submitted were returned to review on 2026-11-11 (`clinvar_curator.cvc_detach_20261111_annotations`) and went into batch 139, finalized 2026-11-12, where 84 were submitted validly. Batch 139 is after this cutoff, so they are not in these counts. Filter on `not_submitted_detail`.
- **40 reviewed SCVs are excluded** because they are not germline pathogenicity SCVs (10 submitted, 30 no change). They appear in neither figure, and are listed with links on the `Figure 3A-B excluded SCVs` tab.
- **The cutoff leaves out batch 139.** It was finalized 2026-11-12, after release 2026-11-08, so its flags cannot appear in that release. Batch 138 (submitted 2026-10-30) is included, giving 4,843 variants with a flagging candidate submitted, the same number Figure 4 shows.
- **CvC variants are selected, not sampled.** CvC chooses what to review through its curation priorities, so 21.7% is the share of CvC's reviews that were submitted. It is not an estimate of how many ClinVar submissions are incorrect.

### Refreshing Figures 3A and 3B

The tables under the figures are connector extracts and update on refresh. The figures and typed counts do not.

1. To move to a new date, change the `DATE` literal in `manuscript_figure3ab_scv_outcomes_view` and run `bq query --project_id=clingen-dev --use_legacy_sql=false < 03ab-review-outcomes-and-reasons.sql`.
2. In the sheet, choose **Data > Data connectors > Refresh options > Refresh all**.
3. Run `python3 generate_figure3ab.py --as-of YYYY-MM-DD --out output/figure3`.
4. On each figure tab, delete the old image and choose **Insert > Image > Insert image over cells**. Use `figure3a.png` on the `Figure 3A` tab and `figure3b.png` on the `Figure 3B` tab.
5. Update the typed dates and counts in rows 1 and 2 of those tabs, row 2 of the `Figure 3A-B excluded SCVs` tab, the Figures 3A and 3B rows and the open questions on the `About Figure 3` tab, and this section.

---

## Figure 3C: Variants by Molecular Consequence

This section covers Figure 3C of the manuscript draft.

Figure 3C compares the consequence distribution of all pathogenicity-assessed variants in ClinVar with variants flagged through the CvC project. NCBI and ClinGen non-CvC flags are excluded from the CvC bars.

Script `03-flagged-scv-by-consequence.sql` creates the result tables, the refresh procedure and the views behind the sheet. `generate_figure3.py` reads the chart view, calculates the statistics and draws both versions of the figure. Native Google Sheets charts can't draw forest plots or labeled confidence intervals, so the figures are pasted into the sheet as static images, as Figure 4's are.

Figures and counts: [CvC Manuscript Figure 3 sheet](https://docs.google.com/spreadsheets/d/17wr65aFoU9xVD0eluNfLxOzbxpJbAv7jYoG4Ir4POyY/edit). The tab `About Figure 3` has the steps for refreshing the tables and re-pasting the images. Counts quoted below are for ClinVar release 2026-11-08.

```bash
# Requires the bq CLI; PNGs also require Chrome.
python3 generate_figure3.py --out output/figure3

# Redraw from a saved query result
python3 generate_figure3.py --input output/figure3/consequence_counts.csv --out output/figure3
```

| Output | Contents |
| --- | --- |
| `figure3_stacked.svg`, `figure3_stacked.png` | Figure 3C: each group's whole consequence mix, with each consequence group's change from the baseline (points, 95% CI) to the right and a legend beneath. Ratios and per-group p values are in `figure3_statistics.csv` and on the `Figure 3C statistics` tab. On 2026-11-09 the user chose this version as Figure 3C, so the paired-bar version (`figure3_bars`) is no longer drawn. |
| `figure3_statistics.csv` | Per-group statistics, for all five groups and without `other` |
| `figure3_overall_tests.csv` | The overall chi-square tests, for all five groups and without `other` |
| `consequence_counts.csv` | The query result |

### What the Figure Represents

Figure 3C asks: **do the variants currently flagged through CvC have a different mix of molecular consequences than ClinVar's pathogenicity-assessed variants overall?** It is a snapshot of one ClinVar release, counted in variants and shown as percentages, because the two groups differ about 2,000-fold in size.

| | All ClinVar variants (upper bar) | CvC-flagged variants (lower bar) |
| --- | --- | --- |
| **Who is counted** | Every variant with at least one germline pathogenicity SCV (`proposition_type = 'path'`), of any variation type, flagged or not | The subset of those variants with at least one SCV that is flagged in this release, carries a ClinGen flag comment, and was submitted by CvC as a `flagging candidate` on or before the release |
| **Total (n)** | 4,455,922 | 2,019 |
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

- **Currently flagged, not everything CvC requested.** Through this release CvC submitted 6,106 SCV accessions as flagging candidates, not counting the 321 left-out retracted flags (233 discordance project, 88 other gene-disease relationship). 5,367 are still in ClinVar and 5,358 of those are pathogenicity SCVs. Of those, 2,397 are flagged now and 2,961 are not. One of the 321 left-out SCVs, SCV004105932 (retracted in batch 135, not part of the discordance project), is still flagged; it counts in All ClinVar as a flagged SCV with no CvC source. This figure does not explain why an SCV is not flagged. Four CvC-flagged SCVs are not pathogenicity SCVs and are excluded.
- **The groups overlap.** CvC-flagged variants are also counted in All ClinVar. The odds ratios therefore compare flagged variants with all other ClinVar variants (All ClinVar minus flagged), which keeps the two groups separate. The change in points treats the All ClinVar percentages as a fixed baseline.
- **CvC variants are selected, not sampled.** CvC chooses what to review through its curation priorities, so a difference between bars describes what was flagged. It does not show that a consequence type causes flagging or submission errors. The p values share this limit, and variants in the same gene or curation list are not independent, so they may overstate certainty.
- **"Flag source" applies to the flagged bars only.** Variants flagged only by NCBI or ClinGen non-CvC are left out of the CvC-flagged bar but stay in All ClinVar. 14 variants with both CvC and NCBI flags count as CvC-flagged. All 142 ClinGen non-CvC SCVs carry the reason "Conflict with ClinGen Gene Dosage Map".
- **"Other" is mostly synonymous variants.** Of its 904,772 variants, 760,193 are synonymous and 137,939 have no MANE Select annotation, including all 49,555 copy number variants. Stop lost (1,197) and initiator codon (3,794) variants are also here, not in predicted LOF.
- **"Predicted LOF" comes from the consequence label alone.** It does not include additional evidence, such as whether the transcript escapes nonsense-mediated decay.
- **Each variant has one consequence.** Only the first term of the MANE Select label is used. A variant with several MANE Select rows, such as one in overlapping genes, is counted once in its most severe group. 42,891 variants have MANE Select rows with differing consequences.

### Statistics

Figure 3C compares the flagged percentages with the All ClinVar baseline. The odds ratios belonged to the dropped paired-bar version and are still in `figure3_statistics.csv`. The sheet's `Figure 3C statistics` tab calculates the same values with formulas, and also shows them without the `other` group.

| | Odds ratios (statistics only) | Figure 3C (`figure3_stacked`) |
| --- | --- | --- |
| **Compares flagged variants with** | Not flagged variants (All ClinVar minus flagged) | The All ClinVar percentage, as a fixed baseline |
| **Size of the difference** | Odds ratio with a Wald 95% CI | Change in percentage points with a Wilson 95% CI, and the ratio to the baseline |
| **Per-group p value** | Two-sided Fisher's exact test | Two-sided exact binomial test |
| **Overall p value** | Chi-square test of independence | Chi-square goodness-of-fit test |

Per-group p values are Holm-adjusted across the groups.

| Group | All ClinVar | Flagged | Odds ratio (95% CI) | Change, points (95% CI) | Ratio to baseline |
| --- | ---: | ---: | ---: | ---: | ---: |
| predicted LOF | 7.44% | 17.73% | 2.68 (2.39-3.01) | +10.29 (+8.69 to +12.02) | 2.38 |
| missense | 56.24% | 68.20% | 1.67 (1.52-1.83) | +11.96 (+9.90 to +13.96) | 1.21 |
| inframe indels | 0.70% | 2.23% | 3.22 (2.40-4.33) | +1.53 (+0.97 to +2.27) | 3.17 |
| UTR/intronic | 15.31% | 6.44% | 0.38 (0.32-0.45) | -8.87 (-9.86 to -7.72) | 0.42 |
| other | 20.30% | 5.40% | 0.22 (0.18-0.27) | -14.91 (-15.81 to -13.83) | 0.27 |

All five per-group p values are below 0.001 in both tests. Overall, the test of independence gives a chi-square of 730.5 and the goodness-of-fit test 730.1, each with 4 degrees of freedom and p below 1e-150.

- **Read the size of the difference as well as the p value.** With counts this large, even small differences can reach p < 0.001.
- **An odds ratio is not a ratio of percentages.** For common groups the odds ratio looks larger: missense has an odds ratio of 1.67, but its share only rises from 56% to 68%, a ratio of 1.21.
- **The missense result depends on the `other` group.** Without `other`, missense is 72.09% of flagged variants and 70.57% of ClinVar (+1.53 points, 95% CI -0.53 to +3.49; odds ratio 1.08, 95% CI 0.98-1.19; Holm-adjusted p = 0.145), so it is no longer significant. The other groups stay below p = 0.001.

### Refreshing the Data

The table under each figure is a connector extract of `manuscript_cvc_vs_clinvar_consequence_bar_view`, and the `Figure 3C statistics` tab recalculates from the same counts, so both update on refresh. The figures are static images. Row 1 of each figure tab says when its image no longer matches the data.

After a new ClinVar release:

1. Update the BigQuery tables. Nothing in this repo or `clinvar-ingest-bq-tools` schedules this, so someone must run it:

   ```sql
   CALL `clinvar_ingest.refresh_flagged_scv_by_consequence`(NULL);
   ```

2. In the sheet, choose **Data > Data connectors > Refresh options > Refresh all**.
3. From this folder, run `python3 generate_figure3.py --out output/figure3`.
4. On each figure tab, delete the old image and choose **Insert > Image > Insert image over cells**. Use `figure3_stacked.png` on the `Figure 3C (stacked)` tab.
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

-- Figure 3C bar chart
SELECT * FROM `clinvar_ingest.manuscript_cvc_vs_clinvar_consequence_bar_view`;

-- Exact flag source combinations (count_level = 'scv' or 'variant')
SELECT * FROM `clinvar_ingest.manuscript_flag_source_combo_by_consequence_view`;

-- Counts by variation type and consequence group
SELECT * FROM `clinvar_ingest.manuscript_flagged_scv_by_consequence_view`;
```

---

## Figure 4: Outcomes of SCV Annotations

Script `04-conflict-resolution-outcomes.sql` creates a table function that returns one row per reviewed variant, and the views behind the sheet. `generate_figure4.py` calls the table function and draws each panel as its own titled image, using the shared palette, type and sizes in `figure_style.py` (see [STYLE.md](STYLE.md)). Google Sheets has no Sankey chart, so the figures are pasted into the sheet as static images.

Figures and counts: [CvC Manuscript Figure 4 sheet](https://docs.google.com/spreadsheets/d/1qx6_90ZHtcu_xlVq0zU1DjkSnk0tHFJDA-GJMcvvkos/edit). The tab `About Figure 4` has the steps for refreshing the tables and re-pasting the images. Counts quoted below are for batches through 2026-11-08, the latest ClinVar release.

```bash
# Only when the SQL changes: deploy the excluded SCVs view, then the table function and views
bq query --project_id=clingen-dev --use_legacy_sql=false < 00-excluded-scvs.sql
bq query --project_id=clingen-dev --use_legacy_sql=false < 04-conflict-resolution-outcomes.sql

# All batches. Requires the bq CLI; PNGs also require Chrome.
python3 generate_figure4.py --out figure4-output

# Limit to batches released by a date
python3 generate_figure4.py --as-of 2026-05-31 --out figure4-may2026
```

| Output | Contents |
| --- | --- |
| `figure4a.svg`, `figure4b.svg` | Each panel, with its title. Panel B is one Sankey at one scale: medically significant conflicts are the upper group of starting conflicts, non-medically significant (VUS vs B/LB) conflicts the lower group, and both flow into the same results |
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
| Classification removed | `non-conflict removed` | No conflict, and no contributing SCVs are left |
| Flagged, not resolved | `other conflict modified` | Top group flagged, and the conflict remains at a level that is not reduced |
| | `non-conflict modified` | Top group flagged, no conflict before or after |
| | `non-conflict, classification changed at lower rank` | Top group fully flagged, and a lower group with a different tier takes over |
| | `conflict exposed at lower rank` | Top group fully flagged, and a lower group in conflict takes over |
| | `conflict, top rank not flagged` | Only lower groups flagged, and the top group is in conflict |
| | `non-conflict, top rank not flagged` | Only lower groups flagged, and the top group is not in conflict |
| No change | `no flagging candidate submitted` | Reviewed, with no valid flagging candidate in a batch |

The denominator is distinct variants with a batch decision on a path SCV.

### Who Is Counted

- **321 SCVs are left out of every count.** These are the SCVs in `clinvar_ingest.manuscript_excluded_scvs` (`00-excluded-scvs.sql`) whose flag CvC later retracted: 233 in the discordance project retraction (batch 129) and 88 other gene-disease relationship flags. Every read of CvC reviews and submissions anti-joins the view on `scv_id`, so neither their flagging candidate submissions nor their remove flagged submissions count, and a variant reviewed only through them is not counted. Where they are in ClinVar on a batch release, they still count as unflagged contributing SCVs, because they are ClinVar submissions.
- **A batch's decision on an SCV is its latest annotation in that batch.** Superseded annotations in the same batch don't count, and a submitted flagging candidate counts only when the batch's latest annotation on that SCV is still a flagging candidate.
- **Archive reviews never count.** They were corrected before submission, so they are not a flagging candidate or a no change decision.

At 2026-11-08 the last two rules leave out 41 variants whose only batch decisions are Archive reviews, all of which were No change, and move 3 variants to No change: 2 from "Flagged, not resolved" and 1 from "Classification removed". Each of the 3 had a submitted flagging candidate that a later no change annotation in the same batch superseded.

### How to Interpret It

- **Direction describes what CvC flagged.** CvC selects outlier submissions, so a flow toward P/LP means VUS or B/LB outliers were flagged. It does not show which classification is correct.
- **Panel B reads the top ranked group only.** `lower_rank_conflict_resolved` and `rank_group_transitions.csv` report conflicts resolved in lower groups, including when the aggregate does not change.
- **A slash means either or both of its labels.** Panel B splits P vs LP in every two-tier starting conflict. B/LB in those node names means B, LB or both, and P/LP vs VUS vs B/LB groups every three-tier conflict. `figure4b_conflict_combinations.csv` has every combination, with related labels such as VUS-high counted with VUS.
- **P/LP after flagging means P, LP or both.** Of the 2,953 medically significant conflicts that move to P/LP, 2,016 are left with both P and LP, 554 with only P and 383 with only LP.
- **The most granular counts are in one view.** `clinvar_ingest.manuscript_figure4b_final_classifications_view` has one row for each `classification_to_start` and result after flagging, shown as a table under the Sankey in the sheet. For example, of the P + LP vs VUS variants, 1,959 ended as P + LP and 3 as VUS. Variants that stayed in conflict are not in this view. `conflict_combination` and `after_classif_group` have the same labels per variant. Its `flagged_scvs` column counts the flagging candidates of the variant's reported batch in the top ranked group, and in any lower group down to the one that takes over.
- **Variants flagged in several batches appear once.** 269 variants are in this group. Each batch is evaluated on its own flags, and the variant keeps its strongest outcome. An earlier flag that ClinVar has applied is rank -3 and already out of the batch release. An earlier flag that it has not applied still counts as a contributing SCV.
- **Retracted flags are still counted.** The figure reflects the point of submission, so 8 variants with another flag that was later retracted stay in their outcome: 5 Conflict resolved, 2 Conflict reduced and 1 "Flagged, not resolved". 7 of them are in Panel B. `any_flag_retracted` identifies these variants. The retracted flags of the 321 left-out SCVs are not among them.
- **"Flagged, not resolved" includes lower ranked flags.** For 471 of the 791 variants, only lower ranked groups were flagged, so the top ranked group did not change: 115 are in conflict and 356 are not. `outcome_detail` identifies them as `conflict, top rank not flagged` and `non-conflict, top rank not flagged`. They are not in Panel B. None of them is in the retracted group.
- **"Flagged, not resolved" is the rest of the flagged variants.** A flagging candidate was submitted, but the conflict was not resolved or reduced and a classification remains. Of its 791 variants, 691 keep the same state (the 471 above, and 220 whose top ranked group lost some SCVs), 96 three-tier conflicts narrow to two tiers but stay medically significant (92 to P/LP vs VUS, 4 to P/LP vs B/LB), and 4 non-conflicts change tier when a lower group takes over.
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

## Figure 5: CvC Flags in Genes with Insufficient Gene-Disease Evidence

Script `05-gdr-flags-by-domain.sql` creates a copy of the ClinGen gene-disease validity export, a table function that returns one row per flag, and the views behind the sheet. `generate_figure5.py` calls the table function and draws the figure, which replaces the draft's donut chart. It is pasted into the sheet as a static image, like Figures 3 and 4.

Figure and counts: [CvC Manuscript Figure 5 sheet](https://docs.google.com/spreadsheets/d/1nWyrtCqaoaXcYWC1gyfAjuFaukn55zdKSYiEioncApk/edit). The tab `About Figure 5` has every choice and the steps for refreshing the data and re-pasting the image. Counts quoted below are for batches through 2026-11-08 and ClinVar release 2026-11-08. The ClinGen export has no date; its latest evaluation date is 2026-02-05.

```bash
# Only when the SQL changes: deploy the objects, after 00-excluded-scvs.sql
bq query --project_id=clingen-dev --use_legacy_sql=false < 00-excluded-scvs.sql
bq query --project_id=clingen-dev --use_legacy_sql=false < 05-gdr-flags-by-domain.sql

# On the first deploy, or to load a newer export of the ClinGen tab
bq query --project_id=clingen-dev --use_legacy_sql=false 'CALL `clinvar_ingest.refresh_manuscript_clingen_gene_validity`()'

# All batches. Requires the bq CLI; PNGs also require Chrome.
python3 generate_figure5.py --out output/figure5

# Limit to batches released by a date, or redraw from a saved query result
# (--input also reads excluded.csv from the same folder)
python3 generate_figure5.py --as-of 2026-05-31 --out output/figure5-may2026
python3 generate_figure5.py --input output/figure5/flags.csv --out output/figure5
```

| Output | Contents |
| --- | --- |
| `figure5.svg`, `figure5.png` | One bar per clinical domain, stacked by validity level, with its title inside the image |
| `figure5_domain_level.csv` | One row per domain and level: SCVs, variants and genes in the figure, and the flags left out |
| `figure5_genes.csv` | The same counts per gene |
| `flags.csv` | The query result |
| `excluded.csv` | Counts by group from `manuscript_excluded_scvs`, for the footnote |

### What the Figure Represents

Figure 5 asks: **in which clinical domains, and at what gene-disease validity level, are the SCVs that CvC has flagged for insufficient gene-disease evidence?** It is a snapshot of one ClinVar release, counted in SCVs.

### Choices Made

| Decision | Choice | Alternatives considered | Effect |
| --- | --- | --- | --- |
| Chart | Bars by clinical domain, stacked by level, following the suggestion in the draft's comments | Bars by level only; level and domain panels together | Focuses on flagging and needs a domain for each flag |
| Time basis | Snapshot of one release, as in Figure 3 | Point of submission, as in Figure 4 | Shows what is flagged in ClinVar now, not everything CvC requested |
| Who is counted | Flags CvC has not retracted that are flagged in ClinVar: 153 | All not retracted: 363. Not retracted, on genes with no Moderate or higher relationship: 185. All 363, split by state | 363 would be 42% CAPN3, BRIP1, USH1C and PCDH15, none of them flagged now |
| Discordance project | Its flags and removals on 233 SCVs are left out, as in every figure | Counted as retracted flags | They were withdrawn as a group and are not part of CvC's flagging results |
| Other retracted flags | Kept in the counts but left out of the bars: 88 | Counted, shown as a lighter segment or in the same bars | Counting them in the bars would overstate flags on genes later judged out of scope |
| Review statuses | Archive reviews are ignored, and each batch counts only its latest annotation of an SCV | Every annotation | Archive reviews were corrected before submission. No flag with this reason was Archive or superseded, so this changes no count |
| No change | Left out | Shown as its own bar, as in the donut | Figure 5 no longer shows a share reviewed; see below |
| Validity level | The curator's note, then ClinGen when the note has none | ClinGen only; the note only | Reflects the reason given for the flag, even if ClinGen has changed since |
| ClinGen data | The export in the `Copy of Table 1` tab of the older figures sheet | A new download from ClinGen | Matches what the team used. It is held in a table, so editing that sheet can't change the figure unnoticed |
| Clinical domain | Drafted from each relationship's expert panel, and still to be confirmed | A mapping from ClinGen or the team | ClinGen's export has no domain column |
| Unit | SCVs, with variants and genes in the table | Variants | Flags are placed on SCVs, and the draft's figure counted SCVs |
| Statistics | None | Tests between domains | The figure describes counts and does not compare groups |
| Domains shown | All 16, including those with 0 | Only domains with flags | Hereditary Cancer, RASopathy, Rheumatologic Autoimmune Disease, Skeletal Disorders and Somatic Cancer show 0 |

### How to Interpret It

- **Only flags in ClinVar on this release are counted.** CvC submitted 451 flags with this reason, on 429 variants in 115 genes, not counting the discordance project. 153 are in the figure, on 147 variants in 83 genes. `shown_in_figure` identifies them, and all 153 carry a ClinGen flag comment on this release. No submitted flag with this reason was on a non-pathogenicity SCV.
- **The discordance project's flags and removals are left out**, as in every figure (`00-excluded-scvs.sql`): 233 SCVs whose gene-disease flag CvC withdrew in batch 129. The figure's footnote names the group, and `manuscript_figure5_callouts_view` reads its count from `manuscript_excluded_scvs`.
- **88 other flags were retracted, and they stay out of the bars.** 87 are on CAPN3, removed in batch 127 because the gene-disease classification changed, and 1 is on BAZ2B. `flag_status` and `retraction_kind` identify them. The BAZ2B removal, [SCV004105932](https://www.ncbi.nlm.nih.gov/clinvar/variation/2505364/), was sent in batch 135 alongside new flags, and ClinVar hasn't applied it, so the SCV is still flagged on this release. It is not counted; a removal-only resubmission is in progress.
- **Archive reviews and superseded annotations don't count.** Each batch counts only its latest annotation of an SCV, and Archive reviews were corrected before submission. No counted flag was Archive or superseded, and every counted flag was submitted.
- **210 flags were not retracted but are not flagged in ClinVar, and they stay out of the bars.** 164 are on a newer SCV version, so a resubmission removed the flag. 33 are no longer in the release. 13 are on the same SCV version but not flagged. 6 of those come from batches submitted on 2026-09-09 (4) and 2026-10-30 (2), 60 days or less before this release, so ClinVar may still be processing them. `clinvar_state` identifies them. 152 of the 210 are on CAPN3, BRIP1, USH1C and PCDH15.
- **12 SCVs in the figure are on genes with a Moderate or higher relationship**, which the draft's Sources section says this effort left out: ALG8 (5), GLIS2 (2), CD164 (2), ZNF423, IL10 and TTN. They are kept because they are flagged in ClinVar. `gene_has_moderate_or_higher` identifies them. The export is later than most of these flags, so a gene's level may have changed after it was flagged.
- **The level is the reason given when the flag was made.** 147 SCVs in the figure take it from the curator's note and 4 from ClinGen. 2 have no level, because the note gives none and the gene doesn't have just one low-evidence level: IL10 and TTN, shown as Not recorded. For 10 SCVs, on ALG8, GLIS2, CD164 and ZNF423, the note's level isn't in the export for that gene. `level_source` and `note_level_in_clingen` identify these.
- **The domain mapping is a draft.** 23 SCVs in the figure come from panels marked `needs_review` in `manuscript_figure5_panel_domain_view`: Motile Ciliopathy (12, Pulmonary), Syndromic Disorders (10, Neurodevelopmental Disorders) and Monogenic Diabetes (1, Other). General, Prenatal, Neurovascular, Craniofacial Malformations and Monogenic Autoinflammatory Diseases are marked too but have no SCVs in the figure. Changing the mapping can move bars.
- **Each flag has one domain.** It comes from a relationship at the flag's level, then another low-evidence relationship, then any relationship, and the most recent evaluation wins. `domain_source` identifies these: 12 SCVs in the figure don't come from a relationship at the flag's level. No SCV in the figure has more than one domain in that set. One flag outside the figure, in NARS2, could fall in either Hearing Loss or Inborn Errors of Metabolism; `all_domains` shows that.
- **These are counts, not rates.** A taller bar can reflect how much of that domain CvC reviewed and how many low-evidence relationships it has. CvC chooses what it reviews, so its variants are selected, not sampled. A difference between bars describes what was flagged. It does not show that a domain has more errors.

### What Changed from the Draft's Donut

The donut's counts were typed by hand from the May 2026 data capture, so they can't be rerun. It shows No change 584, Limited 567, Disputed 134 and Refuted 23. Counts below are for batches through 2026-11-08, without the discordance project's annotations, Archive reviews or superseded annotations.

- **CvC's flags with this reason are 451:** Limited 382, Refuted 39, Disputed 17 and no level in the note 13, by the level named in the curator's note. Every one was submitted.
- **Disputed and Refuted may be swapped in the donut.** It has more Disputed than Refuted, but the notes have more Refuted than Disputed. ClinGen agrees with the notes for the largest genes: BRIP1 (31, Refuted) and MED25 (5, Disputed).
- **The draft's 1,308 is not a count of flags.** Its flag count included the discordance project's flags.
- **584 no change is a subset.** 6,496 SCVs have a latest no change annotation that mentions the discordance project, multiple disease assertions or the gene-disease relationship. 6,021 of them are on genes with a Moderate or higher relationship in the export, and 475 are not.

### Refreshing the Data

The table under the figure is a connector extract of `manuscript_figure5_domain_level_view`. The views cover all batches, so new batches appear on the next connector refresh. The image and typed counts do not update themselves.

1. If `00-excluded-scvs.sql` or `05-gdr-flags-by-domain.sql` changed, deploy them, in that order. Then, in the sheet, choose **Data > Data connectors > Refresh options > Refresh all**.
2. From this folder, run `python3 generate_figure5.py --out output/figure5`.
3. On the `Figure 5` tab, delete the old image and choose **Insert > Image > Insert image over cells** with `figure5.png`.
4. Update the cutoff and counts on the `About Figure 5` and `Figure 5` tabs, checking them against `manuscript_figure5_callouts_view`, and in this section. The call-out view names four genes directly, so update those if the largest genes change.

---

## Figure 6: Reasons Conflicts are Resolved

Script `06-conflict-resolution-reasons.sql` creates a table function that returns one row per time a conflict resolved, and the views behind the sheet. `generate_figure6.py` calls the table function and writes Figure 6A and Figure 6B as separate titled images, which are pasted into the sheet as static images.

Figures and counts: [CvC Manuscript Figure 6 sheet](https://docs.google.com/spreadsheets/d/1hx0aX859RjFrbtwWuIc7t4s1TkQd8wWhKOuQUU839bQ/edit). The tab `About Figure 6` has the steps for refreshing the tables and replacing the images. Counts quoted below are for monthly releases 2023-08 through 2026-10 (release 2026-10-04).

```bash
# First pick up new releases. Nothing schedules this, and it replaces the shared
# monthly conflict tables. Run it from clinvar-ingest-bq-tools.
scripts/conflict-resolution-analysis/00-run-all-analytics.sh --no-gcloud-update

# Only when the SQL changes: deploy the table function and views
bq query --project_id=clingen-dev --use_legacy_sql=false < 06-conflict-resolution-reasons.sql

# All releases. Requires the bq CLI; PNGs also require Chrome.
python3 generate_figure6.py --out output/figure6

# Limit to releases through a date
python3 generate_figure6.py --as-of 2026-06-06 --out output/figure6-jun2026

# Redraw from a saved query result
python3 generate_figure6.py --input output/figure6/resolution_events.csv --out output/figure6
```

### What the Figure Represents

Why do conflicts in ClinVar stop being conflicts, and how often is a flag through CvC the reason? Each resolution is counted once, in the monthly release where the conflict stopped, with one reason. The series compares the first ClinVar release of each month with the release before it, among germline pathogenicity SCVs, reading the conflict from the variant's top ranked group.

| Reason | All conflicts | Medically significant | Non-medically significant |
| --- | --- | --- | --- |
| Reclassified | 8,086 (42.2%) | 3,138 (38.9%) | 4,948 (44.7%) |
| Rank lowered | 3,668 (19.2%) | 659 (8.2%) | 3,009 (27.2%) |
| Removed | 3,003 (15.7%) | 742 (9.2%) | 2,261 (20.4%) |
| Flagged through CvC | 2,368 (12.4%) | 2,291 (28.4%) | 77 (0.7%) |
| Expert panel added | 1,740 (9.1%) | 1,026 (12.7%) | 714 (6.4%) |
| 1 star added to 0 star conflict | 141 (0.7%) | 117 (1.4%) | 24 (0.2%) |
| Flagged outside CvC | 87 (0.5%) | 53 (0.7%) | 34 (0.3%) |
| Other | 48 (0.3%) | 43 (0.5%) | 5 (0.0%) |
| **Total** | **19,141** | **8,069** | **11,072** |

The 19,141 resolutions cover 18,916 variants, because a variant that resolves twice counts twice.

10 resolutions caused only by flags CvC later retracted are left out, along with the rest of the 321 SCVs whose gene-disease relationship flag CvC retracted (`00-excluded-scvs.sql`). Those SCVs also don't count as CvC flagging candidates in `cvc_candidate_before`.

### Outputs

| File | Contents |
| --- | --- |
| `figure6a.svg`, `figure6a.png` | Figure 6A, totals by reason and conflict type |
| `figure6b.svg`, `figure6b.png` | Figure 6B, the same counts by monthly release |
| `resolution_events.csv` | The saved query result, one row per resolution |
| `figure6a_reason_totals.csv` | The table behind Figure 6A |
| `figure6b_monthly.csv` | The table behind Figure 6B |
| `figure6_granular.csv` | One row per exact `classification_to_start` and result |
| `figure6_submitter_concentration.csv` | Resolutions by reason and submitter |

### How to Interpret It

- **Later returns stay counted.** 781 of the 2,368 resolutions flagged through CvC were in conflict again in a later release, and 690 were in conflict at 2026-10-04. So were 893 of 3,668 Rank lowered, 915 of 8,086 Reclassified, 140 of 3,003 Removed and none of the 1,740 Expert panel added. The figure does not show how many stayed resolved, and recent resolutions have had less time to return. Filter `returned_by_cutoff` and `in_conflict_at_cutoff`.
- **A few submitters drive some bars.** 3,664 of the 3,668 Rank lowered resolutions come from two submitters in one release each: PreventionGenetics, 2,864 in 2024-10, and Counsyl, 800 in 2025-07. Illumina accounts for 2,655 of the 3,003 Removed across 24 releases, and 1,694 Removed from all submitters fall in the 2026-04 release. `manuscript_figure6_submitter_concentration_view` has every submitter.
- **Flags come from CvC's own submissions.** Flagged through CvC means a flagged SCV had a valid CvC flagging candidate submitted on or before that release, matched on accession. All 87 Flagged outside CvC carry NCBI flag comments, in three releases: 51 in 2023-12, 11 in 2024-08 and 25 in 2026-02.
- **A candidate before a submitter's own change is timing only.** 514 Reclassified resolutions had a valid candidate on the changed SCV before that release (420 within about 60 days), as did 244 Removed (236) and 19 Rank lowered (17). They stay in those bars, because this does not show that CvC caused the change. Filter `cvc_candidate_before` and `cvc_candidate_within_60_days`.
- **Each resolution has one reason.** 558 had more than one SCV change. The order is expert panel, 1 star added, flagged, removed, rank lowered, reclassified. `all_scv_reasons` lists every change. Three source reasons that describe context (`single_submitter_withdrawn`, `vcv_rank_changed`, `outlier_reclassified`) map to the SCV change behind them, or to Other, and `source_primary_reason` keeps the original.
- **Other is small and specific.** Of the 48, 45 had an existing SCV raised from 0 star to 1 star, 34 of them in the 2026-10 release. 2 had only a new SCV listed, and 1 had no SCV change recorded.
- **Selection applies.** CvC chooses what it reviews, so its flags are selected rather than sampled, and a difference between conflict types describes what was flagged. A resolution means the top ranked group no longer disagrees. It does not show that the remaining classification is correct. The figure compares no sampled groups, so it has no statistical tests.
- **Some classifications are counted together.** P includes pathogenic low penetrance (`p-lp`) and established risk allele (`era`). LP includes likely pathogenic low penetrance (`lp-lp`) and likely risk allele (`lra`). VUS includes `vus-h`, `vus-m`, `vus-l` and uncertain risk allele (`ura`). `source_agg_classif` keeps the original codes. 8 resolutions start with `cdfs` (conflicting data from submitters), which sits in the VUS tier and keeps its own label because it has no agreed group.
- **The cutoff differs from Figures 3 and 4.** This series uses the first release of each month, so it ends at 2026-10-04, while they use 2026-10-24.

### Exclusions

Resolutions before the August 2023 start of the series are left out: 2,852 in the six monthly releases from 2023-02 to 2023-07. No resolution inside the series is excluded.

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
