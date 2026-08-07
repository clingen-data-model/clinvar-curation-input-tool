# S8 — Review & Submit as a v4-native web app (design / brainstorm)

> **Status: DESIGN CONVERGED — ready for writing-plans.** All brainstorm
> decisions (transition model, web app, A–F) are resolved below. Supersedes the
> `2026-08-03-s8-repoint-pipeline.md` scoping stub. Legacy `scvc/` sheet +
> Apps Script pipeline stays **live and untouched** throughout; this target is
> built in parallel and activated only at cutover (go-live is currently parked).

## Goal

Replace the Google Sheet + Apps Script "Review & Submit" pipeline with a
**web app on the existing Firebase project** that reviews, batches, generates,
and finalizes ClinVar submissions directly from the **v4 annotation feed**
(extension → Firestore → BigQuery), eliminating the sheet-as-datastore coupling.

## Decisions locked in brainstorming (2026-08-06)

1. **Transition model = post-cutover v4-only.** We design the clean end-state
   where capture is the extension → Firestore → v4, and the sheet is retired as
   a source. Built now, validated against v4, **activated at cutover**. No
   sheet+v4 bridging/union complexity in the design.
2. **UI = a web app on the existing Firebase project.** Reuses the v4 stack
   wholesale: same Google sign-in, same `allowed_curators` allowlist + Firestore
   rules, same Firestore that already holds annotations. The Sheet + Apps Script
   is retired at cutover.
3. **Region:** curator analytics stays **US** (it joins `clinvar_ingest`, US).
   How the `us-central1` capture reaches US (keep adapter vs relocate capture to
   US) is an open question below — a knob, not a fork.
4. **Reflag is out of scope** for this design (owner may redesign separately).

## Why redesign (what's wrong with the current flow)

The legacy path is triple-coupled to the Sheet, which is simultaneously the
capture source, the review UI, and the workflow datastore:

```text
extension(scvc) → Google Sheet (SCVs) → external BQ table → cvc_annotations TVF
                                                              ↓ (Refresh)
                        Review&Submit Sheet ← connected-sheet refresh
                          review status + "+ batch" live in sheet cells
                          (backed by cvc_clinvar_*_sheet EXTERNAL tables)
                                                              ↓ (Generate)
   NDJSON ← cvc_annotations("unreviewed") JOIN *_sheet WHERE batch_id=N
                                                              ↓ (Finalize)
   insert *_sheet → standard tables "where not exists"; CALL refresh SP; clear sheet
```

Fragility this creates: external-table-over-live-sheet-range coupling; a
"insert-where-not-exists" dedup dance on finalize; connected-sheet refresh lag;
and a **6-minute Apps Script execution ceiling** that `finalize` already warns it
can hit. Batch membership and review status are sheet cells, not queryable
records.

**Validated repoint premise (2026-08-06):** running `generate()`'s exact 13-field
projection against `cvc_annotations` in both lineages over the `SUBMITTED` scope
returned **8,950 vs 8,950 annotation_ids, 0 field diffs, 0 either-only** — for
every annotation that exists in v4, the submission row is byte-identical. The
only reason a v4-`Generate` produces nothing *today* is `UNREVIEWED = 0` in v4:
live capture still flows to the sheet, not the extension. That is the cutover
dependency, not a data defect.

## Target architecture (post-cutover)

Target (post-E, capture relocated to US — no adapter/native landing table):

```text
extension(v4) → Firestore(annotations) → BQ capture(clinvar_cvc_ext, US) → cvc_annotations(v4)  [US]
                     │                                                              │
                     └──────────────── Review & Submit WEB APP (Firebase) ─────────┘
                        • auth: Google sign-in + allowed_curators (reuse rules)
                        • Review queue: unreviewed v4 annotations (from cvc_annotations / Firestore)
                        • Actions: set review status (OK/Fixed/Archive/Question); assign to batch
                        • Generate: server queries cvc_annotations(v4) for batch → NDJSON
                        • Finalize: persist submission/review/batch records; CALL refresh_cvc_impact_analysis; bump batch id
```

Everything the Sheet did becomes a first-class datastore record + a server
action. No external sheet tables, no dedup dance, no 6-minute ceiling.

## Component design

- **Capture** — unchanged (extension → Firestore → BQ, already built/validated).
- **Review + batch state** — moves off the Sheet into a datastore (Firestore vs
  BigQuery: **open question A**). Fields per annotation: `review_status`,
  `reviewer`, `review_notes`, `reviewed_at`, `batch_id`, `assigned_at`.
- **Web app frontend** — lists the review queue, supports per-row + bulk review,
  batch assignment, and a Generate/Finalize action. Hosting: **open question B**.
- **Generate/Finalize backend** — a server endpoint (Cloud Function/Run) that
  runs the `cvc_annotations(v4)` submission query, writes the NDJSON (Drive vs
  GCS+download: **open question C**), drafts/sends the submission email (**open
  question D**), CALLs `refresh_cvc_impact_analysis()`, and advances the batch id.
- **Submission-file contract** — unchanged (the 13-field NDJSON per
  `SUBMISSION_FILE_SPEC.md`); the generate query is the validated projection.

## Resolved design decisions (2026-08-06)

- **A. Workflow-state store = BigQuery.** Review status + batch assignment
  persist as BQ records the impact SP already consumes
  (`cvc_clinvar_reviews`/`submissions`/`batches` shapes) — **no Firestore→BQ
  reconciliation**. The web-app backend owns the writes. (Firestore stays
  capture-only; revisit only if live-collaborative editing is wanted later.)
- **B. Hosting/runtime = Firebase Hosting + Cloud Functions** (same project,
  least new infra).
- **C. Submission-file output = the shared Google Drive folder** (Drive API),
  preserving the reviewers' existing "grab the file from the folder" habit.
- **D. Submission email = Gmail API draft** (add a compose scope), so the
  human-in-the-loop "review the draft, then send" step is preserved.
- **E. Region = relocate the capture dataset to US, deleting the adapter.**
  The cross-region snapshot adapter + `cvc_annotations_native_v4` landing table
  exist **only** because capture is `us-central1` and curator is US. Recreating
  the Firestore→BQ capture in **US** lets the curator lineage read it directly
  (base_mv straight over the US capture), removing the adapter, its refresh lag,
  and a whole moving part. **Caveats (gated at cutover, tracked here):** the
  Firestore→BQ extension must be reconfigured for the US region (per
  `CLAUDE.md`: the extension's region param must match, and a reinstall drops the
  runtime SA's IAM — re-grant `run.invoker` etc.); applies to **both** prod
  (`clingen-cvc`) and dev (`clingen-cvc-dev`) captures; the Firestore DB itself
  (`nam5`) is unaffected — only the BQ export dataset region changes. Until this
  lands, the existing adapter-fed shadow remains the validation surface.
- **F. Batch-id + finalize = a small BQ config table + an atomic finalize.**
  `next_batch_id` / `last_finalized_date` live in a config table; finalize is an
  all-or-nothing backend transaction: persist review/submission/batch records →
  `CALL refresh_cvc_impact_analysis()` → bump batch id.

## Safety / non-impact guarantee

- Legacy `scvc/` sheet + the live Apps Script project + the production Review &
  Submit sheet are **never modified**. This target reads the v4 shadow / v4
  capture only; all new state lives in **new** datastore objects (never the live
  `clinvar_curator.*` staging the sheet writes).
- The web app is a **new** app in the Firebase project; it does not touch the
  extension's capture path.
- Activation is gated on the (currently parked) cutover decision.

## Rough milestones (to be expanded in writing-plans)

1. Resolve open questions A–F.
2. Backend: `generate(batch)` endpoint over `cvc_annotations(v4)` → NDJSON, with
   a legacy-vs-v4 parity harness per batch (extends the 2026-08-06 validation).
3. Workflow-state store + write path (review status, batch assignment).
4. Web app frontend (auth reuse, review queue, batch/generate/finalize).
5. Finalize (persist records, SP refresh, batch bump) + email + file output.
6. End-to-end parity vs a legacy-generated batch; cutover runbook.
