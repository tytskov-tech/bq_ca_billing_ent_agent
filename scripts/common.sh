#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${PROJECT_ROOT}/config/config.env}"
PREVIEW="${PREVIEW:-false}"

log_info() {
  echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log_preview() {
  echo "[PREVIEW] $*"
}

log_warn() {
  echo "[Warning] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_error() {
  echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --preview|preview|-p|--dry-run)
        PREVIEW="true"
        export PREVIEW
        shift
        ;;
      --agent-id|-a)
        if [[ -z "${2:-}" ]]; then
          log_error "--agent-id requires a value."
          exit 1
        fi
        CLI_CA_AGENT_ID="$2"
        export CLI_CA_AGENT_ID
        shift 2
        ;;
      -h|--help)
        echo "Usage: $(basename "$0") [--preview|-p|preview] [--agent-id|-a <agent_id>]"
        echo "  --preview, -p, preview      Print all commands and rendered SQL/JSON without executing them."
        echo "  --agent-id, -a <agent_id>   Override CA_AGENT_ID (default: enterprise_billing_agent)."
        exit 0
        ;;
      *)
        log_error "Unknown argument: $1"
        echo "Usage: $(basename "$0") [--preview|-p|preview] [--agent-id|-a <agent_id>]" >&2
        exit 1
        ;;
    esac
  done
}

# Portable template renderer (replaces ${VAR} placeholders from environment variables)
render_template() {
  local tmpl_file="$1"
  shift
  python3 - "${tmpl_file}" "$@" <<'PYEOF'
import os
import sys

tmpl_path = sys.argv[1]
var_names = sys.argv[2:]

with open(tmpl_path, "r", encoding="utf-8") as f:
    content = f.read()

for var in var_names:
    val = os.environ.get(var, "")
    content = content.replace(f"${{{var}}}", val)

sys.stdout.write(content)
PYEOF
}

# Renders a SQL template and strips leading template comment lines (`-- ...`) for clean UNION ALL SELECT blocks
render_sql_block() {
  render_template "$@" | sed '/^[[:space:]]*--/d'
}

ensure_gcp_auth() {
  if [[ "${GCP_AUTH_VERIFIED:-false}" == "true" ]]; then
    return 0
  fi

  if CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud auth print-access-token >/dev/null 2>&1; then
    export GCP_AUTH_VERIFIED="true"
    return 0
  fi

  local active_account
  active_account="${CLOUDSDK_CORE_ACCOUNT:-$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud config get-value account 2>/dev/null || true)}"

  log_warn "GCP authentication token${active_account:+ for '${active_account}'} is expired or requires reauthentication."
  log_info "Initiating GCP reauthentication via browser${active_account:+ for '${active_account}'}..."

  if [[ -n "${active_account}" ]]; then
    CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud auth revoke "${active_account}" >/dev/null 2>&1 || true
    gcloud auth login "${active_account}" --brief
  else
    gcloud auth login --brief
  fi

  if ! CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud auth print-access-token >/dev/null 2>&1; then
    log_error "GCP authentication failed. Please run: gcloud auth login ${active_account}"
    exit 1
  fi

  export GCP_AUTH_VERIFIED="true"
}

load_config() {
  # Ensure config/config.env is always excluded in local Git metadata even without a tracked .gitignore
  local git_exclude="${PROJECT_ROOT}/.git/info/exclude"
  if [[ -d "${PROJECT_ROOT}/.git/info" ]]; then
    if ! grep -qxF "config/config.env" "${git_exclude}" 2>/dev/null; then
      printf "\nconfig/config.env\n" >> "${git_exclude}"
    fi
  fi

  if [[ ! -f "${CONFIG_FILE}" && -f "${HOME}/.config/billing_ent_agent/config.env" ]]; then
    CONFIG_FILE="${HOME}/.config/billing_ent_agent/config.env"
  fi

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    if [[ "${PREVIEW}" == "true" && -f "${PROJECT_ROOT}/config/config.env.example" ]]; then
      log_preview "config/config.env not found; falling back to config/config.env.example for preview mode."
      CONFIG_FILE="${PROJECT_ROOT}/config/config.env.example"
    else
      log_error "Configuration file not found at: ${CONFIG_FILE}"
      log_error "Copy config/config.env.example to config/config.env (or ~/.config/billing_ent_agent/config.env) and populate your values."
      exit 1
    fi
  fi
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"

  : "${PROJECT_ID:?PROJECT_ID must be set in config.env}"
  : "${BQ_LOCATION:?BQ_LOCATION must be set in config.env}"
  : "${ENT_DATASET:?ENT_DATASET must be set in config.env}"

  # Ensure GCP authentication token is valid before making any bq/gcloud calls
  ensure_gcp_auth

  # Normalize BILLING_ACCOUNTS entries: support both "BA_ID:PROJECT_ID:DATASET" and "PROJECT_ID:DATASET"
  if [[ -n "${NORMALIZED_BILLING_ACCOUNTS_STR:-}" ]]; then
    IFS=' ' read -r -a BILLING_ACCOUNTS <<< "${NORMALIZED_BILLING_ACCOUNTS_STR}"
  elif [[ -n "${BILLING_ACCOUNTS[*]:-}" ]]; then
    local normalized_bas=()
    for entry in "${BILLING_ACCOUNTS[@]}"; do
      local colons="${entry//[^:]/}"
      if [[ "${#colons}" -eq 1 ]]; then
        local ba_proj ba_ds discovered_ba_id=""
        IFS=':' read -r ba_proj ba_ds <<< "${entry}"
        log_info "Auto-discovering Billing Account ID (gcp_billing_export_v1_<BA>) in ${ba_proj}:${ba_ds}..."
        discovered_ba_id="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 bq --project_id="${PROJECT_ID}" ls --max_results=1000 --format=json "${ba_proj}:${ba_ds}" 2>/dev/null | python3 -c '
import json, re, sys
try:
    tables = json.load(sys.stdin)
    for t in tables:
        tid = t.get("tableReference", {}).get("tableId", "")
        m = re.match(r"^gcp_billing_export_v1_([A-Za-z0-9_]+)$", tid)
        if m:
            print(m.group(1))
            sys.exit(0)
except Exception:
    pass
' || true)"
        if [[ -n "${discovered_ba_id}" ]]; then
          log_info "Discovered Billing Account ID '${discovered_ba_id}' in ${ba_proj}:${ba_ds}."
          normalized_bas+=("${discovered_ba_id}:${ba_proj}:${ba_ds}")
        else
          normalized_bas+=("<BA_ID>:${ba_proj}:${ba_ds}")
        fi
      else
        normalized_bas+=("${entry}")
      fi
    done
    BILLING_ACCOUNTS=("${normalized_bas[@]}")
    export NORMALIZED_BILLING_ACCOUNTS_STR="${BILLING_ACCOUNTS[*]}"
  fi
}

run_bq_sql() {
  local sql_content="$1"
  local description="${2:-Executing BigQuery SQL}"
  log_info "${description}..."

  if [[ "${PREVIEW}" == "true" ]]; then
    log_preview "Would execute command:"
    cat <<PREVIEW_EOF
--------------------------------------------------------------------------------
bq query \\
  --project_id="${PROJECT_ID}" \\
  --location="${BQ_LOCATION}" \\
  --use_legacy_sql=false <<'EOF'
${sql_content}
EOF
--------------------------------------------------------------------------------
PREVIEW_EOF
    return 0
  fi

  bq query \
    --project_id="${PROJECT_ID}" \
    --location="${BQ_LOCATION}" \
    --use_legacy_sql=false <<< "${sql_content}"
}

# Applies column and nested RECORD field descriptions from a reference JSON schema file
# to an existing BigQuery view.
apply_view_schema_descriptions() {
  local view_name="$1"
  local ref_schema_file="$2"
  local target_view="${PROJECT_ID}:${ENT_DATASET}.${view_name}"

  if [[ ! -f "${ref_schema_file}" ]]; then
    log_error "Reference schema JSON file not found: ${ref_schema_file}"
    exit 1
  fi

  log_info "Applying field descriptions from $(basename "${ref_schema_file}") to view ${target_view}..."

  if [[ "${PREVIEW}" == "true" ]]; then
    log_preview "Would fetch live schema, merge descriptions from ${ref_schema_file}, and update view:"
    cat <<EOF
--------------------------------------------------------------------------------
bq --project_id="${PROJECT_ID}" show --schema --format=prettyjson "${target_view}" > /tmp/bq_live_schema.json
# Merge column & nested RECORD descriptions from ${ref_schema_file} -> /tmp/bq_merged_schema.json
bq --project_id="${PROJECT_ID}" update "${target_view}" /tmp/bq_merged_schema.json
--------------------------------------------------------------------------------
EOF
    return 0
  fi

  local tmp_live_schema
  local tmp_merged_schema
  tmp_live_schema="$(mktemp /tmp/bq_live_schema_XXXXXX.json)"
  tmp_merged_schema="$(mktemp /tmp/bq_merged_schema_XXXXXX.json)"
  trap 'rm -f "${tmp_live_schema}" "${tmp_merged_schema}"' RETURN

  # Fetch the current view schema from BigQuery
  bq --project_id="${PROJECT_ID}" show \
    --schema \
    --format=prettyjson \
    "${target_view}" > "${tmp_live_schema}"

  # Merge descriptions recursively (matching by field name) so nested RECORD fields
  # and top-level columns receive their descriptions without schema mismatch errors.
  python3 - "${tmp_live_schema}" "${ref_schema_file}" "${tmp_merged_schema}" <<'PYEOF'
import json
import sys

live_path, ref_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(live_path, "r", encoding="utf-8") as f:
    live_schema = json.load(f)

with open(ref_path, "r", encoding="utf-8") as f:
    ref_schema = json.load(f)

def build_ref_map(fields):
    mapping = {}
    for field in fields:
        name = field.get("name")
        if name:
            mapping[name] = field
    return mapping

def merge_descriptions(live_fields, ref_fields):
    ref_map = build_ref_map(ref_fields)
    for field in live_fields:
        name = field.get("name")
        ref_field = ref_map.get(name)
        if not ref_field:
            continue
        if "description" in ref_field and ref_field["description"]:
            field["description"] = ref_field["description"]
        if "fields" in field and "fields" in ref_field:
            merge_descriptions(field["fields"], ref_field["fields"])

merge_descriptions(live_schema, ref_schema)

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(live_schema, f, indent=2)
PYEOF

  bq --project_id="${PROJECT_ID}" update \
    "${target_view}" \
    "${tmp_merged_schema}"

  log_info "Successfully updated column descriptions on ${target_view}."
}

# Authorizes one or more views/materialized views (BQ Data Viewer access) on a target BigQuery dataset.
# Usage: authorize_views_on_dataset <target_project_id> <target_dataset_id> "view_proj:view_ds:view_name" ...
authorize_views_on_dataset() {
  local target_project="$1"
  local target_dataset="$2"
  shift 2
  local view_specs=("$@")
  local ds_ref="${target_project}:${target_dataset}"

  log_info "Authorizing views on dataset ${ds_ref}: ${view_specs[*]}..."

  if [[ "${PREVIEW}" == "true" ]]; then
    log_preview "Would authorize views on dataset ${ds_ref}:"
    cat <<EOF
--------------------------------------------------------------------------------
bq --project_id="${target_project}" show --format=prettyjson "${ds_ref}" > /tmp/bq_dataset.json
# Merge authorized view entries into dataset .access array:
EOF
    for spec in "${view_specs[@]}"; do
      IFS=':' read -r vp vd vt <<< "${spec}"
      echo "#   { \"view\": { \"projectId\": \"${vp}\", \"datasetId\": \"${vd}\", \"tableId\": \"${vt}\" } }"
    done
    cat <<EOF
bq --project_id="${target_project}" update --source /tmp/bq_dataset.json "${ds_ref}"
--------------------------------------------------------------------------------
EOF
    return 0
  fi

  local tmp_ds_json
  tmp_ds_json="$(mktemp /tmp/bq_dataset_XXXXXX.json)"
  trap 'rm -f "${tmp_ds_json}"' RETURN

  bq --project_id="${target_project}" show --format=prettyjson "${ds_ref}" > "${tmp_ds_json}"

  python3 - "${tmp_ds_json}" "${view_specs[@]}" <<'PYEOF'
import json
import sys

ds_path = sys.argv[1]
specs = sys.argv[2:]

with open(ds_path, "r", encoding="utf-8") as f:
    ds_data = json.load(f)

access_list = ds_data.get("access", [])

for spec in specs:
    vp, vd, vt = spec.split(":", 2)
    entry = {
        "view": {
            "projectId": vp,
            "datasetId": vd,
            "tableId": vt,
        }
    }
    if not any(
        item.get("view", {}).get("projectId") == vp
        and item.get("view", {}).get("datasetId") == vd
        and item.get("view", {}).get("tableId") == vt
        for item in access_list
    ):
        access_list.append(entry)

ds_data["access"] = access_list

with open(ds_path, "w", encoding="utf-8") as f:
    json.dump(ds_data, f, indent=2)
PYEOF

  bq --project_id="${target_project}" update --source "${tmp_ds_json}" "${ds_ref}"
  log_info "Successfully authorized views on dataset ${ds_ref}."
}

# Checks whether a BigQuery table or view exists and is accessible.
# Usage: check_bq_table_exists <target_project_id> <target_dataset_id> <target_table_id>
check_bq_table_exists() {
  local target_project="$1"
  local target_dataset="$2"
  local target_table="$3"
  local table_ref="${target_project}:${target_dataset}.${target_table}"
  local bq_out

  if bq_out="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 bq --project_id="${PROJECT_ID}" show "${table_ref}" 2>&1)"; then
    return 0
  fi

  if [[ "${bq_out}" == *"Reauthentication"* ]] || [[ "${bq_out}" == *"gcloud auth login"* ]] || [[ "${bq_out}" == *"invalid_grant"* ]]; then
    log_error "GCP authentication token is expired or requires reauthentication:"
    log_error "${bq_out}"
    log_error "Please run: gcloud auth login ${CLOUDSDK_CORE_ACCOUNT:-}"
    exit 1
  fi

  return 1
}

# Verifies that the mandatory gcp_billing_export_v1_<BA> table exists and is accessible.
# Halts installation immediately (exit 1) if missing or inaccessible.
# Usage: require_ba_standard_table <ba_id> <ba_project_id> <ba_dataset_id>
require_ba_standard_table() {
  local ba_id="$1"
  local ba_project="$2"
  local ba_dataset="$3"
  local std_table="gcp_billing_export_v1_${ba_id}"
  local full_ref="${ba_project}:${ba_dataset}.${std_table}"

  log_info "Verifying mandatory billing table ${full_ref} (Billing Account: ${ba_id})..."
  if ! check_bq_table_exists "${ba_project}" "${ba_dataset}" "${std_table}"; then
    log_error "Mandatory table '${full_ref}' is not present or is inaccessible."
    log_error "Halting installation: Each Billing Account MUST include '${std_table}'."
    log_error "Please enable Standard Usage Cost Export and verify IAM permissions by following the procedure in README.md ('Enabling Required BigQuery Export Tables')."
    exit 1
  fi
  log_info "Verified mandatory table: ${full_ref}"
}

# Verifies whether a non-mandatory export table exists and is accessible.
# Logs a warning message advising the customer to follow the documentation if missing, and returns 1 (without halting).
# Usage: check_optional_table <target_project_id> <target_dataset_id> <target_table_id> <table_label>
check_optional_table() {
  local target_project="$1"
  local target_dataset="$2"
  local target_table="$3"
  local table_label="${4:-${target_table}}"
  local full_ref="${target_project}:${target_dataset}.${target_table}"

  log_info "Verifying table availability: ${full_ref} (${table_label})..."
  if ! check_bq_table_exists "${target_project}" "${target_dataset}" "${target_table}"; then
    log_warn "Optional table '${full_ref}' (${table_label}) is not present or is inaccessible."
    log_warn "Action Recommended: Please create/enable '${target_table}' in '${target_project}:${target_dataset}' by following the procedure outlined in the documentation (README.md -> 'Enabling Required BigQuery Export Tables'). Without this table the agent answers will be less informative."
    return 1
  fi
  log_info "Verified table: ${full_ref}"
  return 0
}

# Runs a full preflight check across all configured Billing Accounts and Recommendations sources.
# Halts if any gcp_billing_export_v1_<BA> table is missing; logs actionable warning guidance for any other missing tables.
verify_all_source_tables() {
  log_info "Verifying availability of all configured BigQuery source export tables..."

  for entry in "${BILLING_ACCOUNTS[@]}"; do
    IFS=':' read -r BA_ID BA_PROJECT_ID BA_DATASET <<< "${entry}"
    # 1. Mandatory table: gcp_billing_export_v1_<BA> (halts on failure)
    require_ba_standard_table "${BA_ID}" "${BA_PROJECT_ID}" "${BA_DATASET}"

    # 2. Other BA tables: report warning advising customer to follow documentation if missing
    check_optional_table "${BA_PROJECT_ID}" "${BA_DATASET}" "gcp_billing_export_resource_v1_${BA_ID}" "Detailed Resource Usage Export for BA ${BA_ID}" || true
    check_optional_table "${BA_PROJECT_ID}" "${BA_DATASET}" "cloud_pricing_export" "Cloud Billing Pricing Export for BA ${BA_ID}" || true
  done

  for rec_entry in "${RECOMMENDATIONS_SOURCES[@]}"; do
    IFS=':' read -r REC_PROJECT_ID REC_DATASET REC_TABLE <<< "${rec_entry}"
    check_optional_table "${REC_PROJECT_ID}" "${REC_DATASET}" "${REC_TABLE}" "Active Assist Recommendations Export" || true
  done
}

# Grants BigQuery Data Viewer IAM role on a specific view in ENT_DATASET to a user.
# Usage: grant_view_data_viewer <user_email> <view_name>
grant_view_data_viewer() {
  local user_email="$1"
  local view_name="$2"
  local view_ref="${PROJECT_ID}:${ENT_DATASET}.${view_name}"

  log_info "Granting roles/bigquery.dataViewer on view ${view_ref} to user:${user_email}..."

  if [[ "${PREVIEW}" == "true" ]]; then
    log_preview "Would execute command:"
    cat <<EOF
--------------------------------------------------------------------------------
bq --project_id="${PROJECT_ID}" add-iam-policy-binding \\
  --member="user:${user_email}" \\
  --role="roles/bigquery.dataViewer" \\
  "${view_ref}"
--------------------------------------------------------------------------------
EOF
    return 0
  fi

  if ! check_bq_table_exists "${PROJECT_ID}" "${ENT_DATASET}" "${view_name}"; then
    log_warn "View '${view_ref}' does not exist. Skipping IAM binding for '${view_name}'."
    log_warn "Action Recommended: Please create/enable the underlying export table(s) by following the procedure in README.md ('Enabling Required BigQuery Export Tables') and re-run ./scripts/03_create_ent_views.sh. Without this table the agent answers will be less informative."
    return 0
  fi

  bq --project_id="${PROJECT_ID}" add-iam-policy-binding \
    --member="user:${user_email}" \
    --role="roles/bigquery.dataViewer" \
    "${view_ref}"
}

# Removes BigQuery Data Viewer IAM role on a specific view in ENT_DATASET from a user.
# Usage: revoke_view_data_viewer <user_email> <view_name>
revoke_view_data_viewer() {
  local user_email="$1"
  local view_name="$2"
  local view_ref="${PROJECT_ID}:${ENT_DATASET}.${view_name}"

  log_info "Removing roles/bigquery.dataViewer on view ${view_ref} from user:${user_email}..."

  if [[ "${PREVIEW}" == "true" ]]; then
    log_preview "Would execute command:"
    cat <<EOF
--------------------------------------------------------------------------------
bq --project_id="${PROJECT_ID}" remove-iam-policy-binding \\
  --member="user:${user_email}" \\
  --role="roles/bigquery.dataViewer" \\
  "${view_ref}"
--------------------------------------------------------------------------------
EOF
    return 0
  fi

  if ! check_bq_table_exists "${PROJECT_ID}" "${ENT_DATASET}" "${view_name}"; then
    log_warn "View '${view_ref}' does not exist. Skipping IAM removal for '${view_name}'."
    return 0
  fi

  bq --project_id="${PROJECT_ID}" remove-iam-policy-binding \
    --member="user:${user_email}" \
    --role="roles/bigquery.dataViewer" \
    "${view_ref}" || log_info "No existing roles/bigquery.dataViewer binding for user:${user_email} on ${view_ref}."
}

# Grants roles/bigquery.jobUser on the host project (PROJECT_ID) so the user can execute BigQuery query jobs.
# Note: In GCP IAM, roles/bigquery.jobUser (bigquery.jobs.create) is a project-level role and does not grant data access to any dataset/table.
# Usage: grant_project_job_user <user_email>
grant_project_job_user() {
  local user_email="$1"

  log_info "Granting roles/bigquery.jobUser on project ${PROJECT_ID} (for dataset ${ENT_DATASET} queries) to user:${user_email}..."

  if [[ "${PREVIEW}" == "true" ]]; then
    log_preview "Would execute command:"
    cat <<EOF
--------------------------------------------------------------------------------
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \\
  --member="user:${user_email}" \\
  --role="roles/bigquery.jobUser" \\
  --condition=None
--------------------------------------------------------------------------------
EOF
    return 0
  fi

  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="user:${user_email}" \
    --role="roles/bigquery.jobUser" \
    --condition=None >/dev/null
}

# Grants roles/geminidataanalytics.dataAgentUser on the BQ Conversational Analytics Data Agent to a user.
# Usage: grant_agent_user <user_email> [agent_id]
grant_agent_user() {
  local user_email="$1"
  local agent_id="${2:-${CA_AGENT_ID:-enterprise_billing_agent}}"
  local agent_location="${CA_AGENT_LOCATION:-global}"
  local agent_url="https://geminidataanalytics.googleapis.com/v1beta/projects/${PROJECT_ID}/locations/${agent_location}/dataAgents/${agent_id}"

  log_info "Granting roles/geminidataanalytics.dataAgentUser on Data Agent '${agent_id}' to user:${user_email}..."

  if [[ "${PREVIEW}" == "true" ]]; then
    log_preview "Would fetch and update IAM policy on Data Agent '${agent_id}':"
    cat <<EOF
--------------------------------------------------------------------------------
# 1. Fetch current Data Agent IAM policy:
curl -sS -X POST \\
  -H "Authorization: Bearer \$(gcloud auth print-access-token)" \\
  -H "Content-Type: application/json" \\
  -H "x-goog-user-project: ${PROJECT_ID}" \\
  "${agent_url}:getIamPolicy" \\
  -d '{}'

# 2. Add member "user:${user_email}" with role "roles/geminidataanalytics.dataAgentUser" and apply:
curl -sS -X POST \\
  -H "Authorization: Bearer \$(gcloud auth print-access-token)" \\
  -H "Content-Type: application/json" \\
  -H "x-goog-user-project: ${PROJECT_ID}" \\
  "${agent_url}:setIamPolicy" \\
  -d '{"policy": {"bindings": [{"role": "roles/geminidataanalytics.dataAgentUser", "members": ["user:${user_email}"]}]}}'
--------------------------------------------------------------------------------
EOF
    return 0
  fi

  local access_token
  access_token="$(gcloud auth print-access-token)"

  local current_policy
  current_policy="$(curl -sS -X POST \
    -H "Authorization: Bearer ${access_token}" \
    -H "Content-Type: application/json" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "${agent_url}:getIamPolicy" \
    -d '{}')"

  local set_policy_payload
  if ! set_policy_payload="$(python3 - "${user_email}" "${current_policy}" <<'PYEOF'
import json
import sys

user_email = sys.argv[1]
raw_policy = sys.argv[2]
member = f"user:{user_email}"
role = "roles/geminidataanalytics.dataAgentUser"

try:
    policy = json.loads(raw_policy)
except Exception as e:
    sys.stderr.write(f"Failed to parse getIamPolicy response: {raw_policy}\n")
    sys.exit(1)

if "error" in policy:
    err_msg = policy["error"].get("message", json.dumps(policy["error"]))
    sys.stderr.write(f"API error: {err_msg}\n")
    sys.exit(1)

bindings = policy.get("bindings", [])
found_role = False
for b in bindings:
    if b.get("role") == role:
        found_role = True
        members = b.get("members", [])
        if member not in members:
            members.append(member)
        b["members"] = members
        break

if not found_role:
    bindings.append({
        "role": role,
        "members": [member]
    })

policy["bindings"] = bindings
print(json.dumps({"policy": policy}))
PYEOF
  )"; then
    log_warn "Could not read IAM policy for Data Agent '${agent_id}'. Ensure the agent '${agent_id}' exists via ./scripts/04_provision_bq_ca_agent.sh."
    return 0
  fi

  local set_resp
  set_resp="$(curl -sS -X POST \
    -H "Authorization: Bearer ${access_token}" \
    -H "Content-Type: application/json" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "${agent_url}:setIamPolicy" \
    -d "${set_policy_payload}")"

  if echo "${set_resp}" | grep -q '"error"'; then
    log_warn "Failed to set IAM policy on Data Agent '${agent_id}': ${set_resp}"
    return 0
  fi

  log_info "Granted roles/geminidataanalytics.dataAgentUser on Data Agent '${agent_id}' to user:${user_email}."
}

# Removes roles/geminidataanalytics.dataAgentUser on the BQ Conversational Analytics Data Agent from a user.
# Usage: revoke_agent_user <user_email> [agent_id]
revoke_agent_user() {
  local user_email="$1"
  local agent_id="${2:-${CA_AGENT_ID:-enterprise_billing_agent}}"
  local agent_location="${CA_AGENT_LOCATION:-global}"
  local agent_url="https://geminidataanalytics.googleapis.com/v1beta/projects/${PROJECT_ID}/locations/${agent_location}/dataAgents/${agent_id}"

  log_info "Removing roles/geminidataanalytics.dataAgentUser on Data Agent '${agent_id}' from user:${user_email}..."

  if [[ "${PREVIEW}" == "true" ]]; then
    log_preview "Would fetch and remove user:${user_email} from IAM policy on Data Agent '${agent_id}':"
    cat <<EOF
--------------------------------------------------------------------------------
curl -sS -X POST \\
  -H "Authorization: Bearer \$(gcloud auth print-access-token)" \\
  -H "Content-Type: application/json" \\
  -H "x-goog-user-project: ${PROJECT_ID}" \\
  "${agent_url}:getIamPolicy" \\
  -d '{}'

# Remove member "user:${user_email}" from role "roles/geminidataanalytics.dataAgentUser" and apply via :setIamPolicy
--------------------------------------------------------------------------------
EOF
    return 0
  fi

  local access_token
  access_token="$(gcloud auth print-access-token)"

  local current_policy
  current_policy="$(curl -sS -X POST \
    -H "Authorization: Bearer ${access_token}" \
    -H "Content-Type: application/json" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "${agent_url}:getIamPolicy" \
    -d '{}')"

  local set_policy_payload
  if ! set_policy_payload="$(python3 - "${user_email}" "${current_policy}" <<'PYEOF'
import json
import sys

user_email = sys.argv[1]
raw_policy = sys.argv[2]
member = f"user:{user_email}"
role = "roles/geminidataanalytics.dataAgentUser"

try:
    policy = json.loads(raw_policy)
except Exception:
    sys.exit(1)

if "error" in policy:
    sys.exit(1)

bindings = policy.get("bindings", [])
new_bindings = []
for b in bindings:
    if b.get("role") == role:
        members = [m for m in b.get("members", []) if m != member]
        if members:
            b["members"] = members
            new_bindings.append(b)
    else:
        new_bindings.append(b)

policy["bindings"] = new_bindings
print(json.dumps({"policy": policy}))
PYEOF
  )"; then
    log_warn "Could not read IAM policy for Data Agent '${agent_id}'. Skipping agent IAM removal."
    return 0
  fi

  curl -sS -X POST \
    -H "Authorization: Bearer ${access_token}" \
    -H "Content-Type: application/json" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "${agent_url}:setIamPolicy" \
    -d "${set_policy_payload}" >/dev/null || true

  log_info "Removed roles/geminidataanalytics.dataAgentUser on Data Agent '${agent_id}' from user:${user_email}."
}


