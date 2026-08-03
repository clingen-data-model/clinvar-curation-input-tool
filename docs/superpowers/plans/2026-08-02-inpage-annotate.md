# In-page Click-to-Annotate (S7) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Put an **Annotate** button on every SCV row on the ClinVar variation page; clicking it opens an in-page form (SCV preselected) with action / reason / notes and a Save that writes the annotation.

**Architecture:** The content script adds an `+ Annotate` button to each SCV row (same cell as the `CvC N` history badge). Clicking opens an in-page form popover built from the shared vocab (`ACTIONS`, `reasonsForAction`/`reasonOptionGroups`). Content scripts can't mint an auth token, so **Save routes through the background service worker**: the content script sends `{subject:'saveAnnotation', scvRow, vcv, input}`; the worker ensures an ID token (silent, falling back to interactive sign-in), builds + validates the v4 doc, and does the create-only Firestore write (keyed by `annotationDocId`, exactly like the popup). On success the content script reloads the tab so the highlight badges refresh.

**Tech Stack:** Vanilla JS, MV3. Reuses `vocab.js`, `annotation.js` (`buildAnnotation`/`validateAnnotation`/`annotationDocId`), `popup-view.js` (`reasonOptionGroups`), and the S6/highlight auth (`firestore-history.js`). Vitest + jsdom.

**Constraints:**
- The **exact same write semantics as the popup**: create-only, content-hash doc id, `ALREADY_EXISTS` → "already saved", `403` → "not authorized" (allowlist). Reuse the code, don't fork it.
- Best-effort / non-destructive to the page: the button + form are additive; any failure shows a message in the form, never throws into the page.
- Popup behavior unchanged (the write-code extraction must be behavior-neutral).
- `scvc/` untouched. No `firestore.rules` change (create rule already allows allowlisted curators).

---

## Context

Branch: `inpage-scv-highlight` (this extends the in-page PR #113). `cd clinvar-cvc && npm test` baseline is 71 green — confirm before starting. Modules are dual-mode (`window.*`/`self` + `module.exports`); the service worker `importScripts` classic scripts, so anything it needs must resolve on `self`/top-level (see how `firestore-history.js` already does this).

Reuse targets (read them first):
- `popup.js` currently owns `toFirestoreFields(obj)`, `classifyWriteError(status, body)`, and `saveAnnotation(data, idToken)` (create-only write; computes `annotationDocId(data)`; throws with `.alreadyExists`/`.notAuthorized`). It also owns `getGoogleAuthToken()` (interactive) and `signInWithGoogle()`; the silent path + `exchangeGoogleToken` already live in `firestore-history.js`.
- `annotation.js` → `buildAnnotation(scvRow, vcv, input, userEmail)`, `validateAnnotation(data)`, `annotationDocId(doc)`.
- `vocab.js` → `ACTIONS` (array), `reasonsForAction(action)`. `popup-view.js` → `reasonOptionGroups(action)` (grouped options; how the popup builds the reason `<select>`).
- `background.js` → classic SW; already handles `getScvHistory`. `content.js` → already adds highlight badges to `.submissions-germline-list tbody tr.germline-sub-col` rows in `applyHighlights`, with `data.row[i]` index-aligned to the i-th row element; already has an `initHighlights` that messages the SW.
- `firestore-history.js` → `getGoogleAuthTokenSilent`, `exchangeGoogleToken`, `silentIdToken`, `fetchHistory` (+ `authError`).
- `manifest.json` content_scripts js: `['scrape.js','highlight.js','content.js']`.

---

## Chunk 1: shared write module + interactive auth helper

### Task 1: Extract `firestore-write.js`
**Files:** Create `clinvar-cvc/firestore-write.js`; Modify `clinvar-cvc/popup.js`, `clinvar-cvc/popup.html`, `clinvar-cvc/test/popup-dom.test.js`; check `clinvar-cvc/test/*` for a `classifyWriteError` test and update its `require` path.

- [ ] Move `toFirestoreFields`, `classifyWriteError`, and `saveAnnotation` verbatim from `popup.js` into a new `firestore-write.js`. They reference `FIREBASE_CONFIG` and `annotationDocId` (keep the existing `(typeof self/window ...) || require('./annotation.js')` resolution style — use `self` not `window` so the worker path works). Footer exposes all three on `self`/`window` + `module.exports`.
- [ ] In `popup.js`, delete those three functions; they're now globals from `firestore-write.js`.
- [ ] In `popup.html`, add `<script src="firestore-write.js"></script>` after `firestore-history.js`, before `popup.js`.
- [ ] Update the script-order assertion in `test/popup-dom.test.js`. If a test imports `classifyWriteError` from `popup.js`, repoint it to `firestore-write.js` (and `popup.js`'s `module.exports` no longer needs it).
- [ ] `node --check popup.js firestore-write.js`; `npm test` green. Commit: `refactor(cvc): extract create-only write into shared firestore-write.js`

### Task 2: `ensureWriteAuth()` in `firestore-history.js`
**Files:** Modify `clinvar-cvc/firestore-history.js`, `clinvar-cvc/popup.js`

- [ ] Move `getGoogleAuthToken()` (the interactive `chrome.identity.getAuthToken({interactive:true})` one) from `popup.js` into `firestore-history.js` (it pairs with the silent one already there). Expose it on the footer.
- [ ] Add `async function ensureWriteAuth()` to `firestore-history.js`: try silent first (`getGoogleAuthTokenSilent()` → if token, `exchangeGoogleToken` → `{idToken,email}`); if no silent token, fall back to interactive (`getGoogleAuthToken()` → `exchangeGoogleToken`). Return `{ idToken, email }`, or throw on failure. Expose on the footer + `module.exports`.
- [ ] In `popup.js`, `signInWithGoogle()` still works (it calls the now-global `getGoogleAuthToken` + `exchangeGoogleToken`). Remove the local `getGoogleAuthToken` definition.
- [ ] `node --check`; `npm test` green. Commit: `feat(cvc): ensureWriteAuth (silent then interactive) in shared auth module`

---

## Chunk 2: service-worker save handler

### Task 3: `saveAnnotation` message in `background.js`
**Files:** Modify `clinvar-cvc/background.js`

- [ ] Add `importScripts` for `annotation.js` and `firestore-write.js` (in addition to the existing env/firebase-config/history/firestore-history).
- [ ] Add a second `onMessage` branch (keep the `getScvHistory` one intact): for `message.subject === 'saveAnnotation'`:
  ```js
  (async () => {
    try {
      const { idToken, email } = await ensureWriteAuth();
      const doc = buildAnnotation(message.scvRow, message.vcv, message.input, email);
      const invalid = validateAnnotation(doc);
      if (invalid) { sendResponse({ ok: false, reason: 'invalid', message: invalid }); return; }
      await saveAnnotation(doc, idToken);
      sendResponse({ ok: true, email });
    } catch (e) {
      if (e && e.alreadyExists) { sendResponse({ ok: false, reason: 'alreadyExists' }); return; }
      if (e && e.notAuthorized) { sendResponse({ ok: false, reason: 'notAuthorized' }); return; }
      sendResponse({ ok: false, reason: 'error', message: e && e.message });
    }
  })();
  return true;
  ```
  (Structure it so both `getScvHistory` and `saveAnnotation` are handled and any other message returns false.)
- [ ] Verify the new importScripts globals (`buildAnnotation`, `validateAnnotation`, `annotationDocId` from annotation.js; `saveAnnotation`, `toFirestoreFields`, `classifyWriteError` from firestore-write.js; `ensureWriteAuth`) resolve in the worker. `annotationDocId` uses `crypto.subtle` — available in the SW. `node --check background.js`.
- [ ] `npm test` green. Commit: `feat(cvc): service worker create-only save handler`

---

## Chunk 3: content-script Annotate button + in-page form (manual-verified)

### Task 4: Annotate button on every row + form popover
**Files:** Modify `clinvar-cvc/content.js`, `clinvar-cvc/manifest.json`, `clinvar-cvc/highlight.css`

- [ ] `manifest.json`: add `vocab.js`, `annotation.js`, `popup-view.js` to `content_scripts[0].js` BEFORE `content.js` (so `ACTIONS`, `reasonsForAction`, `reasonOptionGroups`, `validateAnnotation` are page globals). Order: `['scrape.js','vocab.js','annotation.js','popup-view.js','highlight.js','content.js']`.
- [ ] In `content.js` `applyHighlights` (which iterates rows and already builds the history badge in `cells[3]`), ALSO append an `+ Annotate` button to `cells[3]` of EVERY row (not just annotated ones). Extract a small `ensureRowControls(doc, rowEl, scvRow, summaryByScv)` if it keeps `applyHighlights` readable. The annotate button must be part of the idempotent strip/rebuild (remove prior `.cvc-annotate-btn` alongside `.cvc-hl-badge`). NOTE: annotate buttons should appear even when there is NO history — so add them for all rows in the loop, independent of the `decorateForScv` (history) result.
- [ ] Build the annotate button with `createElement`+`textContent`; on click `ev.stopPropagation()` then `showAnnotateForm(doc, button, scvRow, vcv)` where `vcv = { vcv: data.vcv, variation_id: data.variation_id, name: data.name }` (from the scraped `data`).
- [ ] `showAnnotateForm(doc, anchorEl, scvRow, vcv)`:
  - Close any existing form (`#cvc-annotate-form`).
  - Build a popover anchored under the button (reuse the popover positioning approach from `showScvPopover`).
  - Contents: a title showing `scvRow.scv` (+ submitter); an **action** `<select>` populated from `ACTIONS` (with a “Choose…” default); a **reason** `<select>` (disabled until an action is chosen) populated via `reasonOptionGroups(action)` on action change — mirror popup.js's reset-on-change (reset reason when action changes; for `No Change`, reason not required); a **notes** `<textarea>`; a **Save** button; a status line.
  - On Save: read `input = { action, reason, notes }`; client-validate with `validateAnnotation({ scv: scvRow.scv, action, reason })` and show the message if invalid; else disable Save, show "Saving…", and `chrome.runtime.sendMessage({ subject:'saveAnnotation', scvRow, vcv, input }, (resp) => {...})`.
  - On `resp.ok`: show "Saved" briefly then `location.reload()` (refreshes highlight badges with the new annotation). On `resp.reason==='alreadyExists'`: "This annotation was already saved." On `'notAuthorized'`: "Your account is not authorized to submit — contact an admin." On `'invalid'`: show `resp.message`. Else: "Failed to save: …". Re-enable Save on any non-ok.
  - Everything in try/catch; never throw into the page. `createElement`+`textContent`/`value` only (no innerHTML).
- [ ] `highlight.css`: styles for `.cvc-annotate-btn` (a small button, distinct from the history badge — e.g. outlined) and `.cvc-annotate-form` (reuse the `.cvc-hl-popover` look; style `select`/`textarea`/button/status).
- [ ] `node --check content.js`; `npm test` green (no new unit tests; keep existing green). Commit: `feat(cvc): in-page Annotate button + form that saves via the service worker`

---

## Manual verification (human, in Chrome against DEV)
- [ ] Every SCV row shows an `+ Annotate` button (even rows with no history).
- [ ] Clicking it opens a form with that SCV shown; action list = No Change / Flagging Candidate / Remove Flagged Submission; choosing an action enables + populates reasons (grouped) matching the popup; `No Change` needs no reason.
- [ ] Saving a valid annotation as an allowlisted signed-in dev curator writes it (verify a new badge/count after the auto-reload; confirm the row in dev Firestore/BQ).
- [ ] Re-saving the exact same annotation → "already saved" (no dup).
- [ ] Not signed in → Save triggers interactive Google sign-in (once), then writes.
- [ ] Non-allowlisted account → "not authorized" message; no write.
- [ ] Invalid (e.g. Flagging Candidate with no reason) → inline validation message; no write.
- [ ] Popup (toolbar) still works unchanged; `npm test` green.

## Definition of done
`npm test` green (71 + any new). Write path shared by popup + SW (not forked). Annotate button on every row; form saves via SW with create-only semantics + interactive-auth fallback; page reloads on success. `scvc/` untouched. Manual-verification results recorded on PR #113.
