# clinvar-curation-input-tool
This repository contains the ClinVar Curation Chrome Extension application and all input and output data designs.
The chrome extension is used by the ClinGen curation workflow (link) ...
- The chrome extension scrapes the ClinVar UI html to produce a form that allows the curators to capture actions and reasons related to clinvar submissions (SCVs) that may be in need of re-assessment or removal in the spirit of working to improve the quality of ClinVar data without being fully dependent on submitters to rectify historical anomolies and outdated information.
- The output of the chrome extension is captured in a secured google sheet that is available to admins associated with this project
- The google sheet containing these curations is then utilized by the downstream systems to generate QC reports, statitistics and submissions of these curations to be regularly submitted to NCBI clinvar to support the eventual integration into the actual ClinVar dataset.

## Release Notes

### v3.1
* ClinVar UI changes on Feb.24.2025 introduced issues with the top-level VCV information scraping from the html. This has been resolved.

### v3.0
* This is a combination of merging and modifying v1.16 and v2.0.2 below.
* Major update to the internal code and configuration based on Google chrome extension manifest v3 specifications.
* Removal and replacement of Google API (GAPI) which is no longer supported.
* Internal code refactoring and improvements for more reliable error handling.

### v1.16
* Issue #89 - add new flagging candidate reason resulting from discordance project
* Issue #90 - add new 'Remove Flagged Submission' action

### v1.15
* Fixed addeition minor UI changes related to EP and PG related VCVs from the 03.Jun.24 HTML updates from clinvar. see bug [#83](https://github.com/clingen-data-model/clinvar-curation-input-tool/issues/83) for more info.

### v1.14
* Fixed very minor bug introduced by a ClinVar UI html change to the VCV Germline DIV element. This minor change was introduced by ClinVar on 6/3/2024 and impacted the vcv_revstat and vcv_interp matching logic in content.js.

### v1.13 changes
* Added new combo flagging candidate reason 'Older and Outlier claim with insufficient supporting evidence'.
* Added requirement check that an action is selected.
* Added requirement check that a reason is selected for all Flagging Candidates.

### v1.12.2 bug fix
* Patched a bug causing the inability to read the SCV data in the Submitter column. This was introduced by a change in the underlying ClinVar UI during the 2/21/2024 release.

### v1.12.1 bug fix
* Patched a bug due to introduction of changed terms in ClinVar review_status' on Jan 29, 2024. `no assertion provided` was changed to `no classification provided`.

### v1.12 changes
* Reworked extension to find data in new UI released by ClinVar on Jan 29, 2024. [#72](https://github.com/clingen-data-model/clinvar-curation-input-tool/issues/72)

### v1.11 changes
* Changed data repository google sheet to prevent user direct access in order to prevent user's from changing data after capture.
* Fixed bug in capturing submitter name introduced in v1.10.

### v1.10 changes
This version required some considerable modifications to deal with the html changes to the ClinVar HTML in handling the new section at the bottom called "Flagged Submissions".
* Chrome extension broke due to new "Flagged Submission" UI. [#69](https://github.com/clingen-data-model/clinvar-curation-input-tool/issues/69) 
* In the chrome extension change 'non-contributory' to 'flagging candidate' [#68](https://github.com/clingen-data-model/clinvar-curation-input-tool/issues/68)

### v1.9.8 changes
* Update Non-contributory category headings (missed in 1.9.7) [#57](https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/57)

### v1.9.7 changes
* Modify text of several Non-contributory reasons (and update historical data to match modified text) [#58](https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/58)
* Update Non-contributory action reasons (remove some, modify text of others) [#57](https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/57)
* Remove Follow Up option [#57](https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/57)
* Remove ability to annotate a VCV [#57](https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/57)

### v2.0.2 changes
* Updated category headings that were missed in the 2.0.1 release [#57](https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/57)

### v2.0.1 changes
* Modify text of several Non-contributory reasons (and update historical data to match modified text) [#58](https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/58)
* Update Non-contributory action reasons (remove some, modify text of others) [#57](https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/57)
* Remove Follow Up option [#57](https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/57)
* Remove ability to annotate a VCV [#57](https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/57)

### v2.0 changes
* Update the chrome extension manifest from v2 to v3.

### v1.9.6 changes
* Remove the non-contributory reason "VUS/LB/B claim when a mutually exclusive disease association is P/LP" [#42](https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/42)
* Remove Override option [#41](https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/41)

### v1.9.5 changes
* Updating "Follow up" and "Non-Contributory" reasons in Chrome extension #39 (https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/39)

### v1.9.4 changes
* Updating "Follow up" reasons in Chrome extension #37 (https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/37)

### v1.9.3 changes
* Updating "Follow up" reasons in Chrome extension #35 (https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/35)

### v1.9.2 changes
* (bug fix) ClinVar recently updated the html display which the chrome extension depends on. Minor change to pick up the 'most recent submission date' at the variation level and the 'Last updated' date (or last submission date) from the SCV level. (https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/32)

### v1.9.1 changes
* (bug fix) VCV records that had no Last Evaluation Date caused fields to be mis-mapped (see [git issue #29](https://github.com/clingen-data-model/clinvar-scv-curator-ext/issues/29) )

### v1.9 changes
* Add ability to select VCV to the drop down list for No change & Follow up actions

### v1.8 changes
* Add new action 'Follow Up' with the following reason codes:
  * Contact submitter for clarification
  * Flag for another curator to review
  * Send to VCEP to review
  * Other
* Filter Reason lists based on Selected Action code.

### v1.7 changes
* Change Action 'Exclude' to 'Non-contributory'
* Disable entry of 'Reason' when 'No Change' action is selected
* Change background page to persist in order to eliminate lost connections
* Modify Reason list to reflect categories from SC/ESP presentation
  * Submission errors:
    * New submission from submitter that appears to have been intended to update this older submission
    * Submitter acknowledged an error and the submission will be updated or removed
  * Inappropriate submissions:
    * Clinical significance appears to be a case-level interpretation inconsistent with variant classification
  * Unnecessary conflicting submissions:
    * VUS/LB/B claim when a mutually exclusive disease association is P/LP
    * Unnecessary VUS/LB/B claim for distinct condition when other interpretations are pathogenic
  * Lack of contradictory evidence when other submissions show valid evidence:
    * Older claim that does not account for recent evidence
    * P or LP claim with insufficient evidence to meet at least LP based on ACMG guidelines
    * Claim without supporting evidence provided
    * Conflicts with expert reviewed submission without evidence to support different classification
  * Other

### v1.6 changes
This is the version intended for use in the Oct/Nov '21 VCEP Pilot project
* Exclusion Reason List Updates
  * Consolidated "P/LP claim without supporting evidence provided" and "VUS claim without supporting evidence" into "Claim without supporting evidence provided"
  * Changed "Review by VCEP, no evidence has been provided to dispute this classification" to "Conflicts with expert reviewed submission without evidence to support different classification"
  * Changed "Unnecessary benign claim when other interpretations are pathogenic" to "Unnecessary benign claim for distinct condition when other interpretations are pathogenic"
  * Removed "Reviewed by VCEP, VCEP needs to recurate variant based on new evidence"
  * Added "Clinical significance appears to be a case-level interpretation inconsistent with variant classification"


### v1.5.5 changes
* Added a notification on submit if the user's profile is not sync'd with their google account.

### v1.5.4 changes
* Improved error handling and alerting to users when reload is needed
* Upgraded bootstrap css library from beta to 5.1.1
* Added debugging to display google user info to identify inconsistencies across users.

### v1.5.3 changes
* Added more error logging
* Removed disabled and readonly settings on Reason and Notes fields by default
* Add 1 new entries to drop down for rules...
  * “Unnecessary benign claim when other interpretations are pathogenic”

### v1.5.2 changes
* Add 2 new entries to drop down for rules...
  * “Review by VCEP, no evidence has been provided to dispute this classification”
  * “Reviewed by VCEP, VCEP needs to recurate variant based on new evidence”

### v1.5.1 changes
* Added debugging code to gather analytics on why some installations are freezing.

### v1.5 changes

* Add 2 new entries to drop down for rules...
    * “New submission from submitter that appears to have been intended to update this older submission”
    * “Submitter acknowledged an error and the submission will be updated or removed. “

* Replaced rule entry in dropdown from...
    * “Unnecessary benign claim when other interpretations are pathogenic”
    * “B/BL/VUS claim when a mutually exclusive disease association is P/LP”

* Added new Override fields: Condition, Inheritance

* Submitter field sometimes pulls from Study field. See lines 12-14 in spreadsheet
