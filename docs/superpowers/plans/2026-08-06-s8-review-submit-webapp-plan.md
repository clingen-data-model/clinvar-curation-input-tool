# S8 — Review & Submit v4-native web app: implementation plan

> **Status: PLAN (draft) — ready to execute via subagent-driven-development.**
> Design: `docs/superpowers/specs/2026-08-06-s8-review-submit-webapp-design.md`.
> Legacy `scvc/` sheet + the live Apps Script project + the production Review &
> Submit sheet are **never modified**. Everything here is built in parallel and
> activated only at cutover (go-live is parked). Build/test against the
> adapter-fed v4 shadow; the capture→US relocation (design decision E) is a
> cutover-time infra task, NOT a build blocker.

## Stack & conventions

- **Location:** new `review-app/` dir at repo root (sibling to `clinvar-cvc/`).
- **Backend:** Node Cloud Functions (Firebase Functions) in the existing Firebase
  project; `@google-cloud/bigquery`, Drive + Gmail via googleapis.
- **Frontend:** vanilla JS + Firebase Hosting (matches the extension's no-build
  ethos); Firebase Auth (Google sign-in) reused.
- **Tests:** Vitest (as in `clinvar-cvc/`). Pure logic (SQL/NDJSON builders,
  finalize orchestration, allowlist, batch-id) unit-tested; BQ/Drive/Gmail wiring
  is thin, injected, and integration-smoked + manually verified.
- **Auth/allowlist:** reuse Google sign-in + `allowed_curators`. Backend
  re-checks the caller's verified email against `allowed_curators` on every
  mutating call (never trust the client).
- **Datasets:** all new workflow state lives in the **v4 lineage**
  (`clinvar_curator_v4` / `_dev`) or a new review dataset — **never**
  `clinvar_curator` (the live sheet lineage).

## Data-model decision (resolves a design detail)

The impact SP reads `@@DATASET@@.cvc_clinvar_reviews` / `_submissions` /
`_batches`. In the v4 shadow those are currently **read-only passthrough views**
over the legacy sheet staging. The web app needs to **own and write** them, so:

- Convert the v4 lineage's `cvc_clinvar_reviews` / `cvc_clinvar_submissions` /
  `cvc_clinvar_batches` from passthrough views into **real writable tables**
  populated by the app (same schemas the SP already expects).
- Add `cvc_review_config` (single-row: `next_batch_id`, `last_finalized_date`).
- The "in-progress" review/assignment state (before finalize) also lives in BQ:
  `cvc_review_state` (annotation_id, review_status, reviewer, notes, batch_id,
  timestamps). Finalize promotes the relevant rows into `cvc_clinvar_reviews` /
  `_submissions` and appends the `_batches` row.

This keeps ALL curation state next to the analytics lineage (design decision A),
with zero Firestore↔BQ reconciliation.

## Chunks (dependency-ordered, TDD)

### Chunk 0 — Scaffolding + auth reuse
- **Files:** `review-app/` (firebase.json additions, functions/ skeleton,
  public/ skeleton, package.json, vitest config).
- **Tests first:** `auth.test.js` — `assertAllowlisted(email, lookupFn)` returns
  ok for an allow-listed email, throws `notAuthorized` otherwise (pure; injected
  lookup). `verifyIdToken` wrapper is thin/mocked.
- **Build:** Functions entrypoint with an auth middleware that verifies the
  Firebase ID token and re-checks `allowed_curators`; a hosting page that signs
  in with Google and calls a `whoami` endpoint.
- **Done:** signed-in allow-listed user reaches an authenticated `whoami`;
  non-allow-listed gets 403. Vitest green.

### Chunk 1 — BQ workflow-state schema
- **Files:** `review-app/sql/00-review-state-schema.sql` (create
  `cvc_review_state`, `cvc_review_config`; convert `cvc_clinvar_reviews` /
  `_submissions` / `_batches` from passthrough views to real tables in
  `clinvar_curator_v4_dev` first). A `deploy-review-schema.sh` (dataset-tokenized,
  refuses `DATASET=clinvar_curator`).
- **Tests first:** `schema.test.js` — the generated DDL targets only the v4
  dataset; the guard rejects the legacy dataset.
- **Build + verify:** deploy to `clinvar_curator_v4_dev`; re-run the impact SP
  (`refresh_cvc_impact_analysis`) against the now-real tables → still succeeds and
  the parity anchors (#4/#5) are unchanged.
- **Done:** SP runs green over real (empty) workflow tables in the dev shadow.

### Chunk 2 — Backend read: review queue
- **Files:** `review-app/functions/queue.js` + `queue.sql.js` (query builder).
- **Tests first:** `queue.sql.test.js` — builds the `cvc_annotations(v4,
  "unreviewed")` projection joined to `cvc_review_state` for status; parameterized
  by dataset; no `clinvar_curator` reference.
- **Build:** `GET /queue` returns the unreviewed v4 annotations + any in-progress
  review state.
- **Done:** endpoint returns rows from the dev shadow; unit tests green.

### Chunk 3 — Backend generate(batch) → NDJSON + parity harness
- **Files:** `review-app/functions/generate.js` + `generate.sql.js` (the
  **validated** 13-field projection, dataset-tokenized), `review-app/sql/
  parity-generate.sql` (legacy-vs-v4 per-batch diff, extends the 2026-08-06
  check), `review-app/functions/ndjson.js`.
- **Tests first:** `ndjson.test.js` (rows→newline-delimited `TO_JSON_STRING`
  shape, notes newline-stripping); `generate.sql.test.js` (projection columns ==
  `SUBMISSION_FILE_SPEC.md`; dataset token; scope handling).
- **Build:** `POST /generate {batchId}` runs the query over v4, writes NDJSON to
  the shared Drive folder, returns count + file link. **Read-only w.r.t. state.**
- **Verify:** parity harness — for a historical batch, legacy-vs-v4 NDJSON diff ==
  0 (already shown at the annotation level; here at the file level).
- **Done:** generate produces a byte-identical file to a legacy batch; tests green.

### Chunk 4 — Backend write: review status + batch assignment
- **Files:** `review-app/functions/review.js` (set status, assign/unassign batch),
  `review-app/functions/state.sql.js`.
- **Tests first:** `review.test.js` — status validation (OK/Fixed/Archive/
  Question), assignment idempotency, allowlist enforcement, dataset guard.
- **Build:** `POST /review {annotationId, status, notes}` and `POST /assign
  {annotationId, batchId}` upsert `cvc_review_state` (MERGE), stamping reviewer =
  verified email + timestamp.
- **Done:** round-trips through the dev shadow; unit tests green.

### Chunk 5 — Backend finalize(batch) — atomic
- **Files:** `review-app/functions/finalize.js`, `review-app/functions/email.js`
  (Gmail-API draft), `review-app/sql/finalize.sql` (promote state → reviews /
  submissions, append batches row, bump `cvc_review_config`).
- **Tests first:** `finalize.test.js` — orchestration order (generate → email
  draft → persist → SP refresh → bump) with injected BQ/Gmail/Drive; refuses if
  unreviewed rows remain (mirrors the current warning); rolls back the batch bump
  if any step fails.
- **Build:** `POST /finalize {batchId}`: generate (Chunk 3) → Gmail draft with
  the file attached → persist records (single BQ script/txn) → `CALL
  refresh_cvc_impact_analysis()` → bump `next_batch_id`.
- **Done:** end-to-end finalize on the dev shadow produces file + Gmail draft +
  persisted records + refreshed SP + bumped id; tests green.

### Chunk 6 — Frontend
- **Files:** `review-app/public/` (index.html, app.js, styles).
- **Build (manual-verified):** Google sign-in; review-queue table with per-row
  status + notes and bulk actions; batch panel (assign/unassign, current batch,
  counts); Generate + Finalize buttons wired to the endpoints; a DEV/PROD banner
  like the extension.
- **Done:** a curator can review, assign, generate, and finalize a batch entirely
  in the app against the dev shadow.

### Chunk 7 — End-to-end parity + cutover runbook
- **Files:** `review-app/README.md`, `docs/.../s8-cutover-runbook.md`.
- **Verify:** reproduce a full legacy batch off v4 end-to-end; NDJSON diff == 0.
- **Runbook (cutover-time, not now):** relocate capture dataset to **US** and
  delete the adapter (reconfigure the Firestore→BQ extension region per
  `CLAUDE.md`; re-grant `run.invoker` + the runtime-SA roles after reinstall; do
  prod `clingen-cvc` and dev `clingen-cvc-dev`); switch curators to extension
  capture; retire the sheet + Apps Script; point the app at prod
  (`clinvar_curator_v4`).

## Safety invariants (every chunk)
- No object in `clinvar_curator` (legacy) is created/altered/written. A dataset
  guard in every deploy/query builder hard-refuses `clinvar_curator`.
- Build + test against `clinvar_curator_v4_dev`; promote to `clinvar_curator_v4`
  (prod shadow) only when validated. Neither is the live pipeline.
- The live sheet, Apps Script project, and production Review & Submit sheet are
  never touched.

## Open items to confirm before/while executing
- Firebase project: reuse `clingen-cvc` (prod) / `clingen-cvc-dev` (dev) Hosting +
  Functions, or a separate app project? (Lean: same projects.)
- Gmail draft: which mailbox drafts the submission email (invoking curator via
  per-user OAuth vs a shared service mailbox)? (Lean: invoking curator, add the
  compose scope.)
- Does converting v4 staging views → real tables affect the current parity tests
  (which rely on passthrough over legacy)? Plan: snapshot legacy staging into the
  new real tables once, so existing parity holds until real curation writes begin.
