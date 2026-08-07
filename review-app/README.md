# review-app — Review & Submit (v4-native web app)

Web-app replacement for the Google Sheet + Apps Script "Review & Submit"
pipeline, sourced from the v4 annotation feed. Design + plan:

- `docs/superpowers/specs/2026-08-06-s8-review-submit-webapp-design.md`
- `docs/superpowers/plans/2026-08-06-s8-review-submit-webapp-plan.md`

> **The legacy `scvc/` sheet + Apps Script pipeline stays live and untouched.**
> This app is built in parallel against the v4 **shadow** and activated only at
> cutover.

## Layout

- `public/` — Firebase Hosting static frontend (vanilla JS, no build). Chunk 0:
  Google sign-in + `/api/whoami` smoke; the review/batch/generate/finalize UI
  lands in Chunk 6.
- `functions/` — Cloud Functions backend.
  - `auth.js` — **pure, unit-tested** auth: `assertAllowlisted`, `makeAuthGuard`,
    `authErrorStatus`, `makeFirestoreAllowlistLookup` (reuses Google sign-in +
    the `allowed_curators` allowlist; server re-checks every request).
  - `index.js` — HTTP wiring (`/api/**`); Chunk 0 exposes `/whoami`.
  - `test/` — Vitest.
- `scripts/grant-iam.sh` — dataset-scoped BigQuery IAM (the primary non-impact
  control).
- `firebase.json` / `.firebaserc` — Hosting + Functions (dev default
  `clingen-cvc-dev`). **No `extensions` block** (a reinstall would drop the
  firestore-bigquery-export runtime-SA IAM and 403 live capture).

## Develop / test

```bash
cd review-app/functions && npm install && npm test   # Vitest (pure logic)
```

## Deploy (dev)

```bash
cd review-app
firebase use dev
firebase deploy --only hosting,functions     # NEVER a bare `firebase deploy`
# then, once the runtime SA exists, scope its BigQuery IAM:
SA=<functions-runtime-SA> WRITE_DATASETS="clinvar_curator_v4_dev" ./scripts/grant-iam.sh
```

Manual smoke (Chunk 0 done-criteria): sign in as an allow-listed curator →
`/api/whoami` returns `{ok:true,email}`; a non-allow-listed Google account gets
**403**; a missing/invalid token gets **401**.

## Non-impact invariants

- **IAM is the primary control:** the runtime SA has `dataEditor` only on the v4
  workflow dataset(s), `dataViewer` only on `clinvar_curator` + `clinvar_ingest`,
  `jobUser` on the project. A code bug cannot write legacy.
- **Write-path guard** (second layer, later chunks): reject `clinvar_curator` as
  a DML/DDL target; allow it as a read source (the parity harness reads it).
- Build/test against `clinvar_curator_v4_dev`; promote to `clinvar_curator_v4`
  only when validated.
- Deploy scoped to `hosting,functions`; the live sheet/Apps Script/production
  Review & Submit sheet are never touched.

## Status

- **Chunk 0 (this):** scaffolding + auth reuse + IAM script. Pure auth logic
  unit-tested (10 tests); Hosting/Functions wiring + IAM grant are
  deploy-time/manually verified.
- Next: Chunk 0.5 (Gmail/Drive auth resolution), Chunk 1 (BQ workflow-state
  schema), … see the plan.
