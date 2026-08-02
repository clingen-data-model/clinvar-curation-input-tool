#!/usr/bin/env bash
#
# List the authorized curators (document ids in allowed_curators).
#
# Usage:  ./list-curators.sh
# Needs:  gcloud (authed as an owner/editor of the project), jq

set -euo pipefail
PROJECT="${CVC_PROJECT:-clingen-cvc}"
DB="(default)"
TOKEN=$(gcloud auth print-access-token)

curl -s \
  "https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/${DB}/documents/allowed_curators?pageSize=1000" \
  -H "Authorization: Bearer ${TOKEN}" \
  | jq -r 'if .documents then (.documents[].name | split("/") | last) else "(no curators yet)" end'
