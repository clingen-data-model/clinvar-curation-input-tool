# S8 re-spec — real-time queue via a Firestore LIST read (BQ stays system of record)

> **Status: DESIGN RE-SPEC (2026-08-08), after a 3-reviewer pass.** A first draft
> proposed a full **Firestore-native** pivot (move workflow state onto the
> capture docs, reverse decision A). All three reviewers returned **major-rework**;
> that pivot is **rejected** (see "Why the full pivot was rejected"). This doc is
> the adopted, narrower design: **decision A stands** (workflow state + writes +
> finalize + the submission ledger stay in BigQuery, as already built and
> validated); we add **only** a Firestore live read for the queue *list* to fix
> freshness. Legacy `scvc/` sheet + Apps Script + `clinvar_curator` untouched.

## The problem (unchanged)

The queue must show a just-captured annotation within seconds. Today it reads
`cvc_annotations` (a 2.5 GB `clinvar_ingest` join) over the adapter-fed
`cvc_annotations_native_v4`, so a new capture doesn't appear until the periodic
cross-region adapter re-runs — slow (~7 s) and stale.

## Why the full Firestore-native pivot was rejected (3-reviewer synthesis)

1. **`review_status` name collision (critical, all 3).** The capture doc already
   has `review_status` (the scraped ClinVar star status, in the dedup content
   hash + the annotations view). Reusing it for workflow status makes the queue
   predicate match nothing and corrupts captured data + the parity harness.
2. **The adapter isn't actually removed, and it's not simpler (all 3).** BigQuery
   can't define cross-region views, so `reviews`/`submissions`-as-views over the
   `us-central1` stream can't feed the US impact SP or `generate` — the
   us-central1→US copy (the adapter) stays. The pivot only *adds* parts (capture
   rules, a BQ→Firestore enrichment job, view-mapping, dual-store finalize).
3. **It regresses correctness (all 3).** `submissions`-as-a-view destroys the
   immutable record of what was submitted (and leaks un-finalized assignments);
   finalize becomes dual-store with a read-your-write hazard and loses its
   single-region transaction; a cadence job mutating capture docs breaks
   immutability + floods the fragile shared stream; auto-review can't run on the
   freshest rows (their `clinvar_ingest`-derived flags don't exist yet).

## Adopted design — Firestore for the LIST only

The only real pain is the queue *list* freshness. Fix it without moving the
system of record:

- **Queue list = a live Firestore read** of the captured annotations (real-time;
  index-free by recency/`variation_id`, the pattern the extension already uses in
  `history.js`). A brand-new capture appears in the list immediately — before the
  adapter copies it to BQ.
- **Status + batch + derived flags = BigQuery**, joined by `annotation_id`:
  - in-progress review status / batch from `cvc_review_state` (as built, Chunk 4);
  - the `clinvar_ingest`-derived flags + `autoReview` inputs from `cvc_annotations`
    (as built, Chunk 2/2.5).
  - For a capture **not yet in BQ** (adapter hasn't run), these are simply
    **blank** — the row shows in the list as "new / awaiting enrichment," and the
    auto-review suggestion + flags fill in after the next adapter refresh. The
    curator sees the annotation instantly; the derived assist is eventually
    consistent (its natural cadence anyway).
- **Everything else is unchanged:** all review/assign **writes** → BQ
  `cvc_review_state` (Chunk 4, server-side gate); **finalize** → the single-region
  BQ transaction + append-only submission ledger (Chunk 5); **generate** parity
  (Chunk 3); the impact SP. **No Firestore rules changes** (reads use the existing
  `allow read: if isAllowedCurator()`); **no writes to capture docs** (capture
  stays create-only + immutable); **no enrichment job**, **no cross-region views**.

## What changes vs the built app

- **Chunk 2 (queue) only** — modest: `/queue` returns the Firestore-sourced list
  merged with the BQ review-state + `cvc_annotations` projection (LEFT JOIN on
  `annotation_id`); rows absent from BQ are surfaced with null flags.
- **Chunk 6 (frontend) optional add** — a Firestore `onSnapshot` listener so the
  list updates without a manual reload (the "within seconds, no reload" win). The
  built polling/reload path still works if we skip listeners.
- Chunks 0 / 0.5 / 1 / 3 / 4 / 5 / impact-SP: **unchanged** (decision A stands).

## Open items (small)
- The Firestore list query: scope to recent/unreviewed and paginate (the
  collection holds all history). "Unreviewed" is still decided by the BQ join
  (`cvc_clinvar_reviews`), so the list is the *candidate* set; the join marks
  reviewed/assigned. Confirm the recency window / section filter.
- De-dup migrated-vs-live docs in the Firestore list (migration keyed by
  `annotation_id`, live by content hash) so the same annotation isn't shown twice.
- Cross-region: the BQ half still reads the US curator dataset (adapter-fed);
  that lag only affects the derived flags, not the list. `capture→US` remains an
  optional latency nicety, not required.

## Safety
No change to capture rules or the capture path (read-only Firestore access,
already granted); capture stays immutable; the immutable submission ledger + the
single-region finalize transaction are preserved; legacy + the live sheet remain
untouched.
