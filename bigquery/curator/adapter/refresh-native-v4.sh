#!/usr/bin/env bash
set -euo pipefail
# Full-snapshot cross-region copy of the v4 capture into a native landing table
# BigQuery can't join across locations (capture = us-central1, curator = US), so
# this materializes the capture's flattened `annotations` view, extracts to GCS,
# LOADs into a raw table, then reshapes to the native contract.
#
# Parameterized so ONE script serves both prod and the dev twin:
#   prod (default): CVC_PROD=clingen-cvc      CURATOR_DATASET=clinvar_curator
#   dev shadow:     CVC_PROD=clingen-cvc-dev  CURATOR_DATASET=clinvar_curator_v4_dev  GCS_PREFIX=native_v4_dev
: "${CVC_PROD:=clingen-cvc}"; : "${CURATOR_PROJECT:=clingen-dev}"; : "${GCS_BUCKET:?set GCS_BUCKET (us-central1)}"
: "${CURATOR_DATASET:=clinvar_curator}"   # where _annotations_v4_raw + cvc_annotations_native_v4 land
: "${GCS_PREFIX:=native_v4}"              # GCS subpath for this source's shards (distinct per source to avoid collisions)
cd "$(git rev-parse --show-toplevel)"
SNAP="${CVC_PROD}:clinvar_cvc_ext._native_v4_snapshot"
RAW="${CURATOR_PROJECT}:${CURATOR_DATASET}._annotations_v4_raw"
# Drop `document_id` before the JSON extract: the reshape never uses it, and
# `bq load --autodetect` infers its type from a sample — a dataset mixing
# migrated docs (numeric `annotation_id` doc-ids) with live-capture docs
# (hex content-hash doc-ids) makes autodetect pick INTEGER off the numeric
# majority, then fail on the first hex value. Excluding it is robust for any
# migrated/live mix — prod hits this too once it takes real curator captures
# (test captures go to clingen-cvc-dev, never prod).
bq --project_id="$CVC_PROD" --location=us-central1 query --use_legacy_sql=false --destination_table="$SNAP" --replace \
  "SELECT * EXCEPT(document_id) FROM \`${CVC_PROD}.clinvar_cvc_ext.annotations\`"
# Clear any stale shards from a prior run first: `bq extract` overwrites
# same-named shards but does NOT delete leftover ones, and `load --replace`
# below would sweep an orphan shard back in. Harmless if the prefix is empty.
gcloud storage rm "${GCS_BUCKET}/${GCS_PREFIX}/**" 2>/dev/null || true
bq --project_id="$CVC_PROD" --location=us-central1 extract --destination_format=NEWLINE_DELIMITED_JSON \
  "$SNAP" "${GCS_BUCKET}/${GCS_PREFIX}/*.json"
bq --project_id="$CURATOR_PROJECT" --location=US load --replace --source_format=NEWLINE_DELIMITED_JSON \
  --autodetect "$RAW" "${GCS_BUCKET}/${GCS_PREFIX}/*.json"
sed "s/@@CURATOR_DATASET@@/${CURATOR_DATASET}/g" bigquery/curator/adapter/native_v4_reshape.sql \
  | bq --project_id="$CURATOR_PROJECT" --location=US query --use_legacy_sql=false --format=none
echo "native_v4 refreshed: source=${CVC_PROD} dataset=${CURATOR_PROJECT}.${CURATOR_DATASET}"
