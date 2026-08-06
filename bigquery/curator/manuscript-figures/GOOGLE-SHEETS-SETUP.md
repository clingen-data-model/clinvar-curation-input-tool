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
| 3a | Variants by Consequence Group | `clinvar_ingest.manuscript_flagged_scv_by_consequence_view` | `03-flagged-scv-by-consequence.sql` | Donut Chart | [Link] |
| 3b | Flagged Variants by Consequence Group | `clinvar_ingest.manuscript_flagged_scv_by_consequence_view` | `03-flagged-scv-by-consequence.sql` | Donut Chart | [Link] |

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

**View:** `clinvar_ingest.manuscript_flagged_scv_by_consequence_view`
**Script:** `03-flagged-scv-by-consequence.sql`

**Purpose:** Visualizes the distribution of pathogenicity-assessed variants across molecular consequence categories, comparing all variants versus those with flagged submissions. Shows how ClinVar curation flagging activity varies by predicted functional impact.

### Data Source

Connect to the view `clinvar_ingest.manuscript_flagged_scv_by_consequence_view` in BigQuery. The view is created by running `03-flagged-scv-by-consequence.sql` and calling the refresh procedure:

```sql
CALL `clinvar_ingest.refresh_flagged_scv_by_consequence`(NULL);
```

Both donut charts (3a and 3b) use the same extracted data.

### Figure 3 Setup Steps

1. Connect to `clinvar_ingest.manuscript_flagged_scv_by_consequence_view` via Data Connector
2. Click **Extract** to pull the data into a regular sheet
3. For the donut charts, you may want to aggregate across `variation_type` to show only consequence groups:
   - Create a pivot table or use `SUMIF` formulas to sum `all_variant_count` and `flagged_variant_count` by `consequence_group`
4. Create two donut charts from the aggregated data (see 3a and 3b below)

### Consequence Groups

The view categorizes variants into five molecular consequence groups based on MANE Select transcript annotations:

| Group | Consequence Labels Included |
|-------|----------------------------|
| predicted LOF | nonsense, frameshift variant, splice donor variant, splice acceptor variant |
| missense | missense variant |
| inframe indels | inframe insertion, inframe_insertion, inframe deletion, inframe_deletion, inframe indel, inframe_indel |
| UTR/intronic | 5 prime UTR variant, 3 prime UTR variant, intron variant |
| other | All other consequences (synonymous, stop lost, start lost, etc.) and variants without MANE Select annotation |

---

### Figure 3a: All Variants by Consequence Group

**Chart type:** Donut chart showing the distribution of all pathogenicity-assessed variants across consequence groups.

#### Data Preparation

Aggregate the extracted data by `consequence_group`:

| consequence_group | total_variants |
|-------------------|----------------|
| predicted LOF | `=SUMIF(consequence_group, "predicted LOF", all_variant_count)` |
| missense | `=SUMIF(consequence_group, "missense", all_variant_count)` |
| inframe indels | `=SUMIF(consequence_group, "inframe indels", all_variant_count)` |
| UTR/intronic | `=SUMIF(consequence_group, "UTR/intronic", all_variant_count)` |
| other | `=SUMIF(consequence_group, "other", all_variant_count)` |

#### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Pie > Donut |
| Labels | `consequence_group` |
| Values | Aggregated `all_variant_count` |
| Slice order | By value (descending) or custom order |

#### Chart & Axis Titles

- Chart title: "Pathogenicity-Assessed Variants by Molecular Consequence"
- Chart subtitle: "All Variants with Pathogenicity Classifications in ClinVar"

#### Suggested Colors

| Consequence Group | Color | Hex |
|-------------------|-------|-----|
| predicted LOF | Red | #EA4335 |
| missense | Blue | #4285F4 |
| inframe indels | Yellow | #FBBC05 |
| UTR/intronic | Green | #34A853 |
| other | Gray | #9E9E9E |

---

### Figure 3b: Flagged Variants by Consequence Group

**Chart type:** Donut chart showing the distribution of flagged pathogenicity-assessed variants across consequence groups.

#### Data Preparation

Aggregate the extracted data by `consequence_group`:

| consequence_group | flagged_variants |
|-------------------|------------------|
| predicted LOF | `=SUMIF(consequence_group, "predicted LOF", flagged_variant_count)` |
| missense | `=SUMIF(consequence_group, "missense", flagged_variant_count)` |
| inframe indels | `=SUMIF(consequence_group, "inframe indels", flagged_variant_count)` |
| UTR/intronic | `=SUMIF(consequence_group, "UTR/intronic", flagged_variant_count)` |
| other | `=SUMIF(consequence_group, "other", flagged_variant_count)` |

#### Chart Configuration

| Setting | Value |
|---------|-------|
| Chart type | Pie > Donut |
| Labels | `consequence_group` |
| Values | Aggregated `flagged_variant_count` |
| Slice order | By value (descending) or custom order |

#### Chart & Axis Titles

- Chart title: "Flagged Pathogenicity-Assessed Variants by Molecular Consequence"
- Chart subtitle: "Variants with Flagged Submission Status"

#### Suggested Colors

Use the same color scheme as Figure 3a for consistency.

---

### Figure 3 Key Columns

| Column | Description |
|--------|-------------|
| `variation_type` | Type of variation (e.g., single nucleotide variant, Deletion) |
| `consequence_group` | Categorized molecular consequence (predicted LOF, missense, etc.) |
| `all_variant_count` | Distinct pathogenicity-assessed variants in this group |
| `flagged_variant_count` | Distinct variants with at least one flagged SCV |
| `all_scv_count` | Distinct pathogenicity SCVs in this group |
| `flagged_scv_count` | Distinct SCVs with flagged submission status |
| `consq_labels` | Audit trail: sorted list of consequence labels with counts |

### Figure 3 Interpretation

- **Comparing 3a vs 3b**: Shows whether flagging activity is proportionally distributed across consequence groups or concentrated in certain categories
- **Predicted LOF**: Typically represents loss-of-function variants with strongest functional impact predictions
- **Missense**: Often the largest category and may have higher uncertainty in pathogenicity assessment
- **Other/No MANE Select**: Includes variants without MANE Select transcript annotation, useful for assessing annotation coverage

### Figure 3 Alternative Views

| Variant | Chart Type | Insight |
|---------|-----------|---------|
| Stacked bar by variation_type | Stacked Bar | How does consequence distribution vary by variant type (SNV vs indel)? |
| Flagging rate | Calculated field | `flagged_variant_count / all_variant_count * 100` per consequence group |
| SCV-level donut | Donut | Use `all_scv_count` and `flagged_scv_count` for submission-level view |

---

## Data Refresh

- **Source**: BigQuery `clinvar_ingest` dataset
- **Refresh frequency**: After each ClinVar release (~monthly)
- **To refresh**: Data > Data connectors > Refresh options

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
