# S3+S0: scvc Refactor Analysis → Foundation Port — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if
> subagents available) or superpowers:executing-plans. Steps use `- [ ]` checkboxes.
> Run from the repo root; execute in a dedicated worktree. Uses
> @superpowers:test-driven-development for every code task. Parent roadmap:
> `docs/superpowers/plans/2026-08-01-clinvar-cvc-production.md`. Builds on the
> Vitest harness + scraper characterization snapshot from the S1+S2 plan.

**Goal:** Port the value of the legacy `scvc/` extension (ClinVar page scraping +
rich SCV-picker/annotation form) onto the `clinvar-cvc/` Firestore/Google-sign-in/
allowlist backend, refactored into small tested modules — producing the
production annotation-capture flow. `scvc/` is left untouched.

**Architecture:** Decompose into focused, dual-mode (browser-global + CommonJS for
tests) modules: `scrape.js` (DOM → structured data), `vocab.js` (action/reason
vocabulary), `annotation.js` (scraped + user input → the full Firestore annotation
doc), plus a new `content.js` (page scrape + message passing) and an expanded
popup. Each pure module is TDD'd against the existing fixture/snapshot before it's
wired in, so the refactor is provably behavior-preserving.

**Tech Stack:** Chrome MV3 (vanilla JS, no build), Vitest + jsdom, Firestore REST.

**Decisions in force:** D2 (annotations in Firestore), D4 (evolve in `clinvar-cvc/`),
plus the S1+S2 harness/env-switch already merged.

---

## S3 — Refactor analysis (the map this plan implements)

Concrete findings from reading `scvc/content.js`, `scvc/popup.js`, `scvc/popup.html`,
`scvc/background.js`, and `Review&Submit/SUBMISSION_FILE_SPEC.md`:

1. **Fragile scraping** — `extractClinVarData()` matches long regexes over
   `innerHTML` and uses XPath tied to NCBI class names/DOM shape; the documented #1
   breakage source. Refactor into small named extractors with graceful degradation
   (surface "couldn't parse X" rather than silent `""`), behavior pinned by the
   characterization snapshot.
2. **Debug-log noise** — dozens of `console.log` calls fire on every scrape (they
   flood test output too). Gate behind a `DEBUG` flag, off by default.
3. **Duplicated vocabulary** — the action list and reason-by-action map are
   hardcoded in `scvc/popup.js` AND described in the spec. Extract once to `vocab.js`.
4. **Callback sprawl** — `scvc/background.js` nests `getProfileUserInfo` →
   `getAuthToken` → `fetch`. The `clinvar-cvc/` backend already uses promises/`fetch`
   with Google sign-in; the Sheets `background.js` is not ported at all.
5. **Dead Sheets fields** — `spreadsheet`/`scv_range`/`vcv_range` hidden inputs and
   the `SPREADSHEET_ID` constant die with the Sheets path.

**Target module layout (created under `clinvar-cvc/`):**

| File | Responsibility |
|------|----------------|
| `scrape.js` | Pure: `extractClinVarData(document) → {vcv,…, row:[…]}`. Refactored scvc scraper. Dual-mode export. |
| `vocab.js` | Pure: `ACTIONS`, `reasonsForAction(action) → grouped options`. Dual-mode. |
| `annotation.js` | Pure: `buildAnnotation(scvRow, vcv, userInput, userEmail) → Firestore doc`. Dual-mode. |
| `content.js` | MV3 content script: scrape current page, answer `initializePopup`. Uses `scrape.js`. |
| `popup.html`/`popup.js` | Rich SCV picker + action/reason/notes form; writes via existing Firestore/auth path. |

**Target Firestore annotation document (v4)** — superset of the POC's 5 fields,
aligned to the 13-field submission spec so downstream (S4/S8) works. Field names
match the legacy sheet columns so migrated history is uniform:
`variation_id, vcv, scv, submitter, submitter_id, interp, review_status, action,
reason, notes, user_email, created_at`. (The Firestore→BigQuery extension streams
these as the JSON `data` column automatically; the flattened view is extended in a
later chunk.)

---

## File Structure

- Create `clinvar-cvc/scrape.js` + `clinvar-cvc/test/scrape.test.js`
- Create `clinvar-cvc/vocab.js` + `clinvar-cvc/test/vocab.test.js`
- Create `clinvar-cvc/annotation.js` + `clinvar-cvc/test/annotation.test.js`
- Create `clinvar-cvc/content.js` (new; NOT a copy of scvc's) + test
- Modify `clinvar-cvc/manifest.json` (host permissions + content_scripts)
- Modify `clinvar-cvc/popup.html` + `clinvar-cvc/popup.js` (rich form; wire to backend)
- Modify `clinvar-cvc/bigquery/annotations_view.sql` (new typed columns)

Later chunks (D–F) are outlined at the end and detailed in the next planning pass.

---

## Chunk A: `scrape.js` — refactored, tested scraper

Extracts `scvc/content.js`'s scraping into a pure module with the **identical
output shape** (guarded by the S2 characterization snapshot), decomposed into small
functions, no console noise.

**Files:** Create `clinvar-cvc/scrape.js`, `clinvar-cvc/test/scrape.test.js`.
Reuses fixture `clinvar-cvc/test/fixtures/clinvar-variation.html`.

- [ ] **Step 1: Write the failing test** (`clinvar-cvc/test/scrape.test.js`)

```js
import { describe, it, expect, beforeEach } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { extractClinVarData } = require('../scrape.js');
const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, 'fixtures/clinvar-variation.html'), 'utf8');

describe('scrape.extractClinVarData', () => {
  beforeEach(() => { document.documentElement.innerHTML = html; });

  it('extracts VCV identity', () => {
    const d = extractClinVarData(document);
    expect(d.vcv).toBe('VCV000590935.4');
    expect(d.variation_id).toBe('590935');
    expect(d.vcv_interp).toBeTruthy();
    expect(d.vcv_review).toBeTruthy();
  });
  it('extracts one row per SCV with core fields', () => {
    const d = extractClinVarData(document);
    expect(d.row.length).toBe(3);
    for (const r of d.row) {
      expect(r.scv).toMatch(/^SCV\d+\.\d+$/);
      expect(typeof r.submitter).toBe('string');
      expect(typeof r.interp).toBe('string');
    }
  });
  it('matches the pinned scvc output shape (no regression)', () => {
    expect(extractClinVarData(document)).toMatchSnapshot();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd clinvar-cvc && npx vitest run test/scrape.test.js`
Expected: FAIL — `Cannot find module '../scrape.js'`.

- [ ] **Step 3: Implement `clinvar-cvc/scrape.js`**

Port `scvc/content.js`'s `extractClinVarData` logic, but: (a) take `document` as a
parameter (no reliance on a global — makes it testable), (b) split into named
helpers — `extractVcvHeader(doc)`, `extractScvRows(doc)`, `parseScvRow(cellHtml…)`,
(c) keep the same **scraped-content** fields and semantics as scvc — `vcv`,
`variation_id`, `vcv_interp`, `vcv_review`, `vcv_eval_date`, `vcv_most_recent`,
`name`, and `row[]` (these are what the cross-check enforces) — but **DROP the dead
Sheets-only fields** `spreadsheet`/`scv_range`/`vcv_range` (per S3 finding #5). The
new `scrape.test.js.snap` will therefore omit those three; that is intended and is
the one expected difference from the S2 characterization snapshot, (d) replace
every `console.log` with an optional `debug()` gated on a module
`DEBUG=false` constant, (e) keep the regex/XPath as-is for now (resilience hardening
is a separate, snapshot-guarded follow-up — do NOT change extraction results here).
End with the dual-mode export:
```js
if (typeof window !== 'undefined') { window.extractClinVarData = extractClinVarData; }
if (typeof module !== 'undefined' && module.exports) { module.exports = { extractClinVarData }; }
```

- [ ] **Step 4: Run to verify pass + snapshot**

Run: `cd clinvar-cvc && npx vitest run test/scrape.test.js`
Expected: PASS; a new snapshot is written. **Cross-check** its values against the
S2 `scrape.characterization.test.js.snap` (same fixture) — `vcv`, `variation_id`,
and each row's `scv`/`submitter`/`interp` must match exactly. If they differ, the
refactor changed behavior — fix `scrape.js`, do not edit the snapshot.

- [ ] **Step 5: Commit**

```bash
git add clinvar-cvc/scrape.js clinvar-cvc/test/scrape.test.js clinvar-cvc/test/__snapshots__/scrape.test.js.snap
git commit -m "feat(cvc): extract refactored, tested scrape.js from scvc scraper"
```

---

## Chunk B: `vocab.js` — action/reason vocabulary

Single source of truth for the annotation vocabulary, extracted from
`scvc/popup.js` and reconciled with `SUBMISSION_FILE_SPEC.md`.

**Files:** Create `clinvar-cvc/vocab.js`, `clinvar-cvc/test/vocab.test.js`.

- [ ] **Step 1: Write the failing test**

```js
import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { ACTIONS, reasonsForAction } = require('../vocab.js');

describe('vocab', () => {
  it('exposes the three actions', () => {
    expect(ACTIONS).toEqual(['No Change', 'Flagging Candidate', 'Remove Flagged Submission']);
  });
  it('gives grouped reasons for Flagging Candidate', () => {
    const r = reasonsForAction('Flagging Candidate');
    expect(Object.keys(r)).toContain('Submission errors');
    expect(r['Miscellaneous']).toContain('Other');
  });
  it('gives flat reasons for Remove Flagged Submission', () => {
    const r = reasonsForAction('Remove Flagged Submission');
    expect(r['']).toContain('Curation error');
  });
  it('gives no reasons for No Change', () => {
    expect(reasonsForAction('No Change')).toEqual({});
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd clinvar-cvc && npx vitest run test/vocab.test.js` — Expected: FAIL (no module).

- [ ] **Step 3: Implement `clinvar-cvc/vocab.js`**

Move the `flaggingCandidateReasonOptions` / `flaggedSubmissionReasonOptions` objects
verbatim from `scvc/popup.js` (lines ~196–226), plus `ACTIONS`, and
`reasonsForAction(action)` returning the grouped object (or `{}` for No Change).
Dual-mode export `{ ACTIONS, reasonsForAction }`.

- [ ] **Step 4: Run to verify pass**

Run: `cd clinvar-cvc && npx vitest run test/vocab.test.js` — Expected: 4 passing.

- [ ] **Step 5: Commit**

```bash
git add clinvar-cvc/vocab.js clinvar-cvc/test/vocab.test.js
git commit -m "feat(cvc): shared action/reason vocabulary module"
```

---

## Chunk C: `annotation.js` — scraped + input → Firestore doc

Maps a selected SCV row + VCV context + the curator's action/reason/notes + verified
email into the v4 annotation document, and centralizes the validation rules.

**Files:** Create `clinvar-cvc/annotation.js`, `clinvar-cvc/test/annotation.test.js`.

- [ ] **Step 1: Write the failing test**

```js
import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { buildAnnotation, validateAnnotation } = require('../annotation.js');

const vcv = { vcv: 'VCV000590935.4', variation_id: '590935' };
const scvRow = { scv: 'SCV005831843.1', submitter: 'Labcorp', submitter_id: '500123',
                 interp: 'Uncertain significance', review: 'criteria provided, single submitter' };

describe('annotation', () => {
  it('builds the v4 doc with all fields', () => {
    const a = buildAnnotation(scvRow, vcv, { action: 'No Change', reason: '', notes: 'ok' }, 'jane@x.com');
    expect(a).toMatchObject({
      variation_id: '590935', vcv: 'VCV000590935.4', scv: 'SCV005831843.1',
      submitter: 'Labcorp', submitter_id: '500123', interp: 'Uncertain significance',
      review_status: 'criteria provided, single submitter', action: 'No Change',
      reason: '', notes: 'ok', user_email: 'jane@x.com'
    });
    expect(a.created_at).toBeInstanceOf(Date);
  });
  it('requires an action', () => {
    expect(validateAnnotation({ scv: 'SCV1', action: '' })).toMatch(/action is required/i);
  });
  it('requires a reason unless No Change', () => {
    expect(validateAnnotation({ scv: 'SCV1', action: 'Flagging Candidate', reason: '' }))
      .toMatch(/reason is required/i);
    expect(validateAnnotation({ scv: 'SCV1', action: 'No Change', reason: '' })).toBeNull();
  });
  it('requires an SCV', () => {
    expect(validateAnnotation({ scv: '', action: 'No Change' })).toMatch(/scv.*required/i);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd clinvar-cvc && npx vitest run test/annotation.test.js` — Expected: FAIL (no module).

- [ ] **Step 3: Implement `clinvar-cvc/annotation.js`**

`buildAnnotation(scvRow, vcv, input, userEmail)` returns the v4 doc object (fields
listed in S3), with `created_at: new Date()`. `validateAnnotation(data)` returns an
error string or `null`, encoding: SCV required, action required, reason required
unless action==='No Change' (reuse the current popup.js rules). Dual-mode export.

- [ ] **Step 4: Run to verify pass**

Run: `cd clinvar-cvc && npx vitest run test/annotation.test.js` — Expected: 4 passing.

- [ ] **Step 5: Commit**

```bash
git add clinvar-cvc/annotation.js clinvar-cvc/test/annotation.test.js
git commit -m "feat(cvc): annotation builder + validation (scraped -> v4 Firestore doc)"
```

---

## Chunks D–F (outline — detailed in the next planning pass)

These are integration-heavy (multi-file, DOM, message passing) and get their own
bite-sized breakdown once A–C land and the module interfaces are real:

- **Chunk D — content script + manifest.** New `clinvar-cvc/content.js` that, on
  `initializePopup`, calls `scrape.extractClinVarData(document)` and returns it;
  registers `showPageAction`. Add to `manifest.json`: `host_permissions` +
  `content_scripts` for `https://www.ncbi.nlm.nih.gov/clinvar/variation/*`. Test the
  message handler in jsdom with the fixture. Manual: load unpacked, open a real
  ClinVar page, confirm scrape populates.
- **Chunk E — rich popup form.** Replace the 5-field POC form with the SCV picker +
  read-only SCV/VCV display + action/reason (driven by `vocab.js`) + notes, ported
  from `scvc/popup.html`/`popup.js`. ⚠️ MV3 CSP: `scvc/popup.html` loads Bootstrap
  from a CDN — **vendor Bootstrap CSS locally or replace with hand CSS** (no remote
  scripts/styles that violate CSP). Wire submit through the existing `authMode:
  'google'` + allowlist + Firestore REST path, using `annotation.buildAnnotation`
  and `validateAnnotation`. Tests: form-population + validation logic in jsdom.
- **Chunk F — extend the flattened BQ view.** Update
  `bigquery/annotations_view.sql` to surface the new typed columns (`vcv`,
  `submitter`, `submitter_id`, `interp`, `review_status`) alongside the existing
  ones, so downstream (S4 migration, S8 pipeline) sees the full v4 shape.

**Then:** final full-implementation review, `npm test` green across all modules, and
a live manual pass on a real ClinVar page (dev environment, `ACTIVE_ENV='dev'`)
before this foundation feeds S4 (migration), S6 (history view), S7 (in-page UX).

---

## Definition of done (this plan)

- `scrape.js`, `vocab.js`, `annotation.js` exist as pure, dual-mode modules with
  passing unit tests; `scrape.js` output matches the S2 characterization snapshot.
- The refactor map (S3) is captured above and the module interfaces are stable
  enough for Chunks D–F to build on.
- `cd clinvar-cvc && npm test` green (harness + env + scrape + vocab + annotation).
