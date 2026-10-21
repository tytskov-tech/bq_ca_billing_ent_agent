#!/usr/bin/env bash
# ==============================================================================
# 01_create_datasets_and_tables.sh
# Creates the central `billing_ent` dataset (in the same region as BA exports)
# and the `usr-prv` user access control table.
# Usage: ./scripts/01_create_datasets_and_tables.sh [--preview|-p|preview]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

parse_args "$@"
load_config

log_info "Ensuring central dataset '${PROJECT_ID}:${ENT_DATASET}' exists in location '${BQ_LOCATION}'..."
if [[ "${PREVIEW}" == "true" ]]; then
  log_preview "Would check and create dataset if not exists:"
  cat <<EOF
--------------------------------------------------------------------------------
bq --project_id="${PROJECT_ID}" show --dataset "${PROJECT_ID}:${ENT_DATASET}" || \\
  bq --project_id="${PROJECT_ID}" --location="${BQ_LOCATION}" mk \\
    --dataset \\
    --description="Central Enterprise Multi-Billing Account Analytical Dataset" \\
    "${PROJECT_ID}:${ENT_DATASET}"
--------------------------------------------------------------------------------
EOF
else
  if ! bq --project_id="${PROJECT_ID}" show --dataset "${PROJECT_ID}:${ENT_DATASET}" >/dev/null 2>&1; then
    bq --project_id="${PROJECT_ID}" --location="${BQ_LOCATION}" mk \
      --dataset \
      --description="Central Enterprise Multi-Billing Account Analytical Dataset" \
      "${PROJECT_ID}:${ENT_DATASET}"
    log_info "Dataset '${PROJECT_ID}:${ENT_DATASET}' created."
  else
    log_info "Dataset '${PROJECT_ID}:${ENT_DATASET}' already exists."
  fi
fi

SQL_TMPL="${PROJECT_ROOT}/sql/table_usr_prv.sql.tmpl"
if [[ ! -f "${SQL_TMPL}" ]]; then
  log_error "Missing SQL template: ${SQL_TMPL}"
  exit 1
fi

export PROJECT_ID ENT_DATASET USR_PRV_TABLE
RENDERED_SQL="$(render_template "${SQL_TMPL}" PROJECT_ID ENT_DATASET USR_PRV_TABLE)"

run_bq_sql "${RENDERED_SQL}" "Creating/verifying table ${PROJECT_ID}.${ENT_DATASET}.${USR_PRV_TABLE}"
log_info "Step 01 completed successfully."
