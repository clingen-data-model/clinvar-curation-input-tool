#!/usr/bin/env bash
set -euo pipefail
# Least-privilege, DATASET-SCOPED BigQuery IAM for the Review & Submit web-app
# Cloud Functions runtime SA. This is the PRIMARY non-impact control (plan
# §Non-impact enforcement): with write scoped to the v4 workflow dataset(s) and
# read-only on legacy, NO code path — a guard bug, a mis-tokenized query, a bad
# SP CALL — can physically write the live `clinvar_curator` lineage.
#
#   WRITE (roles/bigquery.dataEditor): the v4 workflow dataset(s) ONLY
#   READ  (roles/bigquery.dataViewer): clinvar_curator (legacy) + clinvar_ingest
#   JOBS  (roles/bigquery.jobUser)   : project-level (to run query jobs)
#
# Run AFTER the Functions are first deployed (the runtime SA must exist), DEV
# first. Idempotent. Prefer a DEDICATED runtime SA (set on the function), not
# the default compute SA.
#
# Usage:
#   SA=review-app@clingen-cvc-dev.iam.gserviceaccount.com \
#   WRITE_DATASETS="clinvar_curator_v4_dev" \
#   ./grant-iam.sh
#
# NOTE: dataset-level IAM here uses `bq add-iam-policy-binding` (recent bq). If
# your bq lacks dataset support, use the dataset access-list method
# (`bq update --dataset`) with the same members/roles. VERIFY at provision time.
: "${SA:?set SA (Functions runtime service account email)}"
: "${CURATOR_PROJECT:=clingen-dev}"            # project holding the BQ datasets
: "${WRITE_DATASETS:=clinvar_curator_v4_dev}"  # space-separated; NEVER clinvar_curator
READ_DATASETS="clinvar_curator clinvar_ingest"

# Hard guard: clinvar_curator must never be a WRITE target.
for ds in $WRITE_DATASETS; do
  if [ "$ds" = "clinvar_curator" ]; then
    echo "REFUSING: clinvar_curator must never be granted WRITE (dataEditor)." >&2
    exit 1
  fi
done

echo "jobUser on project ${CURATOR_PROJECT} for ${SA}…"
gcloud projects add-iam-policy-binding "$CURATOR_PROJECT" \
  --member="serviceAccount:${SA}" --role="roles/bigquery.jobUser" --condition=None >/dev/null

grant() { # <dataset> <role>
  echo "  $2 on ${CURATOR_PROJECT}:$1"
  bq add-iam-policy-binding --member="serviceAccount:${SA}" --role="$2" "${CURATOR_PROJECT}:$1" >/dev/null
}
echo "WRITE (dataEditor):"; for ds in $WRITE_DATASETS; do grant "$ds" roles/bigquery.dataEditor; done
echo "READ  (dataViewer):"; for ds in $READ_DATASETS;  do grant "$ds" roles/bigquery.dataViewer; done

echo "done."
echo "VERIFY: bq get-iam-policy ${CURATOR_PROJECT}:clinvar_curator  # ${SA} must be dataViewer, NOT dataEditor"
