#!/bin/bash
# =============================================================================
# Query Pending/Rejected SCVs
# =============================================================================
#
# Usage:
#   ./query-pending-rejected-scvs.sh [OPTIONS]
#
# Options:
#   --batch BATCH_ID   Filter by specific batch ID
#   --tsv              Output in TSV format (for copy/paste to rejected-scvs.tsv)
#   --help             Show this help message
#
# =============================================================================

set -e

PROJECT="clingen-dev"
BATCH_FILTER=""
TSV_FORMAT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --batch)
            BATCH_FILTER="$2"
            shift 2
            ;;
        --tsv)
            TSV_FORMAT=true
            shift
            ;;
        --help)
            head -15 "$0" | grep -E "^#" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

WHERE_CLAUSE="WHERE outcome = 'pending (or rejected)'"
if [ -n "$BATCH_FILTER" ]; then
    WHERE_CLAUSE="$WHERE_CLAUSE AND batch_id = '$BATCH_FILTER'"
fi

if [ "$TSV_FORMAT" = true ]; then
    # TSV format for easy copy/paste
    bq query --use_legacy_sql=false --format=csv --quiet "
        SELECT
            batch_id,
            scv_id,
            CAST(scv_ver AS STRING) as scv_ver
        FROM \`$PROJECT.clinvar_curator.cvc_submitted_outcomes_view\`
        $WHERE_CLAUSE
        ORDER BY batch_id, scv_id
    " | tail -n +2 | tr ',' '\t'
else
    # Pretty format for review
    bq query --use_legacy_sql=false --format=pretty "
        SELECT
            batch_id,
            scv_id,
            scv_ver,
            submission_date,
            annotation_release_date,
            reason as curation_reason
        FROM \`$PROJECT.clinvar_curator.cvc_submitted_outcomes_view\`
        $WHERE_CLAUSE
        ORDER BY batch_id, scv_id
    "
fi
