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
PROJECT="clingen-cvc"                       # must be globally unique
BILLING_ACCOUNT="016739-DB7AC5-2CFA7E"       # gcloud billing accounts list
MY_EMAIL="lbabb@broadinstitute.org"                   # first authorized curator (you)
ORG_FLAG=""                                  # e.g. "--organization=1234567890" or
                                             # "--folder=..." ; EMPTY = no org
                                             # (needed so External OAuth is allowed)
# ---- usually fine as-is ----------------------------------------------------
LOCATION="nam5"                              # Firestore location (US multi-region)
BQ_LOCATION="us"                             # BigQuery dataset location
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

echo "==> 6/9 Create Web app and capture the apiKey into firebase-config.js"
firebase apps:create WEB "${WEBAPP}" --project "${PROJECT}" || true
APIKEY=$(firebase apps:sdkconfig WEB --project "${PROJECT}" --json | jq -r '.result.sdkConfig.apiKey')
if [ -n "${APIKEY}" ] && [ "${APIKEY}" != "null" ]; then
  sed -i '' "s/PASTE_FIREBASE_WEB_API_KEY_HERE/${APIKEY}/" firebase-config.js
  echo "    apiKey written to firebase-config.js"
else
  echo "    WARN: could not read apiKey — set it in firebase-config.js manually."
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

echo "==> 9/9 Install the Firestore->BigQuery extension"
# The extension has many params; the reliable way to record them is to run the
# interactive installer ONCE (it writes extensions/<id>.env + a firebase.json
# entry), then deploys are reproducible. If that manifest already exists, this
# just deploys it.
if [ -f "extensions/firestore-bigquery-export.env" ]; then
  firebase deploy --only extensions --project "${PROJECT}" --non-interactive --force
else
  echo "    No extension manifest yet. Run this ONCE interactively, answering:"
  echo "      Database ID = (default) | Collection = ${COLLECTION}"
  echo "      Dataset = ${BQ_DATASET} | Table = ${BQ_TABLE} | Dataset location = ${BQ_LOCATION}"
  echo "      Functions location = ${FUNCTIONS_REGION}"
  echo
  echo "      firebase ext:install firebase/firestore-bigquery-export --project=${PROJECT} --local"
  echo
  echo "    Then re-run this script (it will deploy the recorded manifest), or run:"
  echo "      firebase deploy --only extensions --project ${PROJECT}"
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
echo "==> Optional: create the flattened BigQuery view (after the extension has run once)"
echo "    bq query --project_id=${PROJECT} --use_legacy_sql=false < bigquery/annotations_view.sql"
echo
echo "Done with the scriptable parts."
