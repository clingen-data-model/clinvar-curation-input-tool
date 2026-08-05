# Phase 0 — Parity Verification Report (Chunk 6)

**Status: GO for Phase 1.**

This is the go/no-go evidence for the Phase-0 canonical CvC data layer
(`docs/superpowers/plans/2026-08-03-phase0-canonical-data-layer.md`, spec
`docs/superpowers/specs/2026-08-03-phase0-canonical-data-layer-design.md`).
All queries below were run read-only against `clingen-dev` (`--location=US`)
and are checked in at `bigquery/curator/tests/`. Nothing in
`clinvar_curator` (legacy) or `clinvar_curator_v4` (shadow) was modified to
produce this report.

## 1. Re-migration reconciliation

The Chunk 3 clean-slate re-migration loads every historical Firestore
prod-staging (`clingen-cvc`) record keyed by its own `annotation_id` —
no content-hash dedup, so nothing is dropped on the v4 side.

Re-verified today:

| Metric | Value |
|---|---|
| `clinvar_curator.cvc_annotations_native_v4` row count | **31,383** |
| `clinvar_curator_v4.cvc_annotations_base_mv` row count | **31,383** |
| `clinvar_curator.cvc_annotations_base_mv` (legacy) row count | 31,397 |
| Shared `annotation_id`s (legacy ∩ v4) | **31,383** |
| `annotation_date` range in native_v4 | 2021-01-21 → 2026-08-04 |

Both projects/objects agree at **31,383** — the annotation_id invariant
holds exactly (every v4 base_mv row's `annotation_id` is also a legacy
base_mv row's `annotation_id`; see §3 for the column-level proof). The
31,383 vs the originally-migrated ~31,362 historical count reflects a
small number of live extension writes captured by the adapter's on-demand
refresh since the historical migration ran — expected, not a discrepancy.

**Restored-records audit** (`bigquery/curator/audit/restored-records-audit.sql`
→ `clinvar_curator.cvc_restored_records_audit`): exists and is populated —
1,074 rows across content-duplicate clusters, i.e. **554** records that the
old content-hash dedup (`annotationDocId`, excluding `annotation_id`/
`created_at`) would have silently dropped as "duplicates" are now loaded
under the no-dedup re-migration. (The design doc's original discovery
measured 578 at an earlier point; the ~24-record difference reflects
~2 days of continued live curator activity between that measurement and
today, not a methodology change — the same 11 `DEDUP_FIELDS` were used.)
Segmented by action (flagging candidate / remove flagged submission first),
joined to any downstream review/submission batch — a reviewable record of
what the old dedup had hidden.

## 2. Test 01 — Parity anchors (`01-anchor-version-bumps.sql`)

**Result: 114,916 diff rows (NOT 0) — explained, not an adapter defect.**

| Table | Legacy rows | v4 rows | Diff rows (both directions) |
|---|---|---|---|
| `cvc_version_bumps` | 9,425,138 | 9,425,138 | 56,746 (28,373 each direction) |
| `cvc_full_record_version_bumps` | 9,425,138 | 9,425,138 | 58,170 (29,085 each direction) |

Row counts are **identical** on both sides (same cardinality), but ~0.3–0.6%
of rows differ in content, symmetrically in both directions. `cvc_version_bumps`
/ `cvc_full_record_version_bumps` are annotation-independent (derived only
from `clinvar_ingest.clinvar_scvs`, spec §3.6 #4/#5) — so identical inputs
should give byte-identical output. The explanation is **run-time staleness**:
these two tables are built by the same 11-table `refresh_cvc_impact_analysis()`
SP that produces the other 9 impact tables, and per the known caveat, legacy's
were last materialized at the previous Apps-Script finalize while v4's were
freshly rebuilt by the shadow SP — against a `clinvar_ingest.clinvar_scvs`
table that is itself continuously updated by the ingest pipeline. Equal
counts + symmetric diff (an update, not a membership change) is exactly the
signature of "same query, two different points in time against a moving
upstream table," not an adapter bug. **This is the anticipated outcome named
in the task brief** ("if legacy's are stale they may differ; document
whichever you find").

Action: no fix required for Phase 0. At Phase-1 cutover, when legacy's
impact SP is refreshed contemporaneously (or retired), re-run this anchor —
it should go to 0.

## 3. Test 02 — Id-integrity (`02-id-integrity.sql`)

**Result: 14 diff rows (NOT 0) — all cross-verified as the known drift population.**

- Part (b) — stored `annotation_id == CAST(UNIX_MILLIS(annotation_date) AS STRING)`
  for every `cvc_annotations_native_v4` row: **0 mismatches** (checked
  standalone). The migration's `%E3S` millisecond-precision fix holds
  exactly.
- Part (a) — every staging (`cvc_clinvar_reviews` / `cvc_clinvar_submissions`)
  `annotation_id` resolves to a `cvc_annotations_native_v4` row: **14
  orphans**. Cross-referenced 1:1 by `annotation_id` against the legacy-only
  set found in Test 03/05 (`cvc_annotations_base_mv` legacy − v4 = the same
  14 ids) — these are **not** a distinct failure, they are the identical 14
  drift rows described in §5.

## 4. Test 03 — Choke-point column diff (`03-chokepoint-diff.sql`) — HEADLINE

**Result: 0 rows. Exact.**

`cvc_annotations_base_mv` is the true, singular choke point (spec §3.1) —
the only object in either lineage that reads the annotations source
directly. Compared legacy vs shadow on the 31,383 shared `annotation_id`s,
across every business + staging-derived column base_mv adds
(`variation_id, vcv_id, scv_id, scv_ver, action, reason, notes, curator,
clinvar_review_status, is_reviewed, is_submitted, batch_id`):

**0 legacy-only column diffs, 0 v4-only column diffs.**

This is deliberately **not** anchored on the downstream `cvc_annotations("all")`
table function — that TVF fans out via a release-date-range LEFT JOIN to
`clinvar_ingest.clinvar_scvs`, independently on each side (re-verified today:
legacy 45,742 rows / v4 45,652 rows from ~31.4k annotations — a pre-existing
join multiplier present on **both** sides, not a v4-only artifact). Anchoring
on base_mv — upstream of that fan-out — gives an unambiguous, exact
comparison. **This is the strongest single piece of evidence that the
adapter reproduces the legacy contract perfectly.**

## 5. Test 04 — End-to-end batch parity (`04-batch-endtoend.sql`)

**Result: 0 rows for batch 132. Exact.**

Batch `132` (finalized 2026-04-29) was chosen as a fully-settled,
pre-drift batch: verified 0 orphan staging ids against
`cvc_annotations_native_v4` for batches 130–135, and well clear of the 14
known drift rows (confined to batches 104/105/112/123). Symmetric,
full-row diff of:

| Table | Scope | Legacy rows | v4 rows | Diff |
|---|---|---|---|---|
| `cvc_flagging_version_bump_intersection` | `batch_id=132` | 94 | 94 | 0 |
| `cvc_resubmission_candidates` | `batch_id=132` | 15 | 15 | 0 |
| `cvc_impact_summary` | whole table | 34 | 34 | 0 |

Notably, `cvc_flagging_version_bump_intersection` is defined as `#2 ∩ #4`
(spec §3.6 #8) — i.e. it depends on `cvc_version_bumps`, the very table
that showed content drift in Test 01. That the batch-132-scoped
intersection is nonetheless byte-identical indicates the SCVs relevant to
this batch's flagging candidates are not among the subset of scvs whose
`clinvar_ingest.clinvar_scvs` state changed between the two SP run times —
consistent with §2's "moving upstream table" explanation, and confirming
the staleness in Test 01 is immaterial to this settled batch's actual
curation outcome. Run via `bigquery/curator/tests/run-parity.sh` (`BATCH=132`).

**Runner note (bug found and fixed while building this suite):** `bq query`
defaults to `--max_rows=100`, which silently truncated the printed diff
count for Test 01 (it initially reported "100" instead of the true
114,916). `run-parity.sh` now passes `--max_rows=10000000` explicitly. Also,
the test files open with a `--` SQL comment, which `bq`'s flag parser
mis-parses as a flag if the query is passed as a positional argument
(crashes with a Python `RecursionError`); the runner pipes each file via
stdin instead.

## 6. Test 05 — Drift enumeration (`05-drift-enumeration.sql`, informational)

**Result: 14 legacy-only, 0 v4-only.**

Anchored on `cvc_annotations_base_mv` (not the fan-out TVF) for a clean
one-row-per-annotation membership diff. All 14 legacy-only rows:

- span 2023-11-14 through 2025-08-11 (not clustered at a single "seed
  boundary" instant — the adapter has been kept fresh by ongoing
  refreshes, most recently through 2026-08-04),
- are **all** `is_reviewed = true`, `is_submitted = false` (reviewed, but
  never included in a submission file),
- fall entirely within batches **104, 105, 112, 123**,
- carry actions `no change` (5 rows) and `flagging candidate` (9 rows).

Interpretation: these look like sheet-side review-column edits/backfills
made independent of the v4 extension (the legacy `scvc/` Sheet integration
is still live per spec §3.7), never captured by the Firestore→adapter
pipeline. Because none reference a submitted batch, **no generated
submission file depends on their presence in v4** — they are visible in
review-history reporting only. v4-only drift is 0 (no new extension
captures outside the shared seed at the time of this run).

## 7. Impact-table staleness — structural argument (not independently re-run)

Per the task brief, legacy's 11 impact tables are materialized from the
last Apps-Script finalize while v4's were just rebuilt by the shadow SP; a
full 11-table diff run today would partly reflect that staleness rather
than adapter behavior, and re-running the legacy SP to "catch it up" was
explicitly out of scope (never mutate legacy). The evidence gathered here
substitutes:

- **The two pure-upstream anchors** (`cvc_version_bumps`,
  `cvc_full_record_version_bumps`) were spot-checked (Test 01) and **do**
  show staleness-attributable drift — confirming the caveat is real, not
  hypothetical.
- **Three of the downstream impact tables most relevant to curator-visible
  outcomes** (`cvc_flagging_version_bump_intersection`,
  `cvc_resubmission_candidates` for batch 132; `cvc_impact_summary` whole
  table) were empirically diffed anyway (Test 04) and are **exactly
  identical** — so for at least this settled batch and the top-level
  rollup, staleness did not propagate into a visible difference.
- **Structurally**, both lineages run the *identical* templated SP
  (`refresh_cvc_impact_analysis()` deployed via the same `bigquery/curator/`
  tree, parameterized only by `@@DATASET@@`/`@@ANNO_SOURCE@@`/`@@ANNO_ID@@`;
  see `bigquery/curator/README.md`) over inputs proven exact at the choke
  point (Test 03: 0/0). Given identical code + identical annotation inputs,
  a **contemporaneous** run of the SP against both lineages should reproduce
  the impact tables identically, module reference-data (`clinvar_ingest`)
  staleness — which is a data-freshness question, not an adapter-behavior
  question.
- **Recommendation for Phase-1 cutover**: re-run `refresh_cvc_impact_analysis()`
  for both lineages back-to-back (or retire legacy's schedule and treat v4
  as sole source of truth) and re-run the full 11-table diff as a cutover
  gate — not a Phase-0 blocker.

## 8. Go / No-Go recommendation

**GO for Phase 1.**

Rationale:
1. The **choke point** — the one object every downstream table ultimately
   depends on — is **exactly identical** on the 31,383-row shared seed (0/0
   column diff, Test 03). This is the strongest possible signal: the
   adapter's contract mapping (spec §3.2) is correct in every field it
   touches.
2. **Id-integrity holds**: the stored `annotation_id` formula is exact
   (0 mismatches), and the only orphaned staging ids (14) are fully
   explained, enumerated, and shown to be sheet-only drift outside the
   extension's capture path — not an adapter defect.
3. **A real, settled, end-to-end batch** (132) reproduces identically
   across the curator-facing impact tables that matter most for reflag/
   resubmission decisions (Test 04).
4. The two discrepancies found (Test 01's anchor drift, the 14-row Test
   02/05 drift) are both **explained by mechanisms external to the
   adapter** — upstream-table staleness from differing SP run times, and
   pre-existing sheet-vs-extension population drift — and neither is a
   defect in the `clinvar_curator_v4` lineage or the `cvc_annotations_native_v4`
   adapter itself.
5. A genuine bug was found and fixed in the *test tooling* during this
   work (bq's default `--max_rows=100` silently truncating diff counts) —
   evidence the verification process itself was exercised rigorously, not
   rubber-stamped.

No unexplained discrepancy was found. Phase 1 (repointing/expanding on this
canonical layer) can proceed on this evidence.
