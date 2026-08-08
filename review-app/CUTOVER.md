# Review & Submit — cutover runbook (dev-validated → prod)

Activating the v4-native web app as the system of record. **Gated on the (still
parked) go-live decision.** Until then the legacy `scvc/` sheet + Apps Script
pipeline stays live and untouched; this app runs against the dev shadow only.

Design: `docs/superpowers/specs/2026-08-06-s8-review-submit-webapp-design.md`.
Plan: `docs/superpowers/plans/2026-08-06-s8-review-submit-webapp-plan.md`.

## What is already proven (dev shadow, `clinvar_curator_v4_dev`)

- Views→tables conversion transparent (impact SP #1/#2/#3 unchanged).
- `generate` byte-identical to legacy (batches 133/135, 0 diff).
- Review write + assignment gate; finalize promote + batch-row derivation +
  retry-safe bump (e2e on a throwaway batch, then restored — see
  `scripts/e2e-finalize-smoke.sh`).

## Prerequisite: adapter freshness (or eliminate it)

The shadow reads `cvc_annotations_native_v4`, refreshed by the cross-region
adapter (`bigquery/curator/adapter/refresh-native-v4.sh`). A just-captured
annotation is invisible to the queue until the adapter runs. Two options:

- **Interim:** run the adapter on a schedule (accept lag).
- **Target (design decision E):** relocate the Firestore→BQ capture dataset to
  **US** so the curator reads it directly and the adapter disappears. **Rehearse
  in dev first.** Per `CLAUDE.md`: reconfiguring the extension reinstalls it and
  **drops the runtime SA's IAM** (`run.invoker` etc.), silently 403'ing capture.
  Do it **safely**: stand up a **new US export dataset alongside** the existing
  `us-central1` one (keep the old flowing until verified), re-grant the runtime
  SA roles, **verify** (write a test annotation → confirm it lands in the US BQ
  table), with a rollback. Apply to dev (`clingen-cvc-dev`) then prod
  (`clingen-cvc`). Note: `base_mv` becomes a plain VIEW over the US capture (or a
  MATERIALIZED view — decide based on refresh cost).

## Prod cutover steps

1. **Build the prod shadow schema.** `DATASET=clinvar_curator_v4 ./review-app/scripts/deploy-review-schema.sh`
   (converts the prod shadow's staging views→tables + seeds `cvc_review_config`;
   run the join-integrity gate first, as in Chunk 1).
2. **Deploy the app to prod.** `cd review-app && firebase use prod &&
   firebase deploy --only hosting,functions` (NEVER a bare `firebase deploy`).
   Set env: `REVIEW_DATASET=clinvar_curator_v4`, `REVIEW_DRIVE_FOLDER=<prod
   submission folder>`, `SUBMISSION_RECIPIENTS`/`SUBMISSION_CC` (real ClinVar
   contacts — only at true go-live; keep test addresses until then).
3. **Grant dataset-scoped access.** `SA=<prod functions runtime SA>
   WRITE_DATASET="clinvar_curator_v4" CURATOR_PROJECT=clingen-dev
   ./review-app/scripts/grant-iam.sh` (grants via the **dataset ACL** —
   dataset-level IAM setIamPolicy requires org allowlisting not enabled here).
   The SA gets **WRITER on `clinvar_curator_v4`**, **READER on `clinvar_ingest`**,
   `jobUser` on the project, and **no access to legacy `clinvar_curator`**.
4. **Drive.** Add the prod functions runtime SA as a **member of the submission
   Shared Drive** (Content-manager); confirm `REVIEW_DRIVE_FOLDER`.
5. **Curator allowlist / reviewers.** Ensure `allowed_curators` covers all
   curators (it does — 15/15) and seed `cvc_review_config.reviewers` (the auto-OK
   list) + recipients.
6. **Capture switch.** Curators capture via the v4 **extension** (ACTIVE_ENV=prod),
   not the sheet. Watch adoption via
   `bigquery/curator/audit/parallel-run-reconciliation.sh` (capture_only grows;
   sheet_only_gap stays 0).
7. **Retire the sheet pipeline.** Freeze `scvc/` sheet appends + the Apps Script
   Review & Submit; the web app is now the system of record.
8. **Smoke prod.** `/whoami` (allow-listed ok / others 403), `/queue` returns
   rows, generate a batch and diff its file vs a legacy batch, finalize on a
   real batch.

## Rollback

The web app is additive — it only writes `clinvar_curator_v4[*]` (never legacy
`clinvar_curator`). If cutover is aborted: keep the sheet pipeline live (it never
stopped until step 7), point curators back to the sheet, and the v4 shadow simply
continues as a parallel copy. Nothing in the live `clinvar_curator` lineage was
modified at any point.

## Out of scope (follow-on)

- **Reflag** (`Reflag.js`) — post-cutover, reflag must write the extension's
  Firestore capture (or v4) instead of the sheet; the `08-autoreflag-candidates`
  list needs a home. Owner-driven redesign.
