# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains the ClinVar Curation Chrome Extension (v3.2), a specialized tool for ClinGen curation workflow. The extension scrapes ClinVar UI HTML to create a form that allows curators to capture actions and reasons related to ClinVar submissions (SCVs) that may need re-assessment or removal to improve ClinVar data quality.

## Architecture

### Core Components

- **scvc/manifest.json** - Chrome Extension Manifest v3 configuration with OAuth2 Google Sheets integration
- **scvc/background.js** - Service worker handling authentication, Google Sheets API calls, and message passing
- **scvc/content.js** - Content script that extracts ClinVar data from NCBI pages using regex and XPath
- **scvc/popup.js** - Popup UI logic for annotation forms, validation, and user interactions
- **scvc/popup.html** - Extension popup interface (not tracked but referenced)

### Data Flow Architecture

1. **Data Extraction**: Content script scrapes ClinVar variation pages using XPath selectors and regex patterns
2. **UI Population**: Extracted data populates the extension popup with SCV submission details
3. **Annotation Capture**: Users select actions (Flagging Candidate, Remove Flagged Submission, No Change) and reasons
4. **Authentication**: Background script handles Google OAuth2 authentication and user profile retrieval  
5. **Data Persistence**: Annotations are appended to secured Google Sheets via Sheets API v4

### Key Data Structures

The `extractClinVarData()` function in content.js extracts:
- VCV accession and variation ID
- Variant name and germline classification
- Review status and evaluation dates
- SCV submission details (submitter, interpretation, dates, review status)

### Google Sheets Integration

- **Production Spreadsheet**: `1dUnmBZSnz3aeB948b7pIq0iT7_FuCDvtv6FXaVsNcOo`
- **Test Spreadsheet**: `1HVQgZ_uGkzaazgIgz86h-5H-oEfHFFllwqT5jJbw6Do` (used in popup.js)
- **Range**: 'SCVs' sheet for appending curation data
- **OAuth Scope**: `https://www.googleapis.com/auth/spreadsheets`

### Page Target and Permissions

- **Host Permissions**: `https://www.ncbi.nlm.nih.gov/clinvar/variation/*`
- **Content Script Matching**: ClinVar variation pages only
- **Required Permissions**: activeTab, scripting, identity, storage, declarativeContent, tabs

## Common Development Tasks

### Testing the Extension

This is a Chrome extension with no automated tests. Testing requires:

1. Load extension in Chrome developer mode from the `scvc/` directory
2. Navigate to a ClinVar variation page (e.g., `https://www.ncbi.nlm.nih.gov/clinvar/variation/12345/`)
3. Click the extension icon to test data extraction and UI functionality
4. Verify Google Sheets integration with proper OAuth authentication

### Extension Installation

1. Open Chrome and navigate to `chrome://extensions/`
2. Enable "Developer mode"
3. Click "Load unpacked" and select the `scvc/` directory
4. The extension will appear in Chrome's toolbar

### Key Regex Patterns

The content script uses several critical regex patterns that may need updates when ClinVar UI changes:
- `subm_scv_re`: Extracts submitter info and SCV accessions
- `interp_re`: Captures interpretation and evaluation dates  
- `review_method_re`: Matches review status and method information
- `vcv_accession_re` & `vcv_variation_id_re`: Extract VCV identifiers

### Error Handling

The extension includes comprehensive error handling for:
- Authentication failures (OAuth token issues)
- Missing user profile information
- Google Sheets API errors
- Content script data extraction failures
- Form validation (required fields, action-reason dependencies)

### Curation Workflow

The extension supports these annotation actions:
- **Flagging Candidate**: Mark submissions for potential removal with categorized reasons
- **Remove Flagged Submission**: Process already flagged submissions  
- **No Change**: Document review with no action required

Reason categories for flagging include submission errors, unnecessary conflicting interpretations, and old/outlier/unsupported submissions.

## Important Notes

- No package.json, build system, or automated testing - this is a vanilla JavaScript Chrome extension
- The extension frequently breaks due to ClinVar UI changes requiring updates to XPath selectors and regex patterns
- Production uses different spreadsheet ID than the one hardcoded in popup.js
- All console logging includes timestamps for debugging message passing between scripts
- Extension requires users to sync their browser profile with Google account for authentication