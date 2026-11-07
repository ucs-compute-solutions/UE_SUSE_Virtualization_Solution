#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Intersight Deployment Script (Create + Validate + Optional Deploy)
#
# Scope:
# - Creates/ensures Unified Edge profiles and/or server profiles
# - Supports creating 1 to 5 server profiles from a single template
# - Selects servers dynamically from the org-assigned resource group
# - Stops if insufficient eligible servers are available
# - Optionally deploys and activates each created/existing target profile
# - Validates org assignment and key policy/platform constraints
# - Does NOT install an operating system
#
# Usage:
#   ./intersight_deploy_validate.sh [--deploy-scope server-profiles|unified-edge|both]
#   ./intersight_deploy_validate.sh --deploy-scope both ./intersight_deploy_validate_vars.txt ./${PREFIX%-}-SecretKey.txt
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
  cat <<EOF
Usage:
  $(basename "$0") [OPTIONS] [VARS_FILE] [SECRET_KEY_FILE]
  $(basename "$0") --help

Purpose:
  Create, deploy, and validate configured Intersight server profiles,
  Unified Edge profiles, or both.

Scope:
  --deploy-scope server-profiles   Server profile workflow only (default)
  --deploy-scope unified-edge      Unified Edge workflow only
  --deploy-scope both              Run both workflows

  Short aliases:
    --server-profiles
    --unified-edge
    --both

Files and credentials:
  --vars FILE                      Variables file
  --secret-key FILE                Intersight secret key file
  --api-key-file FILE              API key lookup file
  --api-key-name NAME              API key entry name; defaults to PREFIX without trailing '-'

Defaults:
  Variables file                   ./intersight_deploy_validate_vars.txt
  API key file                     ./API-Key.txt, or ./API-Keys.txt
  Secret key file                  ./\${PREFIX%-}-SecretKey.txt

Generic variable overrides:
  Every variable from the vars file can also be passed as an option.
  Use either --VARIABLE value, --VARIABLE=value, or lower-case kebab form.

  Examples:
    --SERVER_PROFILE_COUNT 3
    --server-profile-count 3
    --ALLOWED_VLANS 1341-1344
    --NATIVE_VLAN 1341
    --NATIVE_VLAN=                 Leave native VLAN unset
    --UNIFIED_EDGE_DEPLOY_PROFILE false

Notes:
  Boolean values are true or false.
  CLI variable overrides are applied after the vars file is loaded.
  If you override PREFIX, also override any derived names that should change.
  API-Key.txt or API-Keys.txt must contain: <prefix-without-trailing-dash> <intersight-api-key-id>
  Server-profile runs check for the configured Unified Edge profile and create
  it first when it is missing.

Examples:
  ./intersight_deploy_validate.sh
  ./intersight_deploy_validate.sh --unified-edge
  ./intersight_deploy_validate.sh --both --ALLOWED_VLANS 1341-1344 --NATIVE_VLAN=
  ./intersight_deploy_validate.sh --vars ./intersight_deploy_validate_vars.txt --secret-key ./\${PREFIX%-}-SecretKey.txt --deploy-scope both
EOF
}

usage_error() {
  printf 'ERROR: %s\n\n' "$1" >&2
  show_help >&2
  exit 2
}

DEPLOY_SCOPE="server-profiles"
VARS_FILE=""
SECRET_KEY_OVERRIDE=""
API_KEY_FILE_OVERRIDE=""
API_KEY_NAME_OVERRIDE=""
POSITIONAL_ARGS=()
CLI_OVERRIDE_KEYS=()
CLI_OVERRIDE_VALUES=()

normalize_cli_key() {
  local raw key
  raw="${1#--}"
  key="$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || usage_error "invalid option name: $1"
  printf '%s\n' "$key"
}

add_cli_variable_override() {
  local key="$1" value="$2"
  CLI_OVERRIDE_KEYS+=("$key")
  CLI_OVERRIDE_VALUES+=("$value")
}

set_cli_option() {
  local option="$1" value="$2" key
  key="$(normalize_cli_key "$option")"
  case "$key" in
    DEPLOY_SCOPE)
      DEPLOY_SCOPE="$value"
      ;;
    VARS|VARS_FILE)
      VARS_FILE="$value"
      ;;
    SECRET_KEY|SECRET_KEY_PATH)
      SECRET_KEY_OVERRIDE="$value"
      ;;
    API_KEY_FILE)
      API_KEY_FILE_OVERRIDE="$value"
      ;;
    API_KEY_NAME)
      API_KEY_NAME_OVERRIDE="$value"
      ;;
    *)
      add_cli_variable_override "$key" "$value"
      ;;
  esac
}

apply_cli_variable_overrides() {
  local idx key value
  for idx in "${!CLI_OVERRIDE_KEYS[@]}"; do
    key="${CLI_OVERRIDE_KEYS[$idx]}"
    value="${CLI_OVERRIDE_VALUES[$idx]}"
    printf -v "$key" '%s' "$value"
  done
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help|help)
      show_help
      exit 0
      ;;
    --deploy-scope|--scope|--create)
      [[ $# -ge 2 ]] || usage_error "$1 requires one of: server-profiles, unified-edge, both"
      DEPLOY_SCOPE="$2"
      shift 2
      ;;
    --deploy-scope=*|--scope=*|--create=*)
      DEPLOY_SCOPE="${1#*=}"
      shift
      ;;
    --server-profiles)
      DEPLOY_SCOPE="server-profiles"
      shift
      ;;
    --unified-edge)
      DEPLOY_SCOPE="unified-edge"
      shift
      ;;
    --both)
      DEPLOY_SCOPE="both"
      shift
      ;;
    --vars)
      [[ $# -ge 2 ]] || usage_error "--vars requires a file path"
      VARS_FILE="$2"
      shift 2
      ;;
    --vars=*)
      VARS_FILE="${1#--vars=}"
      shift
      ;;
    --secret-key)
      [[ $# -ge 2 ]] || usage_error "--secret-key requires a file path"
      SECRET_KEY_OVERRIDE="$2"
      shift 2
      ;;
    --secret-key=*)
      SECRET_KEY_OVERRIDE="${1#--secret-key=}"
      shift
      ;;
    --api-key-file)
      [[ $# -ge 2 ]] || usage_error "--api-key-file requires a file path"
      API_KEY_FILE_OVERRIDE="$2"
      shift 2
      ;;
    --api-key-file=*)
      API_KEY_FILE_OVERRIDE="${1#--api-key-file=}"
      shift
      ;;
    --api-key-name)
      [[ $# -ge 2 ]] || usage_error "--api-key-name requires a name"
      API_KEY_NAME_OVERRIDE="$2"
      shift 2
      ;;
    --api-key-name=*)
      API_KEY_NAME_OVERRIDE="${1#--api-key-name=}"
      shift
      ;;
    --)
      shift
      while (( $# > 0 )); do
        POSITIONAL_ARGS+=("$1")
        shift
      done
      ;;
    --*=*)
      set_cli_option "${1%%=*}" "${1#*=}"
      shift
      ;;
    --*)
      [[ $# -ge 2 ]] || usage_error "$1 requires a value"
      set_cli_option "$1" "$2"
      shift 2
      ;;
    -*)
      usage_error "unknown option: $1"
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

(( ${#POSITIONAL_ARGS[@]} <= 2 )) || usage_error "too many positional arguments"
[[ -z "$VARS_FILE" && ${#POSITIONAL_ARGS[@]} -ge 1 ]] && VARS_FILE="${POSITIONAL_ARGS[0]}"
[[ -z "$SECRET_KEY_OVERRIDE" && ${#POSITIONAL_ARGS[@]} -ge 2 ]] && SECRET_KEY_OVERRIDE="${POSITIONAL_ARGS[1]}"

case "$DEPLOY_SCOPE" in
  server-profiles|server-profiles-only|profiles|server)
    DEPLOY_SERVER_PROFILES=true
    DEPLOY_UNIFIED_EDGE=false
    ;;
  unified-edge|unified-edge-only|edge)
    DEPLOY_SERVER_PROFILES=false
    DEPLOY_UNIFIED_EDGE=true
    ;;
  both|all)
    DEPLOY_SERVER_PROFILES=true
    DEPLOY_UNIFIED_EDGE=true
    ;;
  *)
    usage_error "invalid deploy scope: $DEPLOY_SCOPE"
    ;;
esac

VARS_FILE="${VARS_FILE:-$SCRIPT_DIR/intersight_deploy_validate_vars.txt}"
[[ -f "$VARS_FILE" ]] || { printf 'ERROR: variables file not found: %s\n' "$VARS_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$VARS_FILE"
apply_cli_variable_overrides

resolve_local_path() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$SCRIPT_DIR/${path#./}"
  fi
}

default_api_key_file() {
  if [[ -f "$SCRIPT_DIR/API-Key.txt" ]]; then
    printf '%s\n' "$SCRIPT_DIR/API-Key.txt"
  elif [[ -f "$SCRIPT_DIR/API-Keys.txt" ]]; then
    printf '%s\n' "$SCRIPT_DIR/API-Keys.txt"
  else
    printf '%s\n' "$SCRIPT_DIR/API-Key.txt"
  fi
}

default_secret_key_file() {
  local prefix_id prefix_upper prefix_lower
  prefix_id="${PREFIX%-}"
  prefix_id="${prefix_id%_}"
  prefix_upper="$(printf '%s' "$prefix_id" | tr '[:lower:]' '[:upper:]')"
  prefix_lower="$(printf '%s' "$prefix_id" | tr '[:upper:]' '[:lower:]')"

  if [[ -n "$prefix_id" && -f "$SCRIPT_DIR/${prefix_id}-SecretKey.txt" ]]; then
    printf '%s\n' "$SCRIPT_DIR/${prefix_id}-SecretKey.txt"
  elif [[ -n "$prefix_upper" && -f "$SCRIPT_DIR/${prefix_upper}-SecretKey.txt" ]]; then
    printf '%s\n' "$SCRIPT_DIR/${prefix_upper}-SecretKey.txt"
  elif [[ -n "$prefix_lower" && -f "$SCRIPT_DIR/${prefix_lower}-SecretKey.txt" ]]; then
    printf '%s\n' "$SCRIPT_DIR/${prefix_lower}-SecretKey.txt"
  else
    printf '%s\n' "$SCRIPT_DIR/${prefix_id}-SecretKey.txt"
  fi
}

API_KEY_FILE="$(resolve_local_path "${API_KEY_FILE_OVERRIDE:-${API_KEY_FILE:-$(default_api_key_file)}}")"
API_KEY_NAME="${API_KEY_NAME_OVERRIDE:-${API_KEY_NAME:-${PREFIX%-}}}"
[[ -n "$API_KEY_NAME" ]] || { printf 'ERROR: API_KEY_NAME is empty and PREFIX is not set in %s\n' "$VARS_FILE" >&2; exit 1; }
[[ -f "$API_KEY_FILE" ]] || { printf 'ERROR: API key file not found: %s\n' "$API_KEY_FILE" >&2; exit 1; }

API_KEY_ID="$(
  awk -v name="$API_KEY_NAME" '
    $0 ~ /^[[:space:]]*#/ { next }
    NF >= 2 && $1 == name { print $2; found=1; exit }
    END { if (!found) exit 1 }
  ' "$API_KEY_FILE"
)" || {
  printf 'ERROR: API key name %s not found in %s\n' "$API_KEY_NAME" "$API_KEY_FILE" >&2
  exit 1
}

SECRET_KEY_PATH="${SECRET_KEY_OVERRIDE:-${SECRET_KEY_PATH:-$(default_secret_key_file)}}"
SECRET_KEY_PATH="$(resolve_local_path "$SECRET_KEY_PATH")"

# Runtime globals
ORG_MOID=""
RESOURCE_GROUP_MOID=""
ADMIN_ENDPOINT_ROLE_MOID=""
ENDPOINT_USER_POLICY_MOID=""
ENDPOINT_USER_MOID=""
TARGET_PROFILE_NAMES=()
UNIFIED_EDGE_PROFILES=()
UNIFIED_EDGE_CHASSIS_MOID="${UNIFIED_EDGE_CHASSIS_MOID:-}"
UNIFIED_EDGE_NETWORK_ELEMENT_A_MOID="${UNIFIED_EDGE_NETWORK_ELEMENT_A_MOID:-}"
UNIFIED_EDGE_NETWORK_ELEMENT_B_MOID="${UNIFIED_EDGE_NETWORK_ELEMENT_B_MOID:-}"
UNIFIED_EDGE_NETWORK_ELEMENT_A_LABEL="${UNIFIED_EDGE_NETWORK_ELEMENT_A_LABEL:-}"
UNIFIED_EDGE_NETWORK_ELEMENT_B_LABEL="${UNIFIED_EDGE_NETWORK_ELEMENT_B_LABEL:-}"

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "Required variable '$name' is missing in $VARS_FILE"
}

is_harvester_target() {
  local image_name iso_name
  image_name="$(printf '%s' "${OS_IMAGE_NAME:-}" | tr '[:upper:]' '[:lower:]')"
  iso_name="$(printf '%s' "${VMEDIA_FILE_LOCATION:-${OS_IMAGE_LINK:-}}" | sed 's/[?#].*$//' | awk -F/ '{print $NF}' | tr '[:upper:]' '[:lower:]')"
  [[ "$image_name" == *harvester* || "$iso_name" == *harvester* ]]
}

validate_required_vars() {
  local required_vars=(ORG_NAME RESOURCE_GROUP_NAME PREFIX)
  local v

  if [[ "$DEPLOY_SERVER_PROFILES" == "true" ]]; then
    required_vars+=(
      TARGET_PLATFORM
      SERVER_PROFILE_COUNT PROFILE_NAME_PREFIX PROFILE_NAME_PAD_WIDTH
      LOCAL_USER_NAME LOCAL_USER_PASSWORD ADMIN_ENDPOINT_ROLE_NAME LOCAL_USER_POLICY_NAME
      MGMT_GATEWAY MGMT_NETMASK MGMT_IP_FROM MGMT_IP_TO INBAND_VLAN ALLOWED_VLANS
      MAC_FROM MAC_TO VNIC1_NAME VNIC2_NAME VNIC1_SWITCH_ID VNIC2_SWITCH_ID ETH_MTU
      M2_CONTROLLER_SLOT M2_VD_NAME BOOT_LOCALDISK_NAME BOOT_LOCALDISK_SLOT
      UUID_PREFIX UUID_SUFFIX_FROM UUID_SUFFIX_TO
      POWER_PRIORITY POWER_RESTORE_STATE POWER_SAVE_MODE
      KVM_ENABLED KVM_TUNNELED_ENABLED KVM_MAX_SESSIONS KVM_REMOTE_PORT KVM_ENABLE_VIDEO_ENCRYPTION
      IPPOOL_NAME ACCESS_POLICY_NAME BIOS_POLICY_NAME POWER_POLICY_NAME KVM_POLICY_NAME
      MACPOOL_NAME ETH_QOS_POLICY_NAME ETH_NETWORK_GROUP_NAME LCP_NAME
      STORAGE_POLICY_NAME BOOT_POLICY_NAME UUIDPOOL_NAME PROFILE_TEMPLATE_NAME
      DEPLOY_PROFILE DEPLOY_TIMEOUT_SEC DEPLOY_PAUSE_SEC ACTIVATE_PROFILE ACTIVATION_TIMEOUT_SEC ACTIVATION_PROCEED_ON_REBOOT
      ENABLE_OS_INSTALL OS_CONFIG_DIR OS_CONFIG_FILE_PREFIX OS_CONFIG_FILE_SUFFIX OS_CONFIG_NAME_PREFIX
      OS_INSTALL_NAME_PREFIX OS_INSTALL_NAME_PAD_WIDTH OS_CATALOG_NAME OS_HCL_VERSION_PRIMARY
      OS_IMAGE_NAME OS_INSTALL_TIMEOUT_SEC OS_INSTALL_POLL_SEC
      OS_IMAGE_LINK OS_INSTALL_METHOD
    )
    if is_harvester_target; then
      required_vars+=(VMEDIA_POLICY_NAME VMEDIA_DEVICE_TYPE VMEDIA_MOUNT_PROTOCOL VMEDIA_FILE_LOCATION VMEDIA_VOLUME_NAME)
    fi
  fi

  if [[ "$DEPLOY_UNIFIED_EDGE" == "true" ]]; then
    required_vars+=(INBAND_VLAN ALLOWED_VLANS)
  fi

  for v in "${required_vars[@]}"; do
    require_var "$v"
  done

  if [[ "$DEPLOY_SERVER_PROFILES" == "true" ]]; then
    [[ "$DEPLOY_PROFILE" == "true" ]] || fail "DEPLOY_PROFILE must be true (deploy is mandatory)"
    [[ "$ACTIVATE_PROFILE" == "true" ]] || fail "ACTIVATE_PROFILE must be true (activation is mandatory)"
    if [[ -n "${NATIVE_VLAN:-}" ]]; then
      [[ "$NATIVE_VLAN" =~ ^[0-9]+$ ]] || fail "NATIVE_VLAN must be numeric when set"
    fi
  fi
}

wait_for_intersight_connectivity() {
  local retries delay attempt
  retries="${INTERSIGHT_CONNECT_RETRIES:-20}"
  delay="${INTERSIGHT_CONNECT_DELAY_SEC:-15}"

  for (( attempt=1; attempt<=retries; attempt++ )); do
    if isctl --intersight-api-key-id "$API_KEY_ID" --intersight-secret-key "$SECRET_KEY_PATH" get organization organization --filter "Name eq '$ORG_NAME'" -o json >/dev/null 2>&1; then
      log "Intersight API connectivity confirmed"
      return 0
    fi
    log "Waiting for Intersight API connectivity ($attempt/$retries)"
    sleep "$delay"
  done

  fail "Unable to reach Intersight API after $retries attempts"
}

isctl_cmd() {
  local attempt rc output
  for attempt in 1 2 3 4 5; do
    if output="$(isctl --intersight-api-key-id "$API_KEY_ID" --intersight-secret-key "$SECRET_KEY_PATH" "$@" 2>&1)"; then
      if ! printf '%s' "$output" | grep -q 'level=fatal msg="ERROR:'; then
        printf '%s\n' "$output"
        return 0
      fi
      rc=1
    else
      rc=$?
    fi
    if printf '%s' "$output" | grep -Eiq 'TLS handshake timeout|no such host|timeout|connection reset|EOF|500 Internal Server Error|Retry later'; then
      sleep $(( attempt * 2 ))
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$rc"
  done
  printf '%s\n' "$output" >&2
  return "$rc"
}

isctl_cmd_body() {
  local body attempt rc output
  body="$(cat)"
  for attempt in 1 2 3 4 5; do
    if output="$(printf '%s' "$body" | isctl --intersight-api-key-id "$API_KEY_ID" --intersight-secret-key "$SECRET_KEY_PATH" "$@" 2>&1)"; then
      if ! printf '%s' "$output" | grep -q 'level=fatal msg="ERROR:'; then
        printf '%s\n' "$output"
        return 0
      fi
      rc=1
    else
      rc=$?
    fi
    if printf '%s' "$output" | grep -Eiq 'TLS handshake timeout|no such host|timeout|connection reset|EOF|500 Internal Server Error|Retry later'; then
      sleep $(( attempt * 2 ))
      continue
    fi
    printf '%s\n' "$output" >&2
    return "$rc"
  done
  printf '%s\n' "$output" >&2
  return "$rc"
}

get_moid_in_org() {
  local noun="$1" type="$2" name="$3"
  local json count
  if [[ "$noun" == "organization" && "$type" == "organization" ]]; then
    json="$(isctl_cmd get "$noun" "$type" --filter "Name eq '$name' and Moid eq '$ORG_MOID'" -o json)"
  else
    json="$(isctl_cmd get "$noun" "$type" --filter "Name eq '$name' and Organization.Moid eq '$ORG_MOID'" -o json)"
  fi
  count="$(printf '%s' "$json" | jq 'length')"
  (( count <= 1 )) || fail "Strict lookup violation: multiple '$noun $type' objects found in org for Name='$name'"
  printf '%s' "$json" | jq -r '.[0].Moid // empty'
}

exists_in_org() {
  local noun="$1" type="$2" name="$3"
  [[ -n "$(get_moid_in_org "$noun" "$type" "$name")" ]]
}

resolve_vmedia_policy_moid() {
  get_moid_in_org vmedia policy "$VMEDIA_POLICY_NAME"
}

ensure_harvester_vmedia_policy() {
  local policy_moid mappings organization_ref
  policy_moid="$(resolve_vmedia_policy_moid)"
  mappings="$(jq -c -n \
    --arg device "$VMEDIA_DEVICE_TYPE" \
    --arg protocol "$VMEDIA_MOUNT_PROTOCOL" \
    --arg location "$VMEDIA_FILE_LOCATION" \
    --arg volume "$VMEDIA_VOLUME_NAME" \
    '[{DeviceType:$device,MountProtocol:$protocol,FileLocation:$location,VolumeName:$volume}]')"
  organization_ref="{\"Moid\":\"$ORG_MOID\",\"ObjectType\":\"organization.Organization\"}"

  if [[ -z "$policy_moid" ]]; then
    log "Creating vMedia policy '$VMEDIA_POLICY_NAME' for Harvester ISO '$VMEDIA_FILE_LOCATION'"
    isctl_cmd create vmedia policy \
      --Name "$VMEDIA_POLICY_NAME" \
      --Organization "$organization_ref" \
      --Enabled \
      --Mappings "$mappings" >/dev/null
  else
    log "Updating vMedia policy '$VMEDIA_POLICY_NAME' (moid=$policy_moid) for Harvester ISO"
    isctl_cmd update vmedia policy moid "$policy_moid" \
      --Enabled \
      --Mappings "$mappings" >/dev/null
  fi

  policy_moid="$(resolve_vmedia_policy_moid)"
  [[ -n "$policy_moid" ]] || fail "Unable to resolve vMedia policy '$VMEDIA_POLICY_NAME' after create/update"
}

get_profile_moid_in_org_by_name() {
  local profile_name="$1"
  isctl_cmd get server profile --filter "Name eq '$profile_name' and Organization.Moid eq '$ORG_MOID'" -o json \
    | jq -r '.[0].Moid // empty'
}

get_profile_json_in_org_by_name() {
  local profile_name="$1"
  isctl_cmd get server profile --filter "Name eq '$profile_name' and Organization.Moid eq '$ORG_MOID'" -o json
}

build_target_profile_names() {
  [[ "$SERVER_PROFILE_COUNT" =~ ^[0-9]+$ ]] || fail "SERVER_PROFILE_COUNT must be numeric (1..5)"
  (( SERVER_PROFILE_COUNT >= 1 && SERVER_PROFILE_COUNT <= 5 )) || fail "SERVER_PROFILE_COUNT must be in range 1..5"

  local i fmt name
  TARGET_PROFILE_NAMES=()
  fmt="%0${PROFILE_NAME_PAD_WIDTH}d"
  for (( i=1; i<=SERVER_PROFILE_COUNT; i++ )); do
    printf -v name "%s${fmt}" "$PROFILE_NAME_PREFIX" "$i"
    TARGET_PROFILE_NAMES+=("$name")
  done
}

prefix_lower() {
  printf '%s' "${PREFIX%-}" | tr '[:upper:]' '[:lower:]'
}

default_unified_edge_profile_name() {
  printf '%s-chassis1\n' "$(prefix_lower)"
}

build_unified_edge_profiles() {
  local raw name
  UNIFIED_EDGE_PROFILES=()
  raw="${UNIFIED_EDGE_PROFILE_NAMES:-${UNIFIED_EDGE_PROFILE_NAME:-$(default_unified_edge_profile_name)}}"
  raw="${raw//,/ }"
  for name in $raw; do
    [[ -n "$name" ]] || continue
    UNIFIED_EDGE_PROFILES+=("$name")
  done
  (( ${#UNIFIED_EDGE_PROFILES[@]} > 0 )) || fail "No Unified Edge profile names resolved"
}

get_scoped_moid_by_name() {
  local noun="$1" type="$2" name="$3"
  local json count
  json="$(isctl_cmd get "$noun" "$type" --filter "Name eq '$name'" -o json)"
  count="$(
    printf '%s' "$json" | jq --arg org "$ORG_MOID" '
      [
        .[]?
        | select(
            ((.Organization.Moid // "") == $org)
            or (((.PermissionResources // []) | map(.Moid // "") | index($org)) != null)
          )
      ] | length
    '
  )"
  (( count <= 1 )) || fail "Strict lookup violation: multiple scoped '$noun $type' objects found for Name='$name'"
  printf '%s' "$json" | jq -r --arg org "$ORG_MOID" '
    [
      .[]?
      | select(
          ((.Organization.Moid // "") == $org)
          or (((.PermissionResources // []) | map(.Moid // "") | index($org)) != null)
        )
    ][0].Moid // empty
  '
}

get_moid_by_filter() {
  local noun="$1" type="$2" filter="$3"
  local json count
  json="$(isctl_cmd get "$noun" "$type" --filter "$filter" -o json)"
  count="$(printf '%s' "$json" | jq 'length')"
  (( count <= 1 )) || fail "Strict lookup violation: multiple '$noun $type' objects found for filter: $filter"
  printf '%s' "$json" | jq -r '.[0].Moid // empty'
}

resolve_admin_endpoint_role_moid() {
  local admin_roles_json role_bindings_json inferred_moid fallback_moid
  admin_roles_json="$({
    isctl_cmd get iam endpointrole --filter "Name eq '$ADMIN_ENDPOINT_ROLE_NAME'" -o json
  })"
  [[ "$(printf '%s' "$admin_roles_json" | jq 'length')" -gt 0 ]] || fail "No endpoint role found with Name='$ADMIN_ENDPOINT_ROLE_NAME'"

  role_bindings_json="$(isctl_cmd get iam endpointuserrole -o json)"
  inferred_moid="$({
    jq -r --argjson admins "$admin_roles_json" '
      [ $admins[]?.Moid ] as $adminMoids
      | [ .[] | ((.EndPointRole // .EndPointRoles // [])[]?.Moid // "") | select(. != "" and (. as $m | $adminMoids | index($m))) ]
      | group_by(.) | map({moid: .[0], count: length}) | sort_by(-.count) | .[0].moid // empty
    ' <<< "$role_bindings_json"
  })"

  fallback_moid="$({
    printf '%s' "$admin_roles_json" | jq -r 'sort_by(.CreateTime // "9999-12-31T23:59:59Z") | .[0].Moid // empty'
  })"

  ADMIN_ENDPOINT_ROLE_MOID="${inferred_moid:-$fallback_moid}"
  [[ -n "$ADMIN_ENDPOINT_ROLE_MOID" ]] || fail "Unable to resolve ADMIN_ENDPOINT_ROLE_MOID"
  log "Resolved ADMIN_ENDPOINT_ROLE_MOID=$ADMIN_ENDPOINT_ROLE_MOID"
}

ensure_org_and_resource_group() {
  log "Ensuring org '$ORG_NAME' exists and is bound to resource group '$RESOURCE_GROUP_NAME'"
  local count org_json rg_bound
  count="$(isctl_cmd get organization organization --name "$ORG_NAME" --count 2>/dev/null || echo 0)"
  if [[ "$count" == "0" ]]; then
    isctl_cmd create organization organization --Name "$ORG_NAME" >/dev/null
  fi

  ORG_MOID="$(
    isctl_cmd get organization organization --name "$ORG_NAME" -o json \
      | jq -r 'if type=="array" then .[0].Moid // empty elif type=="object" then .Moid // empty else empty end'
  )"
  [[ -n "$ORG_MOID" ]] || fail "Unable to resolve ORG_MOID for $ORG_NAME"

  RESOURCE_GROUP_MOID="$(
    isctl_cmd get resource group --name "$RESOURCE_GROUP_NAME" -o json \
      | jq -r 'if type=="array" then .[0].Moid // empty elif type=="object" then .Moid // empty else empty end'
  )"
  if [[ -z "$RESOURCE_GROUP_MOID" && "$RESOURCE_GROUP_NAME" != *-rg ]]; then
    local fallback_rg
    fallback_rg="${RESOURCE_GROUP_NAME}-rg"
    RESOURCE_GROUP_MOID="$(
      isctl_cmd get resource group --name "$fallback_rg" -o json \
        | jq -r 'if type=="array" then .[0].Moid // empty elif type=="object" then .Moid // empty else empty end'
    )"
    if [[ -n "$RESOURCE_GROUP_MOID" ]]; then
      log "Resource group '$RESOURCE_GROUP_NAME' not found; using '$fallback_rg'"
      RESOURCE_GROUP_NAME="$fallback_rg"
    fi
  fi
  [[ -n "$RESOURCE_GROUP_MOID" ]] || fail "Unable to resolve resource group '$RESOURCE_GROUP_NAME'"

  org_json="$(isctl_cmd get organization organization moid "$ORG_MOID" -o json)"
  rg_bound="$(
    printf '%s' "$org_json" \
      | jq -r --arg rg "$RESOURCE_GROUP_MOID" '
          ((.ResourceGroups // []) | map(.Moid // "") | index($rg)) != null
        '
  )"
  if [[ "$rg_bound" == "true" ]]; then
    log "Org '$ORG_NAME' is already bound to resource group '$RESOURCE_GROUP_NAME'"
    log "ORG_MOID=$ORG_MOID RESOURCE_GROUP_MOID=$RESOURCE_GROUP_MOID"
    return 0
  fi

  if [[ "$DEPLOY_SERVER_PROFILES" != "true" ]]; then
    log "Skipping org resource-group binding update for Unified Edge-only scope"
    log "ORG_MOID=$ORG_MOID RESOURCE_GROUP_MOID=$RESOURCE_GROUP_MOID"
    return 0
  fi

  isctl_cmd update organization organization moid "$ORG_MOID" \
    --ResourceGroups "[{\"Moid\":\"$RESOURCE_GROUP_MOID\"}]" >/dev/null

  log "ORG_MOID=$ORG_MOID RESOURCE_GROUP_MOID=$RESOURCE_GROUP_MOID"
}

ensure_base_policies() {
  log "Ensuring base policies: IP pool and access policy"
  if ! exists_in_org ippool pool "$IPPOOL_NAME"; then
    isctl_cmd create ippool pool \
      --Name "$IPPOOL_NAME" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" \
      --IpV4Config "{\"Gateway\":\"$MGMT_GATEWAY\",\"Netmask\":\"$MGMT_NETMASK\"}" \
      --IpV4Blocks "[{\"From\":\"$MGMT_IP_FROM\",\"To\":\"$MGMT_IP_TO\"}]" >/dev/null
  fi

  if ! exists_in_org access policy "$ACCESS_POLICY_NAME"; then
    isctl_cmd create access policy \
      --Name "$ACCESS_POLICY_NAME" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" \
      --ConfigurationType '{"ConfigureInband":true,"ConfigureOutOfBand":false}' \
      --AddressType '{"EnableIpV4":true,"EnableIpV6":false}' \
      --InbandVlan "$INBAND_VLAN" \
      --InbandIpPool "{\"Selector\":\"Name eq '$IPPOOL_NAME' and Organization.Moid eq '$ORG_MOID'\"}" >/dev/null
  fi
}

ensure_users_and_bios() {
  log "Ensuring local user policy, local user/role, and BIOS policy"
  if ! exists_in_org iam endpointuserpolicy "$LOCAL_USER_POLICY_NAME"; then
    isctl_cmd create iam endpointuserpolicy \
      --Name "$LOCAL_USER_POLICY_NAME" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" \
      --PasswordProperties '{"EnablePasswordExpiry":false,"EnforceStrongPassword":true,"ForceSendPassword":false,"GracePeriod":0,"NotificationPeriod":15,"PasswordExpiryDuration":90,"PasswordHistory":5}' >/dev/null
  fi
  ENDPOINT_USER_POLICY_MOID="$(get_moid_in_org iam endpointuserpolicy "$LOCAL_USER_POLICY_NAME")"

  if ! exists_in_org iam endpointuser "$LOCAL_USER_NAME"; then
    isctl_cmd create iam endpointuser \
      --Name "$LOCAL_USER_NAME" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" >/dev/null
  fi
  ENDPOINT_USER_MOID="$(get_moid_in_org iam endpointuser "$LOCAL_USER_NAME")"

  local existing_role_moids
  existing_role_moids="$({
    isctl_cmd get iam endpointuserrole -o json \
      | jq --arg p "$ENDPOINT_USER_POLICY_MOID" --arg u "$ENDPOINT_USER_MOID" \
        -r '.[] | select((.EndPointUserPolicy.Moid // "")==$p and (.EndPointUser.Moid // "")==$u) | .Moid'
  })"

  if [[ -n "$existing_role_moids" ]]; then
    while IFS= read -r role_moid; do
      [[ -z "$role_moid" ]] && continue
      isctl_cmd delete iam endpointuserrole moid "$role_moid" >/dev/null
    done <<< "$existing_role_moids"
  fi

  isctl_cmd create iam endpointuserrole \
    --Enabled \
    --EndPointUserPolicy "{\"Moid\":\"$ENDPOINT_USER_POLICY_MOID\"}" \
    --EndPointUser "{\"Moid\":\"$ENDPOINT_USER_MOID\"}" \
    --EndPointRole "[{\"Moid\":\"$ADMIN_ENDPOINT_ROLE_MOID\"}]" \
    --Password "$LOCAL_USER_PASSWORD" >/dev/null

  if ! exists_in_org bios policy "$BIOS_POLICY_NAME"; then
    isctl_cmd create bios policy \
      --Name "$BIOS_POLICY_NAME" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" >/dev/null
  fi
}

ensure_power_and_kvm() {
  log "Ensuring power policy and virtual KVM policy"

  if ! exists_in_org power policy "$POWER_POLICY_NAME"; then
    isctl_cmd create power policy \
      --Name "$POWER_POLICY_NAME" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" \
      --PowerPriority "$POWER_PRIORITY" \
      --PowerRestoreState "$POWER_RESTORE_STATE" \
      --PowerSaveMode "$POWER_SAVE_MODE" >/dev/null
  fi

  if ! exists_in_org kvm policy "$KVM_POLICY_NAME"; then
    isctl_cmd create kvm policy \
      --Name "$KVM_POLICY_NAME" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" \
      --Enabled="$KVM_ENABLED" \
      --TunneledKvmEnabled="$KVM_TUNNELED_ENABLED" \
      --MaximumSessions "$KVM_MAX_SESSIONS" \
      --RemotePort "$KVM_REMOTE_PORT" \
      --EnableVideoEncryption="$KVM_ENABLE_VIDEO_ENCRYPTION" >/dev/null
  fi
}

server_vlan_settings_json() {
  if [[ -n "${NATIVE_VLAN:-}" ]]; then
    jq -c -n \
      --arg allowed "$ALLOWED_VLANS" \
      --argjson native "$NATIVE_VLAN" \
      '{AllowedVlans:$allowed,NativeVlan:$native}'
  else
    jq -c -n \
      --arg allowed "$ALLOWED_VLANS" \
      '{AllowedVlans:$allowed}'
  fi
}

server_vlan_settings_match() {
  local policy_json="$1" actual_allowed expected_allowed
  actual_allowed="$(printf '%s' "$policy_json" | jq -r '.VlanSettings.AllowedVlans // empty')"
  actual_allowed="$(normalize_vlan_list "$actual_allowed")"
  expected_allowed="$(normalize_vlan_list "$ALLOWED_VLANS")"
  [[ "$actual_allowed" == "$expected_allowed" ]] || return 1

  printf '%s' "$policy_json" \
    | jq -e \
        --arg native "${NATIVE_VLAN:-}" '
        if $native == "" then
          ((.VlanSettings.NativeVlan // 0) == 0)
        else
          ((.VlanSettings.NativeVlan // empty | tostring) == $native)
        end
      ' >/dev/null
}

ensure_networking() {
  log "Ensuring networking policies and vNIC interfaces"
  local vlan_settings
  vlan_settings="$(server_vlan_settings_json)"

  if ! exists_in_org macpool pool "$MACPOOL_NAME"; then
    isctl_cmd create macpool pool \
      --Name "$MACPOOL_NAME" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" \
      --MacBlocks "[{\"From\":\"$MAC_FROM\",\"To\":\"$MAC_TO\"}]" >/dev/null
  fi

  if ! exists_in_org vnic ethqospolicy "$ETH_QOS_POLICY_NAME"; then
    isctl_cmd create vnic ethqospolicy \
      --Name "$ETH_QOS_POLICY_NAME" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" \
      --Mtu "$ETH_MTU" >/dev/null
  fi

  if ! exists_in_org fabric ethnetworkgrouppolicy "$ETH_NETWORK_GROUP_NAME"; then
    isctl_cmd create fabric ethnetworkgrouppolicy \
      --Name "$ETH_NETWORK_GROUP_NAME" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" \
      --VlanSettings "$vlan_settings" >/dev/null
  else
    local eth_group_moid eth_group_json
    eth_group_moid="$(get_moid_in_org fabric ethnetworkgrouppolicy "$ETH_NETWORK_GROUP_NAME")"
    eth_group_json="$(isctl_cmd get fabric ethnetworkgrouppolicy moid "$eth_group_moid" -o json)"
    if ! server_vlan_settings_match "$eth_group_json"; then
      if [[ -n "${NATIVE_VLAN:-}" ]]; then
        log "Updating Ethernet network group '$ETH_NETWORK_GROUP_NAME' allowed VLANs and native VLAN '$NATIVE_VLAN'"
      else
        log "Updating Ethernet network group '$ETH_NETWORK_GROUP_NAME' allowed VLANs without a native VLAN"
      fi
      isctl_cmd update fabric ethnetworkgrouppolicy moid "$eth_group_moid" \
        --VlanSettings "$vlan_settings" >/dev/null
    fi
  fi

  if ! exists_in_org vnic lanconnectivitypolicy "$LCP_NAME"; then
    isctl_cmd create vnic lanconnectivitypolicy \
      --Name "$LCP_NAME" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" \
      --TargetPlatform "$TARGET_PLATFORM" \
      --PlacementMode custom >/dev/null
  fi

  local lcp_moid
  lcp_moid="$(get_moid_in_org vnic lanconnectivitypolicy "$LCP_NAME")"
  [[ -n "$lcp_moid" ]] || fail "Unable to resolve LAN connectivity policy moid"

  if [[ -z "$(isctl_cmd get vnic ethif --filter "Name eq '$VNIC1_NAME' and LanConnectivityPolicy.Moid eq '$lcp_moid'" -o json | jq -r '.[0].Moid // empty')" ]]; then
    isctl_cmd create vnic ethif \
      --Name "$VNIC1_NAME" \
      --Order 0 \
      --Placement "{\"AutoPciLink\":true,\"PciLinkAssignmentMode\":\"None\",\"SwitchId\":\"$VNIC1_SWITCH_ID\"}" \
      --Cdn "{\"Source\":\"user\",\"Value\":\"$VNIC1_NAME\"}" \
      --MacAddressType POOL \
      --LanConnectivityPolicy "{\"Selector\":\"Name eq '$LCP_NAME' and Organization.Moid eq '$ORG_MOID'\"}" \
      --MacPool "{\"Selector\":\"Name eq '$MACPOOL_NAME' and Organization.Moid eq '$ORG_MOID'\"}" \
      --FabricEthNetworkGroupPolicy "[{\"Selector\":\"Name eq '$ETH_NETWORK_GROUP_NAME' and Organization.Moid eq '$ORG_MOID'\"}]" \
      --EthQosPolicy "{\"Selector\":\"Name eq '$ETH_QOS_POLICY_NAME' and Organization.Moid eq '$ORG_MOID'\"}" >/dev/null
  fi

  if [[ -z "$(isctl_cmd get vnic ethif --filter "Name eq '$VNIC2_NAME' and LanConnectivityPolicy.Moid eq '$lcp_moid'" -o json | jq -r '.[0].Moid // empty')" ]]; then
    isctl_cmd create vnic ethif \
      --Name "$VNIC2_NAME" \
      --Order 1 \
      --Placement "{\"AutoPciLink\":true,\"PciLinkAssignmentMode\":\"None\",\"SwitchId\":\"$VNIC2_SWITCH_ID\"}" \
      --Cdn "{\"Source\":\"user\",\"Value\":\"$VNIC2_NAME\"}" \
      --MacAddressType POOL \
      --LanConnectivityPolicy "{\"Selector\":\"Name eq '$LCP_NAME' and Organization.Moid eq '$ORG_MOID'\"}" \
      --MacPool "{\"Selector\":\"Name eq '$MACPOOL_NAME' and Organization.Moid eq '$ORG_MOID'\"}" \
      --FabricEthNetworkGroupPolicy "[{\"Selector\":\"Name eq '$ETH_NETWORK_GROUP_NAME' and Organization.Moid eq '$ORG_MOID'\"}]" \
      --EthQosPolicy "{\"Selector\":\"Name eq '$ETH_QOS_POLICY_NAME' and Organization.Moid eq '$ORG_MOID'\"}" >/dev/null
  fi
}

ensure_storage_boot_uuid() {
  log "Ensuring storage, boot, and UUID pool"
  if ! exists_in_org storage storagepolicy "$STORAGE_POLICY_NAME"; then
    isctl_cmd create storage storagepolicy \
      --Name "$STORAGE_POLICY_NAME" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" \
      --M2VirtualDrive "{\"Enable\":true,\"ControllerSlot\":\"$M2_CONTROLLER_SLOT\",\"Name\":\"$M2_VD_NAME\"}" \
      --UnusedDisksState UnconfiguredGood >/dev/null
  fi

  local desired_boot_devices boot_moid current_vm_name
  desired_boot_devices="$(jq -c -n \
    --arg ld_name "$BOOT_LOCALDISK_NAME" \
    --arg ld_slot "$BOOT_LOCALDISK_SLOT" \
    '[{"ClassId":"boot.LocalDisk","ObjectType":"boot.LocalDisk","Enabled":true,"Name":$ld_name,"Slot":$ld_slot,"Bootloader":{"ClassId":"boot.Bootloader","ObjectType":"boot.Bootloader","Name":"","Description":"","Path":""}},{"ClassId":"boot.VirtualMedia","ObjectType":"boot.VirtualMedia","Enabled":true,"Name":"CimcMappedDvd","Subtype":"cimc-mapped-dvd"}]')"

  if ! exists_in_org boot precisionpolicy "$BOOT_POLICY_NAME"; then
    isctl_cmd create boot precisionpolicy \
      --Name "$BOOT_POLICY_NAME" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" \
      --ConfiguredBootMode Uefi \
      --BootDevices "$desired_boot_devices" >/dev/null
  else
    boot_moid="$(get_moid_in_org boot precisionpolicy "$BOOT_POLICY_NAME")"
    current_vm_name="$(isctl_cmd get boot precisionpolicy moid "$boot_moid" -o json | jq -r '[.BootDevices[]? | select(.ObjectType=="boot.VirtualMedia")][0].Name // empty')"
    if [[ "$current_vm_name" != "CimcMappedDvd" ]]; then
      log "Updating boot policy '$BOOT_POLICY_NAME' to include VirtualMedia Name='CimcMappedDvd'"
      isctl_cmd update boot precisionpolicy moid "$boot_moid" \
        --ConfiguredBootMode Uefi \
        --BootDevices "$desired_boot_devices" >/dev/null
    fi
  fi

  if ! exists_in_org uuidpool pool "$UUIDPOOL_NAME"; then
    isctl_cmd create uuidpool pool \
      --Name "$UUIDPOOL_NAME" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" \
      --Prefix "$UUID_PREFIX" \
    --UuidSuffixBlocks "[{\"From\":\"$UUID_SUFFIX_FROM\",\"To\":\"$UUID_SUFFIX_TO\"}]" >/dev/null
  fi
}

init_unified_edge_defaults() {
  local pfx
  pfx="$(prefix_lower)"

  UNIFIED_EDGE_TARGET_PLATFORM="${UNIFIED_EDGE_TARGET_PLATFORM:-Unified Edge}"
  UNIFIED_EDGE_PROFILE_NAME="${UNIFIED_EDGE_PROFILE_NAME:-${pfx}-chassis1}"
  UNIFIED_EDGE_SWITCH_A_NAME="${UNIFIED_EDGE_SWITCH_A_NAME:-${UNIFIED_EDGE_PROFILE_NAME}-A}"
  UNIFIED_EDGE_SWITCH_B_NAME="${UNIFIED_EDGE_SWITCH_B_NAME:-${UNIFIED_EDGE_PROFILE_NAME}-B}"

  UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME="${UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME:-${pfx}-vlan}"
  UNIFIED_EDGE_PORT_POLICY_NAME="${UNIFIED_EDGE_PORT_POLICY_NAME:-${pfx}-ports}"
  UNIFIED_EDGE_QOS_POLICY_NAME="${UNIFIED_EDGE_QOS_POLICY_NAME:-${pfx}-qos-besteffort}"
  UNIFIED_EDGE_NETWORK_CONNECTIVITY_POLICY_NAME="${UNIFIED_EDGE_NETWORK_CONNECTIVITY_POLICY_NAME:-${pfx}-network-connectivity}"
  UNIFIED_EDGE_NTP_POLICY_NAME="${UNIFIED_EDGE_NTP_POLICY_NAME:-${pfx}-ntp}"

  UNIFIED_EDGE_ALLOWED_VLANS="${UNIFIED_EDGE_ALLOWED_VLANS:-$ALLOWED_VLANS}"
  UNIFIED_EDGE_VLAN_NAME_PREFIX="${UNIFIED_EDGE_VLAN_NAME_PREFIX:-vlan}"
  UNIFIED_EDGE_QOS_MTU="${UNIFIED_EDGE_QOS_MTU:-${ETH_MTU:-1500}}"
  UNIFIED_EDGE_NTP_TIMEZONE="${UNIFIED_EDGE_NTP_TIMEZONE:-${TIMEZONE:-UTC}}"
  UNIFIED_EDGE_NTP_SERVERS="${UNIFIED_EDGE_NTP_SERVERS:-${NTP_SERVERS:-}}"
  UNIFIED_EDGE_DNS_SERVERS="${UNIFIED_EDGE_DNS_SERVERS:-${DNS_SERVERS:-}}"
  UNIFIED_EDGE_ENABLE_PORT_POLICY="${UNIFIED_EDGE_ENABLE_PORT_POLICY:-true}"
  UNIFIED_EDGE_PORT_POLICY_DEVICE_MODEL="${UNIFIED_EDGE_PORT_POLICY_DEVICE_MODEL:-UCSXE-ECMC-G1}"
  UNIFIED_EDGE_ENABLE_UPLINK_ROLE="${UNIFIED_EDGE_ENABLE_UPLINK_ROLE:-true}"
  UNIFIED_EDGE_UPLINK_SLOT_ID="${UNIFIED_EDGE_UPLINK_SLOT_ID:-1}"
  UNIFIED_EDGE_UPLINK_PORT_ID="${UNIFIED_EDGE_UPLINK_PORT_ID:-1}"
  UNIFIED_EDGE_UPLINK_ADMIN_SPEED="${UNIFIED_EDGE_UPLINK_ADMIN_SPEED:-Auto}"
  UNIFIED_EDGE_UPLINK_FEC="${UNIFIED_EDGE_UPLINK_FEC:-Auto}"
  UNIFIED_EDGE_ASSIGN_PROFILE="${UNIFIED_EDGE_ASSIGN_PROFILE:-true}"
  UNIFIED_EDGE_ASSIGN_TIMEOUT_SEC="${UNIFIED_EDGE_ASSIGN_TIMEOUT_SEC:-900}"
  UNIFIED_EDGE_ASSIGN_POLL_SEC="${UNIFIED_EDGE_ASSIGN_POLL_SEC:-15}"
  UNIFIED_EDGE_DEPLOY_PROFILE="${UNIFIED_EDGE_DEPLOY_PROFILE:-true}"
  UNIFIED_EDGE_DEPLOY_TIMEOUT_SEC="${UNIFIED_EDGE_DEPLOY_TIMEOUT_SEC:-1800}"
  UNIFIED_EDGE_DEPLOY_POLL_SEC="${UNIFIED_EDGE_DEPLOY_POLL_SEC:-30}"
}

json_org_ref() {
  jq -c -n --arg moid "$ORG_MOID" '{Moid:$moid,ObjectType:"organization.Organization"}'
}

ensure_unified_edge_eth_network_policy() {
  log "Ensuring Unified Edge Ethernet network policy '$UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME'"
  if ! exists_in_org fabric ethnetworkpolicy "$UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME"; then
    isctl_cmd create fabric ethnetworkpolicy \
      --Name "$UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME" \
      --Organization "$(json_org_ref)" \
      --TargetPlatform "$UNIFIED_EDGE_TARGET_PLATFORM" >/dev/null
  fi
}

expand_vlan_list() {
  local raw token start end i
  raw="${1//,/ }"
  for token in $raw; do
    [[ -n "$token" ]] || continue
    if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      (( start <= end )) || fail "Invalid VLAN range '$token'"
      for (( i=start; i<=end; i++ )); do
        printf '%s\n' "$i"
      done
    elif [[ "$token" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$token"
    else
      fail "Invalid VLAN token '$token' in '$1'"
    fi
  done | sort -n -u
}

normalize_vlan_list() {
  expand_vlan_list "$1" | awk 'NF {printf "%s%s", (seen++ ? "," : ""), $1}'
}

ensure_unified_edge_vlans() {
  local eth_moid vlan_id vlan_name existing_moid existing_json body
  log "Ensuring Unified Edge VLANs '$UNIFIED_EDGE_ALLOWED_VLANS' in policy '$UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME'"
  eth_moid="$(get_moid_in_org fabric ethnetworkpolicy "$UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME")"
  [[ -n "$eth_moid" ]] || fail "Unable to resolve Unified Edge Ethernet network policy '$UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME'"

  while IFS= read -r vlan_id; do
    [[ -n "$vlan_id" ]] || continue
    vlan_name="${UNIFIED_EDGE_VLAN_NAME_PREFIX}-${vlan_id}"
    existing_moid="$(get_moid_by_filter fabric vlan "Name eq '$vlan_name' and EthNetworkPolicy.Moid eq '$eth_moid'")"

    body="$(
      jq -c -n \
        --arg name "$vlan_name" \
        --arg eth "$eth_moid" \
        --argjson vlan "$vlan_id" '
        {
          Name:$name,
          VlanId:$vlan,
          EthNetworkPolicy:{Moid:$eth,ObjectType:"fabric.EthNetworkPolicy"},
          SharingType:"None",
          AutoAllowOnUplinks:true,
          IsNative:false
        }
      '
    )"

    if [[ -z "$existing_moid" ]]; then
      printf '%s' "$body" | isctl_cmd_body create fabric vlan --bodyformat json >/dev/null
    else
      existing_json="$(isctl_cmd get fabric vlan moid "$existing_moid" -o json)"
      if printf '%s' "$existing_json" \
        | jq -e \
            --arg name "$vlan_name" \
            --argjson vlan "$vlan_id" '
            (.Name == $name)
            and (.VlanId == $vlan)
            and ((.SharingType // "") == "None")
            and ((.AutoAllowOnUplinks // false) == true)
            and ((.IsNative // false) == false)
          ' >/dev/null; then
        log "Unified Edge VLAN '$vlan_name' already has no native VLAN setting"
        continue
      fi
      printf '%s' "$body" | isctl_cmd_body update fabric vlan moid "$existing_moid" --bodyformat json >/dev/null
    fi
  done < <(expand_vlan_list "$UNIFIED_EDGE_ALLOWED_VLANS")
}

ensure_unified_edge_port_policy() {
  local args port_moid current_model
  log "Ensuring Unified Edge port policy '$UNIFIED_EDGE_PORT_POLICY_NAME'"
  if ! exists_in_org fabric portpolicy "$UNIFIED_EDGE_PORT_POLICY_NAME"; then
    args=(
      create fabric portpolicy
      --Name "$UNIFIED_EDGE_PORT_POLICY_NAME"
      --Organization "$(json_org_ref)"
      --DeviceModel "$UNIFIED_EDGE_PORT_POLICY_DEVICE_MODEL"
    )
    isctl_cmd "${args[@]}" >/dev/null
  else
    port_moid="$(get_moid_in_org fabric portpolicy "$UNIFIED_EDGE_PORT_POLICY_NAME")"
    current_model="$(
      isctl_cmd get fabric portpolicy moid "$port_moid" -o json \
        | jq -r '.DeviceModel // empty'
    )"
    if [[ "$current_model" != "$UNIFIED_EDGE_PORT_POLICY_DEVICE_MODEL" ]]; then
      log "Updating Unified Edge port policy '$UNIFIED_EDGE_PORT_POLICY_NAME' DeviceModel from '${current_model:-unset}' to '$UNIFIED_EDGE_PORT_POLICY_DEVICE_MODEL'"
      isctl_cmd update fabric portpolicy moid "$port_moid" \
        --DeviceModel "$UNIFIED_EDGE_PORT_POLICY_DEVICE_MODEL" >/dev/null
    fi
  fi
}

ensure_unified_edge_uplink_role() {
  local port_moid existing_moid body
  [[ "$UNIFIED_EDGE_ENABLE_UPLINK_ROLE" == "true" ]] || return 0

  port_moid="$(get_moid_in_org fabric portpolicy "$UNIFIED_EDGE_PORT_POLICY_NAME")"
  [[ -n "$port_moid" ]] || fail "Unable to resolve Unified Edge port policy '$UNIFIED_EDGE_PORT_POLICY_NAME'"

  existing_moid="$(
    isctl_cmd get fabric uplinkrole -o json \
      | jq -r \
          --arg pp "$port_moid" \
          --argjson slot "$UNIFIED_EDGE_UPLINK_SLOT_ID" \
          --argjson port "$UNIFIED_EDGE_UPLINK_PORT_ID" '
          [
            .[]?
            | select((.PortPolicy.Moid // "") == $pp)
            | select((.SlotId // -1) == $slot)
            | select((.PortId // -1) == $port)
          ][0].Moid // empty
        '
  )"

  body="$(
    jq -c -n \
      --arg pp "$port_moid" \
      --argjson slot "$UNIFIED_EDGE_UPLINK_SLOT_ID" \
      --argjson port "$UNIFIED_EDGE_UPLINK_PORT_ID" \
      --arg speed "$UNIFIED_EDGE_UPLINK_ADMIN_SPEED" \
      --arg fec "$UNIFIED_EDGE_UPLINK_FEC" '
      {
        PortPolicy:{Moid:$pp,ObjectType:"fabric.PortPolicy"},
        SlotId:$slot,
        PortId:$port,
        AdminSpeed:$speed,
        Fec:$fec
      }
    '
  )"

  log "Ensuring Unified Edge uplink role slot=$UNIFIED_EDGE_UPLINK_SLOT_ID port=$UNIFIED_EDGE_UPLINK_PORT_ID in port policy '$UNIFIED_EDGE_PORT_POLICY_NAME'"
  if [[ -z "$existing_moid" ]]; then
    printf '%s' "$body" | isctl_cmd_body create fabric uplinkrole --bodyformat json >/dev/null
  else
    printf '%s' "$body" | isctl_cmd_body update fabric uplinkrole moid "$existing_moid" --bodyformat json >/dev/null
  fi
}

ensure_unified_edge_qos_policy() {
  local classes_json
  log "Ensuring Unified Edge QoS policy '$UNIFIED_EDGE_QOS_POLICY_NAME'"
  classes_json="$(
    jq -c -n --argjson mtu "$UNIFIED_EDGE_QOS_MTU" '
      [
        {ClassId:"fabric.QosClass",ObjectType:"fabric.QosClass",Name:"Bronze",AdminState:"Disabled",BandwidthPercent:0,Cos:1,Mtu:$mtu,MulticastOptimize:false,PacketDrop:true,Weight:7},
        {ClassId:"fabric.QosClass",ObjectType:"fabric.QosClass",Name:"Silver",AdminState:"Disabled",BandwidthPercent:0,Cos:2,Mtu:$mtu,MulticastOptimize:false,PacketDrop:true,Weight:8},
        {ClassId:"fabric.QosClass",ObjectType:"fabric.QosClass",Name:"Gold",AdminState:"Disabled",BandwidthPercent:0,Cos:4,Mtu:$mtu,MulticastOptimize:false,PacketDrop:true,Weight:9},
        {ClassId:"fabric.QosClass",ObjectType:"fabric.QosClass",Name:"Platinum",AdminState:"Disabled",BandwidthPercent:0,Cos:5,Mtu:$mtu,MulticastOptimize:false,PacketDrop:true,Weight:10},
        {ClassId:"fabric.QosClass",ObjectType:"fabric.QosClass",Name:"Best Effort",AdminState:"Enabled",BandwidthPercent:100,Cos:255,Mtu:$mtu,MulticastOptimize:false,PacketDrop:true,Weight:5}
      ]
    '
  )"

  if ! exists_in_org fabric systemqospolicy "$UNIFIED_EDGE_QOS_POLICY_NAME"; then
    isctl_cmd create fabric systemqospolicy \
      --Name "$UNIFIED_EDGE_QOS_POLICY_NAME" \
      --Organization "$(json_org_ref)" \
      --TargetPlatform "$UNIFIED_EDGE_TARGET_PLATFORM" \
      --Classes "$classes_json" >/dev/null
  fi
}

ensure_unified_edge_network_config_policy() {
  local primary_dns alternate_dns body net_moid
  log "Ensuring Unified Edge network connectivity policy '$UNIFIED_EDGE_NETWORK_CONNECTIVITY_POLICY_NAME'"
  primary_dns="$(printf '%s' "$UNIFIED_EDGE_DNS_SERVERS" | tr ',' ' ' | awk '{print $1}')"
  alternate_dns="$(printf '%s' "$UNIFIED_EDGE_DNS_SERVERS" | tr ',' ' ' | awk '{print $2}')"

  body="$(
    jq -c -n \
      --arg name "$UNIFIED_EDGE_NETWORK_CONNECTIVITY_POLICY_NAME" \
      --arg org "$ORG_MOID" \
      --arg primary "$primary_dns" \
      --arg alternate "$alternate_dns" '
      {
        Name:$name,
        Organization:{Moid:$org,ObjectType:"organization.Organization"},
        EnableIpv4dnsFromDhcp:false,
        EnableIpv6:false
      }
      + (if $primary != "" then {PreferredIpv4dnsServer:$primary} else {} end)
      + (if $alternate != "" then {AlternateIpv4dnsServer:$alternate} else {} end)
    '
  )"

  net_moid="$(get_moid_in_org networkconfig policy "$UNIFIED_EDGE_NETWORK_CONNECTIVITY_POLICY_NAME")"
  if [[ -z "$net_moid" ]]; then
    printf '%s' "$body" | isctl_cmd_body create networkconfig policy --bodyformat json >/dev/null
  else
    printf '%s' "$body" | isctl_cmd_body update networkconfig policy moid "$net_moid" --bodyformat json >/dev/null
  fi
}

ensure_unified_edge_ntp_policy() {
  local ntp_json body enabled ntp_moid
  log "Ensuring Unified Edge NTP policy '$UNIFIED_EDGE_NTP_POLICY_NAME'"
  ntp_json="$(
    printf '%s' "$UNIFIED_EDGE_NTP_SERVERS" \
      | tr ',' '\n' \
      | awk 'NF {print $1}' \
      | jq -R . \
      | jq -s .
  )"
  enabled=false
  [[ "$(printf '%s' "$ntp_json" | jq 'length')" -gt 0 ]] && enabled=true

  body="$(
    jq -c -n \
      --arg name "$UNIFIED_EDGE_NTP_POLICY_NAME" \
      --arg org "$ORG_MOID" \
      --arg timezone "$UNIFIED_EDGE_NTP_TIMEZONE" \
      --argjson servers "$ntp_json" \
      --argjson enabled "$enabled" '
      {
        Name:$name,
        Organization:{Moid:$org,ObjectType:"organization.Organization"},
        Enabled:$enabled,
        Timezone:$timezone,
        NtpServers:$servers
      }
    '
  )"

  ntp_moid="$(get_moid_in_org ntp policy "$UNIFIED_EDGE_NTP_POLICY_NAME")"
  if [[ -z "$ntp_moid" ]]; then
    printf '%s' "$body" | isctl_cmd_body create ntp policy --bodyformat json >/dev/null
  else
    printf '%s' "$body" | isctl_cmd_body update ntp policy moid "$ntp_moid" --bodyformat json >/dev/null
  fi
}

unified_edge_policy_bucket_json() {
  local eth_moid port_moid qos_moid net_moid ntp_moid
  eth_moid="$(get_moid_in_org fabric ethnetworkpolicy "$UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME")"
  qos_moid="$(get_moid_in_org fabric systemqospolicy "$UNIFIED_EDGE_QOS_POLICY_NAME")"
  net_moid="$(get_moid_in_org networkconfig policy "$UNIFIED_EDGE_NETWORK_CONNECTIVITY_POLICY_NAME")"
  ntp_moid="$(get_moid_in_org ntp policy "$UNIFIED_EDGE_NTP_POLICY_NAME")"
  port_moid=""
  if [[ "$UNIFIED_EDGE_ENABLE_PORT_POLICY" == "true" ]]; then
    port_moid="$(get_moid_in_org fabric portpolicy "$UNIFIED_EDGE_PORT_POLICY_NAME")"
  fi

  jq -c -n \
    --arg eth "$eth_moid" \
    --arg port "$port_moid" \
    --arg qos "$qos_moid" \
    --arg net "$net_moid" \
    --arg ntp "$ntp_moid" '
    [
      {Moid:$eth,ObjectType:"fabric.EthNetworkPolicy"},
      {Moid:$qos,ObjectType:"fabric.SystemQosPolicy"},
      {Moid:$ntp,ObjectType:"ntp.Policy"},
      {Moid:$net,ObjectType:"networkconfig.Policy"}
    ]
    + (if $port != "" then [{Moid:$port,ObjectType:"fabric.PortPolicy"}] else [] end)
  '
}

ensure_unified_edge_switch_profile() {
  local name="$1" switch_id="$2" cluster_moid="$3"
  local profile_moid policy_bucket body
  log "Ensuring Unified Edge switch profile '$name'"
  profile_moid="$(get_scoped_moid_by_name fabric switchprofile "$name")"
  policy_bucket="$(unified_edge_policy_bucket_json)"

  body="$(
    jq -c -n \
      --arg name "$name" \
      --arg switch_id "$switch_id" \
      --arg cluster "$cluster_moid" \
      --arg target "$UNIFIED_EDGE_TARGET_PLATFORM" \
      --argjson bucket "$policy_bucket" '
      {
        Name:$name,
        Type:"instance",
        TargetPlatform:$target,
        SwitchId:$switch_id,
        SwitchClusterProfile:{Moid:$cluster,ObjectType:"fabric.SwitchClusterProfile"},
        PolicyBucket:$bucket
      }
    '
  )"

  if [[ -z "$profile_moid" ]]; then
    printf '%s' "$body" | isctl_cmd_body create fabric switchprofile --bodyformat json >/dev/null
  else
    printf '%s' "$body" | isctl_cmd_body update fabric switchprofile moid "$profile_moid" --bodyformat json >/dev/null
  fi
}

resolve_unified_edge_assignment_pair() {
  local elements_json profiles_json busy_json resolved

  if [[ -n "${UNIFIED_EDGE_NETWORK_ELEMENT_A_MOID:-}" && -n "${UNIFIED_EDGE_NETWORK_ELEMENT_B_MOID:-}" ]]; then
    local override_json override_chassis_a override_chassis_b
    override_json="$(isctl_cmd get network element -o json)"
    override_chassis_a="$(
      printf '%s' "$override_json" \
        | jq -r --arg moid "$UNIFIED_EDGE_NETWORK_ELEMENT_A_MOID" '.[]? | select(.Moid == $moid) | .EquipmentChassis.Moid // .Parent.Moid // empty'
    )"
    override_chassis_b="$(
      printf '%s' "$override_json" \
        | jq -r --arg moid "$UNIFIED_EDGE_NETWORK_ELEMENT_B_MOID" '.[]? | select(.Moid == $moid) | .EquipmentChassis.Moid // .Parent.Moid // empty'
    )"
    [[ -n "$override_chassis_a" && "$override_chassis_a" == "$override_chassis_b" ]] || fail "Override Unified Edge network elements do not belong to the same chassis"
    UNIFIED_EDGE_CHASSIS_MOID="${UNIFIED_EDGE_CHASSIS_MOID:-$override_chassis_a}"
    UNIFIED_EDGE_NETWORK_ELEMENT_A_LABEL="$(
      printf '%s' "$override_json" \
        | jq -r --arg moid "$UNIFIED_EDGE_NETWORK_ELEMENT_A_MOID" '.[]? | select(.Moid == $moid) | .Name // .Dn // .Moid'
    )"
    UNIFIED_EDGE_NETWORK_ELEMENT_B_LABEL="$(
      printf '%s' "$override_json" \
        | jq -r --arg moid "$UNIFIED_EDGE_NETWORK_ELEMENT_B_MOID" '.[]? | select(.Moid == $moid) | .Name // .Dn // .Moid'
    )"
    return 0
  fi

  elements_json="$(isctl_cmd get network element -o json)"
  profiles_json="$(isctl_cmd get fabric switchprofile -o json)"
  busy_json="$(
    printf '%s' "$profiles_json" \
      | jq '[ .[]? | (.AssignedSwitch.Moid // empty), (.AssociatedSwitch.Moid // empty) | select(length>0) ] | unique'
  )"

  resolved="$(
    printf '%s' "$elements_json" \
      | jq -r --arg org "$ORG_MOID" --argjson busy "$busy_json" '
        [
          .[]?
          | select(((.PermissionResources // []) | map(.Moid // "") | index($org)) != null)
          | select((.SwitchType // "") == "EdgeChassisManagementController")
          | select(((.Operability // "") == "online") or ((.Operability // "") == ""))
          | select((.SwitchProfileName // "") == "")
          | select((.Moid as $m | $busy | index($m)) == null)
          | {
              chassis:(.EquipmentChassis.Moid // .Parent.Moid // ""),
              switch:(.SwitchId // ""),
              moid:(.Moid // ""),
              serial:(.Serial // ""),
              name:(.Name // .Dn // "")
            }
        ]
        | sort_by(.chassis, .switch)
        | group_by(.chassis)
        | map({
            chassis:.[0].chassis,
            a:(map(select(.switch == "A"))[0] // null),
            b:(map(select(.switch == "B"))[0] // null)
          })
        | map(select(.a != null and .b != null))
        | .[0]
        | if . then [.a.moid, .a.serial, .a.name, .b.moid, .b.serial, .b.name, .chassis] | @tsv else empty end
      '
  )"

  [[ -n "$resolved" ]] || fail "No free Unified Edge A/B network element pair found in org '$ORG_NAME'"
  IFS=$'\t' read -r \
    UNIFIED_EDGE_NETWORK_ELEMENT_A_MOID UNIFIED_EDGE_NETWORK_ELEMENT_A_SERIAL UNIFIED_EDGE_NETWORK_ELEMENT_A_LABEL \
    UNIFIED_EDGE_NETWORK_ELEMENT_B_MOID UNIFIED_EDGE_NETWORK_ELEMENT_B_SERIAL UNIFIED_EDGE_NETWORK_ELEMENT_B_LABEL \
    UNIFIED_EDGE_CHASSIS_MOID <<< "$resolved"

  log "Selected free Unified Edge chassis moid=$UNIFIED_EDGE_CHASSIS_MOID"
  log "Selected eCMC-A ${UNIFIED_EDGE_NETWORK_ELEMENT_A_LABEL:-$UNIFIED_EDGE_NETWORK_ELEMENT_A_MOID} serial=${UNIFIED_EDGE_NETWORK_ELEMENT_A_SERIAL:-unknown}"
  log "Selected eCMC-B ${UNIFIED_EDGE_NETWORK_ELEMENT_B_LABEL:-$UNIFIED_EDGE_NETWORK_ELEMENT_B_MOID} serial=${UNIFIED_EDGE_NETWORK_ELEMENT_B_SERIAL:-unknown}"
}

unified_edge_assignment_json() {
  local profile_name="$1"
  jq -c -n \
    --arg a "$UNIFIED_EDGE_NETWORK_ELEMENT_A_MOID" \
    --arg b "$UNIFIED_EDGE_NETWORK_ELEMENT_B_MOID" \
    --arg sp_a "${profile_name}-A" \
    --arg sp_b "${profile_name}-B" '
    [
      {
        NetworkElement:{Moid:$a,ObjectType:"network.Element"},
        SourceSwitchProfileOrTemplateName:$sp_a
      },
      {
        NetworkElement:{Moid:$b,ObjectType:"network.Element"},
        SourceSwitchProfileOrTemplateName:$sp_b
      }
    ]
  '
}

wait_for_unified_edge_assignment() {
  local profile_name="$1"
  local timeout poll elapsed switch_a_moid switch_b_moid assigned_a assigned_b
  timeout="$UNIFIED_EDGE_ASSIGN_TIMEOUT_SEC"
  poll="$UNIFIED_EDGE_ASSIGN_POLL_SEC"
  elapsed=0

  while (( elapsed < timeout )); do
    switch_a_moid="$(get_scoped_moid_by_name fabric switchprofile "${profile_name}-A")"
    switch_b_moid="$(get_scoped_moid_by_name fabric switchprofile "${profile_name}-B")"
    assigned_a=""
    assigned_b=""

    if [[ -n "$switch_a_moid" ]]; then
      assigned_a="$(
        isctl_cmd get fabric switchprofile moid "$switch_a_moid" -o json \
          | jq -r '.AssignedSwitch.Moid // .AssociatedSwitch.Moid // empty'
      )"
    fi
    if [[ -n "$switch_b_moid" ]]; then
      assigned_b="$(
        isctl_cmd get fabric switchprofile moid "$switch_b_moid" -o json \
          | jq -r '.AssignedSwitch.Moid // .AssociatedSwitch.Moid // empty'
      )"
    fi

    if [[ "$assigned_a" == "$UNIFIED_EDGE_NETWORK_ELEMENT_A_MOID" && "$assigned_b" == "$UNIFIED_EDGE_NETWORK_ELEMENT_B_MOID" ]]; then
      return 0
    fi

    sleep "$poll"
    elapsed=$(( elapsed + poll ))
  done

  fail "Timeout waiting for Unified Edge profile '$profile_name' to assign to selected eCMC A/B pair"
}

unified_edge_deployed_on_both_switches() {
  case "$1" in
    AB|A,B|Both|3) return 0 ;;
    *) return 1 ;;
  esac
}

assign_unified_edge_profile() {
  local profile_name="$1" cluster_moid switch_a_moid switch_b_moid assigned_a assigned_b cluster_assigned
  cluster_moid="$(get_moid_in_org fabric switchclusterprofile "$profile_name")"
  [[ -n "$cluster_moid" ]] || fail "Unable to resolve Unified Edge profile '$profile_name' for assignment"

  switch_a_moid="$(get_scoped_moid_by_name fabric switchprofile "${profile_name}-A")"
  switch_b_moid="$(get_scoped_moid_by_name fabric switchprofile "${profile_name}-B")"
  if [[ -n "$switch_a_moid" && -n "$switch_b_moid" ]]; then
    assigned_a="$(
      isctl_cmd get fabric switchprofile moid "$switch_a_moid" -o json \
        | jq -r '.AssignedSwitch.Moid // .AssociatedSwitch.Moid // empty'
    )"
    assigned_b="$(
      isctl_cmd get fabric switchprofile moid "$switch_b_moid" -o json \
        | jq -r '.AssignedSwitch.Moid // .AssociatedSwitch.Moid // empty'
    )"
    if [[ -n "$assigned_a" && -n "$assigned_b" ]]; then
      UNIFIED_EDGE_NETWORK_ELEMENT_A_MOID="$assigned_a"
      UNIFIED_EDGE_NETWORK_ELEMENT_B_MOID="$assigned_b"
      cluster_assigned="$(
        isctl_cmd get fabric switchclusterprofile moid "$cluster_moid" -o json \
          | jq -r '.AssignedEntity.Moid // empty'
      )"
      UNIFIED_EDGE_CHASSIS_MOID="$cluster_assigned"
      log "Unified Edge profile '$profile_name' is already assigned to chassis moid=${UNIFIED_EDGE_CHASSIS_MOID:-unknown}"
      return 0
    fi
  fi

  resolve_unified_edge_assignment_pair
  log "Assigning Unified Edge profile '$profile_name' to chassis moid=$UNIFIED_EDGE_CHASSIS_MOID"
  isctl_cmd update fabric switchclusterprofile moid "$cluster_moid" \
    --AssignedEntity "{\"Moid\":\"$UNIFIED_EDGE_CHASSIS_MOID\",\"ObjectType\":\"equipment.Chassis\"}" >/dev/null
  wait_for_unified_edge_assignment "$profile_name"
}

wait_for_unified_edge_deploy() {
  local profile_name="$1" cluster_moid switch_a_moid switch_b_moid
  local timeout poll elapsed cluster_json switch_a_json switch_b_json
  local cluster_state cluster_summary cluster_oper deploy_status deployed_switches
  local switch_a_state switch_b_state inconsistency
  timeout="$UNIFIED_EDGE_DEPLOY_TIMEOUT_SEC"
  poll="$UNIFIED_EDGE_DEPLOY_POLL_SEC"
  elapsed=0

  cluster_moid="$(get_moid_in_org fabric switchclusterprofile "$profile_name")"
  switch_a_moid="$(get_scoped_moid_by_name fabric switchprofile "${profile_name}-A")"
  switch_b_moid="$(get_scoped_moid_by_name fabric switchprofile "${profile_name}-B")"
  [[ -n "$cluster_moid" && -n "$switch_a_moid" && -n "$switch_b_moid" ]] || fail "Unable to resolve Unified Edge profile members for '$profile_name'"

  while (( elapsed < timeout )); do
    cluster_json="$(isctl_cmd get fabric switchclusterprofile moid "$cluster_moid" -o json)"
    switch_a_json="$(isctl_cmd get fabric switchprofile moid "$switch_a_moid" -o json)"
    switch_b_json="$(isctl_cmd get fabric switchprofile moid "$switch_b_moid" -o json)"

    cluster_state="$(printf '%s' "$cluster_json" | jq -r '.ConfigContext.ConfigState // empty')"
    cluster_summary="$(printf '%s' "$cluster_json" | jq -r '.ConfigContext.ConfigStateSummary // empty')"
    cluster_oper="$(printf '%s' "$cluster_json" | jq -r '.ConfigContext.OperState // empty')"
    deploy_status="$(printf '%s' "$cluster_json" | jq -r '.DeployStatus // empty')"
    deployed_switches="$(printf '%s' "$cluster_json" | jq -r '.DeployedSwitches // empty')"
    inconsistency="$(printf '%s' "$cluster_json" | jq -r '.ConfigContext.InconsistencyReason // [] | join(",")')"
    switch_a_state="$(printf '%s' "$switch_a_json" | jq -r '.ConfigContext.ConfigState // empty')"
    switch_b_state="$(printf '%s' "$switch_b_json" | jq -r '.ConfigContext.ConfigState // empty')"

    log "Unified Edge deploy state '$profile_name': Cluster=$cluster_state/$cluster_summary Oper=$cluster_oper DeployStatus=$deploy_status DeployedSwitches=$deployed_switches A=$switch_a_state B=$switch_b_state"

    if [[ "$cluster_state" == "Failed" || "$cluster_summary" == "Failed" || "$switch_a_state" == "Failed" || "$switch_b_state" == "Failed" ]]; then
      [[ -z "$inconsistency" ]] || log "Unified Edge deploy inconsistency: $inconsistency"
      fail "Unified Edge profile '$profile_name' deployment failed"
    fi

    if [[ "$deploy_status" == "Complete" ]] && unified_edge_deployed_on_both_switches "$deployed_switches"; then
      if [[ "$cluster_state" == "Associated" && "$switch_a_state" == "Associated" && "$switch_b_state" == "Associated" ]]; then
        return 0
      fi
    fi
    if [[ "$cluster_state" == "Associated" && "$switch_a_state" == "Associated" && "$switch_b_state" == "Associated" ]]; then
      return 0
    fi

    sleep "$poll"
    elapsed=$(( elapsed + poll ))
  done

  fail "Unified Edge profile '$profile_name' deployment did not finish within ${timeout}s"
}

deploy_unified_edge_profile() {
  local profile_name="$1" cluster_moid cluster_json cluster_state deploy_status deployed_switches deploy_out
  cluster_moid="$(get_moid_in_org fabric switchclusterprofile "$profile_name")"
  [[ -n "$cluster_moid" ]] || fail "Unable to resolve Unified Edge profile '$profile_name' for deployment"

  cluster_json="$(isctl_cmd get fabric switchclusterprofile moid "$cluster_moid" -o json)"
  cluster_state="$(printf '%s' "$cluster_json" | jq -r '.ConfigContext.ConfigState // empty')"
  deploy_status="$(printf '%s' "$cluster_json" | jq -r '.DeployStatus // empty')"
  deployed_switches="$(printf '%s' "$cluster_json" | jq -r '.DeployedSwitches // empty')"

  if [[ "$cluster_state" == "Associated" && "$deploy_status" == "Complete" ]] && unified_edge_deployed_on_both_switches "$deployed_switches"; then
    log "Deploy skipped for Unified Edge profile '$profile_name' (already Associated and Complete)"
    return 0
  fi

  log "Deploying Unified Edge profile '$profile_name'"
  if ! deploy_out="$(isctl_cmd update fabric switchclusterprofile moid "$cluster_moid" --Action Deploy 2>&1)"; then
    if printf '%s' "$deploy_out" | grep -q "Action 'Deploy' is not allowed in the current state"; then
      log "Deploy action not allowed for '$profile_name'; validating current deployment state"
      wait_for_unified_edge_deploy "$profile_name"
      return 0
    fi
    printf '%s\n' "$deploy_out" >&2
    fail "Deploy trigger failed for Unified Edge profile '$profile_name'"
  fi

  wait_for_unified_edge_deploy "$profile_name"
}

ensure_unified_edge_profiles() {
  local profile_name cluster_moid switch_a_moid switch_b_moid switch_refs

  init_unified_edge_defaults
  ensure_unified_edge_eth_network_policy
  ensure_unified_edge_vlans
  if [[ "$UNIFIED_EDGE_ENABLE_PORT_POLICY" == "true" ]]; then
    ensure_unified_edge_port_policy
    ensure_unified_edge_uplink_role
  fi
  ensure_unified_edge_qos_policy
  ensure_unified_edge_network_config_policy
  ensure_unified_edge_ntp_policy

  for profile_name in "${UNIFIED_EDGE_PROFILES[@]}"; do
    log "Ensuring Unified Edge switch cluster profile '$profile_name'"

    if ! exists_in_org fabric switchclusterprofile "$profile_name"; then
      isctl_cmd create fabric switchclusterprofile \
        --Name "$profile_name" \
        --Organization "$(json_org_ref)" \
        --TargetPlatform "$UNIFIED_EDGE_TARGET_PLATFORM" \
        --Type instance >/dev/null
    fi

    cluster_moid="$(get_moid_in_org fabric switchclusterprofile "$profile_name")"
    [[ -n "$cluster_moid" ]] || fail "Unable to resolve Unified Edge profile '$profile_name'"

    ensure_unified_edge_switch_profile "${profile_name}-A" A "$cluster_moid"
    ensure_unified_edge_switch_profile "${profile_name}-B" B "$cluster_moid"

    switch_a_moid="$(get_scoped_moid_by_name fabric switchprofile "${profile_name}-A")"
    switch_b_moid="$(get_scoped_moid_by_name fabric switchprofile "${profile_name}-B")"
    switch_refs="$(jq -c -n --arg a "$switch_a_moid" --arg b "$switch_b_moid" '[{Moid:$a,ObjectType:"fabric.SwitchProfile"},{Moid:$b,ObjectType:"fabric.SwitchProfile"}]')"
    isctl_cmd update fabric switchclusterprofile moid "$cluster_moid" --SwitchProfiles "$switch_refs" >/dev/null
    if [[ "$UNIFIED_EDGE_ENABLE_PORT_POLICY" == "true" ]]; then
      local port_moid
      port_moid="$(get_moid_in_org fabric portpolicy "$UNIFIED_EDGE_PORT_POLICY_NAME")"
      isctl_cmd update fabric portpolicy moid "$port_moid" --Profiles "$switch_refs" >/dev/null
    fi

    if [[ "$UNIFIED_EDGE_ASSIGN_PROFILE" == "true" ]]; then
      assign_unified_edge_profile "$profile_name"
    fi

    if [[ "$UNIFIED_EDGE_DEPLOY_PROFILE" == "true" ]]; then
      [[ "$UNIFIED_EDGE_ASSIGN_PROFILE" == "true" ]] || fail "UNIFIED_EDGE_DEPLOY_PROFILE=true requires UNIFIED_EDGE_ASSIGN_PROFILE=true"
      deploy_unified_edge_profile "$profile_name"
    fi
  done
}

ensure_unified_edge_before_server_profiles() {
  local profile_name missing_profile

  [[ "$DEPLOY_UNIFIED_EDGE" != "true" ]] || return 0

  build_unified_edge_profiles
  init_unified_edge_defaults
  missing_profile=""

  for profile_name in "${UNIFIED_EDGE_PROFILES[@]}"; do
    if ! exists_in_org fabric switchclusterprofile "$profile_name"; then
      missing_profile="$profile_name"
      break
    fi
  done

  if [[ -z "$missing_profile" ]]; then
    log "Unified Edge profile precheck passed: ${UNIFIED_EDGE_PROFILES[*]}"
    return 0
  fi

  log "Unified Edge profile '$missing_profile' not found; deploying Unified Edge before server profiles"
  log "Target Unified Edge profiles: ${UNIFIED_EDGE_PROFILES[*]}"
  ensure_unified_edge_profiles
  validate_unified_edge_all
}

# Select eligible servers strictly from the org-assigned resource group.
# Excludes servers already assigned/associated to any server profile.
get_available_server_moids() {
  local blades_json profiles_json busy_json
  blades_json="$(isctl_cmd get compute blade -o json)"
  profiles_json="$(isctl_cmd get server profile -o json)"
  busy_json="$(
    printf '%s' "$profiles_json" \
      | jq '[ .[]? | (.AssociatedServer.Moid // empty), (.AssignedServer.Moid // empty) | select(length>0) ] | unique'
  )"

  printf '%s' "$blades_json" | jq -r --arg org "$ORG_MOID" --argjson busy "$busy_json" '
    [ .[]?
        | select(((.PermissionResources // []) | map(.Moid) | index($org)) != null)
        | select(((.ConnectionStatus // "") == "Connected") or ((.ConnectionStatus // "") == ""))
        | select((.Moid as $m | $busy | index($m)) == null)
        | {moid: .Moid, serial: (.Serial // "")}
      ]
    | sort_by(.serial)
    | .[]
    | "\(.moid)\t\(.serial)"
  '
}

server_profile_policy_bucket_json() {
  local include_vmedia=false
  if is_harvester_target; then
    include_vmedia=true
  fi
  jq -c -n \
    --arg org "$ORG_MOID" \
    --arg access "$ACCESS_POLICY_NAME" \
    --arg users "$LOCAL_USER_POLICY_NAME" \
    --arg bios "$BIOS_POLICY_NAME" \
    --arg power "$POWER_POLICY_NAME" \
    --arg kvm "$KVM_POLICY_NAME" \
    --arg lcp "$LCP_NAME" \
    --arg storage "$STORAGE_POLICY_NAME" \
    --arg boot "$BOOT_POLICY_NAME" \
    --arg vmedia "${VMEDIA_POLICY_NAME:-}" \
    --argjson include_vmedia "$include_vmedia" '
    def selector($name): "Name eq \u0027\($name)\u0027 and Organization.Moid eq \u0027\($org)\u0027";
    [
      {ObjectType:"access.Policy", Selector:selector($access)},
      {ObjectType:"iam.EndPointUserPolicy", Selector:selector($users)},
      {ObjectType:"bios.Policy", Selector:selector($bios)},
      {ObjectType:"power.Policy", Selector:selector($power)},
      {ObjectType:"kvm.Policy", Selector:selector($kvm)},
      {ObjectType:"vnic.LanConnectivityPolicy", Selector:selector($lcp)},
      {ObjectType:"storage.StoragePolicy", Selector:selector($storage)},
      {ObjectType:"boot.PrecisionPolicy", Selector:selector($boot)}
    ] + (if $include_vmedia then [{ObjectType:"vmedia.Policy", Selector:selector($vmedia)}] else [] end)
  '
}

ensure_template_and_profiles() {
  log "Ensuring profile template and target server profiles"
  local policy_bucket template_moid template_json current_bucket current_vmedia_count current_vmedia_selector desired_bucket template_selector
  if is_harvester_target; then
    ensure_harvester_vmedia_policy
  fi
  policy_bucket="$(server_profile_policy_bucket_json)"

  if ! exists_in_org server profiletemplate "$PROFILE_TEMPLATE_NAME"; then
    isctl_cmd create server profiletemplate \
      --Name "$PROFILE_TEMPLATE_NAME" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" \
      --TargetPlatform "$TARGET_PLATFORM" \
      --UuidAddressType POOL \
      --UuidPool "{\"Selector\":\"Name eq '$UUIDPOOL_NAME' and Organization.Moid eq '$ORG_MOID'\"}" \
      --PolicyBucket "$policy_bucket" >/dev/null
  fi

  template_moid="$(get_moid_in_org server profiletemplate "$PROFILE_TEMPLATE_NAME")"
  [[ -n "$template_moid" ]] || fail "Unable to resolve template moid"
  template_json="$(isctl_cmd get server profiletemplate moid "$template_moid" -o json)"
  current_bucket="$(printf '%s' "$template_json" | jq -c '.PolicyBucket // []')"
  current_vmedia_count="$(printf '%s' "$current_bucket" | jq '[.[] | select((.ObjectType // "") == "vmedia.Policy")] | length')"
  if is_harvester_target; then
    template_selector="$(jq -nr --arg name "$VMEDIA_POLICY_NAME" --arg org "$ORG_MOID" '"Name eq \u0027\($name)\u0027 and Organization.Moid eq \u0027\($org)\u0027"')"
    current_vmedia_selector="$(printf '%s' "$current_bucket" | jq -r '[.[] | select((.ObjectType // "") == "vmedia.Policy")][0].Selector // empty')"
    if [[ "$current_vmedia_count" != "1" || "$current_vmedia_selector" != "$template_selector" ]]; then
      desired_bucket="$(printf '%s' "$current_bucket" | jq -c --arg selector "$template_selector" '
        [.[] | select((.ObjectType // "") != "vmedia.Policy")]
        + [{ObjectType:"vmedia.Policy",Selector:$selector}]')"
      log "Adding vMedia policy '$VMEDIA_POLICY_NAME' to profile template '$PROFILE_TEMPLATE_NAME' before creating server profiles"
      isctl_cmd update server profiletemplate moid "$template_moid" --PolicyBucket "$desired_bucket" >/dev/null
    else
      log "Profile template '$PROFILE_TEMPLATE_NAME' already references vMedia policy '$VMEDIA_POLICY_NAME'"
    fi
  elif [[ "$current_vmedia_count" -gt 0 ]]; then
    log "Removing vMedia policy from profile template '$PROFILE_TEMPLATE_NAME' for non-Harvester target"
    isctl_cmd update server profiletemplate moid "$template_moid" --PolicyBucket "$policy_bucket" >/dev/null
  fi

  local missing_profiles=()
  local profile_name
  for profile_name in "${TARGET_PROFILE_NAMES[@]}"; do
    if ! exists_in_org server profile "$profile_name"; then
      missing_profiles+=("$profile_name")
    fi
  done

  if (( ${#missing_profiles[@]} == 0 )); then
    log "All target profiles already exist (${#TARGET_PROFILE_NAMES[@]}/${#TARGET_PROFILE_NAMES[@]})"
    return 0
  fi

  local available_lines=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    available_lines+=("$line")
  done < <(get_available_server_moids)

  local need_count="${#missing_profiles[@]}"
  local have_count="${#available_lines[@]}"
  (( have_count >= need_count )) || fail "Not enough available servers in resource group '$RESOURCE_GROUP_NAME': need=$need_count available=$have_count"

  # Keep track of newly-used servers so we can apply the tunneled-KVM refresh section.
  local created_server_moids=()
  local idx=0 server_moid server_serial
  for profile_name in "${missing_profiles[@]}"; do
    server_moid="$(printf '%s' "${available_lines[$idx]}" | awk -F '\t' '{print $1}')"
    server_serial="$(printf '%s' "${available_lines[$idx]}" | awk -F '\t' '{print $2}')"
    [[ -n "$server_moid" ]] || fail "Unable to select server moid for profile $profile_name"

    log "Creating profile '$profile_name' on server serial '$server_serial' (moid=$server_moid)"
    isctl_cmd create server profile \
      --Name "$profile_name" \
      --Organization "{\"Moid\":\"$ORG_MOID\"}" \
      --TargetPlatform "$TARGET_PLATFORM" \
      --ServerAssignmentMode Static \
      --AssignedServer "{\"Moid\":\"$server_moid\",\"ObjectType\":\"compute.Blade\"}" \
      --SrcTemplate "{\"Moid\":\"$template_moid\",\"ObjectType\":\"server.ProfileTemplate\"}" >/dev/null

    created_server_moids+=("$server_moid")
    idx=$(( idx + 1 ))
  done

  # Section: refresh tunneled KVM on newly used servers (disable, then enable).
  # This is done immediately after new profile creation and before deploy/activate.
  if (( ${#created_server_moids[@]} > 0 )); then
    log "Refreshing tunneled KVM on ${#created_server_moids[@]} newly used server(s)"
    local s_moid
    for s_moid in "${created_server_moids[@]}"; do
      log "Tunneled KVM disable on server moid '$s_moid'"
      isctl_cmd update compute blade moid "$s_moid" --TunneledKvm=false >/dev/null
      sleep 2
      log "Tunneled KVM enable on server moid '$s_moid'"
      isctl_cmd update compute blade moid "$s_moid" --TunneledKvm=true >/dev/null
      sleep 2
    done
  fi
}

deploy_profile_by_name() {
  local profile_name="$1"
  log "Ensuring profile '$profile_name' is template-attached and deploying"
  local profile_moid
  profile_moid="$(get_profile_moid_in_org_by_name "$profile_name")"
  [[ -n "$profile_moid" ]] || fail "Profile '$profile_name' not found in org '$ORG_NAME'"

  local policy_bucket_count template_sync_status
  policy_bucket_count="$(
    get_profile_json_in_org_by_name "$profile_name" \
      | jq -r '.[0].PolicyBucket|length'
  )"
  template_sync_status="$(
    get_profile_json_in_org_by_name "$profile_name" \
      | jq -r '.[0].TemplateSyncStatus // ""'
  )"

  if [[ "$policy_bucket_count" == "0" || "$template_sync_status" == "None" ]]; then
    isctl_cmd update server profile moid "$profile_moid" --TemplateActions '[{"Type":"Attach"}]' >/dev/null
  elif [[ "$template_sync_status" != "OK" ]]; then
    log "Synchronizing profile '$profile_name' with template '$PROFILE_TEMPLATE_NAME'"
    isctl_cmd update server profile moid "$profile_moid" --TemplateActions '[{"Type":"Sync"}]' >/dev/null
  fi

  local elapsed=0
  while (( elapsed < DEPLOY_TIMEOUT_SEC )); do
    policy_bucket_count="$(
      get_profile_json_in_org_by_name "$profile_name" \
        | jq -r '.[0].PolicyBucket|length'
    )"
    template_sync_status="$(
      get_profile_json_in_org_by_name "$profile_name" \
        | jq -r '.[0].TemplateSyncStatus // ""'
    )"
    if [[ "$policy_bucket_count" -gt 0 && "$template_sync_status" == "OK" ]]; then
      break
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
  done

  [[ "$policy_bucket_count" -gt 0 ]] || fail "Profile '$profile_name' has no attached policies after template sync"
  [[ "$template_sync_status" == "OK" ]] || fail "Profile '$profile_name' template sync not complete after ${DEPLOY_TIMEOUT_SEC}s"

  local pre_state
  pre_state="$(
    get_profile_json_in_org_by_name "$profile_name" \
      | jq -r '.[0].ConfigContext.ConfigState // ""'
  )"
  if [[ "$pre_state" == "Associated" ]]; then
    log "Deploy skipped for '$profile_name' (already Associated)"
    return 0
  fi

  log "Pausing ${DEPLOY_PAUSE_SEC}s before deploy trigger for '$profile_name'"
  sleep "$DEPLOY_PAUSE_SEC"
  local deploy_out
  if ! deploy_out="$(isctl_cmd update server profile moid "$profile_moid" --Action Deploy 2>&1)"; then
    if printf '%s' "$deploy_out" | grep -q "Action 'Deploy' is not allowed in the current state"; then
      log "Deploy skipped for '$profile_name' (not allowed in current state)"
      return 0
    fi
    printf '%s\n' "$deploy_out" >&2
    fail "Deploy trigger failed for '$profile_name'"
  fi
  log "Pausing ${DEPLOY_PAUSE_SEC}s after deploy trigger for '$profile_name'"
  sleep "$DEPLOY_PAUSE_SEC"

  elapsed=0
  while (( elapsed < DEPLOY_TIMEOUT_SEC )); do
    local config_state oper_state
    config_state="$(
      get_profile_json_in_org_by_name "$profile_name" \
        | jq -r '.[0].ConfigContext.ConfigState // ""'
    )"
    oper_state="$(
      get_profile_json_in_org_by_name "$profile_name" \
        | jq -r '.[0].ConfigContext.OperState // ""'
    )"
    log "Deploy state '$profile_name': ConfigState=$config_state OperState=$oper_state"
    if [[ "$config_state" == "Associated" ]]; then
      return 0
    fi
    if [[ "$config_state" == "Failed" ]]; then
      fail "Profile '$profile_name' deployment failed"
    fi
    sleep 10
    elapsed=$(( elapsed + 10 ))
  done

  fail "Profile '$profile_name' deployment did not finish within ${DEPLOY_TIMEOUT_SEC}s"
}

activate_profile_by_name() {
  local profile_name="$1"
  log "Scheduling activation for profile '$profile_name'"
  local profile_moid
  profile_moid="$(get_profile_moid_in_org_by_name "$profile_name")"
  [[ -n "$profile_moid" ]] || fail "Profile '$profile_name' not found in org '$ORG_NAME'"

  local activate_out
  if ! activate_out="$(
    isctl_cmd update server profile moid "$profile_moid" \
      --ScheduledActions "[{\"Action\":\"Activate\",\"ProceedOnReboot\":$ACTIVATION_PROCEED_ON_REBOOT}]" 2>&1
  )"; then
    if printf '%s' "$activate_out" | grep -q "Action 'Activate' is not allowed in the current state"; then
      log "Activation request rejected for '$profile_name' (already active or state not eligible)"
      return 0
    fi
    printf '%s\n' "$activate_out" >&2
    fail "Activation scheduling failed for '$profile_name'"
  fi

  local elapsed=0
  while (( elapsed < ACTIVATION_TIMEOUT_SEC )); do
    local config_state oper_state inconsistency
    config_state="$(
      get_profile_json_in_org_by_name "$profile_name" \
        | jq -r '.[0].ConfigContext.ConfigState // ""'
    )"
    oper_state="$(
      get_profile_json_in_org_by_name "$profile_name" \
        | jq -r '.[0].ConfigContext.OperState // ""'
    )"
    inconsistency="$(
      get_profile_json_in_org_by_name "$profile_name" \
        | jq -r '. [0].ConfigContext.InconsistencyReason // [] | join(",")'
    )"
    log "Activation state '$profile_name': ConfigState=$config_state OperState=$oper_state InconsistencyReason=$inconsistency"

    if [[ "$config_state" == "Associated" ]]; then
      return 0
    fi
    if [[ "$config_state" == "Failed" ]]; then
      fail "Profile '$profile_name' activation failed"
    fi
    sleep 30
    elapsed=$(( elapsed + 30 ))
  done

  fail "Profile '$profile_name' activation did not finish within ${ACTIVATION_TIMEOUT_SEC}s"
}

resolve_os_catalog_moid() {
  local wanted_name catalogs_json
  if [[ -n "${OS_CATALOG_MOID:-}" ]]; then
    printf '%s\n' "$OS_CATALOG_MOID"
    return 0
  fi
  if [[ "${OS_CATALOG_NAME}" == "ORG" ]]; then
    wanted_name="$ORG_MOID"
  else
    wanted_name="$OS_CATALOG_NAME"
  fi
  catalogs_json="$(isctl_cmd get os catalog --filter "Name eq '$wanted_name'" -o json)"
  printf '%s\n' "$catalogs_json" \
    | jq -r --arg org "$ORG_MOID" '
      [ .[] | select(((.PermissionResources // []) | map(.Moid // "") | index($org)) != null) ][0].Moid // empty
    '
}

resolve_hcl_os_moid_by_version() {
  local version="$1"
  isctl_cmd get hcl operatingsystem --filter "Version eq '$version'" -o json | jq -r '.[0].Moid // empty'
}

resolve_os_config_moid_by_name() {
  local cfg_name="$1" catalog_moid="${2:-}"
  local cfg_json
  cfg_json="$(isctl_cmd get os configurationfile --filter "Name eq '$cfg_name'" -o json)"
  if [[ -n "$catalog_moid" ]]; then
    printf '%s\n' "$cfg_json" | jq -r --arg cm "$catalog_moid" '[.[] | select((.Catalog.Moid // "") == $cm)][0].Moid // empty'
  else
    printf '%s\n' "$cfg_json" | jq -r '.[0].Moid // empty'
  fi
}

profile_server_moid_by_name() {
  local profile_name="$1" server_moid
  server_moid="$(
    isctl_cmd get server profile --filter "Name eq '$profile_name' and Organization.Moid eq '$ORG_MOID'" -o json \
      | jq -r '.[0].AssignedServer.Moid // .[0].AssociatedServer.Moid // empty'
  )"
  printf '%s\n' "$server_moid"
}

profile_serial_by_name() {
  local profile_name="$1" server_moid
  server_moid="$(profile_server_moid_by_name "$profile_name")"
  [[ -n "$server_moid" ]] || return 1
  isctl_cmd get compute blade moid "$server_moid" -o json | jq -r '.Serial // empty'
}

resolve_os_image_moid() {
  local osf_moid repo_catalog_moid
  if [[ -n "${OS_IMAGE_MOID:-}" ]]; then
    printf '%s\n' "$OS_IMAGE_MOID"
    return 0
  fi
  repo_catalog_moid="$(resolve_software_repo_catalog_moid || true)"
  osf_moid="$(
    isctl_cmd get softwarerepository operatingsystemfile --filter "Name eq '$OS_IMAGE_NAME'" -o json \
      | jq -r --arg org "$ORG_MOID" --arg cm "$repo_catalog_moid" '
        [
          .[]
          | select(
              (((.PermissionResources // []) | map(.Moid // "") | index($org)) != null)
              or ((.Catalog.Moid // "") == $cm)
            )
        ][0].Moid // empty
      '
  )"
  printf '%s\n' "$osf_moid"
}

resolve_software_repo_catalog_moid() {
  local catalogs_json
  catalogs_json="$(isctl_cmd get softwarerepository catalog -o json)"
  printf '%s\n' "$catalogs_json" \
    | jq -r --arg org "$ORG_MOID" '
      [ .[]
        | select(((.PermissionResources // []) | map(.Moid // "") | index($org)) != null)
        | select((.Name // "") == "user-catalog")
      ][0].Moid // empty
    '
}

resolve_osdu_image_moid() {
  isctl_cmd get firmware serverconfigurationutilitydistributable -o json \
    | jq -r --arg org "$ORG_MOID" '
      (
        [ .[]
          | select(((.PermissionResources // []) | map(.Moid // "") | index($org)) != null)
        ] | sort_by(.CreateTime // "") | reverse | .[0].Moid
      ) // (
        [ .[] | select((.SharedScope // "") == "shared") ]
        | sort_by(.CreateTime // "") | reverse | .[0].Moid
      ) // empty
    '
}

ensure_os_image_file() {
  log "Ensuring OS image object exists in Software Repository (from URL)"
  local osf_moid catalog_moid current_link body
  osf_moid="$(resolve_os_image_moid)"
  catalog_moid="$(resolve_software_repo_catalog_moid)"
  [[ -n "$catalog_moid" ]] || fail "Unable to resolve software repository catalog moid for org '$ORG_NAME'"

  if [[ -z "$osf_moid" ]]; then
    body="$(jq -n \
      --arg name "$OS_IMAGE_NAME" \
      --arg desc "OS image for ${ORG_NAME}" \
      --arg cm "$catalog_moid" \
      --arg org "$ORG_MOID" \
      --arg link "$OS_IMAGE_LINK" \
      --arg vendor "Ubuntu" \
      --arg version "$OS_HCL_VERSION_PRIMARY" \
      '{
        Name:$name,
        Description:$desc,
        Vendor:$vendor,
        Version:$version,
        Catalog:{Moid:$cm,ObjectType:"softwarerepository.Catalog"},
        Source:{ObjectType:"softwarerepository.HttpServer",LocationLink:$link,Username:""}
      }'
    )"
    printf '%s' "$body" | isctl_cmd_body create softwarerepository operatingsystemfile --bodyformat json >/dev/null
    log "Created OS image '$OS_IMAGE_NAME' from '$OS_IMAGE_LINK'"
  else
    current_link="$(
      isctl_cmd get softwarerepository operatingsystemfile moid "$osf_moid" -o json \
        | jq -r '.Source.LocationLink // empty'
    )"
    if [[ "$current_link" != "$OS_IMAGE_LINK" ]]; then
      body="$(jq -n \
        --arg name "$OS_IMAGE_NAME" \
        --arg desc "OS image for ${ORG_NAME}" \
        --arg cm "$catalog_moid" \
        --arg org "$ORG_MOID" \
        --arg link "$OS_IMAGE_LINK" \
        --arg vendor "Ubuntu" \
        --arg version "$OS_HCL_VERSION_PRIMARY" \
        '{
          Name:$name,
          Description:$desc,
          Vendor:$vendor,
          Version:$version,
          Catalog:{Moid:$cm,ObjectType:"softwarerepository.Catalog"},
          Source:{ObjectType:"softwarerepository.HttpServer",LocationLink:$link,Username:""}
        }'
      )"
      printf '%s' "$body" | isctl_cmd_body update softwarerepository operatingsystemfile moid "$osf_moid" --bodyformat json >/dev/null
      log "Updated OS image '$OS_IMAGE_NAME' source URL to '$OS_IMAGE_LINK'"
    else
      log "OS image '$OS_IMAGE_NAME' already points to '$OS_IMAGE_LINK'"
    fi
  fi
}


validate_all() {
  log "Validating org assignments and critical settings"
  local ok=true

  validate_obj() {
    local noun="$1" type="$2" name="$3"
    local moid
    moid="$(get_moid_in_org "$noun" "$type" "$name")"
    if [[ -z "$moid" ]]; then
      ok=false
      log "Missing in org: $noun $type $name"
    fi
  }

  validate_obj organization organization "$ORG_NAME"
  validate_obj ippool pool "$IPPOOL_NAME"
  validate_obj access policy "$ACCESS_POLICY_NAME"
  validate_obj iam endpointuserpolicy "$LOCAL_USER_POLICY_NAME"
  validate_obj iam endpointuser "$LOCAL_USER_NAME"
  validate_obj bios policy "$BIOS_POLICY_NAME"
  validate_obj power policy "$POWER_POLICY_NAME"
  validate_obj kvm policy "$KVM_POLICY_NAME"
  validate_obj macpool pool "$MACPOOL_NAME"
  validate_obj vnic ethqospolicy "$ETH_QOS_POLICY_NAME"
  validate_obj fabric ethnetworkgrouppolicy "$ETH_NETWORK_GROUP_NAME"
  validate_obj vnic lanconnectivitypolicy "$LCP_NAME"
  validate_obj storage storagepolicy "$STORAGE_POLICY_NAME"
  validate_obj boot precisionpolicy "$BOOT_POLICY_NAME"
  validate_obj uuidpool pool "$UUIDPOOL_NAME"
  validate_obj server profiletemplate "$PROFILE_TEMPLATE_NAME"
  if is_harvester_target; then
    validate_obj vmedia policy "$VMEDIA_POLICY_NAME"
  fi

  local p
  for p in "${TARGET_PROFILE_NAMES[@]}"; do
    validate_obj server profile "$p"
  done

  local admin_binding_count
  admin_binding_count="$({
    isctl_cmd get iam endpointuserrole -o json \
      | jq --arg p "$ENDPOINT_USER_POLICY_MOID" --arg u "$ENDPOINT_USER_MOID" --arg r "$ADMIN_ENDPOINT_ROLE_MOID" \
        '[.[] | select((.EndPointUserPolicy.Moid // "")==$p and (.EndPointUser.Moid // "")==$u and (((.EndPointRole // .EndPointRoles // []) | map(.Moid // "")) | index($r) != null))] | length'
  })"
  [[ "$admin_binding_count" -gt 0 ]] || { ok=false; log "Local user '$LOCAL_USER_NAME' is not bound to admin endpoint role"; }

  local lcp_moid vnic1_switch vnic2_switch
  lcp_moid="$(get_moid_in_org vnic lanconnectivitypolicy "$LCP_NAME")"
  vnic1_switch="$(isctl_cmd get vnic ethif --filter "Name eq '$VNIC1_NAME' and LanConnectivityPolicy.Moid eq '$lcp_moid'" -o json | jq -r '.[0].Placement.SwitchId // empty')"
  vnic2_switch="$(isctl_cmd get vnic ethif --filter "Name eq '$VNIC2_NAME' and LanConnectivityPolicy.Moid eq '$lcp_moid'" -o json | jq -r '.[0].Placement.SwitchId // empty')"

  [[ "$vnic1_switch" == "$VNIC1_SWITCH_ID" && "$vnic2_switch" == "$VNIC2_SWITCH_ID" ]] || { ok=false; log "vNIC SwitchId validation failed"; }

  local controller_slot boot_devices template_platform template_vmedia_bucket_count eth_group_json eth_allowed_vlans eth_native_vlan
  local eth_allowed_vlans_normalized expected_allowed_vlans_normalized
  controller_slot="$(isctl_cmd get storage storagepolicy --filter "Name eq '$STORAGE_POLICY_NAME' and Organization.Moid eq '$ORG_MOID'" -o json | jq -r '.[0].M2VirtualDrive.ControllerSlot // empty')"
  boot_devices="$(isctl_cmd get boot precisionpolicy --filter "Name eq '$BOOT_POLICY_NAME' and Organization.Moid eq '$ORG_MOID'" -o json | jq -r '.[0].BootDevices | map(.Name + ":" + (.Slot // "")) | join(",")')"
  template_platform="$(isctl_cmd get server profiletemplate --filter "Name eq '$PROFILE_TEMPLATE_NAME' and Organization.Moid eq '$ORG_MOID'" -o json | jq -r '.[0].TargetPlatform // empty')"
  template_vmedia_bucket_count="$(isctl_cmd get server profiletemplate --filter "Name eq '$PROFILE_TEMPLATE_NAME' and Organization.Moid eq '$ORG_MOID'" -o json | jq '[.[0].PolicyBucket[]? | select((.ObjectType // "") == "vmedia.Policy")] | length')"
  eth_group_json="$(isctl_cmd get fabric ethnetworkgrouppolicy --filter "Name eq '$ETH_NETWORK_GROUP_NAME' and Organization.Moid eq '$ORG_MOID'" -o json | jq '.[0]')"
  eth_allowed_vlans="$(printf '%s' "$eth_group_json" | jq -r '.VlanSettings.AllowedVlans // empty')"
  eth_allowed_vlans_normalized="$(normalize_vlan_list "$eth_allowed_vlans")"
  expected_allowed_vlans_normalized="$(normalize_vlan_list "$ALLOWED_VLANS")"
  eth_native_vlan="$(printf '%s' "$eth_group_json" | jq -r '.VlanSettings.NativeVlan // 0')"

  [[ "$controller_slot" == "$M2_CONTROLLER_SLOT" ]] || { ok=false; log "Storage controller slot validation failed"; }
  [[ "$boot_devices" == *"$BOOT_LOCALDISK_NAME:$BOOT_LOCALDISK_SLOT"* ]] || { ok=false; log "Boot policy MSTOR-RAID validation failed"; }
  [[ "$boot_devices" != *"PCHSTORAGE"* ]] || { ok=false; log "Boot policy still contains PCHSTORAGE"; }
  [[ "$template_platform" == "$TARGET_PLATFORM" ]] || { ok=false; log "Template TargetPlatform validation failed"; }
  if is_harvester_target; then
    [[ "$template_vmedia_bucket_count" -gt 0 ]] || { ok=false; log "Profile template '$PROFILE_TEMPLATE_NAME' is missing the Harvester vMedia policy"; }
  else
    [[ "$template_vmedia_bucket_count" == "0" ]] || { ok=false; log "Profile template '$PROFILE_TEMPLATE_NAME' still contains a vMedia policy"; }
  fi
  [[ "$eth_allowed_vlans_normalized" == "$expected_allowed_vlans_normalized" ]] || { ok=false; log "Ethernet network group allowed VLANs are '$eth_allowed_vlans', expected equivalent of '$ALLOWED_VLANS'"; }
  if [[ -n "${NATIVE_VLAN:-}" ]]; then
    [[ "$eth_native_vlan" == "$NATIVE_VLAN" ]] || { ok=false; log "Ethernet network group native VLAN is '$eth_native_vlan', expected '$NATIVE_VLAN'"; }
  else
    [[ "$eth_native_vlan" == "0" ]] || { ok=false; log "Ethernet network group native VLAN is '$eth_native_vlan', expected none"; }
  fi

  for p in "${TARGET_PROFILE_NAMES[@]}"; do
    local profile_platform profile_vmedia_bucket_count
    profile_platform="$(isctl_cmd get server profile --filter "Name eq '$p' and Organization.Moid eq '$ORG_MOID'" -o json | jq -r '.[0].TargetPlatform // empty')"
    profile_vmedia_bucket_count="$(isctl_cmd get server profile --filter "Name eq '$p' and Organization.Moid eq '$ORG_MOID'" -o json | jq '[.[0].PolicyBucket[]? | select((.ObjectType // "") == "vmedia.Policy")] | length')"
    [[ "$profile_platform" == "$TARGET_PLATFORM" ]] || { ok=false; log "TargetPlatform validation failed for profile '$p'"; }
    if is_harvester_target; then
      [[ "$profile_vmedia_bucket_count" -gt 0 ]] || { ok=false; log "Server profile '$p' is missing the Harvester vMedia policy"; }
    else
      [[ "$profile_vmedia_bucket_count" == "0" ]] || { ok=false; log "Server profile '$p' still contains a vMedia policy"; }
    fi
  done

  if [[ "$ok" == true ]]; then
    log "Validation PASSED"
  else
    fail "Validation FAILED"
  fi
}

validate_unified_edge_all() {
  log "Validating Unified Edge profile and policy settings"
  local ok=true profile_name cluster_moid switch_a_moid switch_b_moid switch_moid
  local eth_moid port_moid qos_moid net_moid ntp_moid vlan_count bucket_check

  eth_moid="$(get_moid_in_org fabric ethnetworkpolicy "$UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME")"
  port_moid=""
  if [[ "$UNIFIED_EDGE_ENABLE_PORT_POLICY" == "true" ]]; then
    port_moid="$(get_moid_in_org fabric portpolicy "$UNIFIED_EDGE_PORT_POLICY_NAME")"
  fi
  qos_moid="$(get_moid_in_org fabric systemqospolicy "$UNIFIED_EDGE_QOS_POLICY_NAME")"
  net_moid="$(get_moid_in_org networkconfig policy "$UNIFIED_EDGE_NETWORK_CONNECTIVITY_POLICY_NAME")"
  ntp_moid="$(get_moid_in_org ntp policy "$UNIFIED_EDGE_NTP_POLICY_NAME")"

  [[ -n "$eth_moid" ]] || { ok=false; log "Missing Unified Edge Ethernet network policy '$UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME'"; }
  if [[ "$UNIFIED_EDGE_ENABLE_PORT_POLICY" == "true" ]]; then
    [[ -n "$port_moid" ]] || { ok=false; log "Missing Unified Edge port policy '$UNIFIED_EDGE_PORT_POLICY_NAME'"; }
    if [[ -n "$port_moid" ]]; then
      local port_model uplink_role_count
      port_model="$(
        isctl_cmd get fabric portpolicy moid "$port_moid" -o json \
          | jq -r '.DeviceModel // empty'
      )"
      [[ "$port_model" == "$UNIFIED_EDGE_PORT_POLICY_DEVICE_MODEL" ]] || { ok=false; log "Unified Edge port policy '$UNIFIED_EDGE_PORT_POLICY_NAME' has DeviceModel='$port_model', expected '$UNIFIED_EDGE_PORT_POLICY_DEVICE_MODEL'"; }

      if [[ "$UNIFIED_EDGE_ENABLE_UPLINK_ROLE" == "true" ]]; then
        uplink_role_count="$(
          isctl_cmd get fabric uplinkrole -o json \
            | jq \
                --arg pp "$port_moid" \
                --argjson slot "$UNIFIED_EDGE_UPLINK_SLOT_ID" \
                --argjson port "$UNIFIED_EDGE_UPLINK_PORT_ID" \
                --arg speed "$UNIFIED_EDGE_UPLINK_ADMIN_SPEED" \
                --arg fec "$UNIFIED_EDGE_UPLINK_FEC" '
                [
                  .[]?
                  | select((.PortPolicy.Moid // "") == $pp)
                  | select((.SlotId // -1) == $slot)
                  | select((.PortId // -1) == $port)
                  | select((.AdminSpeed // "") == $speed)
                  | select((.Fec // "") == $fec)
                ] | length
              '
        )"
        [[ "$uplink_role_count" -gt 0 ]] || { ok=false; log "Missing Unified Edge uplink role slot=$UNIFIED_EDGE_UPLINK_SLOT_ID port=$UNIFIED_EDGE_UPLINK_PORT_ID under port policy '$UNIFIED_EDGE_PORT_POLICY_NAME'"; }
      fi
    fi
  fi
  [[ -n "$qos_moid" ]] || { ok=false; log "Missing Unified Edge QoS policy '$UNIFIED_EDGE_QOS_POLICY_NAME'"; }
  [[ -n "$net_moid" ]] || { ok=false; log "Missing Unified Edge network connectivity policy '$UNIFIED_EDGE_NETWORK_CONNECTIVITY_POLICY_NAME'"; }
  [[ -n "$ntp_moid" ]] || { ok=false; log "Missing Unified Edge NTP policy '$UNIFIED_EDGE_NTP_POLICY_NAME'"; }

  if [[ -n "$net_moid" && -n "${UNIFIED_EDGE_DNS_SERVERS:-}" ]]; then
    local expected_primary_dns expected_alternate_dns actual_primary_dns actual_alternate_dns
    expected_primary_dns="$(printf '%s' "$UNIFIED_EDGE_DNS_SERVERS" | tr ',' ' ' | awk '{print $1}')"
    expected_alternate_dns="$(printf '%s' "$UNIFIED_EDGE_DNS_SERVERS" | tr ',' ' ' | awk '{print $2}')"
    actual_primary_dns="$(
      isctl_cmd get networkconfig policy moid "$net_moid" -o json \
        | jq -r '.PreferredIpv4dnsServer // empty'
    )"
    actual_alternate_dns="$(
      isctl_cmd get networkconfig policy moid "$net_moid" -o json \
        | jq -r '.AlternateIpv4dnsServer // empty'
    )"
    [[ "$actual_primary_dns" == "$expected_primary_dns" ]] || { ok=false; log "Unified Edge network connectivity policy primary DNS is '$actual_primary_dns', expected '$expected_primary_dns'"; }
    if [[ -n "$expected_alternate_dns" ]]; then
      [[ "$actual_alternate_dns" == "$expected_alternate_dns" ]] || { ok=false; log "Unified Edge network connectivity policy alternate DNS is '$actual_alternate_dns', expected '$expected_alternate_dns'"; }
    fi
  fi

  if [[ -n "$ntp_moid" ]]; then
    local expected_ntp_json actual_ntp_json actual_timezone actual_ntp_enabled
    expected_ntp_json="$(
      printf '%s' "${UNIFIED_EDGE_NTP_SERVERS:-}" \
        | tr ',' '\n' \
        | awk 'NF {print $1}' \
        | jq -R . \
        | jq -s -S -c 'sort'
    )"
    actual_ntp_json="$(
      isctl_cmd get ntp policy moid "$ntp_moid" -o json \
        | jq -S -c '(.NtpServers // []) | sort'
    )"
    actual_timezone="$(
      isctl_cmd get ntp policy moid "$ntp_moid" -o json \
        | jq -r '.Timezone // empty'
    )"
    actual_ntp_enabled="$(
      isctl_cmd get ntp policy moid "$ntp_moid" -o json \
        | jq -r '.Enabled // false'
    )"
    [[ "$actual_timezone" == "$UNIFIED_EDGE_NTP_TIMEZONE" ]] || { ok=false; log "Unified Edge NTP policy timezone is '$actual_timezone', expected '$UNIFIED_EDGE_NTP_TIMEZONE'"; }
    [[ "$actual_ntp_json" == "$expected_ntp_json" ]] || { ok=false; log "Unified Edge NTP policy servers are '$actual_ntp_json', expected '$expected_ntp_json'"; }
    if [[ "$expected_ntp_json" != "[]" ]]; then
      [[ "$actual_ntp_enabled" == "true" ]] || { ok=false; log "Unified Edge NTP policy is not enabled"; }
    fi
  fi

  if [[ -n "$eth_moid" ]]; then
    local native_vlan_count
    vlan_count="$(
      isctl_cmd get fabric vlan --filter "EthNetworkPolicy.Moid eq '$eth_moid'" -o json \
        | jq 'length'
    )"
    [[ "$vlan_count" -gt 0 ]] || { ok=false; log "No VLANs found under Unified Edge Ethernet policy '$UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME'"; }
    native_vlan_count="$(
      isctl_cmd get fabric vlan --filter "EthNetworkPolicy.Moid eq '$eth_moid'" -o json \
        | jq '[.[]? | select((.IsNative // false) == true)] | length'
    )"
    [[ "$native_vlan_count" == "0" ]] || { ok=false; log "Unified Edge Ethernet policy '$UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME' still has native VLAN entries"; }
  fi

  for profile_name in "${UNIFIED_EDGE_PROFILES[@]}"; do
    cluster_moid="$(get_moid_in_org fabric switchclusterprofile "$profile_name")"
    [[ -n "$cluster_moid" ]] || { ok=false; log "Missing Unified Edge profile '$profile_name'"; continue; }

    switch_a_moid="$(get_scoped_moid_by_name fabric switchprofile "${profile_name}-A")"
    switch_b_moid="$(get_scoped_moid_by_name fabric switchprofile "${profile_name}-B")"
    [[ -n "$switch_a_moid" ]] || { ok=false; log "Missing Unified Edge switch profile '${profile_name}-A'"; }
    [[ -n "$switch_b_moid" ]] || { ok=false; log "Missing Unified Edge switch profile '${profile_name}-B'"; }

    if [[ "$UNIFIED_EDGE_ENABLE_PORT_POLICY" == "true" && -n "$port_moid" && -n "$switch_a_moid" && -n "$switch_b_moid" ]]; then
      local port_profile_check
      port_profile_check="$(
        isctl_cmd get fabric portpolicy moid "$port_moid" -o json \
          | jq -r --arg a "$switch_a_moid" --arg b "$switch_b_moid" '
              [ .Profiles[]?.Moid ] as $m
              | (($m | index($a)) != null) and (($m | index($b)) != null)
            '
      )"
      [[ "$port_profile_check" == "true" ]] || { ok=false; log "Unified Edge port policy '$UNIFIED_EDGE_PORT_POLICY_NAME' is not linked to both switch profiles"; }
    fi

    for switch_moid in "$switch_a_moid" "$switch_b_moid"; do
      [[ -n "$switch_moid" ]] || continue
      bucket_check="$(
        isctl_cmd get fabric switchprofile moid "$switch_moid" -o json \
          | jq -r --arg eth "$eth_moid" --arg port "$port_moid" --arg qos "$qos_moid" --arg ntp "$ntp_moid" --arg net "$net_moid" '
              [ .PolicyBucket[]?.Moid ] as $m
              | (($m | index($eth)) != null)
                and (($port == "") or (($m | index($port)) != null))
                and (($m | index($qos)) != null)
                and (($m | index($ntp)) != null)
                and (($m | index($net)) != null)
            '
      )"
      [[ "$bucket_check" == "true" ]] || { ok=false; log "Unified Edge switch profile moid '$switch_moid' policy bucket is incomplete"; }
    done

    if [[ "$UNIFIED_EDGE_ASSIGN_PROFILE" == "true" ]]; then
      local assigned_a assigned_b
      assigned_a="$(
        isctl_cmd get fabric switchprofile moid "$switch_a_moid" -o json \
          | jq -r '.AssignedSwitch.Moid // .AssociatedSwitch.Moid // empty'
      )"
      assigned_b="$(
        isctl_cmd get fabric switchprofile moid "$switch_b_moid" -o json \
          | jq -r '.AssignedSwitch.Moid // .AssociatedSwitch.Moid // empty'
      )"
      [[ "$assigned_a" == "$UNIFIED_EDGE_NETWORK_ELEMENT_A_MOID" ]] || { ok=false; log "Unified Edge switch profile '${profile_name}-A' is not assigned to selected eCMC-A"; }
      [[ "$assigned_b" == "$UNIFIED_EDGE_NETWORK_ELEMENT_B_MOID" ]] || { ok=false; log "Unified Edge switch profile '${profile_name}-B' is not assigned to selected eCMC-B"; }
    fi

    if [[ "$UNIFIED_EDGE_DEPLOY_PROFILE" == "true" ]]; then
      local cluster_json cluster_state deploy_status deployed_switches
      cluster_json="$(isctl_cmd get fabric switchclusterprofile moid "$cluster_moid" -o json)"
      cluster_state="$(printf '%s' "$cluster_json" | jq -r '.ConfigContext.ConfigState // empty')"
      deploy_status="$(printf '%s' "$cluster_json" | jq -r '.DeployStatus // empty')"
      deployed_switches="$(printf '%s' "$cluster_json" | jq -r '.DeployedSwitches // empty')"
      [[ "$cluster_state" == "Associated" ]] || { ok=false; log "Unified Edge profile '$profile_name' is not Associated after deployment"; }
      [[ "$deploy_status" == "Complete" ]] || { ok=false; log "Unified Edge profile '$profile_name' deploy status is not Complete"; }
      unified_edge_deployed_on_both_switches "$deployed_switches" || { ok=false; log "Unified Edge profile '$profile_name' is not deployed on both switches"; }
    fi
  done

  if [[ "$ok" == true ]]; then
    log "Unified Edge validation PASSED"
  else
    fail "Unified Edge validation FAILED"
  fi
}

run_profile_actions_parallel() {
  local action_label="$1" action_fn="$2"
  local -a pids=()
  local -a names=()
  local p idx fail_count
  fail_count=0

  log "Starting ${action_label} in parallel for ${#TARGET_PROFILE_NAMES[@]} profile(s)"
  for p in "${TARGET_PROFILE_NAMES[@]}"; do
    (
      "$action_fn" "$p"
    ) &
    pids+=("$!")
    names+=("$p")
  done

  for idx in "${!pids[@]}"; do
    if wait "${pids[$idx]}"; then
      log "${action_label} completed for '${names[$idx]}'"
    else
      fail_count=$(( fail_count + 1 ))
      log "${action_label} failed for '${names[$idx]}'"
    fi
  done

  (( fail_count == 0 )) || fail "${action_label} failed for ${fail_count} profile(s)"
  log "Completed ${action_label} in parallel for all target profiles"
}

main() {
  need_cmd isctl
  need_cmd jq
  validate_required_vars
  [[ -f "$SECRET_KEY_PATH" ]] || fail "Secret key file not found: $SECRET_KEY_PATH"
  wait_for_intersight_connectivity

  log "Starting deployment workflow"
  log "Deploy scope: $DEPLOY_SCOPE"
  log "Variables file: $VARS_FILE"
  log "API key file: $API_KEY_FILE (entry: $API_KEY_NAME)"
  log "Secret key: $SECRET_KEY_PATH"
  log "Org=$ORG_NAME ResourceGroup=$RESOURCE_GROUP_NAME Prefix=$PREFIX"

  ensure_org_and_resource_group

  if [[ "$DEPLOY_UNIFIED_EDGE" == "true" ]]; then
    build_unified_edge_profiles
    init_unified_edge_defaults
    log "Target Unified Edge profiles: ${UNIFIED_EDGE_PROFILES[*]}"
    ensure_unified_edge_profiles
    validate_unified_edge_all
  fi

  if [[ "$DEPLOY_SERVER_PROFILES" == "true" ]]; then
    build_target_profile_names
    log "Target server profiles: ${TARGET_PROFILE_NAMES[*]}"
    ensure_unified_edge_before_server_profiles

    resolve_admin_endpoint_role_moid
    ensure_base_policies
    ensure_users_and_bios
    ensure_power_and_kvm
    ensure_networking
    ensure_storage_boot_uuid
    ensure_template_and_profiles

    # Two-step execution by design and policy: deploy is always followed by activation.
    run_profile_actions_parallel "deploy" deploy_profile_by_name
    run_profile_actions_parallel "activation" activate_profile_by_name

    validate_all

    if [[ "$ENABLE_OS_INSTALL" == "true" ]]; then
      ensure_os_configuration_files
    fi
  fi

  log "Completed create+validate workflow for scope '$DEPLOY_SCOPE'."
}

main "$@"
