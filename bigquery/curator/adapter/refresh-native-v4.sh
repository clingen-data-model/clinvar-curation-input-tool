#!/usr/bin/env bash
set -euo pipefail
: "${CVC_PROD:=clingen-cvc}"; : "${CURATOR_PROJECT:=clingen-dev}"; : "${GCS_BUCKET:?set GCS_BUCKET (us-central1)}"
cd "$(git rev-parse --show-toplevel)"
SNAP="${CVC_PROD}:clinvar_cvc_ext._native_v4_snapshot"
RAW="${CURATOR_PROJECT}:clinvar_curator._annotations_v4_raw"
bq --project_id="$CVC_PROD" --location=us-central1 query --use_legacy_sql=false --destination_table="$SNAP" --replace \
  'SELECT * FROM `clingen-cvc.clinvar_cvc_ext.annotations`'
bq --project_id="$CVC_PROD" --location=us-central1 extract --destination_format=NEWLINE_DELIMITED_JSON \
  "$SNAP" "${GCS_BUCKET}/native_v4/*.json"
bq --project_id="$CURATOR_PROJECT" --location=US load --replace --source_format=NEWLINE_DELIMITED_JSON \
  --autodetect "$RAW" "${GCS_BUCKET}/native_v4/*.json"
bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=none \
  < bigquery/curator/adapter/native_v4_reshape.sql
echo "native_v4 refreshed."
