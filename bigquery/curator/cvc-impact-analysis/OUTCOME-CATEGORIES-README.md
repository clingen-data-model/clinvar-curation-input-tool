# Flagging Candidate Attrition Funnel — Outcome Categories

When CVC submits a "flagging candidate" to ClinVar requesting that an outlier SCV be flagged, the submission doesn't always result in a flag. This reference describes each outcome category used in Charts 1a (funnel) and 1b (pie).

Every flagging candidate submission is placed into exactly one mutually exclusive category. Categories are evaluated in priority order — the first matching rule wins.

---

## Category Definitions

### 01. Flagged
The CVC flag was successfully applied to the SCV (rank set to -3). The submitter's outlier assertion is now excluded from ClinVar's aggregate classification. This is the primary measure of CVC success.

### 02. Reclassified
The submitter changed their clinical classification (e.g., Pathogenic to VUS) before or instead of being flagged. The conflict was resolved because the submitter reconsidered their assertion. This is a positive outcome — the submitter self-corrected.

### 03. Removed
The submitter deleted their SCV entirely before or instead of being flagged. The conflicting assertion no longer exists in ClinVar. Another form of submitter-initiated success.

### 04. Substantive Changes
The submitter made real, meaningful changes to their SCV — updated their last-evaluated date, added or removed PubMed citations, changed the condition, or updated the evidence summary — but kept the same clinical classification. The submitter engaged with the record but stood by their interpretation. Neither success nor evasion.

### 05. Within Grace Pending
The submission is from a recent CVC batch still within the 60-day grace period that ClinVar gives submitters before applying flags. Too early to determine the outcome.

### 06. Version Bump During Grace
The submitter resubmitted their SCV during the 60-day grace period with no substantive changes. None of the 6 key fields changed: classification, submitted classification, last evaluated date, condition, PubMed citations, or evidence summary. This resets the clock with ClinVar, effectively preventing the flag from being applied without addressing the clinical disagreement.

### 07. Version Bump After Grace
Same as above, but the version bump occurred after the 60-day grace period ended. The submitter resubmitted with no substantive changes, avoiding or removing the flag. Indicates a pattern of continued bumping.

### 08. Stale at Submission
When NCBI accepted the CVC batch, the SCV version CVC referenced was already outdated — the submitter had already updated the SCV before the batch was processed. NCBI should have rejected this submission but didn't. This is a gap in NCBI's validation process, not a CVC issue.

### 09. Unflagged (CVC Requested Removal)
CVC submitted a "remove flagged submission" for this SCV after the original flagging candidate was submitted. This means CVC explicitly decided the flag should be removed — the SCV is intentionally not flagged. This supersedes all other outcomes except rejection. These are not anomalies.

### 10. Anomaly — Should Flag
The SCV is past the 60-day grace period, has the same version as when CVC submitted the flagging candidate, has no CVC removal request, and is still not flagged. By all logic this SCV should have been flagged but wasn't. Common causes include: submitter disputed directly with NCBI, the conflict resolved organically, or a missing rejection record. These need investigation.

### 11. Rejected by NCBI
NCBI rejected the CVC submission before processing it (e.g., version mismatch, deleted SCV, submitter dispute). The submission never entered the grace period. Excluded from outcome analysis since it reflects submission mechanics, not curation effectiveness.

### 12. Other/Unknown
Edge cases that don't fit any category above. Typically caused by SCVs from batches missing acceptance dates, or unexpected data states. These should be rare and are worth investigating individually.

---

## Category Groupings

| Group | Categories | What it means |
|-------|------------|---------------|
| **Success** | Flagged, Reclassified, Removed | The conflict was addressed — either by CVC flag or submitter action |
| **Neutral** | Substantive Changes | Submitter made real changes but maintained their classification |
| **In Progress** | Within Grace Pending | Too early to determine outcome |
| **Concerning** | Version Bump During Grace, Version Bump After Grace | Submitter avoided flag without making substantive changes |
| **CVC Action** | Unflagged | CVC explicitly requested flag removal after the original flagging candidate |
| **Process Issues** | Stale at Submission, Anomaly, Rejected by NCBI | Issues requiring investigation or outside normal workflow |
| **Edge Cases** | Other/Unknown | Rare situations not covered by other categories |

---

## How to Read the Funnel (Chart 1a)

The funnel starts with all submitted flagging candidates (100%) and shows how many end up in each outcome. The stacked bar breaks down where submissions "went."

- **Green segments** (Flagged, Reclassified, Removed) — Success. The conflict was addressed.
- **Yellow segment** (Substantive Changes) — Neutral. Submitter engaged but disagreement persists.
- **Red/Orange segments** (Version Bumps) — Concerning. Submitter avoided flags without meaningful changes.
- **Teal segment** (Unflagged) — CVC explicitly requested flag removal for these SCVs.
- **Light Purple segment** (Stale at Submission) — NCBI accepted a stale version reference.
- **Purple segment** (Anomaly) — Should have been flagged but wasn't. Needs investigation.
- **Gray segments** (Rejected, Other) — Out of scope or edge cases.

The green-to-red ratio is the core metric: it shows how effective CVC's flagging program is versus how much impact is lost to version bump evasion.

---

## The 6 Substantive Fields

Categories 04, 06, and 07 depend on whether the submitter changed any of these fields between the submitted version and the current version:

| Field | What it represents |
|-------|--------------------|
| Classification type | Clinical significance category (e.g., Pathogenic, VUS) |
| Submitted classification | Free-text classification provided by the submitter |
| Last evaluated | Date the submitter last evaluated the variant |
| Condition/trait | The disease associated with the assertion |
| PubMed citations | Ordered list of PubMed IDs cited as evidence |
| Evidence summary | Interpretation text or evidence description |

If none of these changed, the version change is a "version bump" (categories 06-07). If any changed, it's a "substantive change" (category 04).

---

## Priority Order

Categories are evaluated top to bottom. The first match wins:

1. Rejected by NCBI
2. Unflagged (CVC requested removal)
3. Flagged
4. Reclassified
5. Removed
6. Version Bump During Grace
7. Version Bump After Grace
8. Substantive Changes
9. Stale at Submission
10. Anomaly — Should Flag
11. Within Grace Pending
12. Other/Unknown

This means, for example, that an SCV where CVC requested removal is always categorized as "Unflagged" even if the SCV is currently flagged (NCBI hasn't processed the removal yet) or had a version bump.

---

## Chart Colors

| Category | Color | Hex |
|----------|-------|-----|
| Flagged | Dark Green | #1B7F37 |
| Reclassified | Light Green | #6AA84F |
| Removed | Medium Green | #93C47D |
| Substantive Changes | Yellow | #F1C232 |
| Within Grace Pending | Light Gray | #B7B7B7 |
| Version Bump During Grace | Red | #CC0000 |
| Version Bump After Grace | Orange | #E69138 |
| Stale at Submission | Light Purple | #B4A7D6 |
| Unflagged | Teal | #0097A7 |
| Anomaly — Should Flag | Purple | #674EA7 |
| Rejected by NCBI | Gray | #666666 |
| Other/Unknown | Dark Gray | #999999 |

---

*Source: `clinvar_curator.sheets_flagging_candidate_funnel_pivoted` and `clinvar_curator.sheets_flagging_candidate_pie`*
*Pipeline: `scripts/clinvar-curation/cvc-impact-analysis/06-version-bump-flagging-intersection.sql`*
