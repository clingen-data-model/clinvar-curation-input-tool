# ClinVar CvC v4 (Firestore/BigQuery) — Program Roadmap

> **For agentic workers:** This is a PROGRAM roadmap that decomposes the major
> release into sequenced sub-plans. Each sub-plan is written separately as a
> detailed, bite-sized TDD plan (via superpowers:writing-plans) once its gating
> decisions are locked, then executed via superpowers:subagent-driven-development.
> This document is the map; it is not itself executed step-by-step.

**Goal:** Ship the next major version of the ClinVar Curator Chrome extension —
built on the `clinvar-cvc/` (Firestore + Google sign-in + curator allowlist +
BigQuery streaming) foundation, replacing the legacy `scvc/` Google-Sheets save
path — without modifying the `scvc/` artifacts.

**Architecture:** Merge the two existing extensions. Take `clinvar-cvc/`'s backend
(Firestore REST writes, Google sign-in, `allowed_curators` allowlist, Firestore→
BigQuery streaming) and port `scvc/`'s value (ClinVar page scraping + rich SCV
picker/annotation form) onto it, refactored for testability and resilience. Add
a dev/prod environment split, migrate historical sheet data, and add two UX
features (in-extension annotation history; in-page click-to-annotate).

**Tech stack:** Chrome MV3 (vanilla JS, no build step preserved where possible),
Firestore REST API, Firebase Auth (Google sign-in via Identity Toolkit), Firebase
Extension `firestore-bigquery-export`, BigQuery, GCP project `clingen-cvc` (+ a
dev project), Vitest + jsdom for tests (proposed), gcloud/firebase CLIs for IaC.

---

## Scope check — this is a program of sub-plans

The request spans six largely independent subsystems plus one adjacent integration
workstream. Each is planned and shipped on its own so it produces working,
testable software independently:

| # | Sub-plan | Maps to your item | Depends on |
|---|---|---|---|
| **S0** | Foundation: evolve `clinvar-cvc/` into the full extension (port `scvc/` scraping + rich form onto the Firestore backend) | (4) refactor | S1, S2 |
| **S1** | Environments: dev vs prod projects + config selection | (6) safe trialing | — |
| **S2** | Test infrastructure + first unit tests | (1) unit testing | — |
| **S3** | `scvc/*.js` review & refactor analysis (feeds S0) | (4) | S2 |
| **S4** | Historical sheet → annotations migration | (2) data copy | S0, S1 |
| **S5** | Allowlist backfill from historical emails | (3) | S4 |
| **S6** | In-extension annotation history view | (2) new feature | S0, S4 |
| **S7** | In-page click-to-annotate on ClinVar pages | (5) | S0 |
| **S8** | *(Adjacent)* Repoint Review&Submit/Generate pipeline to the new annotations table | integration | S4 |

**Recommended sequence:** S1 + S2 (parallel, foundational) → S3 → S0 → S4 → S5 →
S6 / S7 (parallel) → S8. S8 is called out because the extension change is not
truly "production" until the downstream batch pipeline reads the new source.

---

## Foundational decisions to lock before detailed planning

These gate the concrete task breakdowns. My recommendation is given; please confirm
or redirect. (Captured here rather than assumed.)

> **LOCKED 2026-08-01:** **D1 = A** (`clingen-cvc` is production; add
> `clingen-cvc-dev` twin). **D2 = A** (history lands in Firestore, streams to BQ,
> extension reads it). **D3 = A** (Vitest + jsdom). **D4–D6:** defaults accepted —
> keep the `clinvar-cvc/` directory (D4); env selected via a config constant + dev
> banner (D5); pipeline repoint planned as S8 with a transition bridge (D6).

### D1 — Environment model (item 6) ⭐ highest impact
**Options:**
- **(A, recommended)** Treat the current `clingen-cvc` as **production**, and stand
  up a separate **`clingen-cvc-dev`** project that mirrors it (same rules, extension,
  allowlist, dataset). Trial all changes in dev; promote by deploying the same
  version-controlled artifacts (`firestore.rules`, extension manifest, `setup-*.sh`)
  to prod. The extension selects environment via config (see D5).
- **(B)** Treat current `clingen-cvc` as **dev/sandbox** and create a fresh
  `clingen-cvc-prod` for launch. Cleaner prod, but re-does the migration/allowlist there.

**Recommendation: A** — `clingen-cvc` already has verified infra and a real curator;
make it prod and add a cheap, disposable dev twin. The setup is already scripted,
so mirroring to `clingen-cvc-dev` is one script run.

### D2 — Historical data store (item 2) ⭐
Where does the migrated Google-Sheet history land, and how does the extension read
annotation history for a variation/SCV?
- **(A, recommended)** Load history into the **Firestore** `clinvar_cvc_ext_annotations`
  collection. It then (a) streams to BigQuery automatically via the existing
  extension, and (b) is directly readable by the Chrome extension over REST — which
  is exactly what the S6 history feature needs. One uniform read path.
- **(B)** Load history into **BigQuery only**; the S6 history view calls a backend
  (Cloud Function) that queries BQ. Adds a service; the extension can't read BQ directly.

**Recommendation: A.** It answers your open question ("start at Firestore or add to
BQ") with *start at Firestore*, and makes the in-extension history view a plain
Firestore query. Caveat: needs Firestore composite indexes on `variation_id` and
`scv_id`, and a one-time bulk import (thousands of docs — cheap, but the Firestore→BQ
extension will stream them all, so run the import deliberately).

### D3 — Test framework (item 1)
- **(A, recommended)** **Vitest + jsdom** — fast, great DX, ESM-friendly, mocks
  `chrome.*` and `fetch` easily, jsdom covers the scraping/DOM tests. Introduces
  `node_modules` + `package.json` (dev-only; the extension itself stays build-free).
- **(B)** Node's built-in `node:test` + a lightweight DOM shim — zero deps, but
  weaker DOM/mocking ergonomics.

**Recommendation: A** (Vitest). `content.js` already exports via `module.exports`
for testing, so it's wired for a runner.

### D4 — New extension identity / directory
The production extension evolves **in `clinvar-cvc/`** (the foundation), leaving
`scvc/` untouched. Decision: keep the dir name `clinvar-cvc/` or rename to something
like `scvc-v4/` / `clinvar-curator-v4/`? **Recommendation:** keep `clinvar-cvc/` for
now (avoids churn); revisit at release. The user-facing extension name/version in
`manifest.json` becomes the "v4" identity.

### D5 — How the extension selects environment (depends on D1)
No build step today. **Recommendation:** a single `ENV`-like constant in
`firebase-config.js` choosing between a `prod` and `dev` config block (both checked
in; only public identifiers), plus a visible dev-mode banner in the popup. Load the
dev-pointed unpacked extension separately during trials. (If we later add a bundler,
switch to `.env` injection.)

### D6 — Downstream pipeline scope (S8)
Is repointing the Review&Submit/Generate/Reflag pipeline (`cvc_annotations` source)
part of *this* release, or a follow-on? **Recommendation:** plan it as S8 in this
program (the release isn't "production" until batch generation reads the new table),
but it can ship slightly after the extension if a bridge view keeps the old pipeline
working during transition.

---

## Sub-plan briefs

Each brief states scope, approach, **testing approach (TDD-first)**, key files, and
risks. Detailed bite-sized plans are written per sub-plan after D1–D6 are locked.

### S1 — Environments (dev/prod)
**Scope:** A reproducible dev twin of `clingen-cvc` and a promotion path.
**Approach:** Parameterize `setup-clingen-cvc.sh` by project id; run it to build
`clingen-cvc-dev` (Firestore `(default)` nam5, rules, extension, allowlist seed,
External audience). Store both projects' public config in `firebase-config.js`
(D5). Document promote = deploy the same `firestore.rules` + extension manifest to
prod. Add a popup dev-mode banner.
**Testing:** Unit-test the env-selection logic (given `ENV`, returns the right
projectId/collection). Smoke-test: a dev write lands only in dev Firestore/BQ.
**Files:** `setup-*.sh` (parameterize), `firebase-config.js`, `popup.html/js` (banner).
**Risks:** Dev project also needs its own OAuth client + audience (console steps);
keep the two client_ids straight.

### S2 — Test infrastructure
**Scope:** A test runner + first meaningful tests; CI-ready.
**Approach (D3=Vitest):** Add dev-only `package.json` + `vitest` + `jsdom`; `.gitignore`
`node_modules`. Provide `chrome.*`/`fetch` mocks. Seed tests: `content.js` scraping
against saved ClinVar HTML fixtures; form validation; Firestore payload builder;
allowlist decisioning; auth token flow (mocked).
**Testing:** This sub-plan *is* the test harness; each later sub-plan adds its tests.
**Files:** `package.json`, `vitest.config.js`, `test/` fixtures + specs, `.gitignore`.
**Risks:** Keep tests out of the shipped extension (they must not affect MV3 load).

### S3 — `scvc/*.js` review & refactor analysis (feeds S0)
**Scope:** A written analysis + refactor targets; no behavior change on `scvc/`.
**Findings so far (seed the analysis):**
- **Fragile scraping** — `content.js` relies on long regexes over `innerHTML` +
  XPath tied to NCBI's DOM/class names; this is the documented #1 breakage source.
  Refactor toward structured selectors, small named extractors, and graceful
  degradation with a "couldn't parse X" surface instead of silent "".
- **Debug noise** — heavy `console.log` throughout; gate behind a debug flag.
- **Duplicated vocab** — action/reason lists are hardcoded in `popup.js`; the same
  vocabulary lives in the spec and Apps Script. Extract to one shared module.
- **Callback sprawl** — `background.js` nests `getProfileUserInfo`/`getAuthToken`/
  `fetch` callbacks; the new backend already uses promises/`fetch` — consolidate.
- **Dead fields** — `spreadsheet`/`scv_range`/`vcv_range` hidden inputs die with the
  Sheets path.
**Approach:** Produce a refactor map that S0 implements (extract modules: `scrape.js`,
`vocab.js`, `firestore.js`, `auth.js`, `ui.js`), each independently testable.
**Testing:** Characterization tests (S2) pin current scraping output on fixtures
*before* refactoring, so the refactor is provably behavior-preserving.
**Risks:** Over-refactor; keep it to the modules S0 needs.

### S0 — Foundation: full production extension
**Scope:** Evolve `clinvar-cvc/` into the real extension: ClinVar page scraping +
SCV-picker + action/reason/notes form (from `scvc/`), writing to Firestore (not
Sheets), gated by Google sign-in + allowlist, streaming to BigQuery.
**Approach:** Add host permissions + content script for `ncbi.nlm.nih.gov/clinvar/
variation/*`; port refactored `scrape.js` (S3); replace the 5-field POC form with
the rich picker/form; map the scraped fields → the 13-field annotation schema
(spec); keep the verified-email + allowlist write path. Preserve no-build where
possible (vendor Bootstrap CSS locally to satisfy MV3, or drop it for hand CSS).
**Testing (TDD):** scraping fixtures (S2/S3), field-mapping unit tests
(scraped → Firestore payload matches spec), validation rules, an end-to-end popup
smoke test in jsdom, and a live manual pass on a real ClinVar page.
**Files:** `clinvar-cvc/manifest.json` (host perms, content script), `content.js`
(new, from refactor), `popup.html/js`, `scrape.js`, `vocab.js`, `firestore.js`.
**Risks:** MV3 CSP (no CDN scripts); ClinVar DOM drift (mitigated by S3 resilience).

### S4 — Historical data migration
**Scope:** Copy all Google-Sheet `SCVs` history into the new annotations store.
**Approach (D2=Firestore):** Export the sheet's `SCVs` rows; transform each to the
Firestore doc shape (`variation_id, vcv, scv, submitter, submitter_id, interp,
action, reason, notes, review_status, user_email, created_at/timestamp`); bulk-write
to `clinvar_cvc_ext_annotations` (owner token / Admin SDK), which streams to BQ.
Idempotent (deterministic doc ids to allow re-runs). Run in **dev first**, verify,
then prod.
**Testing (TDD):** transform unit tests (sheet row → doc), dedup/idempotency test,
a dry-run count reconciliation (sheet rows == Firestore docs == BQ rows).
**Files:** `migration/` scripts + transform module + tests.
**Risks:** Volume (thousands of docs → thousands of BQ stream events; cheap but
deliberate); timestamp/format normalization; PII (emails) handling.

### S5 — Allowlist backfill from historical emails
**Scope:** Every distinct `user_email` in the sheet history becomes an
`allowed_curators` doc.
**Approach:** From the migrated data (or the sheet directly), extract distinct
non-empty emails; upsert each via the existing `add-curator.sh` path / batch REST.
Run in dev then prod.
**Testing (TDD):** distinct-email extraction test; idempotent upsert test; verify
`list-curators.sh` count matches distinct historical emails + current curators.
**Files:** `migration/backfill-allowlist.*` (reuses curator-helper logic).
**Risks:** Stale/typo emails from years of data → some allowlisted accounts may
never sign in (harmless); optionally tag provenance (`added_by: "historical"`).

### S6 — In-extension annotation history view
**Scope:** In the popup, show prior annotations for the current `variation_id` /
selected `scv_id` so a curator sees what's already been done.
**Approach (D2=Firestore):** Query `clinvar_cvc_ext_annotations` where
`variation_id ==` (and/or `scv_id ==`) ordered by timestamp desc, rendered as a
compact history panel. Requires Firestore composite indexes + a rules read path
(allowlisted curators may read history). Consider scope: all curators' history vs
own only — **recommend all allowlisted curators see all history** (the stated goal:
awareness of prior annotations).
**Testing (TDD):** query-builder unit test; render test (given docs → panel);
rules test (allowlisted read allowed, non-allowlisted denied).
**Files:** `history.js`, `popup.html/js`, `firestore.rules` (read rule + indexes),
`firestore.indexes.json`.
**Risks:** Read-path rules must not leak data to non-curators; index management.

### S7 — In-page click-to-annotate
**Scope:** Clickable affordances on the ClinVar page's SCV rows that open the
annotation flow prefilled for that SCV.
**Approach:** Content script injects a small button per SCV row; clicking messages
the extension to open the popup (or an injected inline mini-form) prefilled with
that SCV's scraped fields. Reuse S0's scrape + form modules.
**Testing (TDD):** injection test (buttons appear per row on a fixture page);
message-passing test (click → correct SCV payload); prefill test.
**Files:** `content.js` (injection), `popup.js` (accept prefill), messaging.
**Risks:** Injecting into NCBI's DOM (style isolation, re-render robustness);
popups can't be opened programmatically without a user gesture — an inline
in-page mini-form may be required instead of the toolbar popup.

### S8 — (Adjacent) Repoint the batch pipeline
**Scope:** Make Review&Submit/Generate/Reflag read the new annotations table.
**Approach:** Repoint the `cvc_annotations` source (BQ TVF / external table) from
the sheet to `clinvar_cvc_ext.*` (or a reconciling view unioning historical +
new). Update `Generate.js`/`Reflag.js` references. Bridge view keeps old pipeline
alive during transition.
**Testing:** query parity — the pipeline's inputs match pre/post on a sample batch.
**Files:** BQ DDL (out-of-repo), `Review&Submit/*.js` (references).
**Risks:** This is where "capture moved off the sheet" actually lands downstream;
coordinate with whoever owns `clinvar_curator`.

---

## Cross-cutting testing strategy (item 1)

- **TDD throughout:** characterization tests pin current behavior before refactors
  (S3→S0); new behavior is test-first.
- **Layers:** pure logic (transforms, field-mapping, validation, query builders) →
  fast unit tests; DOM scraping/injection → jsdom + saved ClinVar HTML fixtures;
  rules → the Firestore emulator (`firebase emulators:exec`) for allowlist/read/write
  rule tests; migration → dry-run reconciliation counts.
- **No live prod in tests** — everything runs against mocks, fixtures, the emulator,
  or the **dev** project (S1). This is the testing half of your item-6 requirement.
- **CI-ready:** `npm test` runs unit + rules-emulator tests headlessly.

---

## Immediate next steps

1. **Confirm D1–D6** (or redirect). D1 (env model), D2 (Firestore for history), D3
   (Vitest) are the ones that unblock the most.
2. On confirmation, I write the first detailed **bite-sized TDD sub-plan** — start
   with **S1 (Environments) + S2 (Test infra)** since everything else builds on a
   safe dev target and a test harness — followed by S3→S0.
3. Each detailed sub-plan goes through the plan-document review loop, then executes
   via superpowers:subagent-driven-development in a dedicated worktree.
