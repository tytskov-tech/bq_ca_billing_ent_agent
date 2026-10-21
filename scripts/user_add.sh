#!/usr/bin/env bash
# ==============================================================================
# user_add.sh
# Grants end-user IAM permissions:
#   1. roles/bigquery.dataViewer on the 4 analytical views ONLY:
#      - gcp_billing_export_v1_all_ba
#      - gcp_billing_export_resource_v1_all_ba
#      - cloud_pricing_export_all_ba
#      - recommendations_export_all_ba
#   2. roles/bigquery.jobUser on the host project (${PROJECT_ID})
#   3. roles/geminidataanalytics.dataAgentUser on the BQ CA Data Agent (${CA_AGENT_ID}, default: enterprise_billing_agent)
# And adds/updates one or more availability records for the user in `usr-prv`
# (project_id, folder obj_number, billing_id) with `date = CURRENT_TIMESTAMP()`
# and `status = true` (or `false` to temporarily disable the user).
#
# Usage Examples:
#   # Add user with multiple availability records (projects, folders, billing accounts):
#   ./scripts/user_add.sh --user alice@example.com \
#     --project my-project-1 --project my-project-2 \
#     --folder 123456789012 \
#     --billing-account 012345-6789AB-EF0123 \
#     --preview
#
#   # Temporarily disable a user (sets status=false and date=CURRENT_TIMESTAMP()):
#   ./scripts/user_add.sh --user alice@example.com --disable --preview
#
#   # Re-enable a user (sets status=true and date=CURRENT_TIMESTAMP()):
#   ./scripts/user_add.sh --user alice@example.com --enable --preview
#
#   # Delete a user (removes all records from usr-prv and revokes BQ Data Viewer on all 4 views):
#   ./scripts/user_add.sh --user alice@example.com --delete --preview
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

USER_EMAIL=""
STATUS="true"
MODE="upsert" # upsert | disable_all | enable_all | delete_user
PROJECTS=()
FOLDERS=()
BILLING_ACCOUNTS_ARGS=()
COMPOSITE_RECORDS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") --user <email> [options]

Options:
  -u, --user <email>              Google account email of the end user (required)
  --project <project_id>          Allowed GCP project_id (repeatable or comma-separated)
  --folder <obj_number>           Allowed GCP folder number (repeatable or comma-separated)
  --billing-account <billing_id>  Allowed Billing Account ID or 'ALL' (repeatable or comma-separated)
  --record <proj:folder:ba>       Composite record 'project_id:obj_number:billing_id' (repeatable)
  -a, --agent-id <agent_id>       Override CA_AGENT_ID (default: enterprise_billing_agent)
  --status <true|false>           Set record status (default: true)
  --disable                       Temporarily disable user (sets status=false, date=CURRENT_TIMESTAMP())
  --enable                        Re-enable user (sets status=true, date=CURRENT_TIMESTAMP())
  -d, --delete, --remove          Delete user: remove all records from usr-prv and revoke BQ Data Viewer from all agent views
  -p, --preview, preview          Print all IAM and SQL commands without executing them
  -h, --help                      Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)
      USER_EMAIL="${2:-}"
      shift 2
      ;;
    --project)
      IFS=',' read -r -a items <<< "${2:-}"
      PROJECTS+=("${items[@]}")
      shift 2
      ;;
    --folder)
      IFS=',' read -r -a items <<< "${2:-}"
      FOLDERS+=("${items[@]}")
      shift 2
      ;;
    --billing-account|--ba)
      IFS=',' read -r -a items <<< "${2:-}"
      BILLING_ACCOUNTS_ARGS+=("${items[@]}")
      shift 2
      ;;
    --record)
      COMPOSITE_RECORDS+=("${2:-}")
      shift 2
      ;;
    -a|--agent-id)
      CLI_CA_AGENT_ID="${2:-}"
      export CLI_CA_AGENT_ID
      shift 2
      ;;
    --status)
      STATUS="$(echo "${2:-}" | tr '[:upper:]' '[:lower:]')"
      if [[ "${STATUS}" != "true" && "${STATUS}" != "false" ]]; then
        log_error "--status must be 'true' or 'false'"
        exit 1
      fi
      shift 2
      ;;
    --disable)
      STATUS="false"
      MODE="disable_all"
      shift
      ;;
    --enable)
      STATUS="true"
      MODE="enable_all"
      shift
      ;;
    -d|--delete|--remove)
      MODE="delete_user"
      shift
      ;;
    -p|--preview|preview|--dry-run)
      PREVIEW="true"
      export PREVIEW
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "Unknown argument: $1"
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${USER_EMAIL}" ]]; then
  log_error "--user <email> is required."
  usage >&2
  exit 1
fi

load_config

if [[ -n "${CLI_CA_AGENT_ID:-}" ]]; then
  CA_AGENT_ID="${CLI_CA_AGENT_ID}"
fi
: "${CA_AGENT_ID:=enterprise_billing_agent}"

END_USER_VIEWS=(
  "gcp_billing_export_v1_all_ba"
  "gcp_billing_export_resource_v1_all_ba"
  "cloud_pricing_export_all_ba"
  "recommendations_export_all_ba"
)

# Deletes a user from the agent:
# 1. Removes roles/bigquery.dataViewer permissions from all 4 agent views
# 2. Removes roles/geminidataanalytics.dataAgentUser from the BQ CA Data Agent
# 3. Deletes all rows for the user from `${PROJECT_ID}.${ENT_DATASET}.${USR_PRV_TABLE}`
delete_user_from_agent() {
  local target_user="$1"

  log_info "Deleting user ${target_user} from Enterprise Billing Agent..."

  log_info "Removing IAM roles/bigquery.dataViewer on the 4 analytical views from ${target_user}..."
  for view_name in "${END_USER_VIEWS[@]}"; do
    revoke_view_data_viewer "${target_user}" "${view_name}"
  done

  revoke_agent_user "${target_user}" "${CA_AGENT_ID}"

  local escaped_user="${target_user//\'/\\\'}"
  local delete_sql="DELETE FROM \`${PROJECT_ID}.${ENT_DATASET}.${USR_PRV_TABLE}\`
WHERE
  user = '${escaped_user}';"

  run_bq_sql "${delete_sql}" "Deleting all records for user ${target_user} from ${PROJECT_ID}.${ENT_DATASET}.${USR_PRV_TABLE}"
  log_info "User ${target_user} deleted from ${PROJECT_ID}.${ENT_DATASET}.${USR_PRV_TABLE} and view permissions removed."
}

if [[ "${MODE}" == "delete_user" ]]; then
  delete_user_from_agent "${USER_EMAIL}"
  exit 0
fi

# Normalizes Billing Account IDs:
# - xxxxxx_xxxxxx_xxxxxx (or xxxxxx_xxxxx_xxxxxx) -> xxxxxx-xxxxxx-xxxxxx (or xxxxxx-xxxxx-xxxxxx)
# - 18-char unseparated (xxxxxxxxxxxxxxxxxx)      -> xxxxxx-xxxxxx-xxxxxx
# - 17-char unseparated (xxxxxxxxxxxxxxxxx)       -> xxxxxx-xxxxx-xxxxxx
normalize_billing_account_id() {
  local raw="$1"
  if [[ -z "${raw}" ]]; then
    echo ""
    return 0
  fi
  if [[ "$(echo "${raw}" | tr '[:lower:]' '[:upper:]')" == "ALL" ]]; then
    echo "ALL"
    return 0
  fi

  local normalized="${raw}"
  if [[ "${raw}" =~ ^[A-Za-z0-9]+_[A-Za-z0-9]+_[A-Za-z0-9]+$ ]]; then
    normalized="${raw//_/-}"
  elif [[ "${raw}" =~ ^[A-Za-z0-9]{18}$ ]]; then
    normalized="${raw:0:6}-${raw:6:6}-${raw:12:6}"
  elif [[ "${raw}" =~ ^[A-Za-z0-9]{17}$ ]]; then
    normalized="${raw:0:6}-${raw:6:5}-${raw:11:6}"
  fi

  if [[ "${normalized}" != "${raw}" ]]; then
    log_info "Normalized Billing Account ID '${raw}' -> '${normalized}'" >&2
  fi
  echo "${normalized}"
}

# Build list of (project_id, obj_number, billing_id) tuples if any scope flags were passed
RECORD_TUPLES=()
for p in "${PROJECTS[@]+"${PROJECTS[@]}"}"; do
  [[ -n "${p}" ]] && RECORD_TUPLES+=("${p}::")
done
for f in "${FOLDERS[@]+"${FOLDERS[@]}"}"; do
  [[ -n "${f}" ]] && RECORD_TUPLES+=(":${f}:")
done
for b in "${BILLING_ACCOUNTS_ARGS[@]+"${BILLING_ACCOUNTS_ARGS[@]}"}"; do
  if [[ -n "${b}" ]]; then
    norm_b="$(normalize_billing_account_id "${b}")"
    RECORD_TUPLES+=("::${norm_b}")
  fi
done
for r in "${COMPOSITE_RECORDS[@]+"${COMPOSITE_RECORDS[@]}"}"; do
  if [[ -n "${r}" ]]; then
    IFS=':' read -r r_proj r_folder r_ba <<< "${r}"
    if [[ -n "${r_ba:-}" ]]; then
      r_ba="$(normalize_billing_account_id "${r_ba}")"
    fi
    RECORD_TUPLES+=("${r_proj:-}:${r_folder:-}:${r_ba:-}")
  fi
done

# 1. Grant IAM permissions when status is true:
#    - roles/bigquery.dataViewer on the 4 analytical views ONLY
#    - roles/bigquery.jobUser on the host project (${PROJECT_ID})
#    - roles/geminidataanalytics.dataAgentUser on the BQ CA Data Agent (${CA_AGENT_ID})
if [[ "${STATUS}" == "true" ]]; then
  log_info "Granting IAM roles/bigquery.dataViewer on the 4 analytical views to ${USER_EMAIL}..."
  for view_name in "${END_USER_VIEWS[@]}"; do
    grant_view_data_viewer "${USER_EMAIL}" "${view_name}"
  done
  grant_project_job_user "${USER_EMAIL}"
  grant_agent_user "${USER_EMAIL}" "${CA_AGENT_ID}"
fi

# 2. If --disable or --enable was specified WITHOUT specific scope records, update all existing rows for the user
if [[ ${#RECORD_TUPLES[@]} -eq 0 ]]; then
  if [[ "${MODE}" == "disable_all" || "${MODE}" == "enable_all" || "${STATUS}" == "false" ]]; then
    BOOL_LIT="FALSE"
    [[ "${STATUS}" == "true" ]] && BOOL_LIT="TRUE"

    UPDATE_SQL="UPDATE \`${PROJECT_ID}.${ENT_DATASET}.${USR_PRV_TABLE}\`
SET
  status = ${BOOL_LIT},
  date = CURRENT_TIMESTAMP()
WHERE
  user = '${USER_EMAIL}';"

    run_bq_sql "${UPDATE_SQL}" "Updating status=${BOOL_LIT} and date=CURRENT_TIMESTAMP() for user ${USER_EMAIL} in ${PROJECT_ID}.${ENT_DATASET}.${USR_PRV_TABLE}"
    log_info "User ${USER_EMAIL} status updated to ${BOOL_LIT}."
    exit 0
  else
    log_error "At least one availability record (--project, --folder, --billing-account, or --record) is required when adding a user."
    usage >&2
    exit 1
  fi
fi

# 3. Build MERGE statement to insert/update one or more availability records for the user
BOOL_LIT="TRUE"
[[ "${STATUS}" == "false" ]] && BOOL_LIT="FALSE"

sql_nullable_str() {
  local val="$1"
  if [[ -z "${val}" ]]; then
    echo "CAST(NULL AS STRING)"
  else
    # Escape single quotes
    local escaped="${val//\'/\\\'}"
    echo "'${escaped}'"
  fi
}

SOURCE_SELECTS=""
for tuple in "${RECORD_TUPLES[@]}"; do
  IFS=':' read -r rec_proj rec_folder rec_ba <<< "${tuple}"
  proj_sql="$(sql_nullable_str "${rec_proj:-}")"
  folder_sql="$(sql_nullable_str "${rec_folder:-}")"
  ba_sql="$(sql_nullable_str "${rec_ba:-}")"

  if [[ -n "${SOURCE_SELECTS}" ]]; then
    SOURCE_SELECTS+="
    UNION ALL
"
  fi
  SOURCE_SELECTS+="    SELECT
      '${USER_EMAIL}' AS user,
      ${proj_sql} AS project_id,
      ${folder_sql} AS obj_number,
      ${ba_sql} AS billing_id,
      ${BOOL_LIT} AS status"
done

MERGE_SQL="MERGE \`${PROJECT_ID}.${ENT_DATASET}.${USR_PRV_TABLE}\` AS target
USING (
${SOURCE_SELECTS}
) AS source
ON target.user = source.user
   AND IFNULL(target.project_id, '') = IFNULL(source.project_id, '')
   AND IFNULL(target.obj_number, '') = IFNULL(source.obj_number, '')
   AND IFNULL(target.billing_id, '') = IFNULL(source.billing_id, '')
WHEN MATCHED THEN
  UPDATE SET
    status = source.status,
    date = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN
  INSERT (date, user, project_id, obj_number, billing_id, status)
  VALUES (CURRENT_TIMESTAMP(), source.user, source.project_id, source.obj_number, source.billing_id, source.status);"

run_bq_sql "${MERGE_SQL}" "Upserting ${#RECORD_TUPLES[@]} availability record(s) for ${USER_EMAIL} in ${PROJECT_ID}.${ENT_DATASET}.${USR_PRV_TABLE}"

log_info "Completed user provisioning for ${USER_EMAIL}."
