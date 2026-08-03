# CvC Curation Operations Platform — Discovery & Phasing

> **Type:** discovery map + recommended phasing (NOT an execution plan). Produced
> 2026-08-03. Decision taken with the user: **target a Firebase web app, phased**,
> to replace the Review&Submit Google-Sheet + Apps Script process — but bridge the
> sheet short-term and invest in a UI-agnostic data layer first. The actual
> build should be brainstormed/planned in a **fresh, downstream-focused context**;
> the capture work (this repo's other plans) is treated as done.

## 0. TL;DR recommendation

- The whole downstream (review → submit → reflag → impact reporting) is far larger
  than "repoint one table": **88 BigQuery objects** in `clingen-dev:clinvar_curator`
  + a `clinvar_ingest` dataset dependency + ~1,300 lines of Apps Script + a stored
  procedure that rebuilds "11 materialized tables."
- BUT it funnels through a **single choke point**: the canonical annotation access
  (`cvc_annotations_base_mv` → `cvc_annotations_view`, and the TVF
  `cvc_annotations("unreviewed")`) is the only thing reading the capture source.
  Repointing the platform to the new v4 capture is therefore **contained**, not 88
  rewrites.
- **Split the problem into a durable data layer (BQ, UI-agnostic) and a UI/ops layer
  (Sheet today → web app).** Invest in the data layer first (throwaway-proof), keep
  the Sheet alive via a bridge (the real "S8"), then build the web app incrementally.
- The in-flight **"submitter overwrote our flag"** feature is unfinished AND wired to
  the *legacy* capture sheet — do not finish it in Apps Script. Its detection logic
  already lives in BQ (version-bump family of tables); rebuild the *action* (create a
  fresh annotation) as a **v4 Firestore write** (reuse `firestore-write.js` /
  `annotationDocId`) and surface it as the web app's first slice.

---

## 1. Current-state map

### 1a. Capture (DONE — v4)
Chrome extension → Firestore (`clinvar_cvc_ext_annotations`) → BigQuery
(`clinvar_cvc_ext.annotations` flattened view: `variation_id, vcv, name, scv,
submitter, submitter_id, interp, review_status, action, reason, notes, user_email,
created_at, created_at_millis`). Prod loaded (30,784, staging). Legacy `scvc/`
Google-Sheet capture still runs in parallel.

### 1b. Downstream analytics/ops in BigQuery (`clingen-dev:clinvar_curator`, 88 objects)
- **6 EXTERNAL (Sheet-backed) seams:** `clinvar_annotations` (legacy capture),
  `cvc_clinvar_batches_sheet`, `cvc_clinvar_reviews_sheet`,
  `cvc_clinvar_submissions_sheet`, `cvc_clinvar_clinsig_outlier_tracker`,
  `cvc_clinvar_outlier_tracking`.
- **Choke point (the repoint surface):** `cvc_annotations_base_mv` (MATERIALIZED_VIEW)
  is the ONLY object reading the capture source (`clinvar_annotations_native`), joined
  to release + clinsig-map reference data. `cvc_annotations_view` adds an `is_latest`
  flag. The Apps Script reads annotations via the **table-valued function**
  `cvc_annotations(<status>)` (e.g. `"unreviewed"`) and a Connected-Sheet extract on
  top of the same lineage. Only ~6 objects reference the canonical view/MV directly;
  everything else cascades from those.
  - Column contract the MV expects (→ the adapter must supply these names):
    `annotation_date, vcv_id, scv_id, variation_id, submitter_id, action,
    curator_email, reason, notes, review_status, ignore`. All map 1:1 to the v4 view
    (`created_at→annotation_date, vcv→vcv_id, scv→scv_id, user_email→curator_email`,
    `ignore→FALSE`). **Note `action` is stored lowercased downstream** (`LOWER(action)`);
    v4 stores `Flagging Candidate` capitalized — the adapter/MV already lowercases, so
    keep that.
- **Functional groups (by name):**
  - *Canonical annotations:* `clinvar_annotations(_native)`, `cvc_annotations_base_mv`,
    `cvc_annotations_view`, TVF `cvc_annotations()`.
  - *Submission/batch:* `cvc_clinvar_batches(_sheet)`, `cvc_clinvar_submissions(_sheet)`,
    `cvc_clinvar_reviews(_sheet)`, `cvc_submitted_variants`,
    `cvc_submitted_annotations_view` (has `'updated/deleted prior to submission'`
    logic), `cvc_submitted_outcomes_view`, `cvc_batches_enriched`,
    `cvc_batch_scv_max_annotation_view`, `cvc_submission_summary`, `cvc_rejected_scvs`.
  - *Version-bump / overwrite detection (the in-flight feature's data domain):*
    `cvc_version_bumps*`, `cvc_flagging_version_bump_intersection`,
    `cvc_flagging_version_bump_*`, `cvc_full_record_version_bumps*`,
    `cvc_full_record_bumps_by_*`, `cvc_duplicate_bumps_*`.
  - *Reflag / resubmission / autoreflag:* `cvc_autoreflag_candidates`,
    `cvc_autoreflag_export/summary`, `cvc_resubmission_candidates`,
    `cvc_resubmission_export/summary/by_batch/by_submitter`,
    `cvc_resubmission_review_reclassified`, `sheets_autoreflag_*`.
  - *Impact / effectiveness reporting:* `cvc_impact_summary`, `cvc_batch_effectiveness`,
    `cvc_flagging_candidate_outcomes`, `cvc_flagging_outcomes_by_batch`,
    `cvc_reason_effectiveness`, `cvc_remove_flagged_outcomes(_by_batch)`,
    `cvc_resolution_attribution`, `cvc_attribution_by_month`,
    `cvc_clinsig_outlier_vars_by_month`, `cvc_variant_conflict_history`,
    `cvc_targeted_variants`.
  - *Presentation for Sheet dashboards (~20+ `sheets_*` views):* pure UI-coupled;
    clearest retirement candidates once the web app renders its own charts.
  - *Config/suppression:* `cvc_flagging_report_suppressions`,
    `cvc_bulk_downgrade_exclusions`.
- **Impact-analysis engine:** stored procedure `clinvar_curator.refresh_cvc_impact_analysis()`
  rebuilds "11 materialized tables in dependency order" (incl. the reflag-candidate
  list). **Its body + the exact 11 tables were NOT mapped in this pass — a required
  Phase-0 discovery item.**
- **Cross-dataset dependency:** `clinvar_ingest` dataset (functions
  `determineMonthBasedOnRange`, `release_on`; the release table feeding
  `annotation_release_date`). The platform spans `clinvar_curator` + `clinvar_ingest`.

### 1c. Ops process (Apps Script, bound to sheet `1ZPADw8...`, project `clingen-dev`)
"CVC Tools" menu + sheet-button entry points. 6-stage batch lifecycle:
1. **Refresh** (`Code.js:refresh`) — refresh the `cvc_annotations_as_of_extract`
   Connected-Sheet, then `appendNewToReviews()` runs a rules cascade to auto-assign a
   review status/note per new annotation.
2. **Review** — human sets status (`OK/Fixed/Archive/Question`) on `Review & Submit`.
3. **Reflag** (in-flight; `Reflag.js`) — reviewers select version-bumped candidates on
   `Reflag & Review`; `reflagSelected()` creates fresh "Flagging Candidate" annotations.
4. **Assign** (`ReviewSubmit.js:assignToNextBatch`) — OK + actionable rows → `Submissions`
   tagged with `next_batch_id`.
5. **Generate** (`Generate.js:generateOnly`) — BQ query (`cvc_annotations("unreviewed")`
   JOIN `cvc_clinvar_submissions_sheet`) → NDJSON file to Drive.
6. **Finalize** (`Generate.js:finalizeBatch`) — regenerate + Gmail draft, promote
   `_sheet` external staging → permanent tables (3 INSERTs), clear sheets, bump
   `next_batch_id`, refresh, and `CALL refresh_cvc_impact_analysis()`.
Submission file: **NDJSON, 13 fields** (see `SUBMISSION_FILE_SPEC.md`), one object/line,
`no change` excluded, latest annotation per SCV only; ClinVar wants flagging vs.
remove-flagged in **separate files** (spec requirement, NOT enforced in code).

### 1d. Sheet ↔ BQ seams (what a web app takes ownership of)
`cvc_annotations_as_of_extract`, `Review & Submit`, `Submissions`, `Batches` are
BigQuery Connected-Sheet / external tables — **the sheet ranges ARE the data**.
Finalize "promotes" `_sheet` externals into permanent tables. `Reflag.js` writes new
annotations straight into a legacy `SCVs` sheet tab (config placeholder unset).

---

## 2. Key findings & risks

1. **Single repoint choke point** (`cvc_annotations_base_mv` / TVF `cvc_annotations`)
   makes migrating the whole downstream to v4 capture tractable — but BQ **MVs can't be
   defined over a view or external table**, so the repoint is a real design task
   (canonical *table* refreshed on a schedule, or convert MV→view), not a one-liner.
   This is why S8 was correctly pulled out.
2. **Sheet-range-as-database** anti-pattern throughout (sort = data integrity,
   linear-scan "deletes", per-sheet clear branching) — fragile; a web app + Firestore/BQ
   removes this class of bug entirely.
3. **Apps Script 6-min limit** already bites `finalizeBatch()` (impact rebuild polls up
   to 10 min) — there is a documented manual-recovery step. A backend job removes this.
4. **Legacy-source dependency (S8):** the whole pipeline reads BQ derived from the
   *legacy Sheets* capture, not v4 `clinvar_cvc_ext.annotations`. Repoint is outstanding.
5. **Reflag is unfinished + mis-targeted:** `ANNO_SPREADSHEET_ID` is a placeholder and it
   writes to the legacy scvc sheet in the old 13-col format. In v4, reflag = a create-only
   Firestore write (reuse `firestore-write.js`/`annotationDocId`).
6. **Action-casing coupling** (`"flagging candidate"` lowercase downstream vs.
   `"Flagging Candidate"` in v4/Reflag) — a real silent-break risk; normalize centrally.
7. **Irreversible finalize**, magic Drive/spreadsheet IDs, no central config, manual
   email-review gate — all things a web app formalizes.
8. **Impact-analysis SP + 11 tables + reflag-candidate view — SOURCES LOCATED**
   (2026-08-03): the DDL/procs/TVFs live as SQL files in
   `clinvar-ingest-bq-tools/scripts/clinvar-curation/` (hyphenated), incl.
   `cvc-impact-analysis/09-refresh-cvc-impact-analysis.sql` (the SP),
   `cvc-impact-analysis/06-version-bump-flagging-intersection.sql` (the
   flag-overwrite / reflag-candidate detection), `00-cvc-batch-enriched-view.sql`,
   `02-cvc-conflict-attribution.sql`, and the annotation TVFs
   `01/03/04-cvc-*-func.sql`. So Phase 0.3 is answerable from source — NO BQ
   reverse-engineering and NO `clinvar_ingest` rework needed for now.
   (`appscript-refresh-impact.js` currently exists in BOTH repos — drift caused by
   the split; consolidation removes it.)

---

## 3. Recommended target architecture (Firebase web app)

- **Hosting:** Firebase Hosting (static SPA) — same project family as capture.
- **Auth/RBAC:** reuse Google sign-in + the `allowed_curators` allowlist, extended with
  roles (curator / reviewer / admin) — enforced in Firestore rules + backend.
- **App/transactional state:** Firestore (batches, review status, assignments,
  suppressions) — replaces the `_sheet` external staging + sheet-as-DB.
- **Analytics/read:** BigQuery (the existing `cvc_*` view/table web, repointed to v4).
- **Backend jobs:** Cloud Functions / Cloud Run for long-running work (generate file,
  finalize batch, `CALL refresh_cvc_impact_analysis()`), removing the 6-min limit.
- **Reflag = v4 write:** selecting version-bumped candidates creates annotations via the
  same create-only path the extension uses.
- **Submission:** generate NDJSON server-side (split flagging vs remove-flagged per the
  spec), let admin download/queue; keep Gmail/Drive or move to a submissions store.

---

## 4. Phased roadmap (target-agnostic Phase 0/1; web app in Phase 2)

- **Phase 0 — canonical data layer (do first; throwaway-proof).**
  1. Build a `clinvar_curator`-shaped **adapter** over `clinvar_cvc_ext.annotations`
     supplying the MV's column contract (§1b).
  2. Solve the MV-over-view constraint (scheduled canonical table, or MV→regular view).
  3. **Map the impact SP + its 11 tables + the reflag-candidate view** (the gap this
     discovery left open).
  4. Verify the full 88-object downstream still computes off v4 (query-parity on a batch).
- **Phase 1 — bridge / keep ops alive (the real S8).** Repoint the choke point at the
  Phase-0 adapter; the existing Sheet/Apps Script keeps running with minimal rework.
  Stopgap, explicitly not an Apps Script investment.
- **Phase 2 — web app, incrementally (parallel-run, then retire the sheet):**
  1. **Reflag/overwrite preview** first (self-contained, high value, new) — v4 writes.
  2. Review workflow (replace `Review & Submit` + `appendNewToReviews` rules).
  3. Batch assign + generate + finalize + submission file (backend jobs).
  4. Reporting dashboards (replace `sheets_*` views with app queries/charts).
  Retire Apps Script functions + `sheets_*` views as each is replaced.

---

## 5. Prerequisites / open questions before the Phase-2 build
- Map the impact-analysis SP + 11 tables + reflag-candidate view — **sources located**
  in `clinvar-ingest-bq-tools/scripts/clinvar-curation/` (see §2.8); read them in Phase 0.
- `clinvar_ingest` (owned by **clinvar-ingest-bq-tools**): **no dev/prod split**, and it
  will be **refactored eventually**. Treat it as the stable upstream the curator layer
  depends on ONE-WAY (`release_on`, `determineMonthBasedOnRange`, release/version-history
  tables). When it's refactored, the curator layer's references here must be re-verified —
  flag to the user if any source is missing or a rework is needed.
- ClinVar submission: file-only (current) vs. any API; confirm separate-files-per-action.
- Which project hosts the web app + whether analytics stays in `clingen-dev:clinvar_curator`
  or moves alongside `clinvar_cvc_ext` (dev/prod split for the ops platform too).
- Role model (curator/reviewer/admin) and who administers batches.
- Go-live coupling: this platform becoming authoritative is the same milestone as
  "prod capture is the system of record" (then a fresh prod reload; retire scvc + sheet).

## 5b. Repo consolidation — RECOMMENDED: make this repo the single CvC home

The CvC curator SQL/procs/reports currently live in
`clinvar-ingest-bq-tools/scripts/clinvar-curation/` — but they are **CvC-domain and a
downstream CONSUMER of `clinvar_ingest`**, not ingest concerns. **Recommendation: move
them into THIS repo** so it holds ALL CvC resources: capture (extension) + migration +
the curator data layer/procs/reports + (eventually) the web app.

- **Why:** one coherent home + clear ownership; a clean **one-way dependency** (CvC here
  → `clinvar_ingest` upstream, which stays in its own repo); removes existing drift (e.g.
  `appscript-refresh-impact.js` duplicated in both repos); co-locates the BQ objects with
  their Phase-0 adapter and their Phase-2 web-app consumers.
- **Boundary:** `clinvar_ingest` (release ingestion, VCV/SCV version history) stays in
  clinvar-ingest-bq-tools as the upstream. Only the `scripts/clinvar-curation/` tree moves.
- **How (do it deliberately in Phase 0, not ad hoc):** relocate `scripts/clinvar-curation/`
  → e.g. this repo's `bigquery/curator/` (or `curator/`), bring a deployment mechanism
  (the `00-run-cvc-impact-analysis.sh` + numbered-SQL apply order), keep dataset refs to
  `clinvar_curator` / `clinvar_ingest` as-is, and delete the ingest-repo copies in the
  same change so there's a single source of truth. Coordinate with clinvar-ingest-bq-tools.
- **Open Q:** does the CvC analytics dataset (`clinvar_curator`) get a dev/prod split like
  `clinvar_cvc_ext`, or stay single (matching `clinvar_ingest`)? Decide during Phase 0.

## 6. Immediate next step
Recommended: open a **fresh context** and run superpowers:brainstorming →
writing-plans for **Phase 0** (the canonical data layer + impact-SP mapping), since it
unblocks everything and is durable under any UI outcome. Phases 1–2 get their own plans
after Phase 0's parity is proven.
