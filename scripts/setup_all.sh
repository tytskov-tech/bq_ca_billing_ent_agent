#!/usr/bin/env bash
# ==============================================================================
# setup_all.sh
# Executes the complete provisioning pipeline for the Enterprise Billing Agent.
# Usage: ./scripts/setup_all.sh [--preview|-p|preview]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

parse_args "$@"
load_config

log_info "Starting full provisioning pipeline for Enterprise Billing Agent (PREVIEW=${PREVIEW})..."

# Preflight verification of source export tables across all Billing Accounts & Recommendations datasets
verify_all_source_tables

"${SCRIPT_DIR}/01_create_datasets_and_tables.sh" "$@"
"${SCRIPT_DIR}/02_create_ba_materialized_views.sh" "$@"
"${SCRIPT_DIR}/03_create_ent_views.sh" "$@"
"${SCRIPT_DIR}/04_provision_bq_ca_agent.sh" "$@"

log_info "All provisioning steps completed!"
