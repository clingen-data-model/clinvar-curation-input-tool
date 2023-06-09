# clinvar-scv-curator-ext
Chrome extension to allow curators to capture SCV data to a google sheet directly from clinvar website.

## Release Notes
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
