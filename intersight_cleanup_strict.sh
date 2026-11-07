#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Strict Intersight Cleanup Script
#
# Purpose:
# - Delete assets created by intersight_deploy_validate.sh
# - Scope all operations strictly to the organization from vars file
# - Never touch other organizations, shared/global objects, org, or resource group
#
# Usage:
#   ./intersight_cleanup_strict.sh [--cleanup server-profiles|unified-edge|both]
#   ./intersight_cleanup_strict.sh --cleanup both ./intersight_deploy_validate_vars.txt ./${PREFIX%-}-SecretKey.txt
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

show_help() {
  cat <<EOF
Usage:
  $(basename "$0") [OPTIONS] [VARS_FILE] [SECRET_KEY_FILE]
  $(basename "$0") --help

Purpose:
  Delete Intersight assets created by intersight_deploy_validate.sh, scoped
  strictly to the organization in the variables file. The organization and
  resource group are not deleted.

Cleanup scope:
  --cleanup server-profiles  Delete server profiles, server profile template,
                             server-side policies, pools, and OS install jobs.
  --cleanup unified-edge     Delete Unified Edge switch cluster profile,
                             child switch profiles, and attached policies.
  --cleanup both             Delete both sets of objects.

  Short aliases:
    --server-profiles
    --unified-edge
    --both

Defaults:
  Cleanup scope    server-profiles
  VARS_FILE        ./intersight_deploy_validate_vars.txt
  API key file     ./API-Key.txt, or ./API-Keys.txt
  Secret key file  ./\${PREFIX%-}-SecretKey.txt
  Unified Edge     lower-case PREFIX without trailing '-' plus '-chassis1'

Credential file format:
  API-Key.txt or API-Keys.txt must contain one entry per line:

    <prefix-without-trailing-dash> <intersight-api-key-id>

  Blank lines and lines beginning with '#' are ignored. The credential name is
  taken from API_KEY_NAME if set, otherwise from PREFIX in the variables file
  with the trailing dash removed.

Required local files:
  ./API-Key.txt or ./API-Keys.txt
  ./\${PREFIX%-}-SecretKey.txt
  ./intersight_deploy_validate_vars.txt

Overrides:
  --vars FILE
  --secret-key FILE
  --api-key-file FILE
  --api-key-name NAME
  API_KEY_FILE=./API-Key.txt
  API_KEY_NAME=\${PREFIX%-}
  UNIFIED_EDGE_PROFILE_NAME=\${PREFIX}chassis1
  UNIFIED_EDGE_PROFILE_NAMES="\${PREFIX}chassis1 other-profile"

Examples:
  ./intersight_cleanup_strict.sh
  ./intersight_cleanup_strict.sh --cleanup unified-edge
  ./intersight_cleanup_strict.sh --cleanup both
  ./intersight_cleanup_strict.sh --cleanup server-profiles ./intersight_deploy_validate_vars.txt ./\${PREFIX%-}-SecretKey.txt
  API_KEY_FILE=./API-Keys.txt ./intersight_cleanup_strict.sh --both
EOF
}

usage_error() {
  printf 'ERROR: %s\n\n' "$1" >&2
  show_help >&2
  exit 2
}

CLEANUP_SCOPE="server-profiles"
VARS_FILE=""
SECRET_KEY_OVERRIDE=""
POSITIONAL_ARGS=()

if (( $# == 0 )); then
  show_help
  exit 0
fi

while (( $# > 0 )); do
  case "$1" in
    -h|--help|help)
      show_help
      exit 0
      ;;
    --cleanup)
      [[ $# -ge 2 ]] || usage_error "--cleanup requires one of: server-profiles, unified-edge, both"
      CLEANUP_SCOPE="$2"
      shift 2
      ;;
    --cleanup=*)
      CLEANUP_SCOPE="${1#--cleanup=}"
      shift
      ;;
    --server-profiles)
      CLEANUP_SCOPE="server-profiles"
      shift
      ;;
    --unified-edge)
      CLEANUP_SCOPE="unified-edge"
      shift
      ;;
    --both)
      CLEANUP_SCOPE="both"
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
      API_KEY_FILE="$2"
      shift 2
      ;;
    --api-key-file=*)
      API_KEY_FILE="${1#--api-key-file=}"
      shift
      ;;
    --api-key-name)
      [[ $# -ge 2 ]] || usage_error "--api-key-name requires a name"
      API_KEY_NAME="$2"
      shift 2
      ;;
    --api-key-name=*)
      API_KEY_NAME="${1#--api-key-name=}"
      shift
      ;;
    --)
      shift
      while (( $# > 0 )); do
        POSITIONAL_ARGS+=("$1")
        shift
      done
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

case "$CLEANUP_SCOPE" in
  server-profiles|server-profiles-only|profiles|server)
    CLEANUP_SERVER_PROFILES=true
    CLEANUP_UNIFIED_EDGE=false
    ;;
  unified-edge|unified-edge-only|edge)
    CLEANUP_SERVER_PROFILES=false
    CLEANUP_UNIFIED_EDGE=true
    ;;
  both|all)
    CLEANUP_SERVER_PROFILES=true
    CLEANUP_UNIFIED_EDGE=true
    ;;
  *)
    usage_error "invalid cleanup scope: $CLEANUP_SCOPE"
    ;;
esac

VARS_FILE="${VARS_FILE:-$SCRIPT_DIR/intersight_deploy_validate_vars.txt}"
[[ -f "$VARS_FILE" ]] || { printf 'ERROR: variables file not found: %s\n' "$VARS_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$VARS_FILE"

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

API_KEY_FILE="$(resolve_local_path "${API_KEY_FILE:-$(default_api_key_file)}")"
API_KEY_NAME="${API_KEY_NAME:-${PREFIX%-}}"
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
[[ -n "${SECRET_KEY_PATH:-}" ]] || { printf 'ERROR: SECRET_KEY_PATH is required\n' >&2; exit 1; }
[[ -f "$SECRET_KEY_PATH" ]] || { printf 'ERROR: secret key file not found: %s\n' "$SECRET_KEY_PATH" >&2; exit 1; }

ORG_MOID=""
TARGET_PROFILES=()
UNIFIED_EDGE_PROFILES=()
UNIFIED_EDGE_POLICY_REFS_FILE="$(mktemp -t intersight_unified_edge_policy_refs.XXXXXX)"
trap 'rm -f "$UNIFIED_EDGE_POLICY_REFS_FILE"' EXIT

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

isctl_cmd() {
  isctl --intersight-api-key-id "$API_KEY_ID" --intersight-secret-key "$SECRET_KEY_PATH" "$@"
}

build_target_profiles() {
  local i name fmt
  TARGET_PROFILES=()
  [[ "${SERVER_PROFILE_COUNT:-}" =~ ^[0-9]+$ ]] || fail "SERVER_PROFILE_COUNT must be numeric"
  (( SERVER_PROFILE_COUNT >= 1 && SERVER_PROFILE_COUNT <= 5 )) || fail "SERVER_PROFILE_COUNT must be in range 1..5"
  fmt="%0${PROFILE_NAME_PAD_WIDTH}d"
  for (( i=1; i<=SERVER_PROFILE_COUNT; i++ )); do
    printf -v name "%s${fmt}" "$PROFILE_NAME_PREFIX" "$i"
    TARGET_PROFILES+=("$name")
  done
}

default_unified_edge_profile_name() {
  local prefix_base
  prefix_base="$(printf '%s' "${PREFIX%-}" | tr '[:upper:]' '[:lower:]')"
  printf '%s-chassis1\n' "$prefix_base"
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

init_unified_edge_defaults() {
  local prefix_base
  prefix_base="$(printf '%s' "${PREFIX%-}" | tr '[:upper:]' '[:lower:]')"

  UNIFIED_EDGE_PROFILE_NAME="${UNIFIED_EDGE_PROFILE_NAME:-${prefix_base}-chassis1}"
  UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME="${UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME:-${prefix_base}-vlan}"
  UNIFIED_EDGE_PORT_POLICY_NAME="${UNIFIED_EDGE_PORT_POLICY_NAME:-${prefix_base}-ports}"
  UNIFIED_EDGE_LEGACY_PORT_POLICY_NAME="${UNIFIED_EDGE_LEGACY_PORT_POLICY_NAME:-${prefix_base}-ports}"
  UNIFIED_EDGE_EXTRA_PORT_POLICY_NAMES="${UNIFIED_EDGE_EXTRA_PORT_POLICY_NAMES:-${prefix_base}-port}"
  UNIFIED_EDGE_QOS_POLICY_NAME="${UNIFIED_EDGE_QOS_POLICY_NAME:-${prefix_base}-qos-besteffort}"
  UNIFIED_EDGE_NETWORK_CONNECTIVITY_POLICY_NAME="${UNIFIED_EDGE_NETWORK_CONNECTIVITY_POLICY_NAME:-${prefix_base}-network-connectivity}"
  UNIFIED_EDGE_NTP_POLICY_NAME="${UNIFIED_EDGE_NTP_POLICY_NAME:-${prefix_base}-ntp}"
}

resolve_org_moid_strict() {
  local json count
  json="$(isctl_cmd get organization organization --filter "Name eq '$ORG_NAME'" -o json)"
  count="$(printf '%s' "$json" | jq 'length')"
  (( count == 1 )) || fail "Expected exactly one organization named '$ORG_NAME', found $count"
  ORG_MOID="$(printf '%s' "$json" | jq -r '.[0].Moid // empty')"
  [[ -n "$ORG_MOID" ]] || fail "Unable to resolve ORG_MOID for '$ORG_NAME'"
  log "Using organization '$ORG_NAME' (ORG_MOID=$ORG_MOID)"
}

get_unique_moid_in_org_by_name() {
  local noun="$1" type="$2" name="$3"
  local json count
  json="$(isctl_cmd get "$noun" "$type" --filter "Name eq '$name' and Organization.Moid eq '$ORG_MOID'" -o json)"
  count="$(printf '%s' "$json" | jq 'length')"
  (( count <= 1 )) || fail "Strict lookup violation: multiple $noun $type objects in org for Name='$name'"
  printf '%s' "$json" | jq -r '.[0].Moid // empty'
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
  (( count <= 1 )) || fail "Strict lookup violation: multiple scoped $noun $type objects for Name='$name'"
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

delete_moid_if_exists() {
  local noun="$1" type="$2" moid="$3"
  [[ -n "$moid" ]] || return 0
  log "Deleting $noun $type moid=$moid"
  isctl_cmd delete "$noun" "$type" moid "$moid" >/dev/null 2>&1 || true
}

profile_moid_by_name() {
  local name="$1"
  get_unique_moid_in_org_by_name server profile "$name"
}

wait_for_profiles_not_assigned() {
  local timeout elapsed all_done p st
  timeout=1800
  elapsed=0

  while (( elapsed < timeout )); do
    all_done=1
    for p in "${TARGET_PROFILES[@]}"; do
      local pm
      pm="$(profile_moid_by_name "$p")"
      [[ -z "$pm" ]] && continue
      st="$(isctl_cmd get server profile moid "$pm" -o json | jq -r '.ConfigContext.ConfigState // ""')"
      if [[ "$st" != "Not-assigned" ]]; then
        all_done=0
      fi
    done
    (( all_done == 1 )) && return 0
    sleep 15
    elapsed=$(( elapsed + 15 ))
  done

  fail "Timeout waiting for profiles to reach Not-assigned state"
}

cleanup_profiles_and_template() {
  local p pm template_moid
  log "Unassigning target server profiles"
  for p in "${TARGET_PROFILES[@]}"; do
    pm="$(profile_moid_by_name "$p")"
    [[ -z "$pm" ]] && continue
    isctl_cmd update server profile moid "$pm" --Action Unassign >/dev/null 2>&1 || true
  done

  wait_for_profiles_not_assigned

  log "Detaching template links and deleting target profiles"
  for p in "${TARGET_PROFILES[@]}"; do
    pm="$(profile_moid_by_name "$p")"
    [[ -z "$pm" ]] && continue
    isctl_cmd update server profile moid "$pm" --TemplateActions '[{"Type":"Detach"}]' >/dev/null || true
    delete_moid_if_exists server profile "$pm"
  done

  template_moid="$(get_unique_moid_in_org_by_name server profiletemplate "$PROFILE_TEMPLATE_NAME")"
  delete_moid_if_exists server profiletemplate "$template_moid"
}

cleanup_vnic_ethifs() {
  local lcp_moid ethif_moids m
  lcp_moid="$(get_unique_moid_in_org_by_name vnic lanconnectivitypolicy "$LCP_NAME")"
  [[ -n "$lcp_moid" ]] || return 0
  ethif_moids="$(isctl_cmd get vnic ethif --filter "LanConnectivityPolicy.Moid eq '$lcp_moid'" -o json | jq -r '.[].Moid // empty')"
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    delete_moid_if_exists vnic ethif "$m"
  done <<< "$ethif_moids"
}

cleanup_endpoint_user_role() {
  local policy_moid user_moid role_moids m
  policy_moid="$(get_unique_moid_in_org_by_name iam endpointuserpolicy "$LOCAL_USER_POLICY_NAME")"
  user_moid="$(get_unique_moid_in_org_by_name iam endpointuser "$LOCAL_USER_NAME")"
  [[ -n "$policy_moid" && -n "$user_moid" ]] || return 0
  role_moids="$(
    isctl_cmd get iam endpointuserrole -o json \
      | jq -r --arg p "$policy_moid" --arg u "$user_moid" '.[] | select((.EndPointUserPolicy.Moid // "")==$p and (.EndPointUser.Moid // "")==$u) | .Moid'
  )"
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    delete_moid_if_exists iam endpointuserrole "$m"
  done <<< "$role_moids"
}

cleanup_vmedia_policy() {
  local moid remaining
  if [[ -z "${VMEDIA_POLICY_NAME:-}" ]]; then
    log "VMEDIA_POLICY_NAME is unset; skipping vMedia policy cleanup"
    return 0
  fi

  moid="$(get_unique_moid_in_org_by_name vmedia policy "$VMEDIA_POLICY_NAME")"
  if [[ -z "$moid" ]]; then
    log "vMedia policy '$VMEDIA_POLICY_NAME' is not present in org '$ORG_NAME'; nothing to delete"
    return 0
  fi

  log "Deleting vMedia policy '$VMEDIA_POLICY_NAME' (moid=$moid)"
  isctl_cmd delete vmedia policy moid "$moid" >/dev/null
  remaining="$(get_unique_moid_in_org_by_name vmedia policy "$VMEDIA_POLICY_NAME")"
  [[ -z "$remaining" ]] || fail "vMedia policy '$VMEDIA_POLICY_NAME' still exists after delete request"
  log "Deleted vMedia policy '$VMEDIA_POLICY_NAME'"
}

cleanup_policy_and_pool_names() {
  local moid

  # Highest-level dependencies first.
  cleanup_vnic_ethifs
  cleanup_endpoint_user_role

  cleanup_vmedia_policy

  moid="$(get_unique_moid_in_org_by_name boot precisionpolicy "$BOOT_POLICY_NAME")"
  delete_moid_if_exists boot precisionpolicy "$moid"

  moid="$(get_unique_moid_in_org_by_name storage storagepolicy "$STORAGE_POLICY_NAME")"
  delete_moid_if_exists storage storagepolicy "$moid"

  moid="$(get_unique_moid_in_org_by_name vnic lanconnectivitypolicy "$LCP_NAME")"
  delete_moid_if_exists vnic lanconnectivitypolicy "$moid"

  moid="$(get_unique_moid_in_org_by_name fabric ethnetworkgrouppolicy "$ETH_NETWORK_GROUP_NAME")"
  delete_moid_if_exists fabric ethnetworkgrouppolicy "$moid"

  moid="$(get_unique_moid_in_org_by_name vnic ethqospolicy "$ETH_QOS_POLICY_NAME")"
  delete_moid_if_exists vnic ethqospolicy "$moid"

  moid="$(get_unique_moid_in_org_by_name macpool pool "$MACPOOL_NAME")"
  delete_moid_if_exists macpool pool "$moid"

  moid="$(get_unique_moid_in_org_by_name kvm policy "$KVM_POLICY_NAME")"
  delete_moid_if_exists kvm policy "$moid"

  moid="$(get_unique_moid_in_org_by_name power policy "$POWER_POLICY_NAME")"
  delete_moid_if_exists power policy "$moid"

  moid="$(get_unique_moid_in_org_by_name bios policy "$BIOS_POLICY_NAME")"
  delete_moid_if_exists bios policy "$moid"

  moid="$(get_unique_moid_in_org_by_name access policy "$ACCESS_POLICY_NAME")"
  delete_moid_if_exists access policy "$moid"

  moid="$(get_unique_moid_in_org_by_name ippool pool "$IPPOOL_NAME")"
  delete_moid_if_exists ippool pool "$moid"

  moid="$(get_unique_moid_in_org_by_name uuidpool pool "$UUIDPOOL_NAME")"
  delete_moid_if_exists uuidpool pool "$moid"

  moid="$(get_unique_moid_in_org_by_name iam endpointuserpolicy "$LOCAL_USER_POLICY_NAME")"
  delete_moid_if_exists iam endpointuserpolicy "$moid"

  moid="$(get_unique_moid_in_org_by_name iam endpointuser "$LOCAL_USER_NAME")"
  delete_moid_if_exists iam endpointuser "$moid"
}

cleanup_os_installs_in_org() {
  local moids m
  moids="$(isctl_cmd get os install --filter "Organization.Moid eq '$ORG_MOID'" -o json | jq -r '.[].Moid // empty')"
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    delete_moid_if_exists os install "$m"
  done <<< "$moids"
}

unified_edge_profile_moid_by_name() {
  local name="$1"
  get_unique_moid_in_org_by_name fabric switchclusterprofile "$name"
}

object_type_to_isctl() {
  case "$1" in
    fabric.EthNetworkPolicy) printf 'fabric ethnetworkpolicy\n' ;;
    fabric.PortPolicy) printf 'fabric portpolicy\n' ;;
    fabric.SystemQosPolicy) printf 'fabric systemqospolicy\n' ;;
    fabric.SwitchControlPolicy) printf 'fabric switchcontrolpolicy\n' ;;
    fabric.FlowControlPolicy) printf 'fabric flowcontrolpolicy\n' ;;
    fabric.LinkAggregationPolicy) printf 'fabric linkaggregationpolicy\n' ;;
    fabric.LinkControlPolicy) printf 'fabric linkcontrolpolicy\n' ;;
    fabric.MulticastPolicy) printf 'fabric multicastpolicy\n' ;;
    fabric.FcNetworkPolicy) printf 'fabric fcnetworkpolicy\n' ;;
    fabric.FcZonePolicy) printf 'fabric fczonepolicy\n' ;;
    fabric.MacSecPolicy) printf 'fabric macsecpolicy\n' ;;
    fabric.Vlan) printf 'fabric vlan\n' ;;
    fabric.VlanSet) printf 'fabric vlanset\n' ;;
    fabric.PortMode) printf 'fabric portmode\n' ;;
    fabric.ServerRole) printf 'fabric serverrole\n' ;;
    fabric.UplinkRole) printf 'fabric uplinkrole\n' ;;
    fabric.UplinkPcRole) printf 'fabric uplinkpcrole\n' ;;
    fabric.PcMember) printf 'fabric pcmember\n' ;;
    networkconfig.Policy) printf 'networkconfig policy\n' ;;
    ntp.Policy) printf 'ntp policy\n' ;;
    snmp.Policy) printf 'snmp policy\n' ;;
    syslog.Policy) printf 'syslog policy\n' ;;
    smtp.Policy) printf 'smtp policy\n' ;;
    ssh.Policy) printf 'ssh policy\n' ;;
    sol.Policy) printf 'sol policy\n' ;;
    *) return 1 ;;
  esac
}

record_policy_refs_from_json() {
  local json="$1"
  printf '%s' "$json" \
    | jq -r '.PolicyBucket[]? | select((.Moid // "") != "" and (.ObjectType // "") != "") | [.ObjectType,.Moid] | @tsv' \
    >> "$UNIFIED_EDGE_POLICY_REFS_FILE"
}

record_policy_refs_from_switch_profile() {
  local switch_profile_moid="$1" json
  [[ -n "$switch_profile_moid" ]] || return 0
  json="$(isctl_cmd get fabric switchprofile moid "$switch_profile_moid" -o json 2>/dev/null || true)"
  [[ -n "$json" ]] || return 0
  record_policy_refs_from_json "$json"
}

is_managed_unified_edge_switch_profile_name() {
  local name="$1" profile_name
  for profile_name in "${UNIFIED_EDGE_PROFILES[@]}"; do
    [[ "$name" == "${profile_name}-A" || "$name" == "${profile_name}-B" ]] && return 0
  done
  return 1
}

policy_has_external_switch_profile_ref() {
  local policy_moid="$1" names name
  [[ -n "$policy_moid" ]] || return 1

  names="$(
    isctl_cmd get fabric switchprofile -o json 2>/dev/null \
      | jq -r --arg policy "$policy_moid" '
          .[]?
          | select(([.PolicyBucket[]?.Moid] | index($policy)) != null)
          | .Name // empty
        '
  )"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ! is_managed_unified_edge_switch_profile_name "$name"; then
      return 0
    fi
  done <<< "$names"

  return 1
}

delete_ref_if_in_org() {
  local object_type="$1" moid="$2"
  local mapped noun type json name scoped
  [[ -n "$object_type" && -n "$moid" ]] || return 0

  if ! mapped="$(object_type_to_isctl "$object_type")"; then
    log "Skipping unsupported policy object type '$object_type' moid=$moid"
    return 0
  fi

  noun="${mapped%% *}"
  type="${mapped#* }"
  json="$(isctl_cmd get "$noun" "$type" moid "$moid" -o json 2>/dev/null || true)"
  [[ -n "$json" ]] || return 0

  scoped="$(
    printf '%s' "$json" \
      | jq -r --arg org "$ORG_MOID" '
          ((.Organization.Moid // "") == $org)
          or (((.PermissionResources // []) | map(.Moid // "") | index($org)) != null)
        '
  )"
  if [[ "$scoped" != "true" ]]; then
    name="$(printf '%s' "$json" | jq -r '.Name // empty')"
    log "Skipping $object_type '$name' moid=$moid because it is not scoped to org '$ORG_NAME'"
    return 0
  fi

  case "$object_type" in
    fabric.EthNetworkPolicy|fabric.PortPolicy|fabric.SystemQosPolicy|networkconfig.Policy|ntp.Policy)
      if policy_has_external_switch_profile_ref "$moid"; then
        name="$(printf '%s' "$json" | jq -r '.Name // empty')"
        log "Skipping $object_type '$name' moid=$moid because it is still referenced by another switch profile"
        return 0
      fi
      ;;
  esac

  delete_moid_if_exists "$noun" "$type" "$moid"
}

delete_named_if_exists() {
  local noun="$1" type="$2" name="$3" moid
  [[ -n "$name" ]] || return 0
  moid="$(get_unique_moid_in_org_by_name "$noun" "$type" "$name")"
  delete_moid_if_exists "$noun" "$type" "$moid"
}

delete_named_policy_if_unshared() {
  local noun="$1" type="$2" name="$3" moid
  [[ -n "$name" ]] || return 0
  moid="$(get_unique_moid_in_org_by_name "$noun" "$type" "$name")"
  [[ -n "$moid" ]] || return 0
  if policy_has_external_switch_profile_ref "$moid"; then
    log "Skipping $noun $type '$name' moid=$moid because it is still referenced by another switch profile"
    return 0
  fi
  delete_moid_if_exists "$noun" "$type" "$moid"
}

detach_policy_from_switch_profile_buckets() {
  local policy_moid="$1" profile_rows profile_moid profile_name profile_json new_bucket
  [[ -n "$policy_moid" ]] || return 0

  profile_rows="$(
    isctl_cmd get fabric switchprofile -o json 2>/dev/null \
      | jq -r --arg policy "$policy_moid" '
          .[]?
          | select(([.PolicyBucket[]?.Moid] | index($policy)) != null)
          | [.Moid, (.Name // "")] | @tsv
        '
  )"

  while IFS=$'\t' read -r profile_moid profile_name; do
    [[ -z "$profile_moid" ]] && continue
    log "Detaching policy moid=$policy_moid from switch profile '$profile_name'"
    profile_json="$(isctl_cmd get fabric switchprofile moid "$profile_moid" -o json)"
    new_bucket="$(
      printf '%s' "$profile_json" \
        | jq -c --arg policy "$policy_moid" '[.PolicyBucket[]? | select((.Moid // "") != $policy)]'
    )"
    isctl_cmd update fabric switchprofile moid "$profile_moid" --PolicyBucket "$new_bucket" >/dev/null 2>&1 || true
  done <<< "$profile_rows"
}

delete_port_policy_children() {
  local port_moid="$1" noun_type noun type child_moids child_moid
  local force="${2:-false}"
  [[ -n "$port_moid" ]] || return 0
  if [[ "$force" != "true" ]] && policy_has_external_switch_profile_ref "$port_moid"; then
    log "Skipping port-policy children for moid=$port_moid because the policy is still referenced by another switch profile"
    return 0
  fi

  for noun_type in \
    "fabric uplinkrole" \
    "fabric uplinkpcrole" \
    "fabric serverrole" \
    "fabric portmode"; do
    noun="${noun_type%% *}"
    type="${noun_type#* }"
    child_moids="$(
      isctl_cmd get "$noun" "$type" -o json 2>/dev/null \
        | jq -r --arg pp "$port_moid" '.[]? | select((.PortPolicy.Moid // "") == $pp) | .Moid // empty'
    )"
    while IFS= read -r child_moid; do
      [[ -z "$child_moid" ]] && continue
      delete_moid_if_exists "$noun" "$type" "$child_moid"
    done <<< "$child_moids"
  done
}

delete_port_policy_force_by_name() {
  local name="$1" port_moid
  [[ -n "$name" ]] || return 0

  port_moid="$(get_unique_moid_in_org_by_name fabric portpolicy "$name")"
  [[ -n "$port_moid" ]] || return 0

  log "Force deleting Unified Edge port policy '$name'"
  detach_policy_from_switch_profile_buckets "$port_moid"
  isctl_cmd update fabric portpolicy moid "$port_moid" --Profiles "[]" >/dev/null 2>&1 || true
  delete_port_policy_children "$port_moid" true
  delete_moid_if_exists fabric portpolicy "$port_moid"
}

cleanup_unified_edge_named_policies() {
  local eth_moid port_moid vlan_moids vlan_moid extra_name

  log "Deleting named Unified Edge policies created by deploy script"
  eth_moid="$(get_unique_moid_in_org_by_name fabric ethnetworkpolicy "$UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME")"
  if [[ -n "$eth_moid" ]]; then
    if policy_has_external_switch_profile_ref "$eth_moid"; then
      log "Skipping VLAN deletion for '$UNIFIED_EDGE_ETH_NETWORK_POLICY_NAME' because it is still referenced by another switch profile"
    else
      vlan_moids="$(
        isctl_cmd get fabric vlan --filter "EthNetworkPolicy.Moid eq '$eth_moid'" -o json \
          | jq -r '.[].Moid // empty'
      )"
      while IFS= read -r vlan_moid; do
        [[ -z "$vlan_moid" ]] && continue
        delete_moid_if_exists fabric vlan "$vlan_moid"
      done <<< "$vlan_moids"
    fi
  fi

  port_moid="$(get_unique_moid_in_org_by_name fabric portpolicy "$UNIFIED_EDGE_PORT_POLICY_NAME")"
  delete_port_policy_children "$port_moid"
  delete_named_policy_if_unshared fabric portpolicy "$UNIFIED_EDGE_PORT_POLICY_NAME"
  if [[ "${UNIFIED_EDGE_LEGACY_PORT_POLICY_NAME:-}" != "$UNIFIED_EDGE_PORT_POLICY_NAME" ]]; then
    port_moid="$(get_unique_moid_in_org_by_name fabric portpolicy "$UNIFIED_EDGE_LEGACY_PORT_POLICY_NAME")"
    delete_port_policy_children "$port_moid"
    delete_named_policy_if_unshared fabric portpolicy "$UNIFIED_EDGE_LEGACY_PORT_POLICY_NAME"
  fi
  for extra_name in ${UNIFIED_EDGE_EXTRA_PORT_POLICY_NAMES//,/ }; do
    [[ -n "$extra_name" ]] || continue
    [[ "$extra_name" == "$UNIFIED_EDGE_PORT_POLICY_NAME" ]] && continue
    [[ "$extra_name" == "${UNIFIED_EDGE_LEGACY_PORT_POLICY_NAME:-}" ]] && continue
    delete_port_policy_force_by_name "$extra_name"
  done
  delete_named_policy_if_unshared fabric systemqospolicy "$UNIFIED_EDGE_QOS_POLICY_NAME"
  delete_named_policy_if_unshared networkconfig policy "$UNIFIED_EDGE_NETWORK_CONNECTIVITY_POLICY_NAME"
  delete_named_policy_if_unshared ntp policy "$UNIFIED_EDGE_NTP_POLICY_NAME"
  if [[ -n "$eth_moid" ]] && ! policy_has_external_switch_profile_ref "$eth_moid"; then
    delete_moid_if_exists fabric ethnetworkpolicy "$eth_moid"
  fi
}

wait_for_unified_edge_not_assigned() {
  local profile_moid="$1" timeout elapsed state
  timeout=1800
  elapsed=0

  while (( elapsed < timeout )); do
    state="$(
      isctl_cmd get fabric switchclusterprofile moid "$profile_moid" -o json 2>/dev/null \
        | jq -r '.ConfigContext.ConfigState // ""' || true
    )"
    [[ -z "$state" || "$state" == "Not-assigned" ]] && return 0
    sleep 15
    elapsed=$(( elapsed + 15 ))
  done

  fail "Timeout waiting for Unified Edge profile moid=$profile_moid to reach Not-assigned state"
}

cleanup_unified_edge_profiles_and_policies() {
  local profile_name profile_moid profile_json switch_profile_moids switch_profile_moid suffix named_switch_profile_moid
  : > "$UNIFIED_EDGE_POLICY_REFS_FILE"

  log "Collecting Unified Edge profile policy references"
  for profile_name in "${UNIFIED_EDGE_PROFILES[@]}"; do
    profile_moid="$(unified_edge_profile_moid_by_name "$profile_name")"
    if [[ -z "$profile_moid" ]]; then
      log "Unified Edge profile '$profile_name' not found; checking named child switch profiles"
      for suffix in A B; do
        named_switch_profile_moid="$(get_scoped_moid_by_name fabric switchprofile "${profile_name}-${suffix}")"
        record_policy_refs_from_switch_profile "$named_switch_profile_moid"
      done
      continue
    fi

    profile_json="$(isctl_cmd get fabric switchclusterprofile moid "$profile_moid" -o json)"
    record_policy_refs_from_json "$profile_json"

    switch_profile_moids="$(printf '%s' "$profile_json" | jq -r '.SwitchProfiles[]?.Moid // empty')"
    for suffix in A B; do
      named_switch_profile_moid="$(get_scoped_moid_by_name fabric switchprofile "${profile_name}-${suffix}")"
      [[ -n "$named_switch_profile_moid" ]] && switch_profile_moids="${switch_profile_moids}"$'\n'"${named_switch_profile_moid}"
    done
    switch_profile_moids="$(printf '%s\n' "$switch_profile_moids" | awk 'NF' | sort -u)"
    while IFS= read -r switch_profile_moid; do
      [[ -z "$switch_profile_moid" ]] && continue
      record_policy_refs_from_switch_profile "$switch_profile_moid"
    done <<< "$switch_profile_moids"
  done

  log "Unassigning Unified Edge profiles"
  for profile_name in "${UNIFIED_EDGE_PROFILES[@]}"; do
    profile_moid="$(unified_edge_profile_moid_by_name "$profile_name")"
    if [[ -z "$profile_moid" ]]; then
      for suffix in A B; do
        named_switch_profile_moid="$(get_scoped_moid_by_name fabric switchprofile "${profile_name}-${suffix}")"
        delete_moid_if_exists fabric switchprofile "$named_switch_profile_moid"
      done
      continue
    fi
    isctl_cmd update fabric switchclusterprofile moid "$profile_moid" --Action Unassign >/dev/null 2>&1 || true
  done

  for profile_name in "${UNIFIED_EDGE_PROFILES[@]}"; do
    profile_moid="$(unified_edge_profile_moid_by_name "$profile_name")"
    [[ -z "$profile_moid" ]] && continue
    wait_for_unified_edge_not_assigned "$profile_moid"
  done

  log "Deleting Unified Edge switch profiles and cluster profiles"
  for profile_name in "${UNIFIED_EDGE_PROFILES[@]}"; do
    profile_moid="$(unified_edge_profile_moid_by_name "$profile_name")"
    [[ -z "$profile_moid" ]] && continue

    profile_json="$(isctl_cmd get fabric switchclusterprofile moid "$profile_moid" -o json)"
    switch_profile_moids="$(printf '%s' "$profile_json" | jq -r '.SwitchProfiles[]?.Moid // empty')"
    for suffix in A B; do
      named_switch_profile_moid="$(get_scoped_moid_by_name fabric switchprofile "${profile_name}-${suffix}")"
      [[ -n "$named_switch_profile_moid" ]] && switch_profile_moids="${switch_profile_moids}"$'\n'"${named_switch_profile_moid}"
    done
    switch_profile_moids="$(printf '%s\n' "$switch_profile_moids" | awk 'NF' | sort -u)"

    while IFS= read -r switch_profile_moid; do
      [[ -z "$switch_profile_moid" ]] && continue
      isctl_cmd update fabric switchprofile moid "$switch_profile_moid" --TemplateActions '[{"Type":"Detach"}]' >/dev/null 2>&1 || true
      delete_moid_if_exists fabric switchprofile "$switch_profile_moid"
    done <<< "$switch_profile_moids"

    delete_moid_if_exists fabric switchclusterprofile "$profile_moid"

    # Some Intersight relationships delete parent-first; retry child cleanup once.
    while IFS= read -r switch_profile_moid; do
      [[ -z "$switch_profile_moid" ]] && continue
      delete_moid_if_exists fabric switchprofile "$switch_profile_moid"
    done <<< "$switch_profile_moids"
  done

  log "Deleting Unified Edge policies attached to the deleted profiles"
  sort -u "$UNIFIED_EDGE_POLICY_REFS_FILE" | while IFS=$'\t' read -r object_type policy_moid; do
    [[ -n "$object_type" && -n "$policy_moid" ]] || continue
    delete_ref_if_in_org "$object_type" "$policy_moid"
  done

  cleanup_unified_edge_named_policies
}

print_summary() {
  local obj_count
  count_obj() {
    local noun="$1" type="$2"
    isctl_cmd get "$noun" "$type" --filter "Organization.Moid eq '$ORG_MOID'" -o json | jq 'length'
  }
  count_scoped_obj() {
    local noun="$1" type="$2"
    isctl_cmd get "$noun" "$type" -o json \
      | jq --arg org "$ORG_MOID" '
          [ .[]? | select(
              ((.Organization.Moid // "") == $org)
              or (((.PermissionResources // []) | map(.Moid // "") | index($org)) != null)
            )
          ] | length
        '
  }
  log "Post-cleanup summary for org '$ORG_NAME':"
  obj_count="$(count_obj server profile)"; log "  server profile: $obj_count"
  obj_count="$(count_obj server profiletemplate)"; log "  server profiletemplate: $obj_count"
  obj_count="$(count_obj access policy)"; log "  access policy: $obj_count"
  obj_count="$(count_obj vnic lanconnectivitypolicy)"; log "  vnic lanconnectivitypolicy: $obj_count"
  obj_count="$(count_obj storage storagepolicy)"; log "  storage storagepolicy: $obj_count"
  obj_count="$(count_obj boot precisionpolicy)"; log "  boot precisionpolicy: $obj_count"
  obj_count="$(count_obj vmedia policy)"; log "  vmedia policy: $obj_count"
  obj_count="$(count_obj os install)"; log "  os install: $obj_count"
  obj_count="$(count_obj fabric switchclusterprofile)"; log "  fabric switchclusterprofile: $obj_count"
  obj_count="$(count_scoped_obj fabric switchprofile)"; log "  fabric switchprofile: $obj_count"
  obj_count="$(count_obj fabric portpolicy)"; log "  fabric portpolicy: $obj_count"
  obj_count="$(count_obj fabric ethnetworkpolicy)"; log "  fabric ethnetworkpolicy: $obj_count"
  obj_count="$(count_obj fabric systemqospolicy)"; log "  fabric systemqospolicy: $obj_count"
  obj_count="$(count_obj networkconfig policy)"; log "  networkconfig policy: $obj_count"
  obj_count="$(count_obj ntp policy)"; log "  ntp policy: $obj_count"
}

main() {
  need_cmd isctl
  need_cmd jq
  resolve_org_moid_strict
  log "Cleanup scope: $CLEANUP_SCOPE"

  # Keep org and resource group. Only clean assets inside ORG_MOID.
  if [[ "$CLEANUP_SERVER_PROFILES" == "true" ]]; then
    build_target_profiles
    log "Target server profiles: ${TARGET_PROFILES[*]}"
    cleanup_profiles_and_template
    cleanup_policy_and_pool_names
    cleanup_os_installs_in_org
  fi

  if [[ "$CLEANUP_UNIFIED_EDGE" == "true" ]]; then
    build_unified_edge_profiles
    init_unified_edge_defaults
    log "Target Unified Edge profiles: ${UNIFIED_EDGE_PROFILES[*]}"
    cleanup_unified_edge_profiles_and_policies
  fi

  print_summary

  log "Strict cleanup completed for organization '$ORG_NAME'"
}

main "$@"
