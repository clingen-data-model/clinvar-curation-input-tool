# ClinGen CvC — Review & Submit web-app: continuation handoff

Starting point for continuing the **S8 v4 Review & Submit web-app** work in a new
context/account. Read `CLAUDE.md` (repo root) first for the overall project;
this doc is the *current state + how to continue*.

## TL;DR / scope guardrails
- We are building `review-app/` — a **v4 Firestore→BigQuery Review & Submit web
  app** that will eventually replace the legacy **Google Sheet + Apps Script**
  review pipeline. **Everything so far is DEV-ONLY.**
- **DO NOT touch:** the production Google Sheet process, the legacy `scvc/`
  extension, or the prod project `clingen-cvc`. **Go-live off the sheet is
  parked.** Never `CREATE OR REPLACE` against the legacy `clinvar_curator`
  dataset (write-guarded in `dataset-guard.js`).
- Workflow: small PRs → CI green → `gh pr merge --squash` → deploy to dev. End
  commit messages with the `Co-Authored-By: Claude ...` line; PR bodies with the
  `🤖 Generated with Claude Code` line.

## IMMEDIATE NEXT STEP (in progress)
The React data grid had **persistent row/column misalignment** (rows offset from
headers + whitespace left of the header). PR #163 reset both grids to a **plain
semantic table** with explicit `display: table/table-row/table-cell` CSS (guards
against a global/Pico rule setting `display:block/flex` on table elements — the
most likely cause) and added a visible **"header cols / first-row cells" debug
readout**.

**Do this first:** open https://clingen-cvc-dev.web.app, sign in
(lbabb@broadinstitute.org is allow-listed), look at the debug line above each grid:
- **counts equal + now aligned** → success. Re-add, one at a time: (a) column
  **resize** (TanStack `enableColumnResizing`/`columnResizeMode:'onChange'` +
  localStorage persist — was PR #162, reverted in the reset), (b) **per-column
  filtering** as a proper filter `<tr>` in `<thead>` or a single global search
  box (deferred in #159 — inline header inputs distorted `width:100%`).
- **counts equal + STILL misaligned** → it's CSS/layout: inspect computed
  `display` on `table.grid`/`tr`/`td`; check Pico interference; try removing Pico.
- **counts differ** → a column-def bug (header vs cell mismatch) in
  `ReviewView.tsx`/`ReflagView.tsx`.

## Frontend (React + Vite + TS + TanStack Table)
- `review-app/web/` Vite app → builds to `web/dist` → Firebase Hosting serves it
  (`firebase.json` `hosting.public: web/dist`, SPA rewrite, `**` `no-cache`).
- `src/`: `api.ts` (typed `/api` client), `types.ts`, `firebase.ts` (auth via
  `/__/firebase/init.json`), `App.tsx` (auth gate + allowlist check + Review/Reflag
  tabs + release-staleness banner), `views/ReviewView.tsx`, `views/ReflagView.tsx`,
  `views/HistoryHover.tsx`. Styling: Pico.css (CDN) + `src/styles.css`.
- **Local preview:** `cd review-app/web && npm install && npm run dev` →
  http://localhost:5173 (Vite proxies `/api` + `/__` to the dev backend; Google
  sign-in works on localhost).

## Backend (Cloud Functions — unchanged; DO NOT rewrite)
- `review-app/functions/` (Node 20). Endpoints: `/whoami /config /queue
  /scv-history /reflag-candidates /review-bulk /assign-bulk /unassign-bulk /reflag
  /generate /finalize /reprocess /files /files/delete /files/delete-drafts`.
  Plus Firestore `onCapture` trigger + `enrichQueue` (`onTaskDispatched`) for
  **event-driven enrichment**.
- Tests: `cd review-app/functions && npm test` → **129 Vitest green** (pure logic;
  DOM/fetch/deploy verified manually). CI runs these + the web build.
- Modules: `queue.js` (queue + scv-history), `review.js` (bulk review/assign),
  `reflag.js` (reflag candidates + capture writes), `enrich.js` (adapter reimpl +
  base refresh + release stamp), `generate.js`/`finalize.js`/`submission.js`/
  `drive.js`/`files.js`/`config.js`/`autoReview.js`/`dataset-guard.js`.

## Data / enrichment
- BQ in `clingen-dev`: `clinvar_curator_v4_dev` (v4 shadow) + `clinvar_ingest`.
  Firestore capture in `clingen-cvc-dev` (`clinvar_cvc_ext_annotations`).
- Flow: extension/reflag write → Firestore capture → `onCapture` (debounced
  Cloud Task) → `enrich.js` (snapshot→GCS→load→reshape into `cvc_annotations_native_v4`,
  then rebuild `cvc_review_queue_base`, then stamp `cvc_review_config.base_release_date`).
  Manual fallback: `bigquery/curator/adapter/refresh-native-v4.sh`
  (`CVC_PROD=clingen-cvc-dev CURATOR_PROJECT=clingen-dev CURATOR_DATASET=clinvar_curator_v4_dev
  GCS_PREFIX=native_v4_dev GCS_BUCKET=gs://clingen-dev-cvc-native-v4-staging`) + a
  `buildRefreshQueueSql` run.
- **ClinVar-release staleness:** `/config` compares `base_release_date` vs
  `release_on(CURRENT_DATE())` → `releaseStale` shows a banner + **blocks Finalize**
  until "Re-process now" (`/reprocess`) re-enriches.

## Deploy (manual, until CI deploy is enabled)
```
cd review-app/web && npm run build          # produces web/dist
cd .. && "$(npm config get prefix)/bin/firebase" deploy --only hosting,functions \
  --project clingen-cvc-dev --force --non-interactive
```
- CI: `.github/workflows/ci.yml` (ACTIVE — tests+build on `review-app/**`).
  `deploy-dev.yml`/`deploy-prod.yml` are DORMANT drafts (workflow_dispatch only)
  until a **Workload Identity Federation** deploy credential is provisioned — see
  `.github/CI-CD-SETUP.md` (this is a USER/repo-owner action).
- IAM: `review-app/scripts/grant-iam.sh`. **Re-run after any deploy that recreates
  the gen2 Cloud Run services** — it re-asserts the `run.invoker`/`actAs`/
  `cloudtasks.enqueuer` bindings the enrichment triggers need (they silently drop
  otherwise). SA = `362266755807-compute@developer.gserviceaccount.com`.

## Gotchas
- `firebase` CLI lives at `$(npm config get prefix)/bin/firebase` (not on PATH).
- Before `git merge --ff-only origin/main`: `git checkout -- review-app/functions/package-lock.json`
  (npm install dirties it and blocks the ff-merge).
- Firebase preview-channel URLs are NOT auth-authorized domains → use `npm run dev`
  (localhost) for auth-required previews.
- A firebase-admin one-off Node script that doesn't `try/catch` + `process.exit(0)`
  can crash silently — wrap deletes/writes.

## Feature history (PRs, all merged to main)
- #140 fresh-row honesty · #141 bulk review UX · #142 checkbox/no-cache · #143
  Tabulator+Pico · #144/#145 root no-cache · #146 phantom-dirty · #147 clear-to-none
  · #148 apply-auto · #149 sheet-context columns+guide · #150 prior-history popover
  · #151 generated-file mgmt · #152 fast history + fresh-VCV · #153 fresh-VCV keep
  version · #154 event-driven enrichment + release staleness · #155 reflagging
  · #156 UI polish · #157 React+Vite+TS+TanStack + CI · #158 dev cutover to React
  · #159 defer filters · #160/#161/#163 grid alignment · #162 column resize (reverted in #163).

## Open / parked
- **Finish the grid** (verify alignment via #163 debug readout → re-add resize + filtering). ← next
- User-facing **documentation** (extension ops, review, reflagging, reporting).
- **WIF CI deploy credential** (user) to activate the deploy workflows.
- Go-live off the sheet (parked); Gmail draft-with-attachment (parked); Reflag was
  ported to v4 (#155) — legacy `Review&Submit/Reflag.js` is the reference.

## Pointers
- `CLAUDE.md` (repo root) — project + v4 architecture.
- Local memory: `~/.claude/projects/-Users-lbabb-Development-clinvar-curation-input-tool/memory/`
  (`MEMORY.md` index; `s8-review-submit-webapp.md` = full S8 detail). Persists per
  project path on this machine (survives account switch on the same machine).
- Specs/plans: `docs/superpowers/{specs,plans}/2026-08-*`.
