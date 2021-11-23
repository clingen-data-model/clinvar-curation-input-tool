# clinvar-scv-curator-ext
Chrome extension to allow curators to capture SCV data to a google sheet directly from clinvar website.

## Release Notes

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
