#!/bin/bash
# =============================================================================
# CVC Impact Analysis Pipeline Runner
# =============================================================================
#
# Usage:
#   ./00-run-cvc-impact-analysis.sh [OPTIONS]
#
# Options:
#   --dry-run     Show commands without executing
#   --force       Force rebuild even if no new data
#   --check-only  Check if rebuild is needed without running
#   --skip-load   Skip loading TSV files (use existing data)
#   --help        Show this help message
#
# Pipeline Steps:
#   Phase 1 - Load Data Files:
#     - Load rejected-scvs.tsv into cvc_rejected_scvs
#
#   Phase 2 - Core Impact Analysis (01-03):
#     These scripts use cvc_submitted_outcomes_view (existing CVC table)
#     01: Create cvc_submitted_variants table
#     02: Create conflict attribution tables
#     03: Create impact analytics and summary views
#
#   Phase 3 - Flagging Candidate Analysis (00, 04-08):
#     These scripts use cvc_batches_enriched and cvc_rejected_scvs
#     00: Create cvc_batches_enriched view (adds grace period dates)
#     04: Track flagging candidate outcomes
#     05: Detect version bumps across all SCVs
#     06: Analyze version bump and flagging intersection
#     07: Identify resubmission candidates (unflagged SCVs needing action)
#     08: Identify auto-reflag candidates (previously flagged, unflagged by version bump)
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="clingen-dev"
DRY_RUN=false
FORCE=false
CHECK_ONLY=false
SKIP_LOAD=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --check-only)
            CHECK_ONLY=true
            shift
            ;;
        --skip-load)
            SKIP_LOAD=true
            shift
            ;;
        --help)
            head -38 "$0" | grep -E "^#" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

run_query() {
    local sql_file="$1"
    local description="$2"

    if [ ! -f "$sql_file" ]; then
        log_error "SQL file not found: $sql_file"
        return 1
    fi

    log_step "$description"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY RUN] bq query --use_legacy_sql=false --project_id=$PROJECT < $sql_file"
    else
        bq query \
            --use_legacy_sql=false \
            --project_id="$PROJECT" \
            < "$sql_file"

        if [ $? -eq 0 ]; then
            log_info "  Completed: $description"
        else
            log_error "  Failed: $description"
            return 1
        fi
    fi
}

run_loader() {
    local script="$1"
    local description="$2"

    if [ ! -f "$script" ]; then
        log_error "Loader script not found: $script"
        return 1
    fi

    log_step "$description"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY RUN] $script --dry-run"
        "$script" --dry-run 2>/dev/null || true
    else
        "$script"

        if [ $? -eq 0 ]; then
            log_info "  Completed: $description"
        else
            log_error "  Failed: $description"
            return 1
        fi
    fi
}

check_rebuild_needed() {
    log_info "Checking if rebuild is needed..."

    # Check if cvc_submitted_variants table exists
    local table_exists=$(bq query --use_legacy_sql=false --format=csv --quiet \
        "SELECT COUNT(*) FROM \`$PROJECT.clinvar_curator.INFORMATION_SCHEMA.TABLES\`
         WHERE table_name = 'cvc_submitted_variants'" 2>/dev/null | tail -1)

    if [ "$table_exists" = "0" ]; then
        log_info "Table cvc_submitted_variants does not exist. Rebuild needed."
        return 0
    fi

    # Check if there are new batches since last run
    local new_batches=$(bq query --use_legacy_sql=false --format=csv --quiet "
        SELECT COUNT(*) as new_batches
        FROM \`$PROJECT.clinvar_curator.cvc_clinvar_batches\` b
        WHERE NOT EXISTS (
            SELECT 1 FROM \`$PROJECT.clinvar_curator.cvc_submitted_variants\` sv
            WHERE sv.batch_id = b.batch_id
        )
    " 2>/dev/null | tail -1)

    if [ "$new_batches" != "0" ] && [ -n "$new_batches" ]; then
        log_info "Found $new_batches new batches. Rebuild needed."
        return 0
    fi

    # Check if there's new conflict resolution data
    local new_data=$(bq query --use_legacy_sql=false --format=csv --quiet "
        SELECT COUNT(*) as new_months
        FROM \`$PROJECT.clinvar_ingest.monthly_conflict_snapshots\` mcs
        WHERE mcs.snapshot_release_date >= '2023-09-01'
          AND NOT EXISTS (
            SELECT 1 FROM \`$PROJECT.clinvar_curator.cvc_impact_summary\` cis
            WHERE cis.snapshot_release_date = mcs.snapshot_release_date
          )
    " 2>/dev/null | tail -1)

    if [ "$new_data" != "0" ] && [ -n "$new_data" ]; then
        log_info "Found $new_data new monthly snapshots. Rebuild needed."
        return 0
    fi

    # Check if TSV files have been updated (different row count than tables)
    local rejected_scvs_file="$SCRIPT_DIR/rejected-scvs.tsv"

    if [ -f "$rejected_scvs_file" ]; then
        local file_lines=$(grep -v "^#" "$rejected_scvs_file" | grep -v "^$" | wc -l | tr -d ' ')
        local table_rows=$(bq query --use_legacy_sql=false --format=csv --quiet \
            "SELECT COUNT(*) FROM \`$PROJECT.clinvar_curator.cvc_rejected_scvs\`" 2>/dev/null | tail -1)
        if [ "$file_lines" != "$table_rows" ] 2>/dev/null; then
            log_info "rejected-scvs.tsv has different row count than table ($file_lines vs $table_rows). Rebuild needed."
            return 0
        fi
    fi

    log_info "No new data detected. Rebuild not needed."
    return 1
}

main() {
    echo ""
    echo "=========================================="
    echo "  CVC Impact Analysis Pipeline"
    echo "=========================================="
    echo ""
    log_info "Project: $PROJECT"
    log_info "Script directory: $SCRIPT_DIR"
    echo ""

    # Check if rebuild is needed
    if [ "$CHECK_ONLY" = true ]; then
        if check_rebuild_needed; then
            exit 0
        else
            exit 1
        fi
    fi

    if [ "$FORCE" = false ]; then
        if ! check_rebuild_needed; then
            log_info "Use --force to rebuild anyway."
            exit 0
        fi
    else
        log_warn "Force rebuild requested."
    fi

    echo ""
    log_info "Starting pipeline execution..."
    echo ""

    # =========================================================================
    # Phase 1: Load TSV data files
    # =========================================================================
    if [ "$SKIP_LOAD" = false ]; then
        echo "----------------------------------------"
        echo "Phase 1: Loading data files"
        echo "----------------------------------------"
        echo ""

        # Load rejected SCVs
        run_loader "$SCRIPT_DIR/load-rejected-scvs.sh" \
            "Loading rejected-scvs.tsv"
        echo ""
    else
        log_warn "Skipping TSV file loading (--skip-load specified)"
        echo ""
    fi

    # =========================================================================
    # Phase 2: Core Impact Analysis (uses cvc_submitted_outcomes_view)
    # =========================================================================
    echo "----------------------------------------"
    echo "Phase 2: Core Impact Analysis"
    echo "----------------------------------------"
    echo ""

    # Step 1: Create CVC submitted variants table
    run_query "$SCRIPT_DIR/01-cvc-submitted-variants.sql" \
        "Step 1: Building CVC submitted variants table"
    echo ""

    # Step 2: Create conflict attribution tables
    run_query "$SCRIPT_DIR/02-cvc-conflict-attribution.sql" \
        "Step 2: Building conflict attribution tables"
    echo ""

    # Step 3: Create impact analytics and views
    run_query "$SCRIPT_DIR/03-cvc-impact-analytics.sql" \
        "Step 3: Building impact analytics and views"
    echo ""

    # =========================================================================
    # Phase 3: Flagging Candidate Analysis (uses cvc_batches_enriched, cvc_rejected_scvs)
    # =========================================================================
    echo "----------------------------------------"
    echo "Phase 3: Flagging Candidate Analysis"
    echo "----------------------------------------"
    echo ""

    # Step 0: Create batch enriched view (uses batch_end_date from cvc_clinvar_batches directly)
    run_query "$SCRIPT_DIR/00-cvc-batch-enriched-view.sql" \
        "Step 0: Creating batch enriched view (cvc_batches_enriched)"
    echo ""

    # Step 4: Track flagging candidate outcomes
    run_query "$SCRIPT_DIR/04-flagging-candidate-outcomes.sql" \
        "Step 4: Tracking flagging candidate outcomes"
    echo ""

    # Step 5: Detect version bumps (independent - scans all SCVs)
    run_query "$SCRIPT_DIR/05-version-bump-detection.sql" \
        "Step 5: Detecting version bumps"
    echo ""

    # Step 6: Version bump + flagging intersection
    run_query "$SCRIPT_DIR/06-version-bump-flagging-intersection.sql" \
        "Step 6: Analyzing version bump and flagging intersection"
    echo ""

    # Step 7: Identify resubmission candidates
    run_query "$SCRIPT_DIR/07-resubmission-candidates.sql" \
        "Step 7: Identifying resubmission candidates"
    echo ""

    # Step 8: Identify auto-reflag candidates (7 target labs)
    run_query "$SCRIPT_DIR/08-autoreflag-candidates.sql" \
        "Step 8: Identifying auto-reflag candidates"
    echo ""

    # =========================================================================
    # Summary
    # =========================================================================
    echo "=========================================="
    log_info "Pipeline completed successfully!"
    echo "=========================================="
    echo ""

    # Show summary statistics
    if [ "$DRY_RUN" = false ]; then
        log_info "Summary Statistics:"
        echo ""
        bq query --use_legacy_sql=false --format=pretty "
            SELECT 'CVC Submissions' AS metric,
                   (SELECT COUNT(*) FROM \`$PROJECT.clinvar_curator.cvc_submitted_variants\`) AS count
            UNION ALL
            SELECT 'Unique Variants Targeted',
                   (SELECT COUNT(DISTINCT variation_id) FROM \`$PROJECT.clinvar_curator.cvc_submitted_variants\`)
            UNION ALL
            SELECT 'Resolutions Analyzed',
                   (SELECT COUNT(*) FROM \`$PROJECT.clinvar_curator.cvc_resolution_attribution\`)
            UNION ALL
            SELECT 'CVC-Attributed Resolutions',
                   (SELECT COUNT(*) FROM \`$PROJECT.clinvar_curator.cvc_resolution_attribution\` WHERE variant_attribution = 'cvc_attributed')
            UNION ALL
            SELECT 'Flagging Candidates Tracked',
                   (SELECT COUNT(*) FROM \`$PROJECT.clinvar_curator.cvc_flagging_candidate_outcomes\`)
            UNION ALL
            SELECT 'Version Bumps Detected',
                   (SELECT COUNTIF(is_version_bump) FROM \`$PROJECT.clinvar_curator.cvc_version_bumps\`)
            UNION ALL
            SELECT 'Resubmission Candidates',
                   (SELECT COUNT(*) FROM \`$PROJECT.clinvar_curator.cvc_resubmission_candidates\`)
            UNION ALL
            SELECT 'Auto-Reflag Candidates',
                   (SELECT COUNTIF(is_autoreflag_candidate) FROM \`$PROJECT.clinvar_curator.cvc_autoreflag_candidates\`)
        "
    fi
}

main
