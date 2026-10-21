#!/usr/bin/env bash
# ==============================================================================
# 04_provision_bq_ca_agent.sh
# Creates or updates the BigQuery Conversational Analytics (BQ CA) Data Agent
# via the Gemini Data Analytics API (geminidataanalytics.googleapis.com).
# Usage: ./scripts/04_provision_bq_ca_agent.sh [--preview|-p|preview]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

parse_args "$@"
load_config

: "${CA_AGENT_LOCATION:=global}"
if [[ -n "${CLI_CA_AGENT_ID:-}" ]]; then
  CA_AGENT_ID="${CLI_CA_AGENT_ID}"
fi
: "${CA_AGENT_ID:=enterprise_billing_agent}"
: "${CA_AGENT_DISPLAY_NAME:=Enterprise Multi-BA FinOps & Billing Agent}"
: "${CA_AGENT_DESCRIPTION:=Conversational Analytics agent for multi-Billing Account GCP cost, resource usage, pricing, and optimization recommendations.}"

SYS_INST_FILE="${PROJECT_ROOT}/json/agent_instructions.md"
if [[ ! -f "${SYS_INST_FILE}" ]]; then
  SYS_INST_FILE="${PROJECT_ROOT}/agent/system_instructions.md"
fi
GOLDEN_QUERIES_FILE="${PROJECT_ROOT}/json/golden_queries.md"
PAYLOAD_TMPL="${PROJECT_ROOT}/agent/data_agent_payload.json.tmpl"

if [[ ! -f "${SYS_INST_FILE}" || ! -f "${PAYLOAD_TMPL}" ]]; then
  log_error "Missing agent instruction (${SYS_INST_FILE}) or payload template (${PAYLOAD_TMPL})"
  exit 1
fi

if [[ ! -f "${GOLDEN_QUERIES_FILE}" ]]; then
  log_error "Missing golden queries file (${GOLDEN_QUERIES_FILE})"
  exit 1
fi

export PROJECT_ID ENT_DATASET CA_AGENT_DISPLAY_NAME CA_AGENT_DESCRIPTION

# Render variables inside agent_instructions.md and JSON-encode the string
RENDERED_SYS_INST="$(render_template "${SYS_INST_FILE}" PROJECT_ID ENT_DATASET)"
SYSTEM_INSTRUCTION_JSON="$(python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))' <<< "${RENDERED_SYS_INST}")"
export SYSTEM_INSTRUCTION_JSON

# Render variables inside golden_queries.md and parse into exampleQueries JSON array
RENDERED_GOLDEN_QUERIES="$(render_template "${GOLDEN_QUERIES_FILE}" PROJECT_ID ENT_DATASET)"
EXAMPLE_QUERIES_JSON="$(python3 -c '
import json, re, sys
content = sys.stdin.read()
pattern = re.compile(r"\d+\.\s*(?:#+\s*)?\*(.+?)\*\s*```sql\s*(.+?)\s*```", re.DOTALL)
queries = []
for m in pattern.finditer(content):
    question = " ".join(m.group(1).strip().split())
    sql = m.group(2).strip()
    queries.append({
        "naturalLanguageQuestion": question,
        "sqlQuery": sql,
    })
print(json.dumps(queries, indent=2))
' <<< "${RENDERED_GOLDEN_QUERIES}")"
export EXAMPLE_QUERIES_JSON

PAYLOAD_JSON="$(render_template "${PAYLOAD_TMPL}" PROJECT_ID ENT_DATASET CA_AGENT_DISPLAY_NAME CA_AGENT_DESCRIPTION SYSTEM_INSTRUCTION_JSON EXAMPLE_QUERIES_JSON)"

API_BASE="https://geminidataanalytics.googleapis.com/v1beta/projects/${PROJECT_ID}/locations/${CA_AGENT_LOCATION}/dataAgents"
AGENT_RESOURCE_URL="${API_BASE}/${CA_AGENT_ID}"

if [[ "${PREVIEW}" == "true" ]]; then
  log_preview "Would verify analytical views and create/update BQ CA Data Agent '${CA_AGENT_ID}' (with Verified Queries from json/golden_queries.md):"
  cat <<EOF
--------------------------------------------------------------------------------
gcloud services enable geminidataanalytics.googleapis.com --project="${PROJECT_ID}"

# Create (POST) or Update (PATCH) Data Agent '${CA_AGENT_ID}':
curl -sS -X POST \\
  -H "Authorization: Bearer \$(gcloud auth print-access-token)" \\
  -H "Content-Type: application/json" \\
  -H "x-goog-user-project: ${PROJECT_ID}" \\
  "${API_BASE}?dataAgentId=${CA_AGENT_ID}" \\
  -d '${PAYLOAD_JSON}'
--------------------------------------------------------------------------------
EOF
  log_info "Step 04 preview completed successfully."
  exit 0
fi

# Verify mandatory view gcp_billing_export_v1_all_ba exists
if ! check_bq_table_exists "${PROJECT_ID}" "${ENT_DATASET}" "gcp_billing_export_v1_all_ba"; then
  log_error "Mandatory view '${PROJECT_ID}:${ENT_DATASET}.gcp_billing_export_v1_all_ba' is not present or is inaccessible."
  log_error "Halting Agent provisioning: Please ensure 'gcp_billing_export_v1_<BA>' tables exist and run ./scripts/03_create_ent_views.sh first."
  exit 1
fi

# Verify optional views and keep only available views in tableReferences
AVAILABLE_VIEWS=("gcp_billing_export_v1_all_ba")
for opt_view in "gcp_billing_export_resource_v1_all_ba" "cloud_pricing_export_all_ba" "recommendations_export_all_ba"; do
  if check_bq_table_exists "${PROJECT_ID}" "${ENT_DATASET}" "${opt_view}"; then
    AVAILABLE_VIEWS+=("${opt_view}")
  else
    log_warn "View '${PROJECT_ID}:${ENT_DATASET}.${opt_view}' is not present."
    log_warn "Action Recommended: Please create/enable the required underlying export table(s) by following the procedure in README.md ('Enabling Required BigQuery Export Tables') and re-run ./scripts/03_create_ent_views.sh and ./scripts/04_provision_bq_ca_agent.sh. Without this table the agent answers will be less informative."
  fi
done

PAYLOAD_JSON="$(python3 - "${PAYLOAD_JSON}" "${AVAILABLE_VIEWS[@]}" <<'PYEOF'
import json
import sys

payload = json.loads(sys.argv[1])
allowed_views = set(sys.argv[2:])

pub_ctx = payload.get("dataAnalyticsAgent", {}).get("publishedContext", {})
refs = (
    pub_ctx
    .get("datasourceReferences", {})
    .get("bq", {})
    .get("tableReferences", [])
)
if refs:
    pub_ctx["datasourceReferences"]["bq"]["tableReferences"] = [
        r for r in refs if r.get("tableId") in allowed_views
    ]

if "gcp_billing_export_resource_v1_all_ba" not in allowed_views:
    for eq in pub_ctx.get("exampleQueries", []):
        if "sqlQuery" in eq:
            eq["sqlQuery"] = eq["sqlQuery"].replace(
                ".gcp_billing_export_resource_v1_all_ba",
                ".gcp_billing_export_v1_all_ba"
            )

print(json.dumps(payload, indent=2))
PYEOF
)"

log_info "Ensuring geminidataanalytics.googleapis.com API is enabled..."
gcloud services enable geminidataanalytics.googleapis.com --project="${PROJECT_ID}"

ACCESS_TOKEN="$(gcloud auth print-access-token)"

log_info "Checking if Data Agent '${CA_AGENT_ID}' already exists..."
HTTP_STATUS="$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "${AGENT_RESOURCE_URL}")"

if [[ "${HTTP_STATUS}" == "200" ]]; then
  log_info "Updating existing Data Agent '${CA_AGENT_ID}'..."
  curl -sS -X PATCH \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "${AGENT_RESOURCE_URL}?updateMask=displayName,description,dataAnalyticsAgent.publishedContext" \
    -d "${PAYLOAD_JSON}"
  echo ""
  log_info "Data Agent '${CA_AGENT_ID}' updated successfully."
else
  log_info "Creating new Data Agent '${CA_AGENT_ID}'..."
  curl -sS -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "${API_BASE}?dataAgentId=${CA_AGENT_ID}" \
    -d "${PAYLOAD_JSON}"
  echo ""
  log_info "Data Agent '${CA_AGENT_ID}' created successfully."
fi
