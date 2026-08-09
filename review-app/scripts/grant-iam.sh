#!/usr/bin/env bash
set -euo pipefail
# Least-privilege BigQuery access for the Review & Submit web-app Cloud Functions
# runtime SA. This is a primary non-impact control: the SA gets WRITE only on the
# v4 workflow dataset and READ only on clinvar_ingest — it has NO access to the
# live legacy `clinvar_curator` lineage at all (the app never reads it; the
# parity harness runs as an operator, not this SA).
#
#   WRITE (dataset ACL WRITER): the v4 workflow dataset ONLY
#   READ  (dataset ACL READER): clinvar_ingest (cvc_annotations + finalize read it)
#   JOBS  (roles/bigquery.jobUser): project-level (to run query jobs)
#   AUTH  (roles/datastore.viewer): the FIREBASE project — the allowlist check
#         reads the allowed_curators Firestore collection (WITHOUT this the app
#         500s on every request and the UI shows "not authorized").
#
# NOTE: dataset-level access is granted via the dataset ACL (`bq update` access
# entries), NOT `bq add-iam-policy-binding` — dataset-level IAM setIamPolicy
# requires org allowlisting that is not enabled here (verified 2026-08-07).
#
# Run AFTER the Functions are first deployed (the runtime SA must exist). The
# gen2 runtime SA defaults to the project compute SA
# (<PROJECT_NUMBER>-compute@developer.gserviceaccount.com) unless overridden.
#
# Usage:
#   SA=362266755807-compute@developer.gserviceaccount.com \
#   WRITE_DATASET=clinvar_curator_v4_dev \
#   ./grant-iam.sh
: "${SA:?set SA (Functions runtime service account email)}"
: "${CURATOR_PROJECT:=clingen-dev}"            # project holding the BQ datasets
: "${FIREBASE_PROJECT:=clingen-cvc-dev}"       # the SA's project (Firestore allowed_curators lives here); prod = clingen-cvc
: "${WRITE_DATASET:=clinvar_curator_v4_dev}"   # the v4 workflow dataset; NEVER clinvar_curator
READ_DATASETS="clinvar_ingest"

if [ "$WRITE_DATASET" = "clinvar_curator" ]; then
  echo "REFUSING: clinvar_curator (live legacy) must never be granted WRITE." >&2; exit 1
fi

echo "jobUser on project ${CURATOR_PROJECT} for ${SA}…"
gcloud projects add-iam-policy-binding "$CURATOR_PROJECT" \
  --member="serviceAccount:${SA}" --role="roles/bigquery.jobUser" --condition=None >/dev/null

echo "datastore.user on ${FIREBASE_PROJECT} (read allowed_curators + WRITE reflag capture docs)…"
# datastore.user = read (allowlist check) + write (reflagging creates new
# Flagging Candidate docs in the clinvar_cvc_ext_annotations capture collection).
gcloud projects add-iam-policy-binding "$FIREBASE_PROJECT" \
  --member="serviceAccount:${SA}" --role="roles/datastore.user" --condition=None >/dev/null

# Grant a dataset ACL role (WRITER/READER) idempotently via bq update.
grant_acl() { # <dataset> <WRITER|READER>
  local ds="$1" role="$2" f; f="$(mktemp)"
  bq show --format=prettyjson "${CURATOR_PROJECT}:${ds}" > "$f"
  SA="$SA" ROLE="$role" python3 - "$f" <<'PY'
import os, sys, json
f = sys.argv[1]; sa = os.environ['SA']; role = os.environ['ROLE']
d = json.load(open(f)); acc = d.setdefault('access', [])
if not any(e.get('userByEmail') == sa for e in acc):
    acc.append({'role': role, 'userByEmail': sa})
json.dump(d, open(f, 'w'))
PY
  bq update --source "$f" "${CURATOR_PROJECT}:${ds}" >/dev/null
  rm -f "$f"
  echo "  ${role} on ${CURATOR_PROJECT}:${ds}"
}

echo "WRITE:"; grant_acl "$WRITE_DATASET" WRITER
echo "READ:";  for ds in $READ_DATASETS; do grant_acl "$ds" READER; done

# --- event-driven enrichment (onCapture → enrichQueue → enrich.js) ----------
# The Firestore capture trigger runs the adapter (capture→native_v4 via a GCS
# hop) + base refresh. These grants are REQUIRED for that chain and several are
# the classic gen2 gotcha (Firebase does NOT reliably auto-grant them):
ENRICH_BUCKET="${ENRICH_BUCKET:-gs://clingen-dev-cvc-native-v4-staging}"  # us-central1 staging bucket
echo "enrichment IAM:"
# 1. GCS staging bucket (extract writes / load reads / shard cleanup)
gcloud storage buckets add-iam-policy-binding "$ENRICH_BUCKET" \
  --member="serviceAccount:${SA}" --role="roles/storage.objectAdmin" >/dev/null && echo "  objectAdmin on ${ENRICH_BUCKET}"
# 2. BQ in the FIREBASE project (snapshot the capture → _native_v4_snapshot)
for role in roles/bigquery.jobUser roles/bigquery.dataEditor; do
  gcloud projects add-iam-policy-binding "$FIREBASE_PROJECT" \
    --member="serviceAccount:${SA}" --role="$role" --condition=None >/dev/null
done; echo "  jobUser + dataEditor on ${FIREBASE_PROJECT}"
# 3. read clinvar_ingest ROUTINES + project metadata (release_on(CURRENT_DATE())
#    powers the release-staleness check in /config + the enrich release stamp).
#    Project-level dataViewer is READ-ONLY — non-impact is preserved by the
#    write-path guard (dataset-guard.js), which still refuses writes to legacy.
gcloud projects add-iam-policy-binding "$CURATOR_PROJECT" \
  --member="serviceAccount:${SA}" --role="roles/bigquery.dataViewer" --condition=None >/dev/null && echo "  dataViewer (read) on ${CURATOR_PROJECT}"
# 4. Cloud Tasks: onCapture enqueues a (debounced) task with an OIDC token for
#    the SA, so it must be able to enqueue AND actAs itself.
gcloud projects add-iam-policy-binding "$FIREBASE_PROJECT" \
  --member="serviceAccount:${SA}" --role="roles/cloudtasks.enqueuer" --condition=None >/dev/null
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --member="serviceAccount:${SA}" --role="roles/iam.serviceAccountUser" --project="$FIREBASE_PROJECT" >/dev/null
echo "  cloudtasks.enqueuer + serviceAccountUser(self)"
# 5. run.invoker on the trigger targets — Eventarc→onCapture and Tasks→enrichQueue.
#    RE-RUN after any redeploy that recreates these Cloud Run services.
for svc in oncapture enrichqueue; do
  gcloud run services add-iam-policy-binding "$svc" --region=us-central1 --project="$FIREBASE_PROJECT" \
    --member="serviceAccount:${SA}" --role="roles/run.invoker" >/dev/null 2>&1 && echo "  run.invoker on ${svc}" || echo "  (skip run.invoker on ${svc} — deploy it first)"
done

echo "done. The SA WRITES only to the v4 workflow dataset; its clingen-dev read is read-only (legacy writes still guarded)."
