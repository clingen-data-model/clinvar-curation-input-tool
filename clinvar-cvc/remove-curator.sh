#!/usr/bin/env bash
#
# Remove a curator from the clinvar-cvc allowlist (deletes allowed_curators/{email}).
# Effective immediately — the rules re-check the allowlist on every write.
#
# Usage:  ./remove-curator.sh <google-email>
# Needs:  gcloud (authed as an owner/editor of the project), python3

set -euo pipefail
PROJECT="${CVC_PROJECT:-clingen-cvc}"
DB="(default)"

EMAIL="${1:-}"
if [ -z "${EMAIL}" ]; then
  echo "Usage: $0 <google-email>"; exit 1
fi

ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${EMAIL}")
TOKEN=$(gcloud auth print-access-token)

resp=$(curl -s -w $'\n%{http_code}' -X DELETE \
  "https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/${DB}/documents/allowed_curators/${ENC}" \
  -H "Authorization: Bearer ${TOKEN}")
code=$(printf '%s' "${resp}" | tail -1)
body=$(printf '%s' "${resp}" | sed '$d')

if [ "${code}" = "200" ]; then
  echo "✓ Revoked curator: ${EMAIL}  (project ${PROJECT})"
else
  echo "✗ Failed (HTTP ${code}):"; echo "${body}"; exit 1
fi
