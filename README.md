# ClinVar Curation Chrome Extension

A Chrome extension used in the [ClinGen](https://clinicalgenome.org/) curation workflow to help curators evaluate and annotate ClinVar submission (SCV) records. The extension scrapes ClinVar variation pages, presents submission data in a structured form, and captures curation decisions to a secured Google Sheet for downstream processing.

## How It Works

1. **Data Extraction** -- The extension's content script scrapes ClinVar variation pages to extract VCV-level and SCV-level submission data (submitter, interpretation, dates, review status).
2. **Annotation Capture** -- Curators select an action and reason for each SCV through the extension popup, optionally adding notes.
3. **Data Persistence** -- Annotations are appended to a secured Google Sheet via the Sheets API v4 with OAuth2 authentication.
4. **Downstream Processing** -- The captured curations feed into QC reports, statistics, and submissions to NCBI ClinVar to support integration into the ClinVar dataset.

## Curation Actions

| Action | Purpose | Reason Required? |
| ------ | ------- | ---------------- |
| **Flagging Candidate** | Mark SCV submissions that may need re-assessment or removal | Yes |
| **Remove Flagged Submission** | Process SCV submissions that were previously flagged | Yes |
| **No Change** | Document that an SCV was reviewed and no action is needed | No |

### Flagging Candidate Reason Categories

- **Submission errors** -- Duplicate submissions, data entry mistakes
- **Unnecessary Conflicting or Case-level Interpretation Submissions** -- Case-level interpretations, artificial conflicts
- **Old/Outlier/Unsupported Submissions** -- Outdated, outlier, or insufficiently evidenced claims
- **Miscellaneous** -- Non-monogenic phenotype classifications, other

See the [Curation Criteria Guide](docs/CURATION_CRITERIA_GUIDE.md) for detailed criteria on when to use each action and reason.

## Prerequisites

- Google Chrome browser
- Browser profile synced with a Google account (required for OAuth2 authentication)
- Access granted to the project's secured Google Sheet

## Installation

1. Clone or download this repository
2. Open Chrome and navigate to `chrome://extensions/`
3. Enable **Developer mode** (toggle in the top right)
4. Click **Load unpacked** and select the `scvc/` directory
5. The ClinVar Curator extension will appear in Chrome's toolbar

## Usage

1. Navigate to a ClinVar variation page (e.g., `https://www.ncbi.nlm.nih.gov/clinvar/variation/12345/`)
2. Click the ClinVar Curator extension icon in the toolbar
3. The popup will display extracted VCV and SCV data from the page
4. Select an SCV submission to annotate
5. Choose an **Action** and **Reason** from the dropdowns
6. Add optional **Notes** for additional context
7. Click **Submit** to append the annotation to the Google Sheet

## Development

This is a vanilla JavaScript Chrome extension with no build system or package manager. The extension code lives entirely in the `scvc/` directory.

### Project Structure

```text
scvc/
  manifest.json   -- Chrome Extension Manifest v3 configuration
  background.js   -- Service worker for auth, Sheets API, message passing
  content.js      -- Content script that extracts data from ClinVar pages
  popup.js        -- Popup UI logic, form validation, user interactions
  popup.html      -- Extension popup interface
  popup.css       -- Popup styling

testing/          -- Unit testing infrastructure
docs/             -- Curation criteria documentation
```

### Running Tests

```bash
cd testing
npm install
npm test
```

Tests use JSDOM to simulate the browser DOM and validate data extraction against saved ClinVar HTML samples in `testing/html-samples/`.

## Known Limitations

- **ClinVar UI dependency** -- The extension scrapes ClinVar page HTML using XPath selectors and regex patterns. When NCBI updates the ClinVar UI, the extension frequently breaks and requires updates to the extraction logic in `content.js`.
- **No offline support** -- Requires an active internet connection for both ClinVar page access and Google Sheets API calls.
- **Single-page scope** -- The extension only operates on ClinVar variation pages (`https://www.ncbi.nlm.nih.gov/clinvar/variation/*`).

## Changelog

See [Releases](https://github.com/clingen-data-model/clinvar-curation-input-tool/releases) for version history and release notes.
