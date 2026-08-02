# S6 — In-extension Annotation History View Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the CvC popup, show prior annotations for the current variation so a curator sees what's already been done before acting.

**Architecture:** On popup open, after the ClinVar scrape yields `variation_id`, attempt a **silent** Google auth (never force a sign-in). If authorized, query Firestore `clinvar_cvc_ext_annotations WHERE variation_id == <current>` via REST `runQuery` (Bearer idToken; the existing `allow read: if isAllowedCurator()` rule already permits this), sort newest-first client-side, and render a compact read-only "Prior annotations" panel showing every curator's history for that variation. Pure logic (query builder, response parser, sort, view model) is unit-tested; the DOM/auth wiring is manually verified in Chrome against the **dev** project (which now holds the full migrated history).

**Tech Stack:** Vanilla JS, MV3, no build. Vitest + jsdom. Firestore REST `runQuery`. Firebase Auth via `chrome.identity` + Identity Toolkit `signInWithIdp` (already used for saves).

**Key simplifications (deliberate):**
- **No `firestore.rules` change** — reads are already allowed for allowlisted curators.
- **No composite index / `firestore.indexes.json`** — a single `variation_id ==` equality filter uses Firestore's automatic single-field index. We do NOT add `orderBy` to the query (that would force a composite index); instead we sort client-side. Per-variation result sets are small (tens of rows).
- **All-curators visibility** — the query has no `user_email` filter, so every allowlisted curator sees the full history for the variation (the stated goal: awareness of prior work). Each row shows who curated it.

---

## Context for the implementer

The extension lives in `clinvar-cvc/` (all modules dual-mode: `window.*` in browser, `module.exports` under Node/tests). Do **not** modify `scvc/`. Run tests with `cd clinvar-cvc && npm test` (currently 52 green — but this plan runs on a fresh worktree off `main` where the migration tooling is merged; confirm the baseline count with `npm test` before starting). NO `"type":"module"` in package.json.

Relevant existing code:
- `firebase-config.js` → `FIREBASE_CONFIG` = `{ projectId, apiKey, databaseId:'(default)', collection:'clinvar_cvc_ext_annotations', authMode, env }`.
- `popup.js`:
  - `signInWithGoogle()` → `{ idToken, email }` (interactive). It calls `getGoogleAuthToken()` which uses `chrome.identity.getAuthToken({ interactive: true })` then Identity Toolkit `accounts:signInWithIdp`.
  - `saveAnnotation(data, idToken)` shows the REST pattern: `POST https://firestore.googleapis.com/v1/projects/${projectId}/databases/${databaseId}/documents/...` with header `Authorization: Bearer ${idToken}`.
  - `toFirestoreFields(obj)` (encode) already exists; we need the inverse (decode) for history — put it in the new `history.js`.
  - `requestClinVarData()` returns the scraped data object (has `variation_id`, `vcv`, `name`, `row` array of SCVs).
  - The popup's init/DOMContentLoaded flow wires scrape → SCV picker → form. History load hooks in after scrape yields `variation_id`.
- `popup-view.js`: pure view helpers (`scvOptionLabel`, `reasonOptionGroups`, `isScrapeable`). Add `historyView` here.
- `popup.html`: loads scripts in order `env → firebase-config → vocab → annotation → popup-view → popup`. Panels use `<div class="readonly-panel">` with `<div class="row"><span>label</span><span>value</span></div>`.
- Firestore `runQuery` response shape: a JSON array; each element is either `{ document: { name, fields: {...}, createTime, updateTime }, readTime }` or a bookkeeping element with only `readTime` (skip those). Each field value is a typed wrapper, e.g. `{ "stringValue": "..." }` or `{ "timestampValue": "2023-10-07T15:41:55Z" }`.

v4 doc fields present on each annotation: `variation_id, vcv, name, scv, submitter, submitter_id, interp, review_status, action, reason, notes, user_email, created_at`.

---

## Chunk 1: history.js — query builder, response parser, sort (pure, TDD)

### Task 1: `buildHistoryQuery(variationId, collection)`

**Files:**
- Create: `clinvar-cvc/history.js`
- Test: `clinvar-cvc/test/history.test.js`

- [ ] **Step 1: Write the failing test** in `test/history.test.js`

```js
const { buildHistoryQuery } = require('../history.js');

describe('buildHistoryQuery', () => {
  it('builds a structuredQuery filtering by variation_id with a safety limit and NO orderBy', () => {
    const q = buildHistoryQuery('590935', 'clinvar_cvc_ext_annotations');
    expect(q).toEqual({
      structuredQuery: {
        from: [{ collectionId: 'clinvar_cvc_ext_annotations' }],
        where: {
          fieldFilter: {
            field: { fieldPath: 'variation_id' },
            op: 'EQUAL',
            value: { stringValue: '590935' }
          }
        },
        limit: 500
      }
    });
    // orderBy must be absent so no composite index is required
    expect(q.structuredQuery.orderBy).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run to verify it fails** — `cd clinvar-cvc && npx vitest run test/history.test.js` → FAIL (module not found).
- [ ] **Step 3: Implement** `buildHistoryQuery` in `history.js` returning exactly that shape (coerce `variationId` with `String(variationId)`). Add the dual-mode footer (`window.*` + `module.exports`).
- [ ] **Step 4: Run to verify it passes.**
- [ ] **Step 5: Commit** — `feat(cvc): history query builder (variation_id equality, no index)`

### Task 2: `parseHistoryRows(runQueryResponse)`

**Files:** Modify `clinvar-cvc/history.js`; Test `clinvar-cvc/test/history.test.js`

- [ ] **Step 1: Write failing tests**

```js
const { parseHistoryRows } = require('../history.js');

describe('parseHistoryRows', () => {
  const resp = [
    { document: { name: 'projects/p/databases/(default)/documents/c/abc', fields: {
      variation_id: { stringValue: '9' }, vcv: { stringValue: 'VCV000000009.99' },
      name: { stringValue: 'NM_000410.4(HFE):c.845G>A' }, scv: { stringValue: 'SCV000020162.8' },
      submitter: { stringValue: 'OMIM' }, action: { stringValue: 'Flagging Candidate' },
      reason: { stringValue: 'Outlier claim' }, notes: { nullValue: null },
      user_email: { stringValue: 'jratliff@broadinstitute.org' },
      created_at: { timestampValue: '2023-11-14T20:25:27Z' } } }, readTime: '2024-01-01T00:00:00Z' },
    { readTime: '2024-01-01T00:00:00Z' } // bookkeeping element — must be skipped
  ];

  it('maps documents to plain annotation objects and skips non-document elements', () => {
    const rows = parseHistoryRows(resp);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      scv: 'SCV000020162.8', submitter: 'OMIM', action: 'Flagging Candidate',
      reason: 'Outlier claim', user_email: 'jratliff@broadinstitute.org',
      created_at: '2023-11-14T20:25:27Z', name: 'NM_000410.4(HFE):c.845G>A'
    });
  });

  it('decodes nullValue and missing fields to empty string', () => {
    const rows = parseHistoryRows(resp);
    expect(rows[0].notes).toBe('');
  });

  it('returns [] for an empty response', () => {
    expect(parseHistoryRows([])).toEqual([]);
  });
});
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** `parseHistoryRows`. For each element with a `.document`, read `fields` and decode each wanted field via a small local `decode(field)` helper: return `field.stringValue` if present, `field.timestampValue` if present, else `''` (treat `nullValue`/absent as `''`). Extract the v4 fields: `variation_id, vcv, name, scv, submitter, submitter_id, interp, review_status, action, reason, notes, user_email, created_at`.
- [ ] **Step 4: Run to verify passes.**
- [ ] **Step 5: Commit** — `feat(cvc): parse Firestore runQuery response into annotation rows`

### Task 3: `sortHistoryDesc(rows)`

**Files:** Modify `clinvar-cvc/history.js`; Test `clinvar-cvc/test/history.test.js`

- [ ] **Step 1: Write failing test**

```js
const { sortHistoryDesc } = require('../history.js');

it('sorts newest-first by created_at, stable for equal timestamps', () => {
  const rows = [
    { scv: 'a', created_at: '2023-01-01T00:00:00Z' },
    { scv: 'b', created_at: '2024-06-01T00:00:00Z' },
    { scv: 'c', created_at: '2023-12-31T23:59:59Z' }
  ];
  expect(sortHistoryDesc(rows).map(r => r.scv)).toEqual(['b', 'c', 'a']);
});

it('does not mutate the input array', () => {
  const rows = [{ scv: 'a', created_at: '2023-01-01T00:00:00Z' }, { scv: 'b', created_at: '2024-01-01T00:00:00Z' }];
  const copy = rows.slice();
  sortHistoryDesc(rows);
  expect(rows).toEqual(copy);
});
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** `sortHistoryDesc` returning a NEW array (`rows.slice().sort(...)`) ordered by `created_at` descending (ISO strings compare lexicographically for UTC `Z` timestamps; compare with `String` fallback so missing dates sort last).
- [ ] **Step 4: Run to verify passes.**
- [ ] **Step 5: Commit** — `feat(cvc): sort history newest-first (non-mutating)`

---

## Chunk 2: popup-view.js — history view model (pure, TDD)

### Task 4: `historyView(rows, currentScv)`

**Files:** Modify `clinvar-cvc/popup-view.js`; Test `clinvar-cvc/test/popup-view.test.js` (append; if that test file does not exist, create it and confirm the vitest glob picks it up)

Produces display-ready objects the DOM layer maps 1:1 (keeps popup.js free of formatting logic).

- [ ] **Step 1: Write failing tests**

```js
const { historyView } = require('../popup-view.js');

describe('historyView', () => {
  const rows = [
    { scv: 'SCV000020162.8', submitter: 'OMIM', action: 'Flagging Candidate', reason: 'Outlier claim',
      notes: '', user_email: 'jratliff@broadinstitute.org', created_at: '2023-11-14T20:25:27Z' },
    { scv: 'SCV000111.1', submitter: 'LabX', action: 'No Change', reason: '',
      notes: 'looks fine', user_email: 'hrehm@broadinstitute.org', created_at: '2023-10-07T15:41:55Z' }
  ];

  it('returns one display row per annotation, newest-first order preserved', () => {
    const v = historyView(rows, 'SCV000111.1');
    expect(v).toHaveLength(2);
    expect(v[0].scv).toBe('SCV000020162.8');
  });

  it('formats a human date (YYYY-MM-DD) and marks the row matching currentScv', () => {
    const v = historyView(rows, 'SCV000111.1');
    expect(v[0].when).toBe('2023-11-14');
    expect(v[0].isCurrent).toBe(false);
    expect(v[1].isCurrent).toBe(true);
  });

  it('summarizes action + reason, and who', () => {
    const v = historyView(rows, '');
    expect(v[1].summary).toBe('No Change');            // no reason → action only
    expect(v[0].summary).toBe('Flagging Candidate — Outlier claim');
    expect(v[0].who).toBe('jratliff@broadinstitute.org');
  });

  it('is empty for no rows', () => {
    expect(historyView([], 'x')).toEqual([]);
  });
});
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** `historyView(rows, currentScv)`: map each row to `{ when, who, scv, summary, notes, isCurrent }` where `when = (created_at || '').slice(0, 10)`, `who = user_email`, `summary = reason ? `${action} — ${reason}` : action`, `isCurrent = !!currentScv && scv === currentScv`. Export via the dual-mode footer alongside the existing helpers.
- [ ] **Step 4: Run to verify passes.**
- [ ] **Step 5: Commit** — `feat(cvc): history view model (display rows + current-SCV flag)`

---

## Chunk 3: popup wiring + markup (manual-verified)

No new unit tests (DOM/network/`chrome.*` wiring is manually verified in Chrome, per the repo's testing note). Each step must keep `npm test` green and pass `node --check`.

### Task 5: Silent auth + history fetch in popup.js

**Files:** Modify `clinvar-cvc/popup.js`

- [ ] **Step 1: Add `getGoogleAuthTokenSilent()`** — same as `getGoogleAuthToken()` but `chrome.identity.getAuthToken({ interactive: false }, ...)`, and on `lastError`/no-token **resolve `null`** (do not reject — absence of a cached grant is normal).
- [ ] **Step 2: Add `silentIdToken()`** — if `authMode !== 'google'` return `null`; else `const t = await getGoogleAuthTokenSilent(); if (!t) return null;` then exchange via the SAME `signInWithIdp` call `signInWithGoogle` uses (factor the exchange into a helper `exchangeGoogleToken(googleToken)` returning `{ idToken, email }`, and have `signInWithGoogle` reuse it to avoid duplication) and return the `idToken`; wrap in try/catch → return `null` on any failure (history is best-effort).
- [ ] **Step 3: Add `fetchHistory(variationId, idToken)`** — `POST https://firestore.googleapis.com/v1/projects/${projectId}/databases/${encodeURIComponent(databaseId)}/documents:runQuery` with `Authorization: Bearer ${idToken}`, body `JSON.stringify(buildHistoryQuery(variationId, collection))`. On non-ok, `console.info` and return `[]`. On ok, return `sortHistoryDesc(parseHistoryRows(await resp.json()))`.
- [ ] **Step 4:** `node --check popup.js`; `npm test` still green. **Commit** — `feat(cvc): silent auth + Firestore history fetch in popup`

### Task 6: Render the history panel + hook into popup open

**Files:** Modify `clinvar-cvc/popup.html`, `clinvar-cvc/popup.js`

- [ ] **Step 1:** In `popup.html`, add a panel after the VCV Summary block and before `<form id="annotation-form">`:

```html
  <div class="panel-title">Prior annotations</div>
  <div id="historypanel" class="readonly-panel muted">
    <div id="history-empty"><i>No prior annotations for this variation.</i></div>
    <div id="history-list"></div>
  </div>
```

Give `#history-list` a scroll cap via an inline style or a class (e.g. `max-height:160px; overflow:auto;`) consistent with the existing hand-CSS.

- [ ] **Step 2:** In `popup.html`, add `<script src="history.js"></script>` immediately before `<script src="popup.js"></script>`.
- [ ] **Step 3:** In `popup.js`, add `renderHistory(rows, currentScv)`:
  - Build display rows with `historyView(rows, currentScv)`.
  - If empty: show `#history-empty`, clear `#history-list`.
  - Else: hide `#history-empty`; render each display row into `#history-list` as a `<div class="row">` (or a small block) showing `when`, `who`, `summary`, and `notes` when present; add a class/marker when `isCurrent` so the current SCV's prior entries stand out. Build DOM with `document.createElement` + `textContent` (no `innerHTML` with data — avoid injection from stored notes).
- [ ] **Step 4:** Add `async function loadHistory(variationId, currentScv)` — `if (!variationId) return;` then `const idToken = await silentIdToken(); if (!idToken) { /* leave empty-state as-is */ return; }` then `renderHistory(await fetchHistory(variationId, idToken), currentScv)`. Wrap in try/catch → on error `console.info` and leave the empty state (history is non-blocking).
- [ ] **Step 5:** Call `loadHistory(clinvarData.variation_id, '')` from the popup's existing post-scrape init (after `requestClinVarData()` resolves and the picker is populated). When the user selects an SCV in the picker, re-call `renderHistory` with the already-fetched rows and the selected SCV to update the `isCurrent` highlight WITHOUT refetching — cache the fetched rows in a module-scope variable (e.g. `let historyRows = []`). (Fetch once per variation; the highlight is a pure re-render.)
- [ ] **Step 6:** `node --check popup.js`; `npm test` green. **Commit** — `feat(cvc): render Prior annotations panel; load on open, highlight selected SCV`

---

## Manual verification (human, in Chrome against DEV)

Document these in the PR description; they cannot be unit-tested:
- [ ] With `ACTIVE_ENV='dev'` and an allowlisted dev curator signed in, open a ClinVar variation page that has migrated history (e.g. variation 9 / HFE) → the "Prior annotations" panel lists prior entries newest-first, showing date, curator email, action/reason, notes.
- [ ] Selecting an SCV in the picker highlights that SCV's prior entries (no network refetch).
- [ ] A variation with no annotations shows the empty state.
- [ ] When NOT signed in (no cached Google grant), opening the popup does NOT trigger a sign-in prompt; the panel simply shows the empty state. Saving (interactive auth) still works.
- [ ] Non-allowlisted signed-in account: `runQuery` returns 403 → panel shows empty state, no crash (the read rule denies).

---

## Definition of done
- `cd clinvar-cvc && npm test` green (baseline + new history/view tests).
- `history.js` (query builder, parser, sort) + `historyView` are unit-tested; popup wiring passes `node --check`.
- No `firestore.rules` change; no `firestore.indexes.json` added.
- History loads on open only via **silent** auth (never forces sign-in); all-curators visibility; current-SCV highlight is a pure re-render.
- `scvc/` untouched.
- PR to `main` lists the manual-verification checklist with results.
