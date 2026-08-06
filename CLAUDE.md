# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains ClinGen's ClinVar Curation (CvC) Chrome extension, which scrapes ClinVar variation pages so curators can capture actions/reasons on SCV submissions. There are **two extensions**:

- **`clinvar-cvc/` — v4, ACTIVE.** The current major version. Persists annotations to **Firestore → BigQuery** (not Google Sheets), with Google sign-in + a curator allowlist and dev/prod environment isolation. This is where new work happens.
- **`scvc/` — v3.4, LEGACY (do NOT modify).** The prior version that appends annotations to a Google Sheet. Kept intact as reference; the v4 work ports its value without changing it.

## clinvar-cvc — v4 (ACTIVE): Firestore/BigQuery extension

Built on the `clinvar-cvc/` foundation. **Do not modify `scvc/`.**

### Module layout (all vanilla JS, MV3, no build; each is dual-mode: `window.*` global in the browser, `module.exports` under Node/tests)
- `env.js` — `resolveConfig(env)`; per-environment public config (projectId/apiKey/databaseId/collection) for `prod`/`dev`.
- `firebase-config.js` — thin selector: `const ACTIVE_ENV = 'prod'|'dev'` → `FIREBASE_CONFIG`. **Flip `ACTIVE_ENV` here (not env.js) to trial dev**; a red DEV banner shows in the popup when not prod.
- `scrape.js` — `extractClinVarData(doc)`; refactored ClinVar page scraper (ported from `scvc/content.js`, behavior pinned by a characterization snapshot).
- `vocab.js` — `ACTIONS`, `reasonsForAction(action)`; the action/reason vocabulary.
- `annotation.js` — `buildAnnotation(scvRow, vcv, input, userEmail)` → the **v4 doc** (stamps `created_at` + `annotation_id = String(created_at.getTime())`); `validateAnnotation(data)`; `annotationDocId(doc)` = SHA-256 content hash of the exact entry fields (used as the **live** Firestore doc id for double-save dedup; the historical migration instead keys docs by `annotation_id` and does NOT dedup).
- `content.js` — content script; on `initializePopup` returns `scrape.extractClinVarData(document)`, AND on page load draws in-page controls on each SCV row (see in-page features below).
- `popup.html` / `popup.js` / `popup-view.js` — rich SCV-picker + action/reason/notes form; wires scrape → picker → reasons → save; guards non-ClinVar pages, closes on success (and reloads the tab so in-page highlights refresh). The "Prior annotations" panel shows the **selected** SCV's history (from `history.js`); the SCV dropdown appends `(CvC N)` counts.
- `history.js` — pure prior-annotation helpers: `buildHistoryQuery` (Firestore `runQuery` by `variation_id`, index-free), `parseHistoryRows`, `sortHistoryDesc`.
- `firestore-history.js` — shared auth+read: `getGoogleAuthToken`(interactive)/`getGoogleAuthTokenSilent`/`exchangeGoogleToken`/`silentIdToken`/`ensureWriteAuth` (silent→interactive) + `fetchHistory`; used by BOTH the popup and the service worker.
- `firestore-write.js` — shared create-only write: `toFirestoreFields`, `classifyWriteError`, `saveAnnotation` (content-hash doc id); used by the popup and the service worker.
- `highlight.js` — pure in-page decoration logic: `summarizeHistoryByScv`, `decorateForScv`, `entriesForScv`.
- `scv-sections.js` — the **SCV seam registry**: `SCV_SECTIONS` (row selector + inject cell for each of the 3 sections: germline, somatic clinical-impact, somatic oncogenicity), the global `ANNOTATABLE_SCV_SECTIONS` config (**default `['germline']`**; add somatic keys to enable) + `annotatableSections()`. Single source of truth shared by `scrape.js` (extraction) and `content.js`/`popup.js` (badge/picker gating).
- `dom-seams.js` — `inspectSeams(doc)`/`formatSeams`: a health-check over every named DOM location the scraper depends on (VCV header seams + the SCV-row seams from `scv-sections.js`), each with a loose presence/shape probe, so ClinVar markup drift is pinpointed to a seam instead of a silently-blank scrape. Mirrors `scrape.js` locators; a consistency test keeps them in sync.
- `background.js` — MV3 classic service worker; `importScripts` the shared modules and answers content-script messages `getScvHistory` (silent-auth read) and `saveAnnotation` (silent→interactive auth, create-only write). Content scripts can't mint tokens, so all Firestore auth for in-page features routes through here.
- `highlight.css` — `cvc-`prefixed styles for the in-page row badges/buttons + popover/form.

### In-page features (on the ClinVar variation page, via content.js + background.js)
- Each SCV row gets a blue **`+ Annotate`** span-badge (opens an in-page action/reason/notes form that saves via the worker) and, when the SCV has prior annotations, a dark-red **`CvC N`** span-badge (hover = last action/curator/date; click = popover listing that SCV's history). Both read/write route through the service worker's silent/interactive auth. All best-effort: any failure leaves the page untouched.
- `bigquery/annotations_view.sql` — flattened typed view over the extension's `annotations_raw_latest` (`COALESCE(scv, scv_id)` bridges v4/legacy field names). **Must be run per-project** (project id hardcoded; substitute `clingen-cvc-dev` for dev).
- `setup-clingen-cvc.sh` — scripts the automatable GCP provisioning; `add-curator.sh`/`remove-curator.sh`/`list-curators.sh` manage the allowlist.

### v4 annotation doc fields
`variation_id, vcv, name, scv, submitter, submitter_id, interp, review_status, action, reason, notes, user_email, created_at, annotation_id`. (`name` = variant name. Both `name` and `annotation_id` are intentionally EXCLUDED from the dedup hash — see `annotationDocId`. **`annotation_id` = `UNIX_MILLIS(created_at)` as a STRING, computed at write time and stored on the doc** (by `buildAnnotation` and the historical migration) so the BigQuery downstream reads it directly instead of recomputing `UNIX_MILLIS`.)

### GCP / environments
- **Prod** = project **`clingen-cvc`** (project number 493724081911). **Dev** = **`clingen-cvc-dev`** (362266755807) — a full isolated twin for trialing (writes stay in dev; verified 0 leak to prod). Both under the `broadinstitute.org` org (which — surprisingly — DID allow an External + In-production OAuth audience).
- Firestore `(default)` DB in **`nam5`** (US multi-region); BigQuery dataset `clinvar_cvc_ext` in `us-central1`; streaming via the **firestore-bigquery-export** Firebase Extension.

### Access control
Anyone can Google-sign-in (External audience); only accounts whose **verified email** has a doc in the **`allowed_curators`** collection may submit (enforced in `firestore.rules`; `user_email == request.auth.token.email`). Manage with `./add-curator.sh <email>` etc.

### Dedup
Every save is create-only with the doc id = `annotationDocId` (content hash of all entry fields except `created_at`), so an exact-match re-save by the same user returns `ALREADY_EXISTS` → "already saved" (atomic, concurrency-safe). This also makes the future history migration idempotent.

### Testing (this IS testable — unlike scvc)
`cd clinvar-cvc && npm install && npm test` (Vitest + jsdom). Pure logic is unit-tested; DOM/fetch wiring is manually verified in Chrome. A characterization snapshot pins the scraper so refactors are provably behavior-preserving.

### Operational findings / gotchas (full detail in `clinvar-cvc/README.md` Troubleshooting)
- **Install the Firestore→BigQuery extension via the Firebase CONSOLE**, not `firebase deploy --only extensions` — the CLI/manifest install does NOT run the extension's BigQuery setup (no dataset/table created) and does NOT grant the runtime SA its roles. Prod works because it was console-installed.
- **After ANY extension reinstall/reconfigure (dev or prod), re-grant `run.invoker`** to the trigger SA on the extension's Cloud Run service — reinstalling recreates the service and drops the binding, silently 403'ing events. (Also needed: `eventarc.publisher`, `bigquery.dataEditor/jobUser`, `cloudtasks.enqueuer` on the runtime SA — all baked into `setup-clingen-cvc.sh`.)
- The extension's **Firestore Database region param must match the DB** (`nam5`), not `us-central1`.
- A **named** Firestore DB has no Rules tab (deploy rules via the Firebase CLI); the `(default)` DB does. Use **Standard edition / Native mode** (NOT Enterprise/MongoDB, which has SCRAM/OIDC and no rules).
- The flattened BQ **view is created by running the SQL**, not by the extension — run it per project.

### Plans & roadmap
Implementation plans live in `docs/superpowers/plans/` (a program roadmap + per-subsystem TDD sub-plans, executed via superpowers subagent-driven-development in git worktrees). **Done:** S1 (env switch), S2 (test harness), S0 A–F (foundation port), capture fixes, **S6** (in-popup per-SCV history view), and the **in-page features** (S7: `CvC N` highlight badge + history popover, and click-to-annotate). **S4/S5** (Google-Sheet history → Firestore migration via `clinvar-cvc/migration/` reusing `annotationDocId`; allowlist backfill of historical `user_email`s) are **done in dev**; the **prod** load + allowlist are a staging step (`scvc/` Google-Sheet version stays live in parallel; prod may be re-loaded at true go-live). **Phase 0 (data layer, done):** the curator SQL is vendored into `bigquery/curator/` (parameterized by `@@DATASET@@`/`@@ANNO_SOURCE@@`/`@@MV@@`/`@@ANNO_ID@@`), and a **v4-sourced shadow lineage** is built beside the live sheet-sourced `clinvar_curator` and proven at parity — **without flipping** the live pipeline. The shadow is split dev/prod: `clinvar_curator_v4` (from prod capture `clingen-cvc`) and `clinvar_curator_v4_dev` (from dev capture `clingen-cvc-dev`), both fed by `adapter/refresh-native-v4.sh` (cross-region snapshot copy; `CVC_PROD`/`CURATOR_DATASET`/`GCS_PREFIX` env). `tests/06-annotation-id-roundtrip.sql` proves each shadow round-trips the legacy sheet (`annotation_id` + all core fields) with zero drift. **Remaining:** **S8** (repoint the Review&Submit `Generate.js`/`Reflag.js` batch pipeline to the new BQ table) — pulled into its own plan (`docs/superpowers/plans/2026-08-03-s8-repoint-pipeline.md`) as it needs deeper design, and gated on prod becoming the official system of record.

## Legacy extension architecture (`scvc/`, v3.4 — do not modify)

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

Reason categories for flagging include submission errors, unnecessary conflicting interpretations, old/outlier/unsupported submissions, and miscellaneous (including non-monogenic phenotype classifications).

## Important Notes

- No package.json, build system, or automated testing - this is a vanilla JavaScript Chrome extension
- The extension frequently breaks due to ClinVar UI changes requiring updates to XPath selectors and regex patterns
- Production uses different spreadsheet ID than the one hardcoded in popup.js
- All console logging includes timestamps for debugging message passing between scripts
- Extension requires users to sync their browser profile with Google account for authentication