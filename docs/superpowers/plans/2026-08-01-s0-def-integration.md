# S0 D–F: Foundation Integration (content script, rich popup, v4 BQ view)

> **For agentic workers:** REQUIRED: superpowers:subagent-driven-development (or
> superpowers:executing-plans). `- [ ]` checkboxes; execute in a worktree; use
> @superpowers:test-driven-development. Builds directly on the merged A–C modules
> (`scrape.js`, `vocab.js`, `annotation.js`) and the existing `clinvar-cvc/`
> auth/Firestore/allowlist popup infrastructure. Parent: the S3→S0 plan
> (`docs/superpowers/plans/2026-08-01-s3-s0-foundation-port.md`).

**Goal:** Wire the three pure foundation modules into the working production
capture flow: a content script that scrapes ClinVar pages, a rich SCV-picker/
action-reason-notes popup that writes the full v4 annotation via the existing
Google-sign-in + allowlist + Firestore path, and a BigQuery view surfacing the v4
fields. `scvc/` stays untouched.

**Architecture:** Content script = `scrape.js` (global) + a thin `content.js`
message handler. Popup loads `env.js`→`firebase-config.js`→`vocab.js`→
`annotation.js`→`popup.js`; on open it messages the content script for scraped
data, populates the SCV picker, drives reasons from `vocab.js`, and on save builds
the v4 doc with `annotation.buildAnnotation` and writes it through the existing
`ensureAuth`/`saveAnnotation` path. Testable logic is extracted into pure helpers;
DOM wiring is thin and manually verified.

**Tech stack:** Chrome MV3 (vanilla JS, no build), Vitest+jsdom, Firestore REST.
No remote scripts/styles (MV3 CSP) — hand CSS, no Bootstrap CDN.

**Depends on (already merged):** `scrape.js` (`window.extractClinVarData`),
`vocab.js` (`ACTIONS`, `reasonsForAction`), `annotation.js` (`buildAnnotation`,
`validateAnnotation`), and `popup.js`'s `ensureAuth`/`saveAnnotation`/`toFirestoreFields`.

---

## File Structure

- Create `clinvar-cvc/content.js` (+ `clinvar-cvc/test/content.test.js`)
- Modify `clinvar-cvc/manifest.json` (host_permissions, content_scripts, permissions)
- Modify `clinvar-cvc/vocab.js` (IIFE-wrap the internal `var` objects — carry-over from Chunk B review)
- Create `clinvar-cvc/popup-view.js` (+ `clinvar-cvc/test/popup-view.test.js`) — pure popup helpers
- Modify `clinvar-cvc/popup.html` (rich form; load module scripts)
- Modify `clinvar-cvc/popup.js` (request scrape data, populate picker, wire reasons + save)
- Modify `clinvar-cvc/bigquery/annotations_view.sql` (v4 columns)

---

## Chunk D: content script + manifest

### Task D1: `content.js` message handler (TDD)

**Files:** Create `clinvar-cvc/content.js`, `clinvar-cvc/test/content.test.js`. Uses fixture `test/fixtures/clinvar-variation.html`.

- [ ] **Step 1: Write the failing test** (`clinvar-cvc/test/content.test.js`)

```js
import { describe, it, expect, beforeEach } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { handleInitializePopup } = require('../content.js');
const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, 'fixtures/clinvar-variation.html'), 'utf8');

describe('content.handleInitializePopup', () => {
  beforeEach(() => { document.documentElement.innerHTML = html; });
  it('returns scraped data for an initializePopup message', () => {
    const data = handleInitializePopup({ from: 'popup', subject: 'initializePopup' }, document);
    expect(data).not.toBeNull();
    expect(data.vcv).toBe('VCV000590935.4');
    expect(data.row.length).toBe(3);
  });
  it('returns null for unrelated messages', () => {
    expect(handleInitializePopup({ from: 'popup', subject: 'other' }, document)).toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd clinvar-cvc && npx vitest run test/content.test.js` — Expected: FAIL (no module).

- [ ] **Step 3: Implement `clinvar-cvc/content.js`**

Mirror `scvc/content.js`'s structure but use the refactored scraper (exposed as the
global `extractClinVarData` by `scrape.js`, which the manifest loads first in the
same content-script context). Extract a pure, testable handler:
```js
// Pure handler — testable without chrome.
function handleInitializePopup(message, doc) {
  if (message && message.from === 'popup' && message.subject === 'initializePopup') {
    // In the browser, extractClinVarData is a global from scrape.js; in tests it's required.
    const extract = (typeof window !== 'undefined' && window.extractClinVarData) ||
                    require('./scrape.js').extractClinVarData;
    return extract(doc);
  }
  return null;
}

// Browser wiring (skipped under Node/tests).
if (typeof chrome !== 'undefined' && chrome.runtime) {
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    const data = handleInitializePopup(message, document);
    if (data !== null) { sendResponse(data); }
    return true;
  });
}

if (typeof module !== 'undefined' && module.exports) { module.exports = { handleInitializePopup }; }
```
Note: the `require('./scrape.js')` fallback is only reached under Node/tests (where
`window` is jsdom's but `window.extractClinVarData` is unset because `scrape.js`
wasn't loaded as a content script). Guard so the browser path uses the global.

- [ ] **Step 4: Run to verify pass**

Run: `cd clinvar-cvc && npm test` — Expected: all prior + 2 content tests pass.

- [ ] **Step 5: Commit**

```bash
git add clinvar-cvc/content.js clinvar-cvc/test/content.test.js
git commit -m "feat(cvc): content-script scrape handler (uses refactored scrape.js)"
```

### Task D2: manifest — host permissions + content script

**Files:** Modify `clinvar-cvc/manifest.json`.

- [ ] **Step 1: Add to `manifest.json`** (mirror `scvc/manifest.json` targets):
  - `"host_permissions"`: add `"https://www.ncbi.nlm.nih.gov/clinvar/variation/*"` (keep the existing Firestore/identitytoolkit/securetoken entries).
  - `"content_scripts"`: `[{ "matches": ["https://www.ncbi.nlm.nih.gov/clinvar/variation/*"], "js": ["scrape.js", "content.js"], "run_at": "document_end", "all_frames": false }]` (scrape.js FIRST so its `window.extractClinVarData` global exists before content.js runs).
  - `"permissions"`: add `"activeTab"`, `"tabs"` (the popup uses `chrome.tabs.query`/
    `sendMessage`). Keep `identity`, `identity.email`, `storage`. Do NOT add
    `"scripting"` — the static `content_scripts` registration doesn't need it.

- [ ] **Step 2: Validate** — `python3 -m json.tool clinvar-cvc/manifest.json >/dev/null && echo OK`.

- [ ] **Step 3: Manual check (report for the human)** — Load unpacked, open a real
  `.../clinvar/variation/<id>/` page, open the popup; the content script should be
  injected (no console errors). Full popup wiring is Chunk E. ⚠️ A static
  `content_scripts` registration does NOT inject into ClinVar tabs that were already
  open before the extension was loaded/reloaded — **reload the ClinVar tab** after
  loading/reloading the extension, or scrape data won't be available.

- [ ] **Step 4: Commit**

```bash
git add clinvar-cvc/manifest.json
git commit -m "feat(cvc): register ClinVar content script + host permissions"
```

---

## Chunk E: rich popup form

Replace the 5-field POC form with the SCV picker + read-only SCV/VCV display +
action/reason/notes, wired to the scrape data and the existing Firestore/auth path.
Extract pure view-helpers first (TDD), then do the thin DOM wiring.

### Task E0: IIFE-wrap vocab internals (carry-over from Chunk B review)

**Files:** Modify `clinvar-cvc/vocab.js`.

- [ ] **Step 1:** Wrap the module body in an IIFE so `flaggingCandidateReasonOptions`/
  `flaggedSubmissionReasonOptions`/`reasonsByAction` don't leak as `window.*` globals
  when `vocab.js` is `<script>`-included; keep exposing only `window.ACTIONS` and
  `window.reasonsForAction` (and the `module.exports`). Re-run `npm test` — the 4
  vocab tests must still pass unchanged.
- [ ] **Step 2: Commit** — `git commit -am "refactor(cvc): scope vocab internals via IIFE"`.

### Task E1: pure popup view-helpers (TDD)

**Files:** Create `clinvar-cvc/popup-view.js`, `clinvar-cvc/test/popup-view.test.js`.

- [ ] **Step 1: Write the failing test**

```js
import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { scvOptionLabel, reasonOptionGroups } = require('../popup-view.js');

describe('popup-view', () => {
  it('formats an SCV option label (scv, interp, truncated submitter)', () => {
    const label = scvOptionLabel({ scv: 'SCV1.1', interp: 'Pathogenic',
      submitter: 'A very long submitter organization name' });
    expect(label).toContain('SCV1.1');
    expect(label).toContain('Pathogenic');
    expect(label).toMatch(/\.\.\.$/); // submitter truncated with ellipsis
  });
  it('builds grouped reason options for an action', () => {
    const groups = reasonOptionGroups('Flagging Candidate');
    expect(groups.find(g => g.label === 'Submission errors')).toBeTruthy();
    expect(groups.some(g => g.options.includes('Other'))).toBe(true);
  });
  it('builds the flat ("" label) group for Remove Flagged Submission', () => {
    const groups = reasonOptionGroups('Remove Flagged Submission');
    expect(groups.length).toBe(1);
    expect(groups[0].label).toBe('');
    expect(groups[0].options).toContain('Curation error');
  });
  it('returns no groups for No Change', () => {
    expect(reasonOptionGroups('No Change')).toEqual([]);
  });
});
```

- [ ] **Step 2: Run to verify it fails** — `cd clinvar-cvc && npx vitest run test/popup-view.test.js` (FAIL, no module).

- [ ] **Step 3: Implement `clinvar-cvc/popup-view.js`**

- `scvOptionLabel(row)` — returns `` `${row.scv} (${row.interp}) ${truncate(row.submitter, 15)}` `` (port the label format + `truncateString` from `scvc/popup.js` addOptions/truncateString).
- `reasonOptionGroups(action)` — calls `reasonsForAction(action)` (require `vocab.js`) and flattens the grouped object into `[{ label, options: [...] }]` (label `''` allowed for the flat Remove-Flagged group); `[]` when empty. Dual-mode export; require `vocab.js` via the dual-mode pattern.

- [ ] **Step 4: Run to verify pass** — `cd clinvar-cvc && npm test` (all prior + 3 new).

- [ ] **Step 5: Commit** — `git add clinvar-cvc/popup-view.js clinvar-cvc/test/popup-view.test.js && git commit -m "feat(cvc): pure popup view-helpers (scv label, reason groups)"`.

### Task E2: rich popup.html (hand CSS, no CDN)

**Files:** Modify `clinvar-cvc/popup.html`.

- [ ] **Step 1:** Replace the 5-field form with, in order: the `#env-banner` (keep),
  a VCV id + variant name header, an **SCV picker** `<select id="scvselect">`, a
  read-only display block (interp / review / submitter / origin / method / eval
  date; and a VCV-level display), then the form: **Action** `<select id="action">`,
  **Reason** `<select id="reason">`, **Notes** `<textarea id="notes">`, and the
  Save button + `#status`. Use the element ids the wiring in E3 expects. Use hand
  CSS (extend the existing `<style>`); **do NOT add a Bootstrap CDN link** (MV3 CSP
  + no remote deps). Load scripts in order at the end of `<body>`:
  `env.js`, `firebase-config.js`, `vocab.js`, `annotation.js`, `popup-view.js`, `popup.js`.
- [ ] **Step 2:** Sanity — open `clinvar-cvc/popup.html` structure mentally / via a
  DOM test that asserts the key element ids exist (add to `popup-view.test.js` or a
  small `popup-dom.test.js` that loads the HTML into jsdom and checks
  `getElementById` for `scvselect`, `action`, `reason`, `notes`, `save`, `env-banner`).
- [ ] **Step 3: Commit** — `git commit -am "feat(cvc): rich SCV-picker popup markup (hand CSS)"`.

### Task E3: popup.js wiring (scrape → picker → reasons → save)

**Files:** Modify `clinvar-cvc/popup.js`.

- [ ] **Step 1:** In the existing `DOMContentLoaded` handler: **keep the `#env-banner`
  block**, but **DELETE the POC profile-email block** — the `userEmail = await
  getUserEmail()` call and everything that touches `document.getElementById('user_email')`
  (the new markup has no `#user_email` element, so that would throw `null.value`).
  The authoritative verified email now comes from `ensureAuth()` in the save handler
  (Step 3), not a profile hint; you can also delete the now-unused `getUserEmail()`
  helper. Then message the active tab's content script `{from:'popup', subject:
  'initializePopup'}` (port from `scvc/popup.js` bottom); on response, store
  `clinvarData` and populate the SCV `<select>` using `scvOptionLabel` for each
  `clinvarData.row[i]`.
- [ ] **Step 2:** SCV-select `change` → populate the read-only display from the chosen
  row; enable Action. Action `change` → rebuild the Reason `<select>` from
  `reasonOptionGroups(action)` (optgroups for non-empty labels), enable/disable
  Reason accordingly (port the enable/disable logic from `scvc/popup.js`).
- [ ] **Step 3:** Save handler → gather `input = {action, reason, notes}` + the
  selected `scvRow` + the `vcv` context; call `validateAnnotation({scv: scvRow.scv,
  action, reason})` and show any error; then `ensureAuth()` (existing) for the
  verified email + idToken; `const doc = buildAnnotation(scvRow, vcv, input,
  auth.email)`; `await saveAnnotation(doc, auth.idToken)` (existing Firestore write
  — it already uses `toFirestoreFields`, which handles the `created_at` Date). Show
  the saved doc id; a `PERMISSION_DENIED` still surfaces the "not authorized"
  message (existing `notAuthorized` handling). NOTE: `saveAnnotation` stamps the
  authoritative `created_at` at write time via `toFirestoreFields({...data, created_at:
  new Date()})`, so `buildAnnotation`'s `created_at` is harmlessly superseded on the
  real save path — this is intentional, don't "fix" it.
- [ ] **Step 4:** Remove the dead 5-field readForm/validate that the POC used, now
  superseded by `annotation.js` + the picker. Keep `ensureAuth`/`signInWithGoogle`/
  `saveAnnotation`/`toFirestoreFields`/`isConfigured`/`setStatus`.
- [ ] **Step 5: Run** `cd clinvar-cvc && npm test` — all module/unit tests still green
  (popup.js DOM wiring itself isn't unit-tested; its logic lives in the tested
  helpers). **Manual (report for human):** load unpacked against a real ClinVar page
  in `ACTIVE_ENV='dev'`, pick an SCV, choose action/reason/notes, Save → confirm the
  v4 doc lands in dev Firestore + streams to dev BQ with all fields.
- [ ] **Step 6: Commit** — `git commit -am "feat(cvc): wire rich popup to scrape data, vocab, and v4 annotation save"`.

---

## Chunk F: extend the flattened BQ view for v4 fields

**Files:** Modify `clinvar-cvc/bigquery/annotations_view.sql`.

- [ ] **Step 1:** Add the new v4 typed columns via `JSON_VALUE(data, '$.<field>')`:
  `vcv`, `submitter`, `submitter_id`, `interp`, `review_status`. **Resolve the
  scv field-name change explicitly** (v4 `buildAnnotation` emits `scv`; legacy POC
  rows have `scv_id`): use
  `COALESCE(JSON_VALUE(data,'$.scv'), JSON_VALUE(data,'$.scv_id')) AS scv` so both
  v4 and historical rows populate. Keep the unchanged fields as-is (`user_email`,
  `variation_id`, `action`, `reason`, `notes`, `created_at`). The five new v4 fields
  above simply come back NULL for legacy POC rows (they predate those fields) —
  that is expected and acceptable.
- [ ] **Step 2:** Note in the file header that the SQL is applied by running it in
  the BigQuery console (or via `bq query < ...`) for the target project, and that the
  project is currently hardcoded (a follow-up could parameterize dev vs prod, as was
  done ad hoc for the dev view).
- [ ] **Step 3: Commit** — `git commit -am "feat(cvc): surface v4 fields in the flattened BQ view"`.
- [ ] **Step 4 (human, cloud):** re-run the view SQL against dev (and later prod) to
  apply the new columns; verify with a `SELECT *` that the new fields populate for a
  freshly submitted annotation.

---

## Definition of done (D–F)

- `content.js` + manifest register a ClinVar content script using `scrape.js`;
  `handleInitializePopup` is unit-tested.
- The popup is the rich SCV-picker/action-reason-notes form (hand CSS, no CDN),
  driven by the scrape data + `vocab.js`, saving the full v4 doc via
  `annotation.buildAnnotation` + the existing auth/allowlist/Firestore path.
- `bigquery/annotations_view.sql` surfaces the v4 fields.
- `cd clinvar-cvc && npm test` green across all modules; a live manual pass in the
  dev environment confirms a real end-to-end submission with all v4 fields reaching
  dev BigQuery. This foundation then feeds S4 (migration), S6 (history view), S7
  (in-page UX), S8 (pipeline repoint).
