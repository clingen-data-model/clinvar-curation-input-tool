#!/usr/bin/env bash
set -euo pipefail
# Refresh the materialized review-queue base (the enriched-unreviewed set the
# fast /queue reads). Run BATCH-side: after the adapter (refresh-native-v4.sh)
# and at finalize. Guarded: never the live legacy clinvar_curator.
#
# Usage:  DATASET=clinvar_curator_v4_dev ./refresh-review-queue.sh
: "${CURATOR_PROJECT:=clingen-dev}"; : "${DATASET:=clinvar_curator_v4_dev}"
cd "$(git rev-parse --show-toplevel)"
case "$DATASET" in
  clinvar_curator_v4|clinvar_curator_v4_dev) : ;;
  *) echo "REFUSING: unexpected DATASET '$DATASET' (want a clinvar_curator_v4[_dev] shadow)." >&2; exit 1 ;;
esac
sed "s/@@DATASET@@/${DATASET}/g" review-app/sql/refresh-review-queue.sql \
  | bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=none
echo "review-queue base refreshed: ${CURATOR_PROJECT}.${DATASET}"
