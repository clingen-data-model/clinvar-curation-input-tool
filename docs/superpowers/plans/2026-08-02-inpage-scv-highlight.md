# In-page SCV Highlight Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a ClinVar variation page, visually highlight the SCV submission rows that already have prior CvC annotations, so a curator sees what's been curated without opening the popup.

**Architecture:** A background **service worker** (new) does the auth-bearing work content scripts can't: on request it does silent Google auth (reusing S6's history query/fetch) and returns the variation's annotation rows. The content script — which already loads `scrape.js` + `content.js` on ClinVar variation pages — asks the worker for history on page load, maps each returned annotation to its SCV, and decorates the matching row elements (a small badge + row tint + hover tooltip). The pure "summarize history per SCV" and "decorate decision" logic is unit-tested; the service-worker plumbing and DOM decoration are manually verified in Chrome against **dev**.

**Tech Stack:** Vanilla JS, MV3. Vitest + jsdom. MV3 classic service worker with `importScripts`. Reuses `history.js` (S6) and `FIREBASE_CONFIG`.

**Why a service worker:** `chrome.identity` is unavailable in content scripts; only extension pages / the service worker can mint a token. Routing the fetch through the worker means highlights work whenever the curator has a cached Google grant — not only right after using the popup. It also keeps the read path (Firestore rules already `allow read: if isAllowedCurator()`) and silent-auth model identical to S6.

**Deliberate constraints (same spirit as S6):**
- **No `firestore.rules` change, no index** — reuse the S6 `buildHistoryQuery` (single `variation_id ==`, client-side sort).
- **Silent auth only** — the worker NEVER triggers interactive sign-in for a highlight; no cached grant ⇒ no highlight (page is untouched).
- **Best-effort / non-destructive** — any failure (not signed in, non-allowlisted 403, DOM shape changed) leaves the page exactly as ClinVar rendered it. Never throw into the page.
- **All-curators visibility** — highlight reflects every curator's annotations for the variation.

---

## Context for the implementer

Repo layout + rules in `clinvar-cvc/CLAUDE.md`. Modules are dual-mode (`window.*` in the browser page, `module.exports` under Node/tests). Do NOT modify `scvc/`. `cd clinvar-cvc && npm test` is the harness (green baseline — confirm the count before starting; S6 is merged so it includes `history.js`/`popup-view.js` history tests). NO `"type":"module"` in package.json.

Key existing code to reuse:
- `history.js` → `buildHistoryQuery(variationId, collection)`, `parseHistoryRows(runQueryResponse)`, `sortHistoryDesc(rows)`. **Reuse as-is.**
- `popup.js` currently OWNS the silent-auth + fetch helpers `getGoogleAuthTokenSilent()`, `exchangeGoogleToken(googleToken)`, `silentIdToken()`, and `fetchHistory(variationId, idToken)`. **Task 4 extracts these into a shared module** so both the popup and the new service worker use one implementation.
- `scrape.js` → `extractClinVarData(doc)` returns `{ ..., variation_id, name, row: [{ scv, submitter, interp, review, ... }, ...] }`. Crucially, `extractScvRows` iterates `doc.querySelectorAll('.submissions-germline-list tbody tr.germline-sub-col')` IN ORDER, so **`extractClinVarData(document).row[i]` corresponds to the i-th such `<tr>` element** — that index alignment is how the content script maps data → row element.
- `content.js` → content script; currently only responds to the popup's `initializePopup` message. Highlighting is added here.
- `manifest.json` → has `content_scripts:[{js:['scrape.js','content.js'], matches:['https://www.ncbi.nlm.nih.gov/clinvar/variation/*'], run_at:'document_end'}]`, `permissions:['identity','identity.email','storage','activeTab','tabs']`, `host_permissions` include firestore + identitytoolkit + securetoken. There is **no** `background` yet.

Firestore `runQuery` response + field shapes: see `history.js`/`parseHistoryRows`.

---

## Chunk 1: highlight.js — pure per-SCV summary + decoration decision (TDD)

### Task 1: `summarizeHistoryByScv(rows)`

**Files:** Create `clinvar-cvc/highlight.js`; Test `clinvar-cvc/test/highlight.test.js`

Collapses history rows into one summary per SCV.

- [ ] **Step 1: Write failing tests**

```js
const { summarizeHistoryByScv } = require('../highlight.js');

describe('summarizeHistoryByScv', () => {
  const rows = [
    { scv: 'SCV1', action: 'Flagging Candidate', user_email: 'a@x.org', created_at: '2024-01-02T00:00:00Z' },
    { scv: 'SCV1', action: 'No Change',          user_email: 'b@x.org', created_at: '2024-03-01T00:00:00Z' },
    { scv: 'SCV2', action: 'No Change',          user_email: 'c@x.org', created_at: '2023-05-01T00:00:00Z' }
  ];

  it('groups by scv with a count', () => {
    const m = summarizeHistoryByScv(rows);
    expect(m.SCV1.count).toBe(2);
    expect(m.SCV2.count).toBe(1);
  });

  it('flags an SCV that has ANY Flagging Candidate / Remove Flagged Submission action', () => {
    const m = summarizeHistoryByScv(rows);
    expect(m.SCV1.flagged).toBe(true);   // has a Flagging Candidate
    expect(m.SCV2.flagged).toBe(false);  // only No Change
  });

  it('captures the most-recent action/curator/date per scv', () => {
    const m = summarizeHistoryByScv(rows);
    expect(m.SCV1.lastAction).toBe('No Change');        // 2024-03-01 is newest for SCV1
    expect(m.SCV1.lastWho).toBe('b@x.org');
    expect(m.SCV1.lastWhen).toBe('2024-03-01');
  });

  it('returns {} for empty input', () => {
    expect(summarizeHistoryByScv([])).toEqual({});
  });
});
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** `summarizeHistoryByScv(rows)`: reduce into `{ [scv]: { count, flagged, lastAction, lastWho, lastWhen } }`. `flagged = true` if any row for that scv has `action === 'Flagging Candidate' || action === 'Remove Flagged Submission'`. "Most recent" = max `created_at` (ISO compare); `lastWhen = created_at.slice(0,10)`. Ignore rows with empty `scv`.
- [ ] **Step 4: Run to verify passes.** Dual-mode footer (also assign to `self`/`globalThis` when present so the service worker can use it — see NOTE below).
- [ ] **Step 5: Commit** — `feat(cvc): summarize annotation history per SCV`

> **NOTE (module footer for service-worker reuse):** every module the service worker `importScripts` must expose its API in the worker global. Use a footer like:
> ```js
> (function (root) { if (root) { root.summarizeHistoryByScv = summarizeHistoryByScv; root.decorateForScv = decorateForScv; } })(
>   typeof self !== 'undefined' ? self : (typeof window !== 'undefined' ? window : null));
> if (typeof module !== 'undefined' && module.exports) { module.exports = { summarizeHistoryByScv, decorateForScv }; }
> ```
> (`self` covers both the page window and the worker global.)

### Task 2: `decorateForScv(summary)`

**Files:** Modify `clinvar-cvc/highlight.js`; Test `clinvar-cvc/test/highlight.test.js`

Pure decision: given one SCV's summary (or undefined), what should the row show?

- [ ] **Step 1: Write failing tests**

```js
const { decorateForScv } = require('../highlight.js');

it('returns null when there is no history for the scv', () => {
  expect(decorateForScv(undefined)).toBeNull();
});

it('badges a flagged SCV with a warn class and count', () => {
  const d = decorateForScv({ count: 2, flagged: true, lastAction: 'Flagging Candidate', lastWho: 'a@x.org', lastWhen: '2024-01-02' });
  expect(d.cssClass).toBe('cvc-hl cvc-hl-flagged');
  expect(d.badge).toBe('CvC 2');
  expect(d.tooltip).toContain('Flagging Candidate');
  expect(d.tooltip).toContain('a@x.org');
  expect(d.tooltip).toContain('2024-01-02');
});

it('badges a non-flagged annotated SCV with a neutral class', () => {
  const d = decorateForScv({ count: 1, flagged: false, lastAction: 'No Change', lastWho: 'c@x.org', lastWhen: '2023-05-01' });
  expect(d.cssClass).toBe('cvc-hl cvc-hl-noted');
  expect(d.badge).toBe('CvC 1');
});
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** `decorateForScv(summary)` → `null` if falsy; else `{ cssClass: 'cvc-hl ' + (summary.flagged ? 'cvc-hl-flagged' : 'cvc-hl-noted'), badge: 'CvC ' + summary.count, tooltip: `${summary.lastAction} — ${summary.lastWho} (${summary.lastWhen})` + (summary.count > 1 ? ` · ${summary.count} annotations` : '') }`.
- [ ] **Step 4: Run to verify passes.**
- [ ] **Step 5: Commit** — `feat(cvc): per-SCV decoration decision (class/badge/tooltip)`

---

## Chunk 2: shared auth/fetch module + background service worker

### Task 3: Extract shared silent-auth + fetch into `firestore-history.js`

**Files:** Create `clinvar-cvc/firestore-history.js`; Modify `clinvar-cvc/popup.js`, `clinvar-cvc/popup.html`

Single source of truth for the token + query used by BOTH the popup and the worker.

- [ ] **Step 1:** Create `firestore-history.js` containing `getGoogleAuthTokenSilent()`, `exchangeGoogleToken(googleToken)`, `silentIdToken()`, and `fetchHistory(variationId, idToken)` — moved verbatim from `popup.js` (they already reference `FIREBASE_CONFIG`, `chrome.identity`, and the `history.js` globals). Expose them on `self`/`window` (worker + page) via the NOTE footer, plus `module.exports`.
- [ ] **Step 2:** In `popup.js`, DELETE those four functions (keep `getGoogleAuthToken` interactive, `signInWithGoogle`, `saveAnnotation`, etc.) and rely on the now-global `silentIdToken`/`fetchHistory` from `firestore-history.js`. `exchangeGoogleToken` is now shared — have `signInWithGoogle` call the global one.
- [ ] **Step 3:** In `popup.html`, add `<script src="firestore-history.js"></script>` AFTER `history.js` and BEFORE `popup.js`.
- [ ] **Step 4:** `node --check popup.js firestore-history.js`; `npm test` still green (popup DOM test's script-order assertion in `test/popup-dom.test.js` must be updated to include `firestore-history.js` in the expected order). **Commit** — `refactor(cvc): extract silent-auth + history fetch into shared firestore-history.js`

### Task 4: Background service worker

**Files:** Create `clinvar-cvc/background.js`; Modify `clinvar-cvc/manifest.json`

- [ ] **Step 1:** Create `background.js` (classic MV3 worker):
  ```js
  importScripts('env.js', 'firebase-config.js', 'history.js', 'firestore-history.js');
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message || message.subject !== 'getScvHistory') return false;
    (async () => {
      try {
        const idToken = await silentIdToken();          // from firestore-history.js
        if (!idToken) { sendResponse({ ok: false, reason: 'no-auth', rows: [] }); return; }
        const rows = await fetchHistory(message.variationId, idToken);
        sendResponse({ ok: true, rows });
      } catch (e) {
        sendResponse({ ok: false, reason: 'error', rows: [] });
      }
    })();
    return true; // async sendResponse
  });
  ```
- [ ] **Step 2:** In `manifest.json` add `"background": { "service_worker": "background.js" }`. (Classic worker — do NOT set `"type":"module"`, so `importScripts` works and the dual-mode globals resolve on `self`.)
- [ ] **Step 3:** Verify the importScripts globals resolve in the worker: confirm `env.js` (`resolveConfig`, `ENVIRONMENTS`), `firebase-config.js` (`FIREBASE_CONFIG`), `history.js` (`buildHistoryQuery`/`parseHistoryRows`/`sortHistoryDesc`), and `firestore-history.js` (`silentIdToken`/`fetchHistory`) are all reachable from `background.js` after importScripts. If any is NOT (e.g. a top-level `const` that doesn't attach to `self`), fix that module's footer to also assign to `self` (per the NOTE). `node --check background.js`.
- [ ] **Step 4:** `npm test` green. **Commit** — `feat(cvc): background service worker serving silent-auth SCV history`

---

## Chunk 3: content-script highlighting (manual-verified)

**Files:** Modify `clinvar-cvc/content.js`, `clinvar-cvc/manifest.json` (CSS), add `clinvar-cvc/highlight.css`

No new unit tests (DOM/`chrome.*`); keep `npm test` green + `node --check content.js`. content.js already loads AFTER scrape.js and highlight.js will be added to the content_scripts js list so its globals are available.

- [ ] **Step 1:** Create `highlight.css` — minimal, scoped classes: `.cvc-hl` (a subtle left border / background tint), `.cvc-hl-flagged` (amber, e.g. `background: #fff7ed; box-shadow: inset 3px 0 0 #f59e0b;`), `.cvc-hl-noted` (neutral grey tint), and `.cvc-hl-badge` (small inline pill: rounded, tiny font, muted bg) — all prefixed `cvc-` to avoid clashing with NCBI styles.
- [ ] **Step 2:** In `manifest.json` `content_scripts[0]`: add `"highlight.js"` to `js` (after `scrape.js`, before `content.js`) and add `"css": ["highlight.css"]`.
- [ ] **Step 3:** In `content.js`, add `applyHighlights(doc, summaryByScv)`:
  - `const rowEls = doc.querySelectorAll('.submissions-germline-list tbody tr.germline-sub-col');`
  - `const data = (window.extractClinVarData)(doc);` (same scrape used for the popup) → `data.row[i].scv` aligns with `rowEls[i]`.
  - For each `i`: `const dec = decorateForScv(summaryByScv[data.row[i].scv]); if (!dec) continue;` then add `dec.cssClass` to `rowEls[i].classList`, set `rowEls[i].title = dec.tooltip` (native tooltip — simplest, robust), and append a `<span class="cvc-hl-badge">` (via `createElement`+`textContent`, NEVER innerHTML) into a stable cell of the row (e.g. the submitter cell `cells[3]`, guarded for existence).
  - Idempotency: at the top, first remove any prior `.cvc-hl-badge` and `cvc-hl*` classes so re-runs don't stack (SPA re-renders / repeated calls).
- [ ] **Step 4:** In `content.js`, add `initHighlights()`:
  - Scrape once to get `variation_id` (`const data = window.extractClinVarData(document); if (!data || !data.variation_id) return;`).
  - `chrome.runtime.sendMessage({ subject: 'getScvHistory', variationId: data.variation_id }, (resp) => { if (chrome.runtime.lastError || !resp || !resp.ok || !resp.rows.length) return; applyHighlights(document, summarizeHistoryByScv(resp.rows)); });`
  - Guard everything in try/catch → on any error, `console.info` and leave the page untouched.
  - Call `initHighlights()` at load (the content script runs at `document_end`; the SCV table is present). Keep this ADDITIVE — do not disturb the existing `initializePopup` message listener.
- [ ] **Step 5:** `node --check content.js`; `npm test` green. **Commit** — `feat(cvc): highlight annotated SCV rows in-page via the service worker`

---

## Manual verification (human, in Chrome against DEV)

- [ ] Load unpacked from the OAuth-registered path with `ACTIVE_ENV='dev'`, signed-in allowlisted curator. Open ClinVar **variation 9** (HFE) → the 6 annotated SCVs (e.g. `SCV006303009.1`) show a `CvC N` badge + row tint; flagged ones amber, others neutral. Hovering a row shows last action/curator/date.
- [ ] SCVs with no annotations are visually untouched.
- [ ] Not signed-in (no cached Google grant): the page shows NO highlights and NO sign-in prompt appears.
- [ ] Non-allowlisted signed-in account: `runQuery` 403 → worker returns `no rows` → page untouched, no console errors thrown into the page.
- [ ] Confirm no interference with the popup: opening the popup still scrapes, lists SCVs, shows S6 history, and saves.
- [ ] Reload the tab twice → badges do not duplicate (idempotent).

---

## Definition of done
- `cd clinvar-cvc && npm test` green (baseline + new `highlight.js` tests).
- `highlight.js` (summary + decoration) is unit-tested; the service worker, shared `firestore-history.js`, and content-script decoration pass `node --check` and manual verification.
- Popup behavior unchanged (S6 history still works after the auth extraction).
- No `firestore.rules` change; no index; silent-auth only; page never mutated on any failure path.
- `scvc/` untouched. PR to `main` lists the manual-verification results.
