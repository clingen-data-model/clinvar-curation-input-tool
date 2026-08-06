# CVC Resubmission Tracking Guide

This guide explains how to use the Google Sheet for tracking and managing CVC flagging candidate resubmissions.

---

## Overview

Some SCVs submitted as flagging candidates to ClinVar did not get flagged as expected. This happens when:

1. **Version Bump**: The submitter resubmitted their SCV without making real changes (same classification, same evidence), which can prevent flags from being applied
2. **Grace Period Expired**: The 60-day grace period ended but ClinVar did not apply the flag

This Google Sheet helps curators:
- Review which SCVs need resubmission
- Understand why each SCV wasn't flagged
- Mark SCVs for resubmission
- Export selected SCVs for batch resubmission

---

## Sheet Tabs

### Tab 1: Summary
**Data Source:** `clinvar_curator.sheets_resubmission_summary`

High-level overview showing counts by resubmission reason:

| Column | Description |
|--------|-------------|
| Reason for Resubmission | Why the SCV needs resubmission |
| Total SCVs | Total count of SCVs in this category |
| Ready to Resubmit | SCVs that can be immediately resubmitted |
| Needs Review - Reclassified | SCVs where submitter changed classification (needs manual review) |
| VCV Version Changed | Count where the variant record was updated |
| SCV Rank Changed | Count where the SCV's rank changed |
| Had Remove Flag Request | Count where CVC previously requested flag removal |
| Unique Submitters | Number of distinct submitters affected |
| Unique Variants | Number of distinct variants affected |

---

### Tab 2: Actionable
**Data Source:** `clinvar_curator.sheets_resubmission_actionable`

**Use this tab for SCVs ready for immediate resubmission** (excludes reclassified SCVs).

| Column | Description |
|--------|-------------|
| SCV ID | The submission accession (e.g., SCV000123456) |
| ClinVar VCV Link | Click to view variant in ClinVar |
| Variation ID | Internal variation identifier |
| Submitter Name | Name of the submitting lab/organization |
| Submitter ID | ClinVar submitter ID |
| Why Resubmission Needed | Reason: "Version bump", "Grace period expired", or "Both" |
| Original Flagging Reason | The reason we originally flagged this SCV |
| Date ClinVar Accepted | When ClinVar processed our submission |
| 60-Day Grace Period Ended | When the grace period expired |
| Days Past Grace Period | How many days since grace period ended |
| Current SCV Version | Current version number of the SCV |
| Current Classification | Current classification (e.g., P, LP, VUS) |
| Submitted SCV Rank | Rank when we submitted |
| Current SCV Rank | Current rank |
| SCV Rank Change | Shows change if rank differs |
| Submitted VCV Version | VCV version when we submitted |
| Current VCV Version | Current VCV version |
| VCV Version Change | Shows change if VCV version differs |
| Had Version Bump | Whether submitter did a version bump |
| Last Version Bump Date | When the last version bump occurred |
| Remove Flag Requested | Whether we previously requested flag removal |
| Remove Request Date | When we requested flag removal |
| Batch ID | Original CVC batch ID |

---

### Tab 3: Needs Review
**Data Source:** `clinvar_curator.sheets_resubmission_needs_review`

**SCVs where the submitter changed their classification.** These require manual review before deciding to resubmit.

| Column | Description |
|--------|-------------|
| SCV ID | The submission accession |
| ClinVar VCV Link | Click to view variant in ClinVar |
| Submitter Name | Name of the submitting lab/organization |
| Original Classification - When Submitted | Classification when we flagged |
| Current Classification - Now | Current classification |
| Classification Type Change | Shows the change (e.g., "path → vus") |
| SCV Rank Change | Shows rank change if any |
| VCV Version Change | Shows VCV version change if any |
| Why Resubmission Would Be Needed | Reason for potential resubmission |
| Original Flagging Reason | Why we originally flagged |
| Remove Flag Was Requested | Whether we requested flag removal |
| Remove Request Outcome | Result of flag removal request |
| Original Submission Date | When we originally submitted |
| Action Needed | Reminder to review classification |

---

### Tab 4: By Submitter
**Data Source:** `clinvar_curator.sheets_resubmission_by_submitter`

Shows which submitters have the most SCVs needing attention:

| Column | Description |
|--------|-------------|
| Submitter Name | Lab/organization name |
| Total SCVs Needing Action | Total count for this submitter |
| Ready to Resubmit | Count ready for immediate resubmission |
| Needs Review | Count requiring manual review |
| Due to Version Bump | Count due to version bumps |
| Due to Expired Grace Period | Count due to grace period expiration |
| Due to Both Reasons | Count with both issues |
| VCV Version Changed | Count with VCV changes |
| SCV Rank Changed | Count with rank changes |
| Had Remove Flag Request | Count with prior removal requests |
| Unique Variants Affected | Number of distinct variants |

---

### Tab 5: Glossary
**Data Source:** `clinvar_curator.sheets_resubmission_glossary`

Definitions of terms used in the other tabs.

---

### Tab 6: Resubmission Queue (Manual)

**This tab is for tracking SCVs you've reviewed and approved for resubmission.**

Create this tab manually with the following columns:

| Column | Description |
|--------|-------------|
| SCV ID | Copy from Actionable or Needs Review tab |
| Current SCV Version | Current version to submit against |
| Variation ID | Copy from source tab |
| VCV ID | Copy from source tab |
| Submitter ID | Copy from source tab |
| Flagging Reason | Copy original flagging reason |
| Reviewed By | Your name/initials |
| Review Date | Date you reviewed |
| Notes | Any notes about this resubmission |
| Status | "Pending", "Submitted", "Completed" |

---

## Workflow: Reviewing and Approving Resubmissions

### Step 1: Review Summary
1. Open the **Summary** tab
2. Note the total counts by reason
3. Prioritize based on volume and reason

### Step 2: Review Actionable SCVs
1. Open the **Actionable** tab
2. Filter or sort by:
   - **Why Resubmission Needed** - to focus on one category
   - **Submitter Name** - to batch by submitter
   - **Days Past Grace Period** - to prioritize oldest
3. Click **ClinVar VCV Link** to verify the current state
4. Check if the original flagging reason still applies

### Step 3: Review Reclassified SCVs
1. Open the **Needs Review** tab
2. For each SCV:
   - Compare **Original Classification** vs **Current Classification**
   - Decide if flagging is still appropriate
   - If yes, add to Resubmission Queue with notes

### Step 4: Add to Resubmission Queue
1. Copy approved SCVs to the **Resubmission Queue** tab
2. Fill in reviewer name and date
3. Set Status to "Pending"

### Step 5: Export for Submission
1. Filter Resubmission Queue by Status = "Pending"
2. Export to CSV for batch submission
3. After submission, update Status to "Submitted"

---

## Connecting to BigQuery Data

### Initial Setup

1. Open Google Sheets
2. Go to **Data** > **Data connectors** > **Connect to BigQuery**
3. Select project: `clingen-dev`
4. Select dataset: `clinvar_curator`
5. Create tabs for each view:

| Tab Name | View to Connect |
|----------|-----------------|
| Summary | `sheets_resubmission_summary` |
| Actionable | `sheets_resubmission_actionable` |
| Needs Review | `sheets_resubmission_needs_review` |
| By Submitter | `sheets_resubmission_by_submitter` |
| Glossary | `sheets_resubmission_glossary` |

### Refreshing Data

- Click **Data** > **Data connectors** > **Refresh data**
- Or click the refresh icon in the Connected Sheets sidebar

---

## Future Enhancement: Apps Script Automation

A Google Apps Script can be added to automate the resubmission queue workflow.

### Planned Features

1. **"Add to Queue" Button**
   - Select rows in Actionable tab
   - Click button to copy to Resubmission Queue
   - Auto-fills reviewer, date, and status

2. **"Export for Submission" Button**
   - Filters queue for "Pending" status
   - Generates CSV in required format
   - Downloads or saves to Drive

3. **"Mark as Submitted" Button**
   - Select rows in queue
   - Updates status to "Submitted"
   - Records submission date

### Implementation Notes

The Apps Script would need to:
- Read from Connected Sheets data
- Write to the manual Resubmission Queue tab
- Generate properly formatted export files

Contact the data team when ready to implement this automation.

---

## Conditional Formatting: Highlighting Queued SCVs

To visually identify which SCVs in the Actionable/Needs Review tabs have already been added to the Resubmission Queue, use the Apps Script function or manual conditional formatting.

### Using the Apps Script (Recommended)

1. From the **CVC Tools** menu, click **Highlight Queued SCVs**
2. The script will:
   - Scan the Resubmission Queue for SCV IDs
   - Highlight matching rows in Actionable tab with light green
   - Highlight matching rows in Needs Review tab with light green
3. Re-run this after adding new items to the queue

### Manual Conditional Formatting Setup

If you prefer manual setup:

1. Go to the **Actionable** tab
2. Select all data rows (e.g., A2:T1000)
3. Go to **Format** > **Conditional formatting**
4. Set "Format cells if": **Custom formula is**
5. Enter formula: `=COUNTIF('Resubmission Queue'!$A:$A, $A2) > 0`
6. Set formatting: Light green background
7. Click **Done**

Repeat for the **Needs Review** tab.

### Color Legend

| Color | Meaning |
|-------|---------|
| Light Green | SCV is already in Resubmission Queue |
| No highlight | SCV has not been queued for review |

---

## Questions?

- **Data issues**: Contact the ClinVar data team
- **BigQuery access**: Request access through IT
- **Workflow questions**: Contact the CVC curation lead

---

## Version History

| Date | Version | Changes |
|------|---------|---------|
| 2026-02-16 | 1.0 | Initial version |
