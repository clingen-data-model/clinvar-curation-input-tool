#!/usr/bin/env bash
# Deploy the curator SQL into a target dataset with a chosen annotation source.
# Usage: DATASET=clinvar_curator_v4 ANNO_SOURCE=clinvar_curator.cvc_annotations_native_v4 ./deploy.sh [--dry-run]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"    # run from repo root regardless of invocation dir
: "${CURATOR_PROJECT:=clingen-dev}"
: "${DATASET:?set DATASET (e.g. clinvar_curator or clinvar_curator_v4)}"
: "${ANNO_SOURCE:?set ANNO_SOURCE (fully-qualified source table)}"
: "${MV:=MATERIALIZED }"   # legacy default; pass MV="" for the shadow so base_mv is a plain VIEW
DRY=""; [ "${1:-}" = "--dry-run" ] && DRY="--dry_run"
# Numbered apply order: base tables/views/funcs first, then impact-analysis.
FILES=$(ls bigquery/curator/0*-*.sql | sort; ls bigquery/curator/cvc-impact-analysis/0*-*.sql | sort)
for f in $FILES; do
  echo ">> $f"
  sed -e "s/@@DATASET@@/${DATASET}/g" -e "s#@@ANNO_SOURCE@@#${ANNO_SOURCE}#g" -e "s/@@MV@@/${MV}/g" "$f" \
    | bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false $DRY --format=none
done
echo "deploy complete: DATASET=$DATASET ANNO_SOURCE=$ANNO_SOURCE MV='${MV}' ${DRY:+(dry-run)}"
