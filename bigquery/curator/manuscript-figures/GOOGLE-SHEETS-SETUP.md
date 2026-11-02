# Manuscript Figures - Google Sheets Setup Guide

This guide explains how to set up Google Sheets dashboards using BigQuery Data Connector sheets to visualize the datasets produced by the manuscript figure scripts. Each figure in the forthcoming ClinVar Curation manuscript is backed by a query in this folder, with the results connected to Google Sheets for charting.

---

## Dashboard Overview (README Sheet)

Use the table below as a README sheet in your Google Sheets file. Replace `[Link]` with actual hyperlinks to each chart's sheet.

| Figure | Name | View | Script | Chart Type | Link |
| --- | --- | --- | --- | --- | --- |
| 1a | ClinVar Landscape (Conflict Count) | `clinvar_ingest.manuscript_clinvar_landscape` | `01-clinvar-landscape.sql` | Scatter Plot | [Link] |
| 1b | ClinVar Landscape (Conflict Rate) | `clinvar_ingest.manuscript_clinvar_landscape` | `01-clinvar-landscape.sql` | Scatter Plot | [Link] |
| 2 | Submitter Landscape | `clinvar_ingest.manuscript_submitter_landscape` | `02-submitter-landscape.sql` | Bar Chart | [Link] |
| 3 | Variants by Consequence Group: All ClinVar vs CvC Flagged | `clinvar_ingest.manuscript_cvc_vs_clinvar_consequence_bar_view` | `03-flagged-scv-by-consequence.sql` | Clustered Bar Chart | [Link] |
| Supporting | Flag Source Combinations | `clinvar_ingest.manuscript_flag_source_combo_by_consequence_view` | `03-flagged-scv-by-consequence.sql` | Table | [Link] |

---

## Prerequisites

1. Access to BigQuery with the `clinvar_ingest` dataset (project: `clingen-dev`)
2. Google Sheets with Connected Sheets enabled (requires Google Workspace account)
3. Manuscript figure queries have been run to populate the source tables/views

## Connecting BigQuery to Google Sheets

1. Open a new Google Sheet
2. Go to **Data** > **Data connectors** > **Connect to BigQuery**
3. Select the project `clingen-dev`
4. Navigate to the `clinvar_ingest` dataset
5. Select the table or view, or use **Custom Query** to paste the SQL directly

---

## Figure 1: ClinVar Landscape

**View:** `clinvar_ingest.manuscript_clinvar_landscape`
**Script:** `01-clinvar-landscape.sql`

**Purpose:** Visualizes the ClinVar Germline Variant Pathogenicity Classification landscape across GenCC Definitive/Strong/Moderate (DSM) genes. Each gene is plotted as a point to show the relationship between submission volume and clinically significant conflicts. Two versions of the scatter plot show different perspectives: absolute conflict count (1a) and conflict rate as a percentage of total variants (1b).

### Data Source

Connect to the view `clinvar_ingest.manuscript_clinvar_landscape` in BigQuery. The view is created by running `01-clinvar-landscape.sql`. Both charts use the same extracted data.

### Setup Steps (shared)

1. Connect to `clinvar_ingest.manuscript_clinvar_landscape` via Data Connector
2. Click **Extract** to pull the data into a regular sheet
3. Create two charts from the same extracted data (see 1a and 1b below)

### Showing Gene Labels

Gene labels can be shown selectively to avoid clutter on both charts:

1. **Option A - Top N genes only**: Filter the extracted data to the top 20-30 genes by `clinsig_scv_count`, then enable point labels
2. **Option B - On hover**: Google Sheets scatter charts show data on hover by default
3. **Option C - Manual annotations**: Add text boxes for notable genes (e.g., BRCA1, BRCA2, TP53)

To enable point labels:
1. In Chart Editor > **Setup** tab
2. Set **Label** to `gene_symbol`
3. In **Customize** > **Series**, check **Data labels**

### Shared Customize Tab Settings

1. **Series**:
   - Point size: 4-6px
   - Point color: #4285F4 (blue)
   - Point opacity: 70% (helps when dots overlap)
2. **Gridlines and ticks**:
   - X-axis: Consider logarithmic scale if data range is wide
3. **Legend**: None (single series)

---

### Figure 1a: Conflict Count

**Chart type:** Scatter plot showing absolute number of clinically significant conflict variants per gene.

#### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Scatter |
| X-axis | `total_scvs` |
| Y-axis | `total_clinsig_conflict_variants` |
| Point labels | `gene_symbol` (optional) |

#### Axis Configuration

| Axis | Label | Notes |
|------|-------|-------|
| X-axis | Total Pathogenicity SCVs | Log scale recommended |
| Y-axis | Clinically Significant Conflict Variants | Count of variants with agg_sig_type >= 5 |

#### Chart & Axis Titles

- Chart title: "ClinVar Conflict Burden by Gene"
- Chart subtitle: "GenCC Definitive/Strong/Moderate Genes"
- X-axis title: "Total Pathogenicity SCVs"
- Y-axis title: "Clinically Significant Conflict Variants"

#### Key Columns Used

| Column | Chart Role | Description |
|--------|-----------|-------------|
| `gene_symbol` | Label | Gene symbol (e.g., BRCA1) |
| `total_scvs` | X-axis | All pathogenicity SCVs for this gene |
| `total_clinsig_conflict_variants` | Y-axis | Variants with agg_sig_type >= 5 |

#### Interpretation

- **Upper-right quadrant**: Genes with many submissions AND many conflict variants (high-volume, high absolute conflict burden)
- **Lower-right quadrant**: Genes with many submissions but few conflict variants (high-volume, concordant)
- **Upper-left quadrant**: Genes with few submissions but many conflicts (unexpected — worth investigating)
- **Lower-left quadrant**: Genes with few submissions and few conflicts

---

### Figure 1b: Conflict Rate

**Chart type:** Scatter plot showing the percentage of variants in clinically significant conflict per gene.

#### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Scatter |
| X-axis | `total_scvs` |
| Y-axis | `clinsig_conflict_pct` |
| Point labels | `gene_symbol` (optional) |

#### Axis Configuration

| Axis | Label | Notes |
|------|-------|-------|
| X-axis | Total Pathogenicity SCVs | Log scale recommended |
| Y-axis | Clinically Significant Conflict Rate (%) | `total_clinsig_conflict_variants / total_variants * 100` |

#### Chart & Axis Titles

- Chart title: "ClinVar Conflict Rate by Gene"
- Chart subtitle: "GenCC Definitive/Strong/Moderate Genes"
- X-axis title: "Total Pathogenicity SCVs"
- Y-axis title: "% Variants in Clinically Significant Conflict"

#### Key Columns Used

| Column | Chart Role | Description |
|--------|-----------|-------------|
| `gene_symbol` | Label | Gene symbol (e.g., BRCA1) |
| `total_scvs` | X-axis | All pathogenicity SCVs for this gene |
| `clinsig_conflict_pct` | Y-axis | `total_clinsig_conflict_variants / total_variants * 100` |

#### Interpretation

- **Upper-right quadrant**: Genes with many submissions AND a high conflict rate (high-volume, contentious)
- **Lower-right quadrant**: Genes with many submissions but a low conflict rate (high-volume, concordant)
- **Upper-left quadrant**: Genes with few submissions but a high conflict rate (low-volume, contentious)
- **Lower-left quadrant**: Genes with few submissions and low conflict rate

---

### Additional Scatter Plot Variants

The same dataset can support alternative views:

| Variant | X-axis | Y-axis | Insight |
| --- | --- | --- | --- |
| Conflict burden | `total_clinsig_variants` | `total_clinsig_conflict_variants` | Which genes have the most conflicting variants relative to their P/LP count? |
| Concordance rate | `total_scvs` | `concordant_clinsig_variants / total_clinsig_variants * 100` | Which high-volume genes have the highest P/LP concordance? |

---

## Figure 2: Submitter Landscape

**View:** `clinvar_ingest.manuscript_submitter_landscape`
**Script:** `02-submitter-landscape.sql`

**Purpose:** Visualizes how different institution types contribute to ClinVar's Germline Variant Pathogenicity Classification landscape. Shows the distribution of submitters, SCVs, and variants across institution types (clinical testing labs, research institutions, expert panels, etc.).

### Data Source

Connect to the view `clinvar_ingest.manuscript_submitter_landscape` in BigQuery. The view is created by running `02-submitter-landscape.sql`.

### Figure 2 Setup Steps

1. Connect to `clinvar_ingest.manuscript_submitter_landscape` via Data Connector
2. Click **Extract** to pull the data into a regular sheet
3. Create a bar chart from the extracted data

### Figure 2 Chart Configuration

| Setting | Value |
| --- | --- |
| Chart type | Bar (horizontal) or Column (vertical) |
| X-axis / Categories | `type` (institution type) |
| Y-axis / Values | `scv_count` (primary), optionally `submitter_count` or `vcv_count` |
| Sort | By `scv_count` descending |

### Figure 2 Axis Configuration

| Axis | Label | Notes |
| --- | --- | --- |
| X-axis (Categories) | Institution Type | e.g., clinical testing, research, expert panel |
| Y-axis (Values) | Count | SCV count, submitter count, or variant count |

### Figure 2 Chart & Axis Titles

- Chart title: "ClinVar Pathogenicity Submissions by Institution Type"
- Chart subtitle: "Germline Variant Pathogenicity Classifications"
- X-axis title: "Institution Type"
- Y-axis title: "Number of SCVs" (or "Number of Submitters" / "Number of Variants")

### Figure 2 Key Columns

| Column | Chart Role | Description |
| --- | --- | --- |
| `type` | Categories | Institution type (e.g., clinical testing, research) |
| `submitter_count` | Values (option) | Count of distinct submitter organizations |
| `scv_count` | Values (primary) | Count of pathogenicity SCVs from this institution type |
| `vcv_count` | Values (option) | Count of distinct variants with SCVs from this type |

### Figure 2 Interpretation

- **Clinical testing labs** typically contribute the largest volume of pathogenicity SCVs
- **Expert panels** contribute fewer SCVs but often at higher review status
- **Research institutions** may contribute variants not seen from clinical labs
- Comparing `submitter_count` vs `scv_count` shows average submissions per organization

### Figure 2 Alternative Views

| Variant | Y-axis | Insight |
| --- | --- | --- |
| Submitter count | `submitter_count` | How many organizations of each type contribute? |
| Variant coverage | `vcv_count` | How many unique variants does each type cover? |
| SCVs per submitter | `scv_count / submitter_count` | Average productivity per organization type |

---

## Figure 3: Variants by Molecular Consequence

**Chart view:** `clinvar_ingest.manuscript_cvc_vs_clinvar_consequence_bar_view`
**Script:** `03-flagged-scv-by-consequence.sql`

**Purpose:** One bar chart comparing the molecular consequence distribution of all pathogenicity-assessed variants in ClinVar with variants flagged through the CvC project. NCBI and ClinGen non-CvC flags are excluded from the CvC bars.

### Data Source

Run `03-flagged-scv-by-consequence.sql` to create the tables, procedure and views, then populate them with:

```sql
CALL `clinvar_ingest.refresh_flagged_scv_by_consequence`(NULL);
```

Re-running the script replaces the result tables, so always call the procedure afterwards.

### Figure 3 Setup Steps

The current sheet is the [CvC Manuscript Figure 3 sheet](https://docs.google.com/spreadsheets/d/17wr65aFoU9xVD0eluNfLxOzbxpJbAv7jYoG4Ir4POyY/edit). See the [README](README.md#what-the-figure-represents) for what the figure represents. To rebuild it:

1. Connect to `clinvar_ingest.manuscript_cvc_vs_clinvar_consequence_bar_view` via Data Connector
2. Click **Extract** to pull the data into a regular sheet, starting at A1
3. Add the chart source block below in `H1:J6`
4. Select `H1:J6` and insert a chart

### Figure 3 Chart Source Block

Chart titles in Google Sheets are fixed text, but legend labels come from header cells. These formulas put the release date and each group's n in the legend, so they update on refresh.

| Cell | Formula or value |
|------|------------------|
| `H1` | `Molecular consequence group` |
| `I1` | `="All ClinVar variants (n="&TEXT(SUM(C2:C),"#,##0")&"; ClinVar release "&TEXT(MAX(A2:A),"yyyy-mm-dd")&")"` |
| `J1` | `="CvC-flagged variants (n="&TEXT(SUM(D2:D),"#,##0")&"; ClinVar release "&TEXT(MAX(A2:A),"yyyy-mm-dd")&")"` |
| `H2:H6` | `predicted LOF`, `missense`, `inframe indels`, `UTR/intronic`, `other` |
| `I2`, filled down | `=SUMIF($B$2:$B,$H2,$E$2:$E)` |
| `J2`, filled down | `=SUMIF($B$2:$B,$H2,$F$2:$F)` |

### Figure 3 Chart Configuration

The two populations differ by about 2,000-fold, so chart percentages rather than counts.

| Setting | Value |
|---------|-------|
| Chart type | Clustered column or clustered bar |
| Data range | `H1:J6` |
| Use row 1 as headers | On |
| Use column H as labels | On |
| Data labels | On |
| Category order | As listed in `H2:H6`, most to least severe |

### Figure 3 Chart & Axis Titles

- Chart title: "Molecular consequence: all ClinVar variants vs. CvC-flagged variants"
- Category axis title: "Molecular consequence group"
- Value axis title: "% of variants in group"

### Consequence Groups

Each MANE Select row is assigned using the first term of its consequence label. A variant with more than one MANE Select row is counted once, in its most severe group, in the order below.

| Group | Consequence Labels Included |
|-------|----------------------------|
| predicted LOF | nonsense, frameshift variant, splice donor variant, splice acceptor variant |
| missense | missense variant |
| inframe indels | inframe insertion, inframe_insertion, inframe deletion, inframe_deletion, inframe indel, inframe_indel |
| UTR/intronic | 5 prime UTR variant, 3 prime UTR variant, intron variant |
| other | All other consequences (synonymous, stop lost, start lost, etc.) and variants without MANE Select annotation |

### Figure 3 Chart Columns

| Column | Description |
|--------|-------------|
| `release_date` | ClinVar release date used for this snapshot |
| `consequence_group` | Categorized molecular consequence |
| `all_variant_count` | All pathogenicity-assessed variants in this group |
| `cvc_flagged_variant_count` | Variants with an SCV flagged through the CvC project |
| `all_variant_pct` | Percent of all variants in this group |
| `cvc_flagged_variant_pct` | Percent of CvC flagged variants in this group |

### Flag Source Counts

**View:** `clinvar_ingest.manuscript_flag_source_combo_by_consequence_view`

Use this view for the exact source combinations. Rows do not overlap, so they sum to the flagged totals. Filter on `count_level` and never add `scv` and `variant` rows together.

For the summary table on the sheet's `Flag source counts` tab, create a pivot table from the connected view with rows `flag_source_combo` (totals on) and `release_date`, column `count_level`, and value `SUM` of `item_count`.

| Column | Description |
|--------|-------------|
| `variation_type` | Type of variation (e.g., single nucleotide variant, Deletion) |
| `consequence_group` | Categorized molecular consequence |
| `count_level` | `scv` or `variant` |
| `flag_source_combo` | ClinGen CvC, ClinGen non-CvC, NCBI, or a combination such as `ClinGen CvC + NCBI` |
| `item_count` | SCVs or variants with exactly this combination |
| `first_item_ids` | Up to the first 5 of those SCV accessions or variation ids, in order, separated by commas |

### Variation Type Breakdown

**View:** `clinvar_ingest.manuscript_flagged_scv_by_consequence_view`

The per-source columns overlap when a variant or SCV has more than one source. `flagged_variant_count` and `flagged_scv_count` include every source, including NCBI, so do not use them for Figure 3.

| Column | Description |
|--------|-------------|
| `variation_type` | Type of variation (e.g., single nucleotide variant, Deletion) |
| `consequence_group` | Categorized molecular consequence |
| `all_variant_count`, `all_scv_count` | All pathogenicity-assessed variants and SCVs |
| `flagged_variant_count`, `flagged_scv_count` | Flagged from any source |
| `cvc_flagged_variant_count`, `cvc_flagged_scv_count` | Flagged by ClinGen CvC |
| `ncbi_flagged_variant_count`, `ncbi_flagged_scv_count` | Flagged by NCBI |
| `clingen_non_cvc_flagged_variant_count`, `clingen_non_cvc_flagged_scv_count` | Flagged by ClinGen non-CvC |
| `consq_labels` | Audit trail: sorted list of consequence labels with counts |

---

## Data Refresh

- **Source**: BigQuery `clinvar_ingest` dataset
- **Refresh frequency**: After each ClinVar release (~monthly)
- **To refresh**: Data > Data connectors > Refresh options
- **Figure 3**: first run `CALL clinvar_ingest.refresh_flagged_scv_by_consequence(NULL)` in BigQuery, because its views read result tables rather than live ClinVar data

---

## Tips for Manuscript Figures

### Export Quality

- Use **Download** > **PNG** or **SVG** from the chart menu for publication-quality exports
- For higher resolution, increase chart size before exporting
- Consider using Google Slides for final figure assembly (copy chart > paste into slide > export)

### Consistent Styling

Maintain consistent styling across all manuscript figures:

| Element | Standard |
|---------|----------|
| Font | Arial or Helvetica |
| Point color (primary) | #4285F4 (blue) |
| Point color (highlight) | #EA4335 (red) |
| Axis label size | 12pt |
| Title size | 14pt |
| Grid lines | Light gray (#E0E0E0) |

### Reproducibility

All figures are fully reproducible from the SQL scripts in this folder. Record the ClinVar release date used for each figure run (returned as `release_date` in query output) to ensure manuscript figures can be regenerated.
