#!/usr/bin/env bash
# ==============================================================================
# 03_create_ent_views.sh
# Creates the analytical views in the central `billing_ent` dataset:
#   1. billing_projects
#   2. gcp_billing_export_v1_all_ba (+ schema descriptions from json/billing_export_schema.json)
#   3. gcp_billing_export_resource_v1_all_ba (+ schema descriptions from json/billing_export_resource_schema.json)
#   4. recommendations_export_all_ba (+ schema descriptions from json/recommendations_export_schema.json)
#   5. cloud_pricing_export_all_ba (+ schema descriptions from json/cloud_pricing_export_schema.json)
#   6. Authorizes MV `projects`, `billing_projects`, and the 4 `*_all_ba` views on the appropriate datasets.
# Usage: ./scripts/03_create_ent_views.sh [--preview|-p|preview]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

parse_args "$@"
load_config

# 1. Verify mandatory gcp_billing_export_v1_<BA> tables first (halts immediately if any is missing)
for entry in "${BILLING_ACCOUNTS[@]}"; do
  IFS=':' read -r BA_ID BA_PROJECT_ID BA_DATASET <<< "${entry}"
  require_ba_standard_table "${BA_ID}" "${BA_PROJECT_ID}" "${BA_DATASET}"
done

# Track which optional views are created so dataset Authorized Views only reference existing views
CREATED_ENT_VIEWS=("billing_projects" "gcp_billing_export_v1_all_ba")
CREATED_RES_VIEW="false"
CREATED_PRC_VIEW="false"
CREATED_REC_VIEW="false"

# 2. Build billing_projects view
UNION_BA_PROJECTS_MV_QUERY=""
for entry in "${BILLING_ACCOUNTS[@]}"; do
  IFS=':' read -r BA_ID BA_PROJECT_ID BA_DATASET <<< "${entry}"
  if [[ -n "${UNION_BA_PROJECTS_MV_QUERY}" ]]; then
    UNION_BA_PROJECTS_MV_QUERY+="
    UNION ALL
"
  fi
  UNION_BA_PROJECTS_MV_QUERY+="    SELECT * FROM \`${BA_PROJECT_ID}.${BA_DATASET}.projects\`"
done
export PROJECT_ID ENT_DATASET USR_PRV_TABLE UNION_BA_PROJECTS_MV_QUERY

BP_TMPL="${PROJECT_ROOT}/sql/view_billing_projects.sql.tmpl"
RENDERED_BP_SQL="$(render_template "${BP_TMPL}" PROJECT_ID ENT_DATASET USR_PRV_TABLE UNION_BA_PROJECTS_MV_QUERY)"
run_bq_sql "${RENDERED_BP_SQL}" "Creating/updating view ${PROJECT_ID}.${ENT_DATASET}.billing_projects"

# 3. Build gcp_billing_export_v1_all_ba view from per-BA template & apply JSON schema descriptions
STD_TMPL="${PROJECT_ROOT}/sql/view_gcp_billing_export_v1_all_ba.sql.tmpl"
STD_UNION_BODY=""
for entry in "${BILLING_ACCOUNTS[@]}"; do
  IFS=':' read -r BA_ID BA_PROJECT_ID BA_DATASET <<< "${entry}"
  export BA_ID BA_PROJECT_ID BA_DATASET PROJECT_ID ENT_DATASET USR_PRV_TABLE
  if [[ -n "${STD_UNION_BODY}" ]]; then
    STD_UNION_BODY+="
    UNION ALL
"
  fi
  STD_UNION_BODY+="$(render_sql_block "${STD_TMPL}" BA_ID BA_PROJECT_ID BA_DATASET PROJECT_ID ENT_DATASET USR_PRV_TABLE)"
done

STD_SELECT_QUERY="SELECT *
FROM
  (
${STD_UNION_BODY}
  )"

RENDERED_STD_SQL="CREATE OR REPLACE VIEW \`${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_v1_all_ba\`
OPTIONS(
  description=\"Unified standard GCP billing export across all Billing Accounts, filtered by SESSION_USER() permissions via billing_projects\"
) AS
${STD_SELECT_QUERY};"
run_bq_sql "${RENDERED_STD_SQL}" "Creating/updating view ${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_v1_all_ba"
apply_view_schema_descriptions "gcp_billing_export_v1_all_ba" "${PROJECT_ROOT}/json/billing_export_schema.json"

# 4. Build gcp_billing_export_resource_v1_all_ba view (verify table availability per BA)
RES_TMPL="${PROJECT_ROOT}/sql/view_gcp_billing_export_resource_v1_all_ba.sql.tmpl"
RES_UNION_BODY=""
RES_SELECT_QUERY=""
for entry in "${BILLING_ACCOUNTS[@]}"; do
  IFS=':' read -r BA_ID BA_PROJECT_ID BA_DATASET <<< "${entry}"
  export BA_ID BA_PROJECT_ID BA_DATASET PROJECT_ID ENT_DATASET USR_PRV_TABLE
  if check_optional_table "${BA_PROJECT_ID}" "${BA_DATASET}" "gcp_billing_export_resource_v1_${BA_ID}" "Detailed Resource Usage Export for BA ${BA_ID}"; then
    if [[ -n "${RES_UNION_BODY}" ]]; then
      RES_UNION_BODY+="
    UNION ALL
"
    fi
    RES_UNION_BODY+="$(render_sql_block "${RES_TMPL}" BA_ID BA_PROJECT_ID BA_DATASET PROJECT_ID ENT_DATASET USR_PRV_TABLE)"
  fi
done

if [[ -n "${RES_UNION_BODY}" ]]; then
  RES_SELECT_QUERY="SELECT *
FROM
  (
${RES_UNION_BODY}
  )"
  RENDERED_RES_SQL="CREATE OR REPLACE VIEW \`${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba\`
OPTIONS(
  description=\"Unified resource-level GCP billing export across all Billing Accounts, filtered by SESSION_USER() permissions via billing_projects\"
) AS
${RES_SELECT_QUERY};"
  run_bq_sql "${RENDERED_RES_SQL}" "Creating/updating view ${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba"
  apply_view_schema_descriptions "gcp_billing_export_resource_v1_all_ba" "${PROJECT_ROOT}/json/billing_export_resource_schema.json"
  CREATED_ENT_VIEWS+=("gcp_billing_export_resource_v1_all_ba")
  CREATED_RES_VIEW="true"
else
  log_warn "Skipping creation of view '${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba' because no 'gcp_billing_export_resource_v1_<BA>' tables are currently available."
  log_warn "Action Recommended: Please create/enable the Detailed Usage Cost Export tables by following the procedure outlined in README.md ('Enabling Required BigQuery Export Tables') and re-run this script. Without this table the agent answers will be less informative."
fi

# 5. Build recommendations_export_all_ba view (verify table availability per source)
REC_TMPL="${PROJECT_ROOT}/sql/view_recommendations_export_all_ba.sql.tmpl"
REC_UNION_BODY=""
REC_SELECT_QUERY=""
for rec_entry in "${RECOMMENDATIONS_SOURCES[@]}"; do
  IFS=':' read -r REC_PROJECT_ID REC_DATASET REC_TABLE <<< "${rec_entry}"
  export REC_PROJECT_ID REC_DATASET REC_TABLE PROJECT_ID ENT_DATASET
  if check_optional_table "${REC_PROJECT_ID}" "${REC_DATASET}" "${REC_TABLE}" "Active Assist Recommendations Export"; then
    if [[ -n "${REC_UNION_BODY}" ]]; then
      REC_UNION_BODY+="
      UNION ALL
"
    fi
    REC_UNION_BODY+="$(render_sql_block "${REC_TMPL}" REC_PROJECT_ID REC_DATASET REC_TABLE PROJECT_ID ENT_DATASET)"
  fi
done

if [[ -n "${REC_UNION_BODY}" ]]; then
  REC_SELECT_QUERY="SELECT *
  FROM (
${REC_UNION_BODY}
  )"
  RENDERED_REC_SQL="CREATE OR REPLACE VIEW \`${PROJECT_ID}.${ENT_DATASET}.recommendations_export_all_ba\`
OPTIONS(
  description=\"Unified GCP Recommender export across all organizations, filtered by SESSION_USER() permissions via billing_projects\"
) AS
${REC_SELECT_QUERY};"
  run_bq_sql "${RENDERED_REC_SQL}" "Creating/updating view ${PROJECT_ID}.${ENT_DATASET}.recommendations_export_all_ba"
  apply_view_schema_descriptions "recommendations_export_all_ba" "${PROJECT_ROOT}/json/recommendations_export_schema.json"
  CREATED_ENT_VIEWS+=("recommendations_export_all_ba")
  CREATED_REC_VIEW="true"
else
  log_warn "Skipping creation of view '${PROJECT_ID}.${ENT_DATASET}.recommendations_export_all_ba' because no 'recommendations_export' tables are currently available."
  log_warn "Action Recommended: Please create/enable the Recommendations Export tables by following the procedure outlined in README.md ('Enabling Required BigQuery Export Tables') and re-run this script. Without this table the agent answers will be less informative."
fi

# 6. Build cloud_pricing_export_all_ba view (verify table availability per BA)
PRICING_TMPL="${PROJECT_ROOT}/sql/view_cloud_pricing_export_all_ba.sql.tmpl"
PRICING_UNION_BODY=""
PRICING_SELECT_QUERY=""
for entry in "${BILLING_ACCOUNTS[@]}"; do
  IFS=':' read -r BA_ID BA_PROJECT_ID BA_DATASET <<< "${entry}"
  export BA_ID BA_PROJECT_ID BA_DATASET PROJECT_ID ENT_DATASET USR_PRV_TABLE
  if check_optional_table "${BA_PROJECT_ID}" "${BA_DATASET}" "cloud_pricing_export" "Cloud Billing Pricing Export for BA ${BA_ID}"; then
    if [[ -n "${PRICING_UNION_BODY}" ]]; then
      PRICING_UNION_BODY+="
    UNION ALL
"
    fi
    PRICING_UNION_BODY+="$(render_sql_block "${PRICING_TMPL}" BA_ID BA_PROJECT_ID BA_DATASET PROJECT_ID ENT_DATASET USR_PRV_TABLE)"
  fi
done

if [[ -n "${PRICING_UNION_BODY}" ]]; then
  PRICING_SELECT_QUERY="SELECT *
  FROM (
${PRICING_UNION_BODY}
  )"
  RENDERED_PRICING_SQL="CREATE OR REPLACE VIEW \`${PROJECT_ID}.${ENT_DATASET}.cloud_pricing_export_all_ba\`
OPTIONS(
  description=\"Unified GCP Cloud Pricing export across all Billing Accounts, filtered by SESSION_USER() permissions via billing_projects\"
) AS
${PRICING_SELECT_QUERY};"
  run_bq_sql "${RENDERED_PRICING_SQL}" "Creating/updating view ${PROJECT_ID}.${ENT_DATASET}.cloud_pricing_export_all_ba"
  apply_view_schema_descriptions "cloud_pricing_export_all_ba" "${PROJECT_ROOT}/json/cloud_pricing_export_schema.json"
  CREATED_ENT_VIEWS+=("cloud_pricing_export_all_ba")
  CREATED_PRC_VIEW="true"
else
  log_warn "Skipping creation of view '${PROJECT_ID}.${ENT_DATASET}.cloud_pricing_export_all_ba' because no 'cloud_pricing_export' tables are currently available."
  log_warn "Action Recommended: Please create/enable the Cloud Billing Pricing Export tables by following the procedure outlined in README.md ('Enabling Required BigQuery Export Tables') and re-run this script. Without this table the agent answers will be less informative."
fi

# 7. Configure Dataset Authorized Views (BQ Data Viewer for MVs & Views on appropriate datasets)
log_info "Configuring Authorized Views (BQ Data Viewer) across central, Billing Account, and Recommendations datasets..."

# 7a. Central enterprise dataset (`billing_ent`): authorize billing_projects and created *_all_ba views
ENT_AUTH_SPECS=()
for vname in "${CREATED_ENT_VIEWS[@]}"; do
  ENT_AUTH_SPECS+=("${PROJECT_ID}:${ENT_DATASET}:${vname}")
done
authorize_views_on_dataset "${PROJECT_ID}" "${ENT_DATASET}" "${ENT_AUTH_SPECS[@]}"

# 7b. Each Billing Account export dataset: authorize MV `projects`, `billing_projects`, and created billing/pricing views
for entry in "${BILLING_ACCOUNTS[@]}"; do
  IFS=':' read -r BA_ID BA_PROJECT_ID BA_DATASET <<< "${entry}"
  BA_AUTH_SPECS=(
    "${BA_PROJECT_ID}:${BA_DATASET}:projects"
    "${PROJECT_ID}:${ENT_DATASET}:billing_projects"
    "${PROJECT_ID}:${ENT_DATASET}:gcp_billing_export_v1_all_ba"
  )
  if [[ "${CREATED_RES_VIEW}" == "true" ]]; then
    BA_AUTH_SPECS+=("${PROJECT_ID}:${ENT_DATASET}:gcp_billing_export_resource_v1_all_ba")
  fi
  if [[ "${CREATED_PRC_VIEW}" == "true" ]]; then
    BA_AUTH_SPECS+=("${PROJECT_ID}:${ENT_DATASET}:cloud_pricing_export_all_ba")
  fi
  authorize_views_on_dataset "${BA_PROJECT_ID}" "${BA_DATASET}" "${BA_AUTH_SPECS[@]}"
done

# 7c. Each Recommendations export dataset: authorize `billing_projects` and `recommendations_export_all_ba` (if created)
for rec_entry in "${RECOMMENDATIONS_SOURCES[@]}"; do
  IFS=':' read -r REC_PROJECT_ID REC_DATASET REC_TABLE <<< "${rec_entry}"
  REC_AUTH_SPECS=("${PROJECT_ID}:${ENT_DATASET}:billing_projects")
  if [[ "${CREATED_REC_VIEW}" == "true" ]]; then
    REC_AUTH_SPECS+=("${PROJECT_ID}:${ENT_DATASET}:recommendations_export_all_ba")
  fi
  authorize_views_on_dataset "${REC_PROJECT_ID}" "${REC_DATASET}" "${REC_AUTH_SPECS[@]}"
done

if [[ "${PREVIEW}" == "true" ]]; then
  echo ""
  log_preview "================================================================================"
  log_preview "DEMONSTRATION OF SELECT STATEMENTS TO BE USED IN ENTERPRISE VIEWS"
  log_preview "================================================================================"
  echo ""
  log_preview "1. View: \`${PROJECT_ID}.${ENT_DATASET}.billing_projects\`"
  cat <<EOF
--------------------------------------------------------------------------------
$(render_sql_block "${BP_TMPL}" PROJECT_ID ENT_DATASET USR_PRV_TABLE UNION_BA_PROJECTS_MV_QUERY)
--------------------------------------------------------------------------------
EOF
  echo ""
  log_preview "2. View: \`${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_v1_all_ba\`"
  cat <<EOF
--------------------------------------------------------------------------------
${STD_SELECT_QUERY};
--------------------------------------------------------------------------------
EOF
  echo ""
  log_preview "3. View: \`${PROJECT_ID}.${ENT_DATASET}.gcp_billing_export_resource_v1_all_ba\`"
  if [[ -n "${RES_SELECT_QUERY}" ]]; then
    cat <<EOF
--------------------------------------------------------------------------------
${RES_SELECT_QUERY};
--------------------------------------------------------------------------------
EOF
  else
    log_warn "View will NOT be created (no available gcp_billing_export_resource_v1_<BA> tables)."
  fi
  echo ""
  log_preview "4. View: \`${PROJECT_ID}.${ENT_DATASET}.recommendations_export_all_ba\`"
  if [[ -n "${REC_SELECT_QUERY}" ]]; then
    cat <<EOF
--------------------------------------------------------------------------------
${REC_SELECT_QUERY};
--------------------------------------------------------------------------------
EOF
  else
    log_warn "View will NOT be created (no available recommendations_export tables)."
  fi
  echo ""
  log_preview "5. View: \`${PROJECT_ID}.${ENT_DATASET}.cloud_pricing_export_all_ba\`"
  if [[ -n "${PRICING_SELECT_QUERY}" ]]; then
    cat <<EOF
--------------------------------------------------------------------------------
${PRICING_SELECT_QUERY};
--------------------------------------------------------------------------------
EOF
  else
    log_warn "View will NOT be created (no available cloud_pricing_export tables)."
  fi
  echo ""
fi

log_info "Step 03 completed successfully."
