# ClinVar SCV Curation Criteria Guide

This document outlines the conditions and criteria for when curators should tag submissions (SCVs) with specific actions and reasons in the ClinVar Curation Chrome Extension.

---

## Overview of Actions

The extension supports three curation actions:

| Action | Purpose | Reason Required? |
|--------|---------|------------------|
| **Flagging Candidate** | Mark SCV submissions that may need re-assessment or removal to improve ClinVar data quality | Yes |
| **Remove Flagged Submission** | Process SCV submissions that were previously flagged for removal | Yes |
| **No Change** | Document that an SCV has been reviewed and no action is needed | No |

---

## Action 1: Flagging Candidate

Use this action when an SCV submission has quality issues that warrant potential removal or re-assessment. Reasons are organized into three categories.

### Category 1: Submission Errors

These reasons address fundamental submission mistakes.

#### "New submission from submitter that appears to have been intended to update this older submission"

**When to use:**
- The same submitter has created a newer SCV for the same variant
- The older submission appears to be superseded by the new one
- The submitter likely intended to update their existing submission but created a duplicate instead
- Both submissions exist in ClinVar, creating unnecessary conflict or redundancy

**Evidence to look for:**
- Multiple SCVs from the same submitter for the same variant
- Newer submission has more recent evaluation/submission date
- Newer submission may have updated interpretation or additional evidence
- Original submission was never updated or removed by the submitter

#### "Other submission error"

**When to use:**
- The submission contains an error that doesn't fit other specific categories
- There is an obvious data entry mistake in the submission
- The submission has incorrect variant information, condition mapping, or other data issues
- Catch-all for submission problems not covered by other reasons

**Evidence to look for:**
- Mismatched condition/gene associations
- Obvious data entry errors
- Submissions that don't make scientific sense for the variant

---

### Category 2: Unnecessary Conflicting or Case-level Interpretation Submissions

These reasons address submissions that create artificial conflicts or represent inappropriate interpretation types.

#### "Clinical significance appears to be a case-level interpretation inconsistent with variant classification"

**When to use:**
- The submission represents a clinical observation from a single patient case
- The interpretation is based on a specific patient's phenotype rather than variant-level evidence
- The clinical significance assigned is inconsistent with proper variant classification standards
- The submission conflates patient-level findings with variant-level classification

**Evidence to look for:**
- Language suggesting case-specific interpretation (e.g., "observed in patient with...")
- Lack of population-level or functional evidence
- Classification that doesn't align with ACMG/AMP guidelines for the available evidence
- Evidence is primarily or solely clinical observation from case(s)

#### "Unnecessary conflicting claim for distinct condition when other classifications are more relevant"

**When to use:**
- The submission asserts a classification for a condition that creates unnecessary conflict
- Other submissions with more relevant condition associations exist
- The conflicting claim is for a distinct/different condition than more authoritative submissions
- The conflict doesn't provide meaningful additional information

**Evidence to look for:**
- Multiple conditions associated with the variant
- The flagged submission's condition association is less relevant than others
- Other submissions (especially from VCEPs or larger labs) provide more appropriate classifications
- The conflict detracts from clarity rather than adding scientific value

---

### Category 3: Old/Outlier/Unsupported Submissions

These reasons address submissions that lack current scientific support or contradict expert-reviewed evidence.

#### "Older and outlier claim with insufficient supporting evidence"

**When to use:**
- The submission is both old (outdated) AND an outlier compared to other submissions
- The classification differs significantly from the consensus of other submitters
- The supporting evidence is insufficient by current standards
- Combines the criteria of being both temporally outdated and scientifically isolated

**Evidence to look for:**
- Old evaluation/submission date (relative to other submissions)
- Classification that disagrees with majority of other submitters
- Minimal or no evidence provided to support the outlier position
- Evidence cited is outdated or has been superseded

#### "Older claim that does not account for recent evidence"

**When to use:**
- The submission predates significant new evidence about the variant
- New publications, functional studies, or population data have emerged since the submission
- The classification might change if the submitter incorporated newer evidence
- The submission hasn't been updated despite availability of relevant new data

**Evidence to look for:**
- Old evaluation date compared to available evidence
- Publications or ClinGen classifications that post-date the submission
- Population frequency data (gnomAD updates) not reflected in submission
- Functional evidence that emerged after the submission date

#### "Claim with insufficient supporting evidence"

**When to use:**
- The submission lacks adequate evidence regardless of age
- The classification cannot be justified based on provided supporting data
- Does not meet evidence thresholds for the asserted classification
- Evidence quality or quantity is inadequate for the interpretation

**Evidence to look for:**
- Missing or vague assertion method
- No citations or minimal citations provided
- Evidence doesn't meet ACMG/AMP criteria for the classification level
- Review status of "no assertion criteria provided" or similar

#### "Outlier claim with insufficient supporting evidence"

**When to use:**
- The submission disagrees with the consensus of other submitters
- The outlier position is not supported by sufficient evidence
- There's no compelling scientific rationale for the differing classification
- The submission creates conflict without adequate justification

**Evidence to look for:**
- Classification differs from majority/consensus
- Other submitters (especially expert panels) have different classifications
- Limited or unconvincing evidence to justify the outlier position
- No recent updates to address the conflicting interpretations

#### "Conflicts with expert reviewed submission without evidence to support different classification"

**When to use:**
- A VCEP (Variant Curation Expert Panel) or Expert Panel has reviewed the variant
- The flagged submission conflicts with the expert-reviewed classification
- The submitter has not provided evidence sufficient to justify disagreeing with expert review
- Expert panel review represents a higher standard of evidence review

**Evidence to look for:**
- Presence of an expert panel submission (review status: "reviewed by expert panel")
- Conflicting classification from the flagged submission
- Flagged submission lacks equivalent quality evidence
- No compelling new evidence that would warrant different classification

#### "P/LP classification for a variant in a gene with insufficient evidence for a gene-disease relationship"

**When to use:**
- The variant is in a gene where the gene-disease relationship is not well established
- The submission classifies the variant as Pathogenic or Likely Pathogenic
- ClinGen Gene Curation has not confirmed (or has disputed) the gene-disease relationship
- The P/LP claim may be premature given uncertain gene validity

**Evidence to look for:**
- ClinGen gene-disease validity assessment is "Limited," "Disputed," or "Refuted"
- No ClinGen gene curation available for the condition
- The condition assertion may be based on insufficient gene-disease evidence
- Other scientific literature questions the gene-disease relationship

---

## Action 2: Remove Flagged Submission

Use this action when processing submissions that were previously flagged and now need final removal action.

#### "Other SCVs submitted for VCV record"

**When to use:**
- The flagged submission can be removed because other valid SCVs exist
- Removal won't leave the VCV record without submissions
- Other submissions adequately represent the clinical significance of the variant

#### "Gene-disease relationship classification has changed"

**When to use:**
- ClinGen or other authoritative sources have updated the gene-disease relationship
- Previous P/LP classifications are no longer appropriate
- Gene validity reclassification affects the relevance of the submission

#### "Discussion with submitter"

**When to use:**
- Contact was made with the original submitter
- Submitter agreed the submission should be removed or updated
- Follow-up action from prior flagging has been completed

#### "Curation error"

**When to use:**
- The original flagging was made in error
- Re-review determined the submission shouldn't have been flagged
- Correcting a prior curation mistake

---

## Action 3: No Change

Use this action when an SCV has been reviewed but no curation action is warranted.

**When to use:**
- The submission has been evaluated and found to be appropriate
- The submission may be old or differ from consensus but has valid supporting evidence
- The submitter's classification is defensible given their evidence and methods
- Review confirms the submission contributes meaningfully to ClinVar
- You want to document that an SCV was reviewed (audit trail)

**Reason is optional** for "No Change" actions. Use the Notes field to document your rationale if desired.

---

## Decision Tree Summary

```
Review SCV Submission
         │
         ├── Is there an obvious submission error?
         │         │
         │         ├── YES → Flagging Candidate: [Submission errors category]
         │         │
         │         └── NO ↓
         │
         ├── Is it a case-level interpretation or unnecessary conflict?
         │         │
         │         ├── YES → Flagging Candidate: [Unnecessary Conflicting category]
         │         │
         │         └── NO ↓
         │
         ├── Is it old, an outlier, or lacking evidence?
         │         │
         │         ├── YES → Flagging Candidate: [Old/Outlier/Unsupported category]
         │         │
         │         └── NO ↓
         │
         ├── Was this SCV previously flagged and needs removal action?
         │         │
         │         ├── YES → Remove Flagged Submission: [Select appropriate reason]
         │         │
         │         └── NO ↓
         │
         └── Submission is acceptable
                   │
                   └── No Change (optionally document in notes)
```

---

## Key Data Points to Consider During Review

When evaluating an SCV, curators should examine:

1. **SCV Metadata**
   - Submitter name and ID
   - Submission date and evaluation date
   - Review status (criteria provided, expert panel, etc.)
   - Assertion method

2. **Classification Details**
   - Clinical interpretation (P, LP, VUS, LB, B)
   - Associated condition(s)
   - Allele origin

3. **Context from VCV**
   - Overall VCV classification and review status
   - Other SCVs on the same VCV
   - Expert panel submissions present?
   - Total number and consensus of submissions

4. **External Resources**
   - ClinGen gene-disease validity
   - Recent publications
   - gnomAD population frequency data
   - ACMG/AMP guideline alignment

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | December 2025 | Initial documentation based on extension v3.2 |

---

*This document is based on the ClinVar Curation Chrome Extension v3.2 codebase and associated release notes.*
