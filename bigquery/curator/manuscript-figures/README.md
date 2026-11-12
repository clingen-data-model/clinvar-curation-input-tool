# Manuscript Figures

This folder contains SQL scripts that produce the datasets and supporting data for figures included in the forthcoming manuscript describing the ClinVar Curation project.

## Background

The ClinVar Curation project systematically identifies and addresses conflicting variant classifications in ClinVar, with the goal of improving the consistency and clinical utility of submitted interpretations. This manuscript documents the project's methodology, scope, and measurable impact on ClinVar's classification landscape.

Each script in this folder generates a dataset that underpins a specific figure or table in the manuscript. Scripts are numbered in the order they appear in the manuscript.

## Scripts

| Script | View | Description |
| --- | --- | --- |
| `00-excluded-scvs.sql` | `clinvar_ingest.manuscript_excluded_annotations`, `clinvar_ingest.manuscript_excluded_scvs` | CvC annotations every figure leaves out of its counts: the discordance project's flags and removals (batch 129 retraction) on 233 SCVs. Figures anti-join the annotations view on `annotation_id`; the SCV view is for notes and lists. Run it before any figure script, because their SQL reads these views. |
| `01-clinvar-landscape.sql` | `clinvar_ingest.manuscript_figure1_variant_states_core(release, left_out)`, `clinvar_ingest.manuscript_figure1_variant_states(release)`, `clinvar_ingest.manuscript_figure1a_final_classifications(release)`, `clinvar_ingest.manuscript_figure1b_gene_rates(release)`, `clinvar_ingest.manuscript_figure1_callouts(release)`, `clinvar_ingest.manuscript_figure1_variant_states_view`, `clinvar_ingest.manuscript_figure1a_states_view`, `clinvar_ingest.manuscript_figure1a_conflict_types_view`, `clinvar_ingest.manuscript_figure1a_final_classifications_view`, `clinvar_ingest.manuscript_clinvar_landscape`, `clinvar_ingest.manuscript_figure1_callouts_view`, `clinvar_ingest.manuscript_figure1_all_flagged_variants_view`, `clinvar_ingest.manuscript_figure1_discordance_scvs(release)`, `clinvar_ingest.manuscript_figure1_discordance_scvs_view` | The state of ClinVar's pathogenicity-classified variants in one release, read from each variant's top ranked group, and the per-gene rate of medically significant conflicts in GenCC Definitive/Strong/Moderate genes. `generate_figure1.py` calls the table functions and draws both panels. |
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

Until Figures 3A, 3B, 3C and 4 are regenerated, their sections below, images and sheets still describe the earlier rule, which left out 321 whole SCVs. Their deployed SQL now reads the 233-SCV view, so their connector tabs show neither rule exactly until each switches to the annotations view.

How each figure applies it:

| Figure | Effect |
| --- | --- |
| 1 | None. Figure 1 uses no CvC data. |
| 3A, 3B | Left out of the reviewed SCVs' decisions. `03ab-review-outcomes-and-reasons.sql` still anti-joins `manuscript_excluded_scvs` on `scv_id` and must switch to the annotations view. |
| 3C | Not counted as CvC flags. They stay in All ClinVar, because they are still ClinVar submissions. `03-flagged-scv-by-consequence.sql` must switch to the annotations view. |
| 4 | Treated as never reviewed. `04-conflict-resolution-outcomes.sql` must switch to the annotations view. |
| 5 | Left out of the submitted flags and retractions, by `annotation_id`. The footnote names the group, with counts read from `manuscript_excluded_scvs`. |
| 6 | Never credit a flag to CvC or set `cvc_candidate_before`, matched on `annotation_id`. A flag resolution whose only CvC flagging candidate was one of them is dropped rather than shown as Flagged outside CvC: 4 through 2026-11-08. None reaches any other resolution. |

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
| `figure1_discordance_scvs.csv` | One row per discordance project retraction SCV: where it sits in the release, its variant's state as counted, and that state if all 233 were left out |

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

### The Discordance Project Retraction

Figure 1 counts ClinVar submissions, not CvC work. Every view behind it reads only ClinVar tables (`clinvar_scvs`, `clinvar_genes`, `clinvar_single_gene_variations`, `gencc_dsm_genes`) and no CvC annotations, reviews or submissions, so the discordance project's left-out flags and removals (`manuscript_excluded_annotations`) never reach it. Its 233 SCVs (`manuscript_excluded_scvs`) are ClinVar submissions again since their flags were removed, so they stay in the figure as part of ClinVar, as in the All ClinVar baseline of Figure 3C. The user chose this on 2026-11-12. Both images say so in a footnote.

At release 2026-11-08 all 233 SCVs contribute. Leaving the SCVs themselves out too would change these counts and no others:

| Count | As counted | With the 233 SCVs left out |
| --- | ---: | ---: |
| Variants in Panel A | 4,455,641 | 4,455,560 |
| 1 submission | 3,490,066 | 3,490,036 |
| 2 or more concordant submissions | 650,948 | 650,924 |
| Confidence conflict | 130,367 | 130,347 |
| VUS vs B/LB | 152,875 | 152,874 |
| P/LP vs VUS/B/LB | 31,385 | 31,379 |
| LP vs VUS / P + LP vs VUS / P vs VUS | 19,172 / 5,732 / 5,170 | 19,173 / 5,729 / 5,166 |
| Medically significant across all SCVs | 42,115 | 42,108 |
| Of those, not in the top ranked group | 10,730 | 10,729 |
| One top SCV with lower ranked SCVs | 73,160 | 73,154 |
| Panel B variants | 3,165,169 | 3,165,088 |
| Panel B pathogenicity SCVs | 5,460,430 | 5,460,197 |
| Panel B conflict variants | 30,918 | 30,912 |

Panel B keeps all 4,218 genes, the 1,210 at 0%, the 0 to 14.29% range and all 11 labels. Counts change in 25 genes, and the rate in 5 of them, by at most 0.08 points (FIG4, 1.28% to 1.20%).

`manuscript_figure1_discordance_scvs_view` has one row per SCV, so analysts can check each one: whether it is in the release and flagged, its rank and whether it is in the top ranked group, the variant's `variant_state` and `conflict_type` as counted, `variant_state_left_out` and `conflict_type_left_out` (NULL when the variant would leave the figure), `in_figure_1b` and the ClinVar link. It is the only Figure 1 object that reads CvC data. It calls `manuscript_figure1_variant_states_core` with the 233 accessions, the same logic the figure uses with an empty list.

### Refreshing the Data

The views are pinned to one release, so the sheet's tables match the images until the figure is moved on purpose. Row 1 of each figure tab says OUT OF DATE if its table moves to another release.

1. Run `00-excluded-scvs.sql` if it changed. In `01-clinvar-landscape.sql`, change the `DATE` literal in the four pinned views, and `FIGURE_RELEASE` in `generate_figure1.py`. Run the script with `bq query`.
2. In the sheet, choose **Data > Data connectors > Refresh options > Refresh all**. Viewers need BigQuery access to `clingen-dev` to refresh the connected tabs.
3. From this folder, run `python3 generate_figure1.py --out output/figure1`.
4. On each figure tab, delete the old image and choose **Insert > Image > Insert image over cells**. Use `figure1A.png` and `figure1B.png`.
5. Update the date in the row 1 formula of each figure tab, line 2 of the `About Figure 1` tab, the counts on that tab, row 2 and the labeled-gene counts on the figure tabs, and the counts in this section, including the discordance project table.

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

Figures and counts: [CvC Manuscript Figure 6 sheet](https://docs.google.com/spreadsheets/d/1hx0aX859RjFrbtwWuIc7t4s1TkQd8wWhKOuQUU839bQ/edit). The tab `About Figure 6` has the steps for refreshing the tables and replacing the images. Counts quoted below are for monthly releases 2023-08 through 2026-11 (release 2026-11-08).

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
| Reclassified | 8,233 (42.2%) | 3,198 (38.5%) | 5,035 (44.9%) |
| Rank lowered | 3,668 (18.8%) | 659 (7.9%) | 3,009 (26.9%) |
| Removed | 3,006 (15.4%) | 744 (9.0%) | 2,262 (20.2%) |
| Flagged through CvC | 2,480 (12.7%) | 2,403 (29.0%) | 77 (0.7%) |
| Expert panel added | 1,836 (9.4%) | 1,076 (13.0%) | 760 (6.8%) |
| 1 star added to 0 star conflict | 141 (0.7%) | 117 (1.4%) | 24 (0.2%) |
| Flagged outside CvC | 91 (0.5%) | 57 (0.7%) | 34 (0.3%) |
| Other | 48 (0.2%) | 43 (0.5%) | 5 (0.0%) |
| **Total** | **19,503** | **8,297** | **11,206** |

The 19,503 resolutions cover 19,261 variants, because a variant that resolves twice counts twice.

**Left out: the discordance project retraction.** The 597 annotations in `clinvar_ingest.manuscript_excluded_annotations` (`00-excluded-scvs.sql`), the discordance project's flags and removals on 233 SCVs, never count as CvC flagging candidates. The 88 other retracted gene-disease relationship flags, and every other retraction, count as usual. Through 2026-11-08 the left-out annotations reach 4 resolutions and no others. In each, the SCV's only CvC flagging candidate was a discordance project gene-disease relationship flag, ClinVar flagged the SCV, and the conflict resolved. Counting them as Flagged outside CvC would call CvC flags non-CvC ones, so they are dropped, as the user chose on 2026-11-12. All 4 later returned to conflict, after the flags were withdrawn in batch 129.

| Release | Variation | SCV | Flag batch |
| --- | --- | --- | --- |
| 2024-08-05 | [554676](https://www.ncbi.nlm.nih.gov/clinvar/variation/554676/) | SCV004207665 | 107 |
| 2024-11-03 | [1728](https://www.ncbi.nlm.nih.gov/clinvar/variation/1728/) | SCV000021954 | 112 |
| 2025-09-07 | [1008825](https://www.ncbi.nlm.nih.gov/clinvar/variation/1008825/) | SCV004020023 | 121 |
| 2025-09-07 | [241635](https://www.ncbi.nlm.nih.gov/clinvar/variation/241635/) | SCV001140769 | 121 |

How this was checked, at 2026-11-08: the table function's query run with no exclusion returns 19,507 resolutions. The deployed function returns the other 19,503 with every column identical, and none of the 597 annotations is on an SCV behind any of them. `excluded_scvs` and `dropped_flag_resolutions` carry the counts the footnote prints.

Changes from the earlier rule, which left out 321 whole SCVs: through 2026-10-04 it gave 19,141 resolutions with 2,368 Flagged through CvC and 87 Flagged outside CvC. The annotation rule gives 19,147, 2,374 and 87 there: the 6 resolutions from the other retracted flags count again as Flagged through CvC, and the same 4 stay out.

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

- **Later returns stay counted.** 794 of the 2,480 resolutions flagged through CvC were in conflict again in a later release, and 694 were in conflict at 2026-11-08. So were 906 of 3,668 Rank lowered, 932 of 8,233 Reclassified, 146 of 3,006 Removed and 1 of the 1,836 Expert panel added. The figure does not show how many stayed resolved, and recent resolutions have had less time to return. Filter `returned_by_cutoff` and `in_conflict_at_cutoff`.
- **A few submitters drive some bars.** 3,664 of the 3,668 Rank lowered resolutions come from two submitters in one release each: PreventionGenetics, 2,864 in 2024-10, and Counsyl, 800 in 2025-07. Illumina accounts for 2,655 of the 3,006 Removed across 24 releases, and 1,694 Removed from all submitters fall in the 2026-04 release. `manuscript_figure6_submitter_concentration_view` has every submitter.
- **Flags come from CvC's own submissions.** Flagged through CvC means a flagged SCV had a valid CvC flagging candidate submitted on or before that release, matched on accession. Of the 91 Flagged outside CvC, 87 carry NCBI flag comments, in three releases: 51 in 2023-12, 11 in 2024-08 and 25 in 2026-02. The other 4, in 2026-11, are ClinGen flags with the reason "Conflict with ClinGen Gene Dosage Map" on SCVs CvC never annotated.
- **A candidate before a submitter's own change is timing only.** 522 Reclassified resolutions had a valid candidate on the changed SCV before that release (422 within about 60 days), as did 244 Removed (236) and 19 Rank lowered (17). They stay in those bars, because this does not show that CvC caused the change. Filter `cvc_candidate_before` and `cvc_candidate_within_60_days`.
- **Each resolution has one reason.** 573 had more than one SCV change. The order is expert panel, 1 star added, flagged, removed, rank lowered, reclassified. `all_scv_reasons` lists every change. Three source reasons that describe context (`single_submitter_withdrawn`, `vcv_rank_changed`, `outlier_reclassified`) map to the SCV change behind them, or to Other, and `source_primary_reason` keeps the original.
- **Other is small and specific.** Of the 48, 45 had an existing SCV raised from 0 star to 1 star, 34 of them in the 2026-10 release. 2 had only a new SCV listed, and 1 had no SCV change recorded.
- **Selection applies.** CvC chooses what it reviews, so its flags are selected rather than sampled, and a difference between conflict types describes what was flagged. A resolution means the top ranked group no longer disagrees. It does not show that the remaining classification is correct. The figure compares no sampled groups, so it has no statistical tests.
- **Some classifications are counted together.** P includes pathogenic low penetrance (`p-lp`) and established risk allele (`era`). LP includes likely pathogenic low penetrance (`lp-lp`) and likely risk allele (`lra`). VUS includes `vus-h`, `vus-m`, `vus-l` and uncertain risk allele (`ura`). `source_agg_classif` keeps the original codes. 8 resolutions start with `cdfs` (conflicting data from submitters), which sits in the VUS tier and keeps its own label because it has no agreed group.
- **The cutoff matches Figures 1, 3, 4 and 5.** This series uses the first release of each month, and 2026-11-08 is both the first November release and the latest loaded.

### Exclusions

Resolutions before the August 2023 start of the series are left out: 2,852 in the six monthly releases from 2023-02 to 2023-07. Inside the series, only the 4 flag resolutions credited solely to the discordance project's flags are left out (see above).

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
