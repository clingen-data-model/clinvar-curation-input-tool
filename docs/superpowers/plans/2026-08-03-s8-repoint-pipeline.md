# S8 — Repoint the Review&Submit batch pipeline to the new BQ table (SCOPING STUB)

> **Status: NOT STARTED — scoping only.** Pulled out of the main roadmap because
> it needs more work than originally understood. Gated on prod (`clingen-cvc`)
> becoming the official system of record; until then the legacy `scvc/`
> Google-Sheet pipeline stays live in parallel. Do NOT execute this yet — it
> needs a full brainstorm + writing-plans pass first.

**Goal (one sentence):** Make `Review&Submit/Generate.js` (and `Reflag.js`) read
curation annotations from the new Firestore→BigQuery table
(`clingen-cvc.clinvar_cvc_ext.annotations`) instead of the Google Sheet, so the
ClinVar submission file is generated from the v4 capture pipeline.

## Why it's bigger than a one-line "repoint"
The original roadmap framed this as swapping a table reference. Real scope, to be
worked out during a dedicated brainstorm:

- **Schema / semantics gap.** The Sheet-backed source and the v4 BQ view differ in
  columns, casing, and derived fields. Need a field-by-field parity map from what
  `Generate.js`/`Reflag.js` consume today → the v4 `annotations` view (which now
  includes `name`, `created_at`, `created_at_millis`, `review_status`, etc.).
- **Dedup / latest-wins.** The v4 table is append-only create-only with content-hash
  ids; `Generate.js` likely expects one current row per SCV. Need the reconciling
  logic (latest annotation per SCV/curator, and how "no change" vs "flag" vs
  "remove" resolve) defined explicitly.
- **Historical + new union.** During transition, some annotations live only in the
  Sheet (new curations while `scvc/` stays live) and some only in BQ. A bridge/union
  view may be needed so Generate produces a complete file mid-migration.
- **Reflag path.** `Reflag.js` currently appends to the Sheet; repointing capture
  away from the Sheet means Reflag's writes must also move (or be reconciled) — an
  explicit decision, not an afterthought.
- **Google Apps Script vs BQ auth.** `Review&Submit/*.js` are Apps Script; how they
  query BigQuery (service account / BigQuery API from Apps Script, or an exported
  table) needs to be designed.
- **Cutover + rollback.** How to run old and new in parallel, compare outputs
  (query-parity on a sample batch), and cut over safely.

## Prerequisites (before this plan can be written/executed)
1. Prod is the declared system of record (S4/S5 prod load finalized; possibly a
   fresh re-load from the historical dataset at true go-live).
2. `scvc/` Google-Sheet capture is being retired (or an explicit dual-run window is
   defined).
3. Owner of the `clinvar_curator` dataset / Apps Script pipeline is looped in.

## Next action
Run superpowers:brainstorming → writing-plans for S8 once the prerequisites hold,
producing a full bite-sized TDD plan to replace this stub.
