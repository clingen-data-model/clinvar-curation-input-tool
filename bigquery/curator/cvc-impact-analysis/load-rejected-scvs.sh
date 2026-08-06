#!/bin/bash
# =============================================================================
# Load Rejected SCVs into BigQuery
# =============================================================================
#
# Usage:
#   ./load-rejected-scvs.sh [OPTIONS]
#
# Options:
#   --dry-run     Show commands without executing
#   --help        Show this help message
#
# This script:
#   1. Creates the cvc_rejected_scvs table if it doesn't exist
#   2. Loads the rejected-scvs.tsv file into the table (replacing existing data)
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="clingen-dev"
DATASET="clinvar_curator"
TABLE="cvc_rejected_scvs"
TSV_FILE="$SCRIPT_DIR/rejected-scvs.tsv"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            head -18 "$0" | grep -E "^#" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Color output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Check if TSV file exists
if [ ! -f "$TSV_FILE" ]; then
    echo "Error: TSV file not found: $TSV_FILE"
    exit 1
fi

log_info "Loading rejected SCVs from: $TSV_FILE"
log_info "Target table: $PROJECT.$DATASET.$TABLE"

# Create a temporary file with comments stripped and trailing whitespace removed
TEMP_FILE=$(mktemp)
grep -v "^#" "$TSV_FILE" | grep -v "^$" | sed 's/[[:space:]]*$//' > "$TEMP_FILE"

ROW_COUNT=$(wc -l < "$TEMP_FILE" | tr -d ' ')
log_info "Found $ROW_COUNT data rows (excluding comments)"

if [ "$DRY_RUN" = true ]; then
    log_warn "[DRY RUN] Would create/replace table and load $ROW_COUNT rows"
    echo ""
    echo "Table schema:"
    echo "  batch_id: STRING"
    echo "  scv_id: STRING"
    echo "  scv_ver: INT64"
    echo "  rejection_reason: STRING"
    echo "  date_rejected: DATE"
    echo ""
    echo "First 5 data rows:"
    head -5 "$TEMP_FILE"
    rm "$TEMP_FILE"
    exit 0
fi

# Create the table (will be replaced by load)
log_info "Creating/replacing table..."

bq load \
    --project_id="$PROJECT" \
    --replace \
    --source_format=CSV \
    --field_delimiter='\t' \
    --skip_leading_rows=0 \
    "$DATASET.$TABLE" \
    "$TEMP_FILE" \
    "batch_id:STRING,scv_id:STRING,scv_ver:INT64,rejection_reason:STRING,date_rejected:DATE"

rm "$TEMP_FILE"

log_info "Table loaded successfully!"
echo ""

# Show summary
bq query --use_legacy_sql=false --format=pretty "
SELECT
    rejection_reason,
    COUNT(*) as count,
    COUNT(DISTINCT batch_id) as batches_affected
FROM \`$PROJECT.$DATASET.$TABLE\`
GROUP BY rejection_reason
ORDER BY count DESC
"
