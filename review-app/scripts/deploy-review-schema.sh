#!/usr/bin/env bash
set -euo pipefail
# Deploy the Review & Submit workflow-state schema into a v4 dataset (dev shadow
# by default). Write-path guard: HARD-REFUSES clinvar_curator (the live legacy
# lineage) as the target — the primary control is still dataset-scoped IAM
# (scripts/grant-iam.sh), this is the second layer.
#
# Usage:
#   DATASET=clinvar_curator_v4_dev ./deploy-review-schema.sh          # dev (default)
#   DATASET=clinvar_curator_v4     ./deploy-review-schema.sh          # prod shadow
: "${CURATOR_PROJECT:=clingen-dev}"
: "${DATASET:=clinvar_curator_v4_dev}"
cd "$(git rev-parse --show-toplevel)"

if [ "$DATASET" = "clinvar_curator" ]; then
  echo "REFUSING: clinvar_curator is the live legacy lineage — never a write target." >&2
  exit 1
fi
case "$DATASET" in
  clinvar_curator_v4|clinvar_curator_v4_dev) : ;;
  *) echo "REFUSING: unexpected DATASET '$DATASET' (expected a clinvar_curator_v4[_dev] shadow)." >&2; exit 1 ;;
esac

echo ">> deploying review-state schema to ${CURATOR_PROJECT}.${DATASET}"
sed "s/@@DATASET@@/${DATASET}/g" review-app/sql/00-review-state-schema.sql \
  | bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=none
echo "done."
