#!/usr/bin/env bash
# Runs the Phase-0 parity diff suite (bigquery/curator/tests/0[1-4]*.sql),
# each of which returns 0 rows on success. 05-drift-enumeration.sql
# (informational) and 06-annotation-id-roundtrip.sql (legacy-sheet round-trip
# fidelity; needs @@ANNO_V4@@ sed-substituted) are excluded from this glob and
# run separately — see their file headers.
#
# Usage:
#   export CURATOR_PROJECT=clingen-dev   # default
#   BATCH=132 ./bigquery/curator/tests/run-parity.sh
#
# BATCH must be a batch_id finalized well before any known post-seed drift
# (see 02-id-integrity.sql / 05-drift-enumeration.sql for the 14 known
# drift rows, confined to batches 104/105/112/123) — batch 132
# (finalized 2026-04-29) was verified clean at the time this suite was
# written.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
: "${CURATOR_PROJECT:=clingen-dev}"; : "${BATCH:?set BATCH}"
fail=0
for q in bigquery/curator/tests/0[1-4]*.sql; do
  echo "== $q =="
  # NOTE: the query is piped via stdin, not passed as a positional arg — the
  # test files open with a `--` SQL comment, and bq's absl-based flag parser
  # mistakes a positional arg starting with `--` for a flag (hangs/crashes
  # with a RecursionError). stdin sidesteps that entirely.
  # NOTE: bq query defaults to --max_rows=100, which silently truncates the
  # printed row count for any diff larger than 100 (a real bug caught while
  # writing this suite — 01's true diff is >100k rows, not the "100" the
  # default would report). Pass a large --max_rows so the count is exact.
  n=$(bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=csv \
        --max_rows=10000000 \
        --parameter=batch:STRING:"$BATCH" < "$q" | tail -n +2 | wc -l | tr -d ' ')
  if [ "$n" = "0" ]; then echo "PASS ($q)"; else echo "FAIL: $n diff rows ($q)"; fail=1; fi
done
exit $fail
