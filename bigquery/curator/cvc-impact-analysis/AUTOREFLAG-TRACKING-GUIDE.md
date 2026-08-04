# CVC Auto-Reflag Tracking Guide

This guide explains how to set up and use a dedicated Google Sheet for reviewing, selecting, and tracking auto-reflag candidate SCVs for resubmission to ClinVar.

---

## Overview

When CVC submits a flagging candidate to ClinVar, submitters have a 60-90 day grace period to respond. Some submitters resubmit their SCV — incrementing the version — without making substantive changes, which can prevent a flag from being applied or remove an existing one. The auto-reflag analysis identifies these SCVs so they can be re-submitted as flagging candidates.

**This sheet is scoped to 7 target labs:** LabCorp Genetics, CeGaT, Revvity, OMIM, Baylor Genetics, Counsyl, and Eurofins.

An SCV qualifies for auto-reflagging when all 6 substantive fields are unchanged between the submitted version and the current version:

| Field | What it represents |
|-------|--------------------|
| `classif_type` | Classification category (e.g., Pathogenic, VUS) |
| `submitted_classification` | Free-text classification from the submitter |
| `last_evaluated` | Date the submitter last evaluated the variant |
| `trait_set_id` | Condition/disease associated with the assertion |
| `pmids` | Ordered list of PubMed citation IDs |
| `classification_comment` | Evidence summary / interpretation text |

SCVs where any of these fields changed are marked as "Review Needed" and require manual assessment before resubmission.

---

## Google Sheet Setup

### Step 1: Create the Google Sheet

1. Open a new Google Sheet
2. Name it: **CVC Auto-Reflag Tracking — [Month Year]** (e.g., "CVC Auto-Reflag Tracking — June 2026")

### Step 2: Connect to BigQuery

1. Go to **Data** → **Data connectors** → **Connect to BigQuery**
2. Select project: `clingen-dev`
3. Select dataset: `clinvar_curator`
4. Create the following tabs:

| Tab Name | View to Connect | Purpose |
|----------|-----------------|---------|
| All Candidates | `sheets_autoreflag_actionable` | Full list of auto-reflag candidates |
| By Submitter | `sheets_autoreflag_by_submitter` | Summary counts per lab |
| Glossary | `sheets_autoreflag_glossary` | Term definitions for reference |

### Step 3: Extract the data

For each Connected Sheets tab:

1. Click **Extract** to pull data into a regular (editable) sheet
2. This converts the live BigQuery connection into static data you can filter, sort, and annotate
3. Rename the extracted tabs to match: `All Candidates`, `By Submitter`, `Glossary`
4. Delete the original Connected Sheets tabs (the ones with the database icon)

### Step 4: Create the Resubmission Queue tab

Create a new tab called **Resubmission Queue** with the following columns:

| Column | Description | Source |
|--------|-------------|--------|
| SCV ID | The submission accession | Copy from All Candidates |
| Current SCV Version | Version to submit against | Copy from All Candidates (`Current SCV Version`) |
| Variation ID | Internal variation identifier | Copy from All Candidates |
| Submitter Name | Lab/organization | Copy from All Candidates |
| Target Lab | Which of the 7 target labs | Copy from All Candidates |
| Original Flagging Reason | Why CVC originally flagged this SCV | Copy from All Candidates |
| Was Ever Flagged | Whether ClinVar applied the flag | Copy from All Candidates |
| Reviewed By | Curator name/initials | Manual entry |
| Review Date | Date reviewed | Manual entry |
| Decision | "Approve", "Skip", or "Needs Discussion" | Manual entry |
| Notes | Any notes about this SCV | Manual entry |
| Status | "Pending", "Submitted", "Completed" | Manual entry — start as "Pending" |
| Submission Date | When resubmitted to ClinVar | Manual entry — fill after submission |

---

## Setting Up Filter Views

Filter views let multiple users filter the data independently without affecting each other's view.

### Create Filter Views on the All Candidates tab

Go to **Data** → **Create a filter view**, then save each of these as a named filter view:

#### Filter View: "Auto-Reflag Ready"

Shows only SCVs eligible for automatic resubmission (no substantive changes).

- Column: `Action` → filter to show only **Auto-Reflag**

#### Filter View: "Review Needed"

Shows only SCVs that had substantive changes and need manual review.

- Column: `Action` → filter to show only **Review Needed**

#### Filter View: "By Lab — [Lab Name]"

Create one per target lab for focused review sessions:

- Column: `Target Lab` → filter to show only the specific lab
- Column: `Action` → optionally filter to **Auto-Reflag** only

Suggested lab-specific filter views:

- "By Lab — LabCorp"
- "By Lab — CeGaT"
- "By Lab — Revvity"
- "By Lab — OMIM"
- "By Lab — Baylor Genetics"
- "By Lab — Counsyl"
- "By Lab — Eurofins"

#### Filter View: "Never Flagged — Grace Period Bumps"

Shows SCVs that were never flagged because the submitter bumped during the grace period.

- Column: `Was Ever Flagged` → filter to show only **No — Grace period bump**

#### Filter View: "Not Yet Queued"

Shows SCVs that haven't been added to the Resubmission Queue yet (requires conditional formatting — see below).

---

## Conditional Formatting

### Highlight SCVs by Action

1. Select all data rows in the **All Candidates** tab (e.g., A2:T5000)
2. Go to **Format** → **Conditional formatting**
3. Add two rules:

| Rule | Condition | Format |
|------|-----------|--------|
| 1 | Custom formula: `=$P2="Auto-Reflag"` (adjust column letter for `Action`) | Light green background (#D9EAD3) |
| 2 | Custom formula: `=$P2="Review Needed"` (adjust column letter for `Action`) | Light yellow background (#FFF2CC) |

> **Note:** Adjust the column letter (`$P2`) to match whichever column `Action` falls in. Count from column A in your extracted data.

### Highlight SCVs Already in Queue

To visually mark SCVs that have already been added to the Resubmission Queue:

1. Select all data rows in **All Candidates**
2. **Format** → **Conditional formatting**
3. Custom formula: `=COUNTIF('Resubmission Queue'!$A:$A, $A2) > 0`
4. Format: Blue background (#CFE2F3)

### Color Legend

| Color | Meaning |
|-------|---------|
| Light Green | Eligible for auto-reflag (no substantive changes) |
| Light Yellow | Needs manual review (substantive changes detected) |
| Light Blue | Already added to Resubmission Queue |
| No highlight | Not yet reviewed or queued |

---

## Workflow: Reviewing and Selecting SCVs

### Step 1: Review the Summary

1. Open the **By Submitter** tab
2. Note which labs have the most candidates and what percentage are eligible
3. Decide which labs to prioritize

### Step 2: Review Auto-Reflag Candidates

These SCVs had no substantive changes — the submitter version-bumped without addressing the flagging reason.

1. Open the **All Candidates** tab
2. Apply the **"Auto-Reflag Ready"** filter view
3. For each SCV (or in bulk):
   - Verify the `Original Flagging Reason` still applies
   - Optionally click `ClinVar VCV Link` to check the current ClinVar record
   - If approved, copy to the **Resubmission Queue** tab

**For bulk approval:** If you trust the auto-reflag criteria for a given lab, you can select all rows for that lab and copy them to the queue in one action. Use the "By Lab" filter views to isolate one lab at a time.

### Step 3: Review "Review Needed" SCVs

These SCVs had at least one substantive field change. They may or may not still warrant flagging.

1. Apply the **"Review Needed"** filter view
2. For each SCV:
   - Check the `Changes Since Submission` column to see what changed
   - Click `ClinVar VCV Link` to review the current assertion in ClinVar
   - Decide whether the change addresses the original flagging reason
   - If flagging is still warranted, add to the Resubmission Queue with notes

### Step 4: Export for Submission

1. Open the **Resubmission Queue** tab
2. Filter by `Status` = "Pending"
3. Export the required columns (SCV ID, Current SCV Version, Variation ID, Original Flagging Reason) as CSV
4. Submit to ClinVar following the standard CVC batch submission process
5. After submission, update `Status` to "Submitted" and fill in `Submission Date`

### Step 5: Refresh After Next Release

After the next ClinVar release and pipeline re-run:

1. Re-connect to BigQuery and re-extract the data (or create a new sheet)
2. Check if previously submitted SCVs are now flagged
3. Any SCVs still unflagged after resubmission will appear again in the next cycle

---

## Column Reference: All Candidates Tab

| Column | Description |
|--------|-------------|
| `SCV ID` | The submission accession (e.g., SCV000123456) |
| `ClinVar VCV Link` | Click to view variant in ClinVar |
| `Variation ID` | Internal variation identifier |
| `Submitter Name` | Lab/organization name |
| `Target Lab` | Which of the 7 target labs |
| `Original Flagging Reason` | Why CVC originally flagged this SCV |
| `Original Batch ID` | CVC batch that submitted the flagging candidate |
| `Original Submission Date` | When ClinVar accepted the submission |
| `Current Outcome` | Current status from flagging candidate tracking |
| `Was Ever Flagged` | "Yes" or "No — Grace period bump" |
| `Date Flag Applied` | When the flag was applied (blank if never flagged) |
| `Date Flag Removed` | When the flag was removed (blank if never flagged) |
| `Submitted SCV Version` | Version when CVC submitted the flagging candidate |
| `Current SCV Version` | Current version in ClinVar |
| `Version Bumps Since Submitted` | Number of version increments since submission |
| `Current Classification` | Current classification abbreviation |
| `Current Classification Type` | Current classification type |
| `Changes Since Submission` | "None — Ready to Re-Flag" or list of changed fields |
| `Action` | "Auto-Reflag" or "Review Needed" |

---

## Refreshing Data

The underlying BigQuery view (`sheets_autoreflag_actionable`) reflects data from when the CVC Impact Analysis pipeline was last run. If data seems stale:

1. Check when the pipeline was last run:
   ```sql
   SELECT MAX(batch_accepted_date) FROM clinvar_curator.cvc_autoreflag_candidates;
   ```
2. Re-run step 08 of the pipeline:
   ```bash
   cd scripts/clinvar-curation/cvc-impact-analysis
   bq query --use_legacy_sql=false --project_id=clingen-dev < 08-autoreflag-candidates.sql
   ```
3. Re-extract the data in Google Sheets

See the "Keeping Data Current" section in [GOOGLE-SHEETS-SETUP.md](GOOGLE-SHEETS-SETUP.md) for full pipeline re-run instructions.

---

## Questions?

- **Data issues**: Contact the ClinVar data team
- **BigQuery access**: Request access through IT
- **Workflow questions**: Contact the CVC curation lead
- **Auto-reflag criteria**: See the background section in Charts 9a/9b of [GOOGLE-SHEETS-SETUP.md](GOOGLE-SHEETS-SETUP.md)

---

## Version History

| Date | Version | Changes |
|------|---------|---------|
| 2026-06-10 | 1.0 | Initial version |
