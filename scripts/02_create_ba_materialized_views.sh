#!/usr/bin/env bash
# ==============================================================================
# 02_create_ba_materialized_views.sh
# Iterates over each configured Billing Account export dataset and creates
# the `projects` Materialized View inside each BA export dataset.
# Usage: ./scripts/02_create_ba_materialized_views.sh [--preview|-p|preview]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

parse_args "$@"
load_config

SQL_TMPL="${PROJECT_ROOT}/sql/mv_projects.sql.tmpl"
if [[ ! -f "${SQL_TMPL}" ]]; then
  log_error "Missing SQL template: ${SQL_TMPL}"
  exit 1
fi

for entry in "${BILLING_ACCOUNTS[@]}"; do
  IFS=':' read -r BA_ID BA_PROJECT_ID BA_DATASET <<< "${entry}"
  export BA_ID BA_PROJECT_ID BA_DATASET PROJECT_ID ENT_DATASET

  # Mandatory check: halt installation if gcp_billing_export_v1_<BA_ID> is missing or inaccessible
  require_ba_standard_table "${BA_ID}" "${BA_PROJECT_ID}" "${BA_DATASET}"

  log_info "Creating Materialized View 'projects' in ${BA_PROJECT_ID}.${BA_DATASET} (BA: ${BA_ID})..."
  RENDERED_SQL="$(render_template "${SQL_TMPL}" BA_ID BA_PROJECT_ID BA_DATASET PROJECT_ID ENT_DATASET)"

  run_bq_sql "${RENDERED_SQL}" "Materialized View ${BA_PROJECT_ID}.${BA_DATASET}.projects"
done

log_info "Step 02 completed successfully."
