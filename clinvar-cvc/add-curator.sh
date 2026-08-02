#!/usr/bin/env bash
#
# Add a curator to the clinvar-cvc allowlist (allowed_curators/{email}).
# The email becomes the Firestore document id; the security rules then let
# that Google account submit annotations.
#
# Usage:  ./add-curator.sh <google-email>
# Needs:  gcloud (authed as an owner/editor of the project), python3
# Works because an owner OAuth token uses IAM, which bypasses the security
# rules that forbid client writes to allowed_curators.

set -euo pipefail
PROJECT="${CVC_PROJECT:-clingen-cvc}"
DB="(default)"

EMAIL="${1:-}"
if [ -z "${EMAIL}" ]; then
  echo "Usage: $0 <google-email>"; exit 1
fi
case "${EMAIL}" in *@*.*) ;; *) echo "Not a valid email: ${EMAIL}"; exit 1 ;; esac

# URL-encode the email so it is a single valid path segment (@ -> %40, etc.)
ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${EMAIL}")
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BY=$(gcloud config get-value account 2>/dev/null || echo "unknown")
TOKEN=$(gcloud auth print-access-token)

resp=$(curl -s -w $'\n%{http_code}' -X PATCH \
  "https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/${DB}/documents/allowed_curators/${ENC}" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d "{\"fields\":{\"added_by\":{\"stringValue\":\"${BY}\"},\"added_on\":{\"timestampValue\":\"${NOW}\"}}}")
code=$(printf '%s' "${resp}" | tail -1)
body=$(printf '%s' "${resp}" | sed '$d')

if [ "${code}" = "200" ]; then
  echo "✓ Authorized curator: ${EMAIL}  (project ${PROJECT})"
else
  echo "✗ Failed (HTTP ${code}):"; echo "${body}"; exit 1
fi
