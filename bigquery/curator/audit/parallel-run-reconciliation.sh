#!/usr/bin/env bash
set -euo pipefail
#
# Parallel-run reconciliation: the LIVE legacy Google-Sheet source vs the v4
# extension CAPTURE, for the "keep sheet primary, run the extension in parallel
# for confidence" phase. Answers, on demand: are the two converging, and is any
# annotation missing from capture that shouldn't be?
#
# Cross-region by design (sheet = clingen-dev / US, capture = <project> /
# us-central1), so a single BigQuery join is impossible. Instead each side's
# annotation_id set is pulled independently and diffed locally — both queried
# LIVE (no dependency on an adapter refresh). `annotation_id` == UNIX_MILLIS of
# the annotation timestamp on BOTH sides, so it is the natural join key AND, being
# numeric-millis, doubles as a chronological ordering (used for the boundary split
# below).
#
# Buckets:
#   matched       — annotation_id present in BOTH (the migrated overlap + any
#                   sheet row a curator has also entered via the extension)
#   capture_only  — in the extension, not the sheet -> NEW extension captures
#                   (the adoption signal; grows as curators use the extension)
#   sheet_only    — in the sheet, not the extension. Split by the newest matched
#                   timestamp:
#                     * _new  (>= newest matched)  -> ordinary parallel-run sheet
#                       appends while the sheet stays primary (expected)
#                     * _gap  (<  newest matched)  -> an ELIGIBLE sheet annotation
#                       older than the newest captured one yet absent from capture
#                       -> a real gap worth investigating (should be 0)
#
# Usage:
#   ./bigquery/curator/audit/parallel-run-reconciliation.sh            # prod capture
#   CAPTURE_PROJECT=clingen-cvc-dev ./…/parallel-run-reconciliation.sh # dev twin
#
: "${CAPTURE_PROJECT:=clingen-cvc}"                          # v4 capture project
: "${SHEET_PROJECT:=clingen-dev}"                            # legacy analytics project
: "${SHEET_TABLE:=clinvar_curator.clinvar_annotations_native}"  # sheet-sourced native
cd "$(git rev-parse --show-toplevel)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 1) Sheet eligible rows (ignore IS NOT TRUE). id = UNIX_MILLIS(annotation_date).
#    Only comma-free columns are selected so plain CSV splitting is safe.
bq --project_id="$SHEET_PROJECT" --location=US query --use_legacy_sql=false --format=csv --max_rows=10000000 \
  "SELECT CAST(UNIX_MILLIS(annotation_date) AS STRING) AS aid,
          FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S', annotation_date) AS ts, action, curator_email, scv_id
   FROM \`${SHEET_PROJECT}.${SHEET_TABLE}\` WHERE \`ignore\` IS NOT TRUE" \
  2>/dev/null | tail -n +2 | sort -t, -k1,1 > "$TMP/sheet.csv"

# 2) Extension capture rows.
bq --project_id="$CAPTURE_PROJECT" --location=us-central1 query --use_legacy_sql=false --format=csv --max_rows=10000000 \
  "SELECT annotation_id AS aid,
          FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S', created_at) AS ts, action, user_email, scv
   FROM \`${CAPTURE_PROJECT}.clinvar_cvc_ext.annotations\`" \
  2>/dev/null | tail -n +2 | sort -t, -k1,1 > "$TMP/capture.csv"

cut -d, -f1 "$TMP/sheet.csv"   | sort -u > "$TMP/sheet.ids"
cut -d, -f1 "$TMP/capture.csv" | sort -u > "$TMP/capture.ids"

matched="$(comm -12 "$TMP/sheet.ids" "$TMP/capture.ids" | wc -l | tr -d ' ')"
comm -23 "$TMP/sheet.ids" "$TMP/capture.ids" > "$TMP/sheet_only.ids"
comm -13 "$TMP/sheet.ids" "$TMP/capture.ids" > "$TMP/capture_only.ids"

# newest matched id (== newest matched timestamp, since id is UNIX_MILLIS)
newest_matched="$(comm -12 "$TMP/sheet.ids" "$TMP/capture.ids" | sort -n | tail -1)"
newest_matched="${newest_matched:-0}"
gap="$(awk -v m="$newest_matched" '($1+0) <  (m+0)' "$TMP/sheet_only.ids" | wc -l | tr -d ' ')"
new="$(awk -v m="$newest_matched" '($1+0) >= (m+0)' "$TMP/sheet_only.ids" | wc -l | tr -d ' ')"
caponly="$(wc -l < "$TMP/capture_only.ids" | tr -d ' ')"

echo "== Parallel-run reconciliation =="
echo "   sheet   : ${SHEET_PROJECT}.${SHEET_TABLE} (ignore IS NOT TRUE)"
echo "   capture : ${CAPTURE_PROJECT}.clinvar_cvc_ext.annotations"
echo
printf "   %-26s %s\n" "matched"                "$matched"
printf "   %-26s %s\n" "capture_only (adoption)" "$caponly"
printf "   %-26s %s\n" "sheet_only_new (appends)" "$new"
printf "   %-26s %s%s\n" "sheet_only_gap (INVESTIGATE)" "$gap" "$([ "$gap" != 0 ] && echo '   <-- non-zero!')"
echo

# Detail: adoption (all capture_only) and any gap rows (the concerning ones).
if [ "$caponly" != 0 ]; then
  echo "   -- capture_only (extension captures not yet in the sheet) --"
  join -t, "$TMP/capture_only.ids" "$TMP/capture.csv" | sed 's/^/      /'
  echo
fi
if [ "$gap" != 0 ]; then
  echo "   -- sheet_only_gap (eligible sheet rows older than newest capture, absent from capture) --"
  awk -v m="$newest_matched" '($1+0) < (m+0)' "$TMP/sheet_only.ids" > "$TMP/gap.ids"
  join -t, "$TMP/gap.ids" "$TMP/sheet.csv" | sed 's/^/      /'
  echo
fi

[ "$gap" = 0 ] && echo "   OK: no unexplained gaps (capture is a clean subset of the sheet up to its newest row)."
