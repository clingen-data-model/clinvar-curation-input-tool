#!/usr/bin/env bash
#
# Provision the ClinVar CvC extension in a fresh dedicated GCP project (clingen-cvc).
# Automates everything that gcloud/firebase/bq can do; pauses with a clear
# checklist for the identity steps that are CONSOLE-ONLY (OAuth consent screen,
# Chrome-extension OAuth client id, Google provider enable + whitelist).
#
# Run from the clinvar-cvc/ directory (it uses firebase.json + firestore.rules +
# bigquery/annotations_view.sql from here). macOS/BSD sed assumed (darwin).
#
# Prerequisites (install + authenticate first):
#   gcloud (Google Cloud SDK, includes bq)   ->  gcloud auth login
#   firebase-tools                            ->  npm i -g firebase-tools; firebase login
#   jq
#
# Idempotency: creation steps use "|| true" so re-runs don't hard-fail.

set -euo pipefail

# ---- EDIT THESE ------------------------------------------------------------
PROJECT="${CVC_PROJECT:-clingen-cvc}"        # override: CVC_PROJECT=clingen-cvc-dev ./setup-...
BILLING_ACCOUNT="016739-DB7AC5-2CFA7E"       # gcloud billing accounts list
MY_EMAIL="${CVC_EMAIL:-lbabb@broadinstitute.org}"   # first authorized curator (override: CVC_EMAIL=...)
ORG_FLAG=""                                  # e.g. "--organization=1234567890" or
                                             # "--folder=..." ; EMPTY = no org
                                             # (needed so External OAuth is allowed)
# ---- usually fine as-is ----------------------------------------------------
LOCATION="nam5"                              # Firestore location (US multi-region)
BQ_LOCATION="us-central1"                    # BigQuery dataset location (query with --location=this)
FUNCTIONS_REGION="us-central1"
WEBAPP="clinvar-cvc-ext"
COLLECTION="clinvar_cvc_ext_annotations"
BQ_DATASET="clinvar_cvc_ext"
BQ_TABLE="annotations"
# ---------------------------------------------------------------------------

echo "==> 1/9 Create project ${PROJECT}"
gcloud projects create "${PROJECT}" --name="ClinGen CVC Ext" ${ORG_FLAG} || true
gcloud config set project "${PROJECT}"

echo "==> 2/9 Link billing (required for the extension's Cloud Function)"
gcloud billing projects link "${PROJECT}" --billing-account="${BILLING_ACCOUNT}"

echo "==> 3/9 Enable APIs"
gcloud services enable \
  firebase.googleapis.com firestore.googleapis.com identitytoolkit.googleapis.com \
  bigquery.googleapis.com eventarc.googleapis.com cloudfunctions.googleapis.com \
  run.googleapis.com pubsub.googleapis.com cloudbuild.googleapis.com \
  serviceusage.googleapis.com

echo "==> 4/9 Add Firebase to the project"
firebase projects:addfirebase "${PROJECT}" || true

echo "==> 5/9 Create Firestore (default) database (Native mode)"
gcloud firestore databases create --database='(default)' \
  --location="${LOCATION}" --type=firestore-native || true

echo "==> 6/9 Create Web app and capture the apiKey (env.js holds per-env config)"
# NOTE: only create a Web app if the project has none yet — re-runs against a
# project that already has one would otherwise create confusing duplicates.
if ! firebase apps:list --project "${PROJECT}" 2>/dev/null | grep -q ' WEB '; then
  firebase apps:create WEB "${WEBAPP}" --project "${PROJECT}"
fi
APIKEY=$(firebase apps:sdkconfig WEB --project "${PROJECT}" --json 2>/dev/null | jq -r '.result.sdkConfig.apiKey')
if [ -n "${APIKEY}" ] && [ "${APIKEY}" != "null" ]; then
  # A dev run fills the dev placeholder in env.js; for other projects, paste the
  # printed key into the matching env block (prod vs dev) yourself.
  sed -i '' "s/PASTE_DEV_WEB_API_KEY_HERE/${APIKEY}/" env.js || true
  echo "    Web apiKey for ${PROJECT}: ${APIKEY}"
  echo "    -> if this is the dev project, env.js dev.apiKey was just filled;"
  echo "       otherwise paste the key into the matching env.js block."
else
  echo "    WARN: could not read apiKey — set it in env.js manually."
fi

echo "==> 7/9 Deploy Firestore security rules"
firebase deploy --only firestore:rules --project "${PROJECT}"

echo "==> 8/9 Seed the allowlist with ${MY_EMAIL}"
# Owner OAuth token uses IAM, which bypasses security rules — so this can create
# a doc in allowed_curators even though the rules forbid client writes.
TOKEN=$(gcloud auth print-access-token)
curl -s -X PATCH \
  "https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/allowed_curators/${MY_EMAIL}" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"fields":{"added_by":{"stringValue":"setup-clingen-cvc.sh"}}}' >/dev/null
echo "    added allowed_curators/${MY_EMAIL}"

echo "==> 9/9 Firestore->BigQuery extension"
# Fresh projects: the compute SA needs build permissions or the gen1 helper
# functions fail to build ("Access to bucket gcf-sources-... denied").
CSA="$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)')-compute@developer.gserviceaccount.com"
for r in roles/storage.objectViewer roles/logging.logWriter roles/artifactregistry.writer; do
  gcloud projects add-iam-policy-binding "${PROJECT}" --member="serviceAccount:${CSA}" --role="${r}" --condition=None --quiet >/dev/null
done
echo "    granted build roles to ${CSA}"

# `firebase ext:install` only RECORDS params to the local manifest; you must
# `deploy` to actually install. Run the interactive install ONCE, then deploy.
if [ -f "extensions/firestore-bigquery-export.env" ]; then
  firebase deploy --only extensions --project "${PROJECT}" --force
  # Let the Eventarc trigger (created in the DB region) invoke the function's
  # Cloud Run service — otherwise events 403 and nothing streams.
  TRIG_SA=$(gcloud eventarc triggers list --location="${LOCATION}" --project="${PROJECT}" --format="value(serviceAccount)" 2>/dev/null | head -1)
  [ -z "${TRIG_SA}" ] && TRIG_SA="${CSA}"
  gcloud run services add-iam-policy-binding ext-firestore-bigquery-export-fsexportbigquery \
    --region="${FUNCTIONS_REGION}" --project="${PROJECT}" \
    --member="serviceAccount:${TRIG_SA}" --role=roles/run.invoker --quiet >/dev/null 2>&1 \
    && echo "    granted run.invoker to ${TRIG_SA}"
  # The extension's dedicated runtime SA publishes lifecycle events to the
  # Eventarc "firebase" channel; without eventarc.publisher it 403s and the BQ
  # write never completes (dataset never gets created).
  EXT_SA="ext-firestore-bigquery-export@${PROJECT}.iam.gserviceaccount.com"
  gcloud projects add-iam-policy-binding "${PROJECT}" --member="serviceAccount:${EXT_SA}" \
    --role=roles/eventarc.publisher --condition=None --quiet >/dev/null 2>&1 \
    && echo "    granted eventarc.publisher to ${EXT_SA}"
  # Ensure the Eventarc service agent role (fresh projects lag on provisioning it).
  PNUM=$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)')
  gcloud projects add-iam-policy-binding "${PROJECT}" \
    --member="serviceAccount:service-${PNUM}@gcp-sa-eventarc.iam.gserviceaccount.com" \
    --role=roles/eventarc.serviceAgent --condition=None --quiet >/dev/null 2>&1 || true
else
  echo "    No extension manifest yet. Install it ONCE interactively (records params):"
  echo "      firebase ext:install firebase/firestore-bigquery-export --project=${PROJECT}"
  echo "    Answers: Collection=${COLLECTION}, Dataset=${BQ_DATASET}, Table=${BQ_TABLE},"
  echo "             Firestore Database region=${LOCATION}  <-- NOT us-central1 (must match the DB),"
  echo "             view type=view, time partitioning=NONE, dataset location=${BQ_LOCATION}."
  echo "    Then re-run this script; it deploys the manifest and grants run.invoker."
fi

echo
echo "=================  CONSOLE-ONLY STEPS (cannot be scripted)  ================="
cat <<EOF
A) OAuth consent screen (Google Auth Platform > Audience) for ${PROJECT}:
     User type = External, then Publish app > In production.
B) Create the Chrome-extension OAuth client id:
     Load the extension (chrome://extensions, Load unpacked) to get its ID, then
     APIs & Services > Credentials > Create > OAuth client ID > type "Chrome
     extension" > paste the extension id. Copy the client id.
C) Firebase Auth > Sign-in method:
     Enable the Google provider, and under "Whitelist client IDs from external
     projects" add the client id from (B).

Then paste the OAuth client id below to write it into manifest.json:
EOF
read -r -p "OAuth client id (blank to skip): " CLIENT_ID
if [ -n "${CLIENT_ID}" ]; then
  sed -i '' "s/PASTE_CLINGEN_CVC_OAUTH_CLIENT_ID_HERE.apps.googleusercontent.com/${CLIENT_ID}/" manifest.json
  echo "manifest.json updated. Reload the extension in chrome://extensions."
fi

echo
echo "==> Optional: create the flattened BigQuery view (after the extension has streamed a row)"
echo "    bq --location=${BQ_LOCATION} --project_id=${PROJECT} --use_legacy_sql=false < bigquery/annotations_view.sql"
echo
echo "Done with the scriptable parts."
