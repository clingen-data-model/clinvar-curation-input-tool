# S8 — Review & Submit v4-native web app: implementation plan

> **Status: PLAN (revised after 3-reviewer plan-review, 2026-08-06) — ready for
> subagent-driven-development.** Design:
> `docs/superpowers/specs/2026-08-06-s8-review-submit-webapp-design.md`.
> Legacy `scvc/` sheet + the live Apps Script project + the production Review &
> Submit sheet are **never modified**. Built in parallel; activated only at
> cutover (go-live parked). Build/test against the adapter-fed v4 shadow; the
> capture→US relocation (design decision E) is a cutover-time infra task, NOT a
> build blocker.

## Plan-review revisions (what changed vs the first draft)

Three independent reviews (correctness, safety/non-impact, architecture) all
returned **Revise**. Folded in: IAM-based non-impact (not a string guard);
a corrected non-atomic finalize; two new chunks (auth-resolution, auto-review
rules); a real Chunk-1 verification; missing data-flow contracts (batch-row
derivation, `scv_id/scv_ver`, config for reviewers/recipients); and hard
separation of the Drive folder + Gmail recipients pre-cutover.

## Stack & conventions

- **Location:** new `review-app/` dir at repo root (sibling to `clinvar-cvc/`).
- **Backend:** Node Cloud Functions (Firebase Functions); `@google-cloud/bigquery`,
  Drive + Gmail via googleapis.
- **Frontend:** vanilla JS + Firebase Hosting (no-build ethos); Firebase Auth
  (Google sign-in) reused. **Reuse is architectural** (same Google identity +
  allow-list gate), **not code** — `firestore-*.js` are `chrome.*`-based and do
  not run in a web app. Budget Chunk 0 accordingly.
- **Tests:** Vitest. Pure logic (SQL/NDJSON builders, `autoReview()`, finalize
  orchestration, allowlist, batch-id, batch-row derivation) unit-tested; BQ/
  Drive/Gmail wiring is thin, injected, integration-smoked + manually verified.
- **Deploy:** always `firebase deploy --only hosting,functions` — **never** a
  bare `firebase deploy`; `review-app/firebase.json` must NOT declare the
  firestore-bigquery-export extension (a reinstall drops its runtime-SA IAM and
  silently 403s live capture — see CLAUDE.md). Post-deploy, verify a Firestore
  write still lands in BQ.

## Non-impact enforcement (primary control = IAM, not strings)

The v4 shadow datasets live in `clingen-dev` — the **same project** as live
`clinvar_curator` + `clinvar_ingest`. A code-level string guard is not
sufficient. Enforce with **dataset-scoped IAM**:

- App/Functions runtime SA: `roles/bigquery.dataEditor` **only** on
  `clinvar_curator_v4[_dev]` + the review dataset; `roles/bigquery.dataViewer`
  **only** on `clinvar_curator` and `clinvar_ingest`; `jobUser` on the project.
  → no code path (guard bug, mis-token, bad SP CALL, ad-hoc job) can physically
  write legacy.
- **Write-path guard** (second layer): reject `clinvar_curator` as a DDL/DML/
  insert *target*; **allow it as a read source** (the parity harness legitimately
  reads legacy). Match on the exact dataset token, not a substring
  (`clinvar_curator` is a prefix of `clinvar_curator_v4`). Unit-test: a write
  targeting legacy is rejected; a parity read is allowed.
- **Drive:** the app writes to a **separate** Drive folder (dev + prod) with a
  distinct filename prefix (`v4-`/`DEV-`); it must **never** trash files matching
  the legacy `clinvar-annotation-submission-*` name in the live folder.
- **Gmail (pre-cutover):** draft **only** to the invoking curator (or a marked
  test address) with a `TEST/DEV` subject prefix and NO real recipients;
  recipients come from `cvc_review_config`, never the live sheet's named ranges.
- **OAuth:** the Gmail restricted scope must NOT be added to the extension's
  shared consent screen (would force re-verification affecting live sign-in) —
  use a separate OAuth client or a dedicated service mailbox (see Chunk 0.5).

## Data model (BigQuery, in the v4 lineage — never `clinvar_curator`)

The impact SP reads `@@DATASET@@.cvc_clinvar_reviews`/`_submissions`/`_batches`.
In the v4 shadow those are **read-only passthrough views** over legacy. The app
must own+write them:

- Convert those three from passthrough views → **real writable tables** (Chunk 1),
  preserving exact schemas (esp. the `cvc_clinvar_batches` **6 columns** incl. the
  nested `submission` STRUCT, and reviews' `date_added` + `date_last_updated`).
- `cvc_review_state` (in-progress, before finalize): `annotation_id` **(UNIQUE)**,
  `scv_id`, `scv_ver`, `review_status`, `reviewer`, `notes`, `batch_id`,
  `date_added`, `date_last_updated`. (`scv_id/scv_ver` captured at assignment —
  the SP joins submissions on them.)
- `cvc_review_config` (single row): `next_batch_id`, `last_finalized_date`,
  `reviewers[]` (auto-OK allow-list — distinct from `allowed_curators`),
  `submission_recipients[]`, `submission_cc[]`.
- `cvc_review_state` is a separate store NOT read by `base_mv`, so in-cycle rows
  correctly stay "unreviewed" (`is_reviewed = cvc_clinvar_reviews.batch_id IS NOT
  NULL`). Finalize promotes rows from `cvc_review_state` into the real tables.

## Chunks (dependency-ordered, TDD)

### Chunk 0 — Scaffolding + auth reuse + IAM
- Files: `review-app/` skeleton (firebase.json hosting+functions only, functions/,
  public/, package.json, vitest).
- Tests first: `auth.test.js` — `assertAllowlisted(email, lookupFn)` ok/`notAuthorized`.
- Build: ID-token verify middleware + `allowed_curators` re-check; `whoami`.
  Provision the **dataset-scoped IAM** above (dev SA first).
- Done: allow-listed user reaches `whoami`; others 403; SA has write only on
  v4/review, read-only on legacy+ingest (verify by attempting a legacy write →
  denied). Vitest green.

### Chunk 0.5 — Auth resolution for Gmail + Drive (blocker, before Chunk 5)
- Decide + prototype: Gmail draft-in-mailbox via (a) client-side GIS
  `gmail.compose` token forwarded to the Function, (b) a shared service mailbox +
  stored refresh token, or (c) drop the draft → just link the file. Confirm the
  Drive target is a **Shared Drive** and add the runtime SA as Content-manager
  (`supportsAllDrives`); else Drive writes fail. Resolve the "which mailbox" open
  item here.
- Done: a proof that the chosen path can create a draft in the intended mailbox
  and write a file to the (separate, dev) Drive folder as the SA/user.

### Chunk 1 — BQ workflow-state schema (real tables) + snapshot gate
- Files: `review-app/sql/00-review-state-schema.sql`; `deploy-review-schema.sh`
  (dataset-tokenized; write-path guard refuses `clinvar_curator`).
- **Pre-snapshot gate (hard):** assert
  `SELECT annotation_id FROM legacy cvc_clinvar_submissions EXCEPT DISTINCT
  SELECT annotation_id FROM v4 base_mv = 0` (same for reviews). Block if not — a
  submitted id absent from v4 base_mv is INNER-JOIN-dropped from all impact.
- Tests first: `schema.test.js` — DDL targets only the v4 dataset; **column/type
  parity** of the converted tables == legacy staging schema.
- Build + verify: convert views→tables in `clinvar_curator_v4_dev`, snapshot
  legacy staging in once; re-run the impact SP and **diff #1 `cvc_submitted_variants`
  / #2 `cvc_flagging_candidate_outcomes` / #3 `cvc_remove_flagged_outcomes`**
  legacy-vs-shadow = 0 (NOT #4/#5 — those read `clinvar_ingest` only and can't
  detect this regression).
- Done: SP green; #1/#2/#3 parity holds post-conversion.

### Chunk 2 — Backend read: review queue
- Files: `review-app/functions/queue.js` + `queue.sql.js`.
- Tests first: builds `cvc_annotations(v4,"unreviewed")` ⋈ `cvc_review_state`;
  dataset-tokenized; no `clinvar_curator` write.
- Done: `GET /queue` returns unreviewed v4 annotations + in-progress state.

### Chunk 2.5 — Auto-review rules (port `appendNewToReviews`)
- Files: `review-app/functions/autoReview.js` (pure).
- Tests first: `autoReview.test.js` — port every rule from `Code.js:53–150`:
  `Archive` if `is_deleted_scv`; block if a newer annotation supersedes;
  "re-curation needed" on outdated+classification-diff; auto-`OK` for `no change`;
  flag `flagging candidate` on already-flagged SCV / `remove flagged submission`
  on non-flagged; invalid-action error; auto-`OK` for callers in
  `cvc_review_config.reviewers`. Inputs all exist on `cvc_annotations(v4)`.
- Done: `autoReview(row, reviewers)` returns `{status, note}` matching legacy on a
  fixture table; unit tests green.

### Chunk 3 — Generate(batch) → NDJSON + file-level parity (reads Chunk-1 snapshot)
- Files: `generate.js` + `generate.sql.js` (validated 13-field projection,
  dataset-tokenized), `sql/parity-generate.sql`, `ndjson.js`.
- Tests first: `ndjson.test.js` — newline-delimited `TO_JSON_STRING`; notes
  newline-strip; **booleans/null emitted as JSON `true`/`false`/`null`** (never
  "Yes"/"No"); `COUNT(*) == COUNT(DISTINCT annotation_id)` on the projection.
  `generate.sql.test.js` — columns == `SUBMISSION_FILE_SPEC.md`; scope handling.
- Build: `POST /generate {batchId}` over v4 → NDJSON to the **separate dev Drive
  folder**; read-only w.r.t. state.
- Verify: file-level parity vs a legacy batch (uses the Chunk-1 snapshot
  assignments) = 0 diff.
- Done: byte-identical file to a legacy batch; tests green.

### Chunk 4 — Backend write: review status + batch assignment
- Files: `review.js`, `state.sql.js`.
- Tests first: status ∈ {OK,Fixed,Archive,Question}; **assignment gate =
  `status==='OK'` AND action ∈ {flagging candidate, remove flagged submission}
  AND not already assigned**; unassign only from the *next* batch; MERGE
  idempotency on `annotation_id`; both `date_added` + `date_last_updated`;
  allowlist + write-path guard.
- Done: round-trips through the dev shadow; tests green.

### Chunk 5 — Finalize(batch) — idempotent + ordered + compensation (NOT atomic)
- Files: `finalize.js`, `email.js` (from Chunk 0.5), `sql/finalize.sql`.
- Corrected semantics (BQ has no cross-service txn; the SP is DDL + 2–5 min):
  1. generate (Chunk 3) → write file to dev Drive folder.
  2. draft email (Chunk 0.5 path; test recipients pre-cutover).
  3. **promote** `cvc_review_state` → `cvc_clinvar_reviews` (status ∈
     {OK,Fixed,Archive}) + `cvc_clinvar_submissions` (status=OK + actionable
     action) via **MERGE / INSERT…WHERE NOT EXISTS keyed on
     (annotation_id[,batch_id])** — retry-safe — and append the `cvc_clinvar_batches`
     row with the **full 6-column derivation** (prev-batch lookback;
     `clinvar_ingest.release_on`; `determineMonthBasedOnRange` → `submission`
     STRUCT). Wrap the promote + `next_batch_id` bump in one
     `BEGIN TRANSACTION…COMMIT`.
  4. kick `CALL refresh_cvc_impact_analysis()` (v4 SP) as an **async BQ job**
     (return job id for the UI to poll) — it is a full idempotent rebuild, safe
     to re-run; do NOT block finalize on it.
- Preserve **warn-and-proceed** on unreviewed/Question rows (surface count, let
  caller confirm) — not a hard refuse.
- Grant the SA `clinvar_ingest` read (for the batch-row derivation).
- Tests first: `finalize.test.js` — ordering; promotion status sets; batch-row
  6-column derivation; idempotent retry after an injected SP/bump failure does
  NOT double-insert; warn-and-proceed path.
- Done: end-to-end finalize on the dev shadow → file + draft + promoted records
  (retry-safe) + async SP refresh + bumped id; tests green.

### Chunk 6 — Frontend (manual-verified)
- Files: `review-app/public/` (index.html, app.js, styles). Google sign-in;
  review queue (auto-review status + note prefilled, per-row + bulk edit); batch
  panel (assign/unassign, current batch, counts); Generate + Finalize (Finalize
  shows the SP-refresh job status via poll); DEV/PROD banner.
- Done: a curator reviews, assigns, generates, finalizes against the dev shadow.

### Chunk 7 — E2E parity + cutover runbook
- Verify: reproduce a full legacy batch off v4 end-to-end; NDJSON diff = 0. For a
  *live-capture* loop, run the adapter refresh first (base_mv is a plain VIEW over
  the stale full-snapshot native_v4 until then) — or note live-capture E2E is
  gated on decision E.
- Cutover runbook (cutover-time, high-risk — rehearse fully in `clingen-cvc-dev`
  first via the cvc-provision skill): relocate capture to **US** by standing up a
  **new US export dataset alongside** the `us-central1` one (keep the old flowing
  until the new is verified — avoid in-place reinstall), re-grant `run.invoker` +
  runtime-SA roles, verify (write a test annotation → confirm it lands in US BQ),
  with rollback; do prod `clingen-cvc` + dev; retire the sheet + Apps Script;
  isolate the Gmail OAuth client; point the app at prod `clinvar_curator_v4`.
  Note the `base_mv` MV-vs-plain-VIEW tradeoff post-E.

## Safety invariants (every chunk)
- Dataset-scoped IAM is the primary control (write only on v4/review; read-only on
  legacy+ingest); the write-path guard is the second layer.
- Build/test on `clinvar_curator_v4_dev`; promote to `clinvar_curator_v4` only when
  validated. Neither is the live pipeline.
- Separate Drive folder + test-only Gmail recipients until cutover; scoped
  `firebase deploy --only hosting,functions`.
- The live sheet, Apps Script project, and production Review & Submit sheet are
  never touched.

## Follow-ons (explicit, so they aren't lost)
- **Reflag** has no v4 path (out of scope per design): post-cutover capture is the
  extension→Firestore, so a redesigned reflag must write there (or v4), and the
  `08-autoreflag-candidates` list needs a home. Track separately.
