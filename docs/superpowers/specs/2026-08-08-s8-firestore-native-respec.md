# S8 re-spec — Firestore-native review workflow

> **Status: DESIGN RE-SPEC (2026-08-08).** Supersedes **decision A** (workflow
> state in BigQuery) of `2026-08-06-s8-review-submit-webapp-design.md`, and
> retires the "materialized queue + capture→US for the queue" follow-up in favor
> of reading the live Firestore capture. All other locked decisions
> (post-cutover v4-only, web app on Firebase, Drive file output, Gmail draft,
> config-table batch id) stand. Legacy `scvc/` sheet + Apps Script remain
> untouched; rework happens on the v4 dev shadow only.

## Why re-spec

The interactive review queue must show a just-captured annotation **within
seconds** while a curator is actively capturing. The BQ-native design routes the
queue through `cvc_annotations` (a 2.5 GB `clinvar_ingest` join) over
`cvc_annotations_native_v4` (a **periodic cross-region adapter snapshot**), so it
is both slow (~7 s) and stale (a capture doesn't appear until the adapter
re-runs). Materializing the queue only adds a second staleness layer.

**Key realization:** the Chrome extension already writes every annotation to
**Firestore** — a live, millisecond-fresh, US-multi-region store. If the
**review status + batch assignment live in Firestore too**, the queue reads the
live capture directly (real-time, concurrency-safe, no adapter, no materialized
view, no 2.5 GB scan), and those workflow fields **stream to BigQuery for free**
via the existing `firestore-bigquery-export` extension — so the analytics/
submission side needs no separate reconciliation.

## Reversed decision

- **A (was: workflow state in BigQuery) → workflow state in Firestore.**
  `review_status`, `reviewer`, `review_notes`, `reviewed_at`, `batch_id`,
  `assigned_at` become **queryable fields on the annotation's Firestore doc**,
  written by the review app (the extension still create-only-writes the doc; the
  app updates the review fields — create-only dedup preserves them on re-save,
  and they are outside the content-hash id). Firestore rules enforce
  "a curator writes only review fields, and only if allow-listed."

## Target architecture

```text
Chrome extension ─create→ Firestore annotation doc ──(firestore-bigquery-export stream)──▶ BQ capture
                               ▲  │                                                            │
        review app ─update─────┘  │ (review_status, batch_id, …)                               │
                                  ▼                                                            ▼
             Review queue = LIVE Firestore query (real-time)          BQ analytics / generate / finalize
             (unreviewed = review_status is null)                     read the STREAMED review/batch fields
```

- **Queue (real-time):** the app queries Firestore for unreviewed annotations
  (`where review_status == null`, etc.) — instant; optional live listeners so a
  teammate's capture appears without a reload. **No BQ, no adapter, no MV.**
- **Writes (real-time):** set status / assign batch = Firestore updates (a
  transaction enforces the assignment gate: OK + flag/remove action + not already
  assigned). Rules re-check the allowlist.
- **BQ side (batch-tolerant), fed by the existing stream:**
  - `cvc_clinvar_reviews` / `cvc_clinvar_submissions` become **VIEWS over the
    streamed capture** (annotations with a status / with a `batch_id`) — the S8
    finalize "promote" step largely disappears.
  - `cvc_clinvar_batches` + the impact SP stay BQ-computed (finalize writes the
    batch row + refreshes + bumps the id).
  - `generate` still runs its validated submission projection in BQ, reading
    batch membership from the streamed `batch_id`.
  - The cross-region hop (capture `us-central1` → curator `US`) still exists for
    the **BQ** side, but generate/finalize/impact are deliberate batch actions,
    so adapter/cadence lag there is acceptable. **`capture→US` becomes optional**
    (a latency nicety for BQ), no longer required for queue freshness.

## The one gap: ClinVar-derived flags (cadence enrichment)

`is_outdated_scv` / `is_deleted_scv` / `is_latest` / `latest_scv_classification`
/ `clinvar_review_status` — which drive the auto-review suggestion — are derived
by joining `clinvar_ingest` (BQ only); Firestore doesn't have them. They change
only when **ClinVar releases (~monthly)**, so:

- **Cadence enrichment (chosen):** on each ClinVar release, a small BQ job
  computes these flags for open (unreviewed) annotations and **writes them back
  onto the Firestore docs**. The queue stays pure-Firestore + real-time; the
  flags are release-fresh (which is exactly their natural cadence).
- `autoReview()` (unchanged pure function) then runs client- or server-side over
  the Firestore doc's fields.

## Rework map (vs the built chunks 0–7)

| Chunk | Change |
|---|---|
| 0 auth · 0.5 file/mailto | **unchanged** (already Firebase/Firestore-native) |
| 1 BQ workflow schema | **replaced** — drop `cvc_review_state`/`cvc_review_config` BQ tables + the views→tables conversion; instead define `cvc_clinvar_reviews`/`_submissions` as **views over the streamed capture**; batch-id config lives in Firestore (or a 1-row BQ table) |
| 2 queue | **reworked** — read Firestore (unreviewed), not the BQ TVF |
| 2.5 autoReview | **unchanged** (pure); inputs now from the enriched Firestore doc |
| 3 generate | **minor** — batch membership from the streamed `batch_id` view; projection unchanged (still byte-identical to legacy) |
| 4 review/assign writes | **reworked** — Firestore updates + a transaction gate + rules, not BQ MERGE |
| 5 finalize | **simplified** — no promote (reviews/submissions are views); compute the batches row + refresh SP + bump id |
| 6 frontend | **adjusted** — Firestore reads (optionally live), writes via the reworked endpoints |
| 7 e2e | **re-verify** the new flow |
| impact SP | **unchanged** |

**Deleted concerns:** the adapter as a queue dependency, `cvc_annotations_native_v4`
for the queue, the materialized-queue follow-up, and capture→US as a hard
requirement.

## Open decisions (resolve before rework)
- **Review fields on the annotation doc vs a parallel `reviews/{id}` doc.**
  *Lean: fields on the doc* (so `where review_status == null` queries the queue
  directly + one BQ row per annotation). Rules restrict which fields the app may
  write.
- **Where the Firestore→BQ views map the review fields** (the extension's
  changelog/latest schema → the SP's expected `cvc_clinvar_reviews` shape).
- **Batch-id config home:** a Firestore config doc (real-time, app-native) vs a
  1-row BQ table. *Lean: Firestore* (keeps workflow state together).
- **Cadence-enrichment trigger:** ClinVar-release hook vs a scheduled job.

## Safety
Dev shadow / dev Firestore (`clingen-cvc-dev`) only; legacy `clinvar_curator` +
the live sheet/Apps Script untouched. The review app only writes review fields on
annotation docs (rules-enforced) + the batches row/impact in the v4 BQ dataset.
