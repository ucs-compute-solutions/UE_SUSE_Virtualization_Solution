#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Intersight Policy Reconcile (Strict Org Scope)
#
# Purpose:
# - Read desired settings from intersight_deploy_validate_vars.txt
# - Compare current policy/pool state in the target organization
# - Highlight differences
# - Ask whether changes should be provisioned
#
# Strictness:
# - Every mutable operation is scoped to Organization.Moid
# - Name-only operations are not used for update/delete
# - Fails on duplicate name matches inside the target org
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_FILE="${1:-$SCRIPT_DIR/intersight_deploy_validate_vars.txt}"
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

SECRET_KEY_PATH="${2:-${SECRET_KEY_PATH:-$(default_secret_key_file)}}"
SECRET_KEY_PATH="$(resolve_local_path "$SECRET_KEY_PATH")"
[[ -n "${SECRET_KEY_PATH:-}" ]] || { printf 'ERROR: SECRET_KEY_PATH is required\n' >&2; exit 1; }
[[ -f "$SECRET_KEY_PATH" ]] || { printf 'ERROR: secret key file not found: %s\n' "$SECRET_KEY_PATH" >&2; exit 1; }

ORG_MOID=""
declare -a CHANGED_IDS=()
STATUS_FILE="$(mktemp -t intersight_policy_status.XXXXXX)"
trap 'rm -f "$STATUS_FILE"' EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { printf 'ERROR: missing command: %s\n' "$1" >&2; exit 1; }
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

is_harvester_target() {
  local image_name iso_name
  image_name="$(printf '%s' "${OS_IMAGE_NAME:-}" | tr '[:upper:]' '[:lower:]')"
  iso_name="$(printf '%s' "${VMEDIA_FILE_LOCATION:-${OS_IMAGE_LINK:-}}" | sed 's/[?#].*$//' | awk -F/ '{print $NF}' | tr '[:upper:]' '[:lower:]')"
  [[ "$image_name" == *harvester* || "$iso_name" == *harvester* ]]
}

validate_harvester_vmedia_vars() {
  local name
  for name in VMEDIA_POLICY_NAME VMEDIA_DEVICE_TYPE VMEDIA_MOUNT_PROTOCOL VMEDIA_FILE_LOCATION VMEDIA_VOLUME_NAME; do
    [[ -n "${!name:-}" ]] || fail "Harvester target requires '$name' in $VARS_FILE"
  done
}

isctl_cmd() {
  isctl --intersight-secret-key "$SECRET_KEY_PATH" "$@"
}

resolve_org_moid_strict() {
  local json count
  json="$(isctl_cmd get organization organization --filter "Name eq '$ORG_NAME'" -o json)"
  count="$(printf '%s' "$json" | jq 'length')"
  (( count == 1 )) || fail "Expected exactly one organization named '$ORG_NAME', found $count"
  ORG_MOID="$(printf '%s' "$json" | jq -r '.[0].Moid // empty')"
  [[ -n "$ORG_MOID" ]] || fail "Unable to resolve ORG_MOID"
}

get_unique_moid_in_org_by_name() {
  local noun="$1" type="$2" name="$3"
  local json count
  json="$(isctl_cmd get "$noun" "$type" --filter "Name eq '$name' and Organization.Moid eq '$ORG_MOID'" -o json)"
  count="$(printf '%s' "$json" | jq 'length')"
  (( count <= 1 )) || fail "Duplicate objects for $noun $type Name='$name' inside org"
  printf '%s' "$json" | jq -r '.[0].Moid // empty'
}

desired_boot_devices_json() {
  jq -c -n \
    --arg ld_name "$BOOT_LOCALDISK_NAME" \
    --arg ld_slot "$BOOT_LOCALDISK_SLOT" \
    '[{"ClassId":"boot.LocalDisk","ObjectType":"boot.LocalDisk","Enabled":true,"Name":$ld_name,"Slot":$ld_slot,"Bootloader":{"ClassId":"boot.Bootloader","ObjectType":"boot.Bootloader","Name":"","Description":"","Path":""}},{"ClassId":"boot.VirtualMedia","ObjectType":"boot.VirtualMedia","Enabled":true,"Name":"CimcMappedDvd","Subtype":"cimc-mapped-dvd"}]'
}

desired_json() {
  local id="$1"
  case "$id" in
    ippool)
      jq -n --arg gw "$MGMT_GATEWAY" --arg nm "$MGMT_NETMASK" --arg f "$MGMT_IP_FROM" --arg t "$MGMT_IP_TO" \
        '{Gateway:$gw,Netmask:$nm,From:$f,To:$t}'
      ;;
    access)
      jq -n --argjson vlan "$INBAND_VLAN" \
        '{ConfigureInband:true,ConfigureOutOfBand:false,EnableIpV4:true,EnableIpV6:false,InbandVlan:$vlan}'
      ;;
    power)
      jq -n --arg pri "$POWER_PRIORITY" --arg rs "$POWER_RESTORE_STATE" --arg sm "$POWER_SAVE_MODE" \
        '{PowerPriority:$pri,PowerRestoreState:$rs,PowerSaveMode:$sm}'
      ;;
    kvm)
      jq -n --argjson en "$KVM_ENABLED" --argjson ten "$KVM_TUNNELED_ENABLED" \
        --argjson ms "$KVM_MAX_SESSIONS" --argjson rp "$KVM_REMOTE_PORT" --argjson eve "$KVM_ENABLE_VIDEO_ENCRYPTION" \
        '{Enabled:$en,TunneledKvmEnabled:$ten,MaximumSessions:$ms,RemotePort:$rp,EnableVideoEncryption:$eve}'
      ;;
    macpool)
      jq -n --arg f "$MAC_FROM" --arg t "$MAC_TO" '{From:$f,To:$t}'
      ;;
    ethqos)
      jq -n --argjson mtu "$ETH_MTU" '{Mtu:$mtu}'
      ;;
    ethnetgrp)
      jq -n --argjson nv "$INBAND_VLAN" --arg av "$ALLOWED_VLANS" '{NativeVlan:$nv,AllowedVlans:$av}'
      ;;
    lcp)
      jq -n --arg tp "$TARGET_PLATFORM" '{TargetPlatform:$tp,PlacementMode:"custom"}'
      ;;
    storage)
      jq -n --arg cs "$M2_CONTROLLER_SLOT" --arg n "$M2_VD_NAME" \
        '{ControllerSlot:$cs,Name:$n,Enable:true,UnusedDisksState:"UnconfiguredGood"}'
      ;;
    boot)
      jq -n --arg bm "Uefi" --argjson bd "$(desired_boot_devices_json)" '{ConfiguredBootMode:$bm,BootDevices:$bd}'
      ;;
    vmedia)
      jq -n --arg dt "$VMEDIA_DEVICE_TYPE" --arg mp "$VMEDIA_MOUNT_PROTOCOL" --arg fl "$VMEDIA_FILE_LOCATION" --arg vn "$VMEDIA_VOLUME_NAME" \
        '{Enabled:true,Mapping:{DeviceType:$dt,MountProtocol:$mp,FileLocation:$fl,VolumeName:$vn}}'
      ;;
    uuidpool)
      jq -n --arg p "$UUID_PREFIX" --arg f "$UUID_SUFFIX_FROM" --arg t "$UUID_SUFFIX_TO" '{Prefix:$p,From:$f,To:$t}'
      ;;
    *)
      fail "Unknown policy id in desired_json: $id"
      ;;
  esac
}

current_json() {
  local id="$1" moid="$2" raw
  [[ -n "$moid" ]] || { printf '{}\n'; return 0; }
  case "$id" in
    ippool)
      raw="$(isctl_cmd get ippool pool moid "$moid" -o json)"
      printf '%s' "$raw" | jq '{Gateway:(.IpV4Config.Gateway // ""),Netmask:(.IpV4Config.Netmask // ""),From:(.IpV4Blocks[0].From // ""),To:(.IpV4Blocks[0].To // "")}'
      ;;
    access)
      raw="$(isctl_cmd get access policy moid "$moid" -o json)"
      printf '%s' "$raw" | jq '{ConfigureInband:(.ConfigurationType.ConfigureInband // false),ConfigureOutOfBand:(.ConfigurationType.ConfigureOutOfBand // false),EnableIpV4:(.AddressType.EnableIpV4 // false),EnableIpV6:(.AddressType.EnableIpV6 // false),InbandVlan:(.InbandVlan // 0)}'
      ;;
    power)
      raw="$(isctl_cmd get power policy moid "$moid" -o json)"
      printf '%s' "$raw" | jq '{PowerPriority:(.PowerPriority // ""),PowerRestoreState:(.PowerRestoreState // ""),PowerSaveMode:(.PowerSaveMode // "")}'
      ;;
    kvm)
      raw="$(isctl_cmd get kvm policy moid "$moid" -o json)"
      printf '%s' "$raw" | jq '{Enabled:(.Enabled // false),TunneledKvmEnabled:(.TunneledKvmEnabled // false),MaximumSessions:(.MaximumSessions // 0),RemotePort:(.RemotePort // 0),EnableVideoEncryption:(.EnableVideoEncryption // false)}'
      ;;
    macpool)
      raw="$(isctl_cmd get macpool pool moid "$moid" -o json)"
      printf '%s' "$raw" | jq '{From:(.MacBlocks[0].From // ""),To:(.MacBlocks[0].To // "")}'
      ;;
    ethqos)
      raw="$(isctl_cmd get vnic ethqospolicy moid "$moid" -o json)"
      printf '%s' "$raw" | jq '{Mtu:(.Mtu // 0)}'
      ;;
    ethnetgrp)
      raw="$(isctl_cmd get fabric ethnetworkgrouppolicy moid "$moid" -o json)"
      printf '%s' "$raw" | jq '{NativeVlan:(.VlanSettings.NativeVlan // 0),AllowedVlans:(.VlanSettings.AllowedVlans // "")}'
      ;;
    lcp)
      raw="$(isctl_cmd get vnic lanconnectivitypolicy moid "$moid" -o json)"
      printf '%s' "$raw" | jq '{TargetPlatform:(.TargetPlatform // ""),PlacementMode:(.PlacementMode // "")}'
      ;;
    storage)
      raw="$(isctl_cmd get storage storagepolicy moid "$moid" -o json)"
      printf '%s' "$raw" | jq '{ControllerSlot:(.M2VirtualDrive.ControllerSlot // ""),Name:(.M2VirtualDrive.Name // ""),Enable:(.M2VirtualDrive.Enable // false),UnusedDisksState:(.UnusedDisksState // "")}'
      ;;
    boot)
      raw="$(isctl_cmd get boot precisionpolicy moid "$moid" -o json)"
      printf '%s' "$raw" | jq '{ConfiguredBootMode:(.ConfiguredBootMode // ""),BootDevices:((.BootDevices // []) | map({ObjectType:(.ObjectType // ""),Name:(.Name // ""),Slot:(.Slot // ""),Subtype:(.Subtype // ""),Enabled:(.Enabled // false)}))}'
      ;;
    vmedia)
      raw="$(isctl_cmd get vmedia policy moid "$moid" -o json)"
      printf '%s' "$raw" | jq '{Enabled:(.Enabled // false),Mapping:{DeviceType:(.Mappings[0].DeviceType // ""),MountProtocol:(.Mappings[0].MountProtocol // ""),FileLocation:(.Mappings[0].FileLocation // ""),VolumeName:(.Mappings[0].VolumeName // "")}}'
      ;;
    uuidpool)
      raw="$(isctl_cmd get uuidpool pool moid "$moid" -o json)"
      printf '%s' "$raw" | jq '{Prefix:(.Prefix // ""),From:(.UuidSuffixBlocks[0].From // ""),To:(.UuidSuffixBlocks[0].To // "")}'
      ;;
    *)
      fail "Unknown policy id in current_json: $id"
      ;;
  esac
}

policy_name() {
  local id="$1"
  case "$id" in
    ippool) printf '%s' "$IPPOOL_NAME" ;;
    access) printf '%s' "$ACCESS_POLICY_NAME" ;;
    power) printf '%s' "$POWER_POLICY_NAME" ;;
    kvm) printf '%s' "$KVM_POLICY_NAME" ;;
    macpool) printf '%s' "$MACPOOL_NAME" ;;
    ethqos) printf '%s' "$ETH_QOS_POLICY_NAME" ;;
    ethnetgrp) printf '%s' "$ETH_NETWORK_GROUP_NAME" ;;
    lcp) printf '%s' "$LCP_NAME" ;;
    storage) printf '%s' "$STORAGE_POLICY_NAME" ;;
    boot) printf '%s' "$BOOT_POLICY_NAME" ;;
    vmedia) printf '%s' "$VMEDIA_POLICY_NAME" ;;
    uuidpool) printf '%s' "$UUIDPOOL_NAME" ;;
    *) fail "Unknown policy id in policy_name: $id" ;;
  esac
}

policy_kind() {
  local id="$1"
  case "$id" in
    ippool) printf 'ippool pool' ;;
    access) printf 'access policy' ;;
    power) printf 'power policy' ;;
    kvm) printf 'kvm policy' ;;
    macpool) printf 'macpool pool' ;;
    ethqos) printf 'vnic ethqospolicy' ;;
    ethnetgrp) printf 'fabric ethnetworkgrouppolicy' ;;
    lcp) printf 'vnic lanconnectivitypolicy' ;;
    storage) printf 'storage storagepolicy' ;;
    boot) printf 'boot precisionpolicy' ;;
    vmedia) printf 'vmedia policy' ;;
    uuidpool) printf 'uuidpool pool' ;;
    *) fail "Unknown policy id in policy_kind: $id" ;;
  esac
}

apply_policy() {
  local id="$1" moid="$2"
  local desired_boot
  case "$id" in
    ippool)
      isctl_cmd update ippool pool moid "$moid" \
        --IpV4Config "{\"Gateway\":\"$MGMT_GATEWAY\",\"Netmask\":\"$MGMT_NETMASK\"}" \
        --IpV4Blocks "[{\"From\":\"$MGMT_IP_FROM\",\"To\":\"$MGMT_IP_TO\"}]" >/dev/null
      ;;
    access)
      isctl_cmd update access policy moid "$moid" \
        --ConfigurationType '{"ConfigureInband":true,"ConfigureOutOfBand":false}' \
        --AddressType '{"EnableIpV4":true,"EnableIpV6":false}' \
        --InbandVlan "$INBAND_VLAN" \
        --InbandIpPool "{\"Selector\":\"Name eq '$IPPOOL_NAME' and Organization.Moid eq '$ORG_MOID'\"}" >/dev/null
      ;;
    power)
      isctl_cmd update power policy moid "$moid" \
        --PowerPriority "$POWER_PRIORITY" \
        --PowerRestoreState "$POWER_RESTORE_STATE" \
        --PowerSaveMode "$POWER_SAVE_MODE" >/dev/null
      ;;
    kvm)
      isctl_cmd update kvm policy moid "$moid" \
        --Enabled="$KVM_ENABLED" \
        --TunneledKvmEnabled="$KVM_TUNNELED_ENABLED" \
        --MaximumSessions "$KVM_MAX_SESSIONS" \
        --RemotePort "$KVM_REMOTE_PORT" \
        --EnableVideoEncryption="$KVM_ENABLE_VIDEO_ENCRYPTION" >/dev/null
      ;;
    macpool)
      isctl_cmd update macpool pool moid "$moid" \
        --MacBlocks "[{\"From\":\"$MAC_FROM\",\"To\":\"$MAC_TO\"}]" >/dev/null
      ;;
    ethqos)
      isctl_cmd update vnic ethqospolicy moid "$moid" \
        --Mtu "$ETH_MTU" >/dev/null
      ;;
    ethnetgrp)
      isctl_cmd update fabric ethnetworkgrouppolicy moid "$moid" \
        --VlanSettings "{\"NativeVlan\":$INBAND_VLAN,\"AllowedVlans\":\"$ALLOWED_VLANS\"}" >/dev/null
      ;;
    lcp)
      isctl_cmd update vnic lanconnectivitypolicy moid "$moid" \
        --TargetPlatform "$TARGET_PLATFORM" \
        --PlacementMode custom >/dev/null
      ;;
    storage)
      isctl_cmd update storage storagepolicy moid "$moid" \
        --M2VirtualDrive "{\"Enable\":true,\"ControllerSlot\":\"$M2_CONTROLLER_SLOT\",\"Name\":\"$M2_VD_NAME\"}" \
        --UnusedDisksState UnconfiguredGood >/dev/null
      ;;
    boot)
      desired_boot="$(desired_boot_devices_json)"
      isctl_cmd update boot precisionpolicy moid "$moid" \
        --ConfiguredBootMode Uefi \
        --BootDevices "$desired_boot" >/dev/null
      ;;
    vmedia)
      isctl_cmd update vmedia policy moid "$moid" \
        --Enabled \
        --Mappings "[{\"DeviceType\":\"$VMEDIA_DEVICE_TYPE\",\"MountProtocol\":\"$VMEDIA_MOUNT_PROTOCOL\",\"FileLocation\":\"$VMEDIA_FILE_LOCATION\",\"VolumeName\":\"$VMEDIA_VOLUME_NAME\"}]" >/dev/null
      ;;
    uuidpool)
      isctl_cmd update uuidpool pool moid "$moid" \
        --Prefix "$UUID_PREFIX" \
        --UuidSuffixBlocks "[{\"From\":\"$UUID_SUFFIX_FROM\",\"To\":\"$UUID_SUFFIX_TO\"}]" >/dev/null
      ;;
    *)
      fail "Unknown policy id in apply_policy: $id"
      ;;
  esac
}

create_vmedia_policy() {
  local mappings organization_ref moid
  mappings="$(jq -c -n \
    --arg device "$VMEDIA_DEVICE_TYPE" \
    --arg protocol "$VMEDIA_MOUNT_PROTOCOL" \
    --arg location "$VMEDIA_FILE_LOCATION" \
    --arg volume "$VMEDIA_VOLUME_NAME" \
    '[{DeviceType:$device,MountProtocol:$protocol,FileLocation:$location,VolumeName:$volume}]')"
  organization_ref="{\"Moid\":\"$ORG_MOID\",\"ObjectType\":\"organization.Organization\"}"
  isctl_cmd create vmedia policy \
    --Name "$VMEDIA_POLICY_NAME" \
    --Organization "$organization_ref" \
    --Enabled \
    --Mappings "$mappings" >/dev/null
  moid="$(get_unique_moid_in_org_by_name vmedia policy "$VMEDIA_POLICY_NAME")"
  [[ -n "$moid" ]] || fail "Unable to resolve vMedia policy '$VMEDIA_POLICY_NAME' after create"
  log "Created vMedia policy '$VMEDIA_POLICY_NAME' (moid=$moid)"
}

set_status() {
  local id="$1" status="$2"
  printf '%s|%s\n' "$id" "$status" >> "$STATUS_FILE"
}

get_status() {
  local id="$1"
  awk -F'|' -v id="$id" '$1==id {print $2}' "$STATUS_FILE" | tail -n1
}

compare_one() {
  local id="$1" kind name noun type moid desired current
  kind="$(policy_kind "$id")"
  noun="${kind%% *}"
  type="${kind#* }"
  name="$(policy_name "$id")"

  moid="$(get_unique_moid_in_org_by_name "$noun" "$type" "$name")"
  desired="$(desired_json "$id")"
  current="$(current_json "$id" "$moid")"

  if [[ -z "$moid" ]]; then
    set_status "$id" "MISSING"
    CHANGED_IDS+=("$id")
    printf '\n[%s] %s (%s)\n' "$id" "$name" "$kind"
    printf 'Status: MISSING in org %s\n' "$ORG_NAME"
    printf 'Desired:\n%s\n' "$(printf '%s' "$desired" | jq -S .)"
    return 0
  fi

  if ! diff -u <(printf '%s' "$current" | jq -S .) <(printf '%s' "$desired" | jq -S .) >/tmp/"${id}_diff_$$.txt"; then
    set_status "$id" "CHANGED"
    CHANGED_IDS+=("$id")
    printf '\n[%s] %s (%s)\n' "$id" "$name" "$kind"
    printf 'Status: CHANGED (moid=%s)\n' "$moid"
    cat /tmp/"${id}_diff_$$.txt"
    rm -f /tmp/"${id}_diff_$$.txt"
  else
    set_status "$id" "UNCHANGED"
    printf '[%s] %s: UNCHANGED\n' "$id" "$name"
  fi
}

main() {
  need_cmd isctl
  need_cmd jq
  need_cmd diff

  if is_harvester_target; then
    validate_harvester_vmedia_vars
    log "Harvester target detected (OS_IMAGE_NAME='${OS_IMAGE_NAME:-}', ISO='$(printf '%s' "${VMEDIA_FILE_LOCATION:-${OS_IMAGE_LINK:-}}" | sed 's/[?#].*$//' | awk -F/ '{print $NF}')'); vMedia policy is included in reconciliation"
  else
    log "Non-Harvester target detected; vMedia policy is excluded from reconciliation"
  fi

  resolve_org_moid_strict
  log "Comparing current policies in org '$ORG_NAME' (ORG_MOID=$ORG_MOID)"

  local ids=(
    ippool access power kvm macpool ethqos ethnetgrp lcp storage boot uuidpool
  )
  if is_harvester_target; then
    ids+=(vmedia)
  fi

  local id
  for id in "${ids[@]}"; do
    compare_one "$id"
  done

  printf '\nSummary:\n'
  for id in "${ids[@]}"; do
    printf '  %-10s %s\n' "$id" "$(get_status "$id" || true)"
  done

  if (( ${#CHANGED_IDS[@]} == 0 )); then
    log "No changes detected."
    exit 0
  fi

  printf '\nProvision these %d change set(s) to org %s? [y/N]: ' "${#CHANGED_IDS[@]}" "$ORG_NAME"
  read -r answer
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    log "No changes provisioned."
    exit 0
  fi

  log "Applying policy updates strictly in org '$ORG_NAME'"
  for id in "${CHANGED_IDS[@]}"; do
    local kind name noun type moid
    kind="$(policy_kind "$id")"
    noun="${kind%% *}"
    type="${kind#* }"
    name="$(policy_name "$id")"
    moid="$(get_unique_moid_in_org_by_name "$noun" "$type" "$name")"
    if [[ -z "$moid" && "$id" == "vmedia" ]]; then
      log "Creating missing Harvester vMedia policy '$name' from configured VMEDIA_* values"
      create_vmedia_policy
      continue
    fi
    [[ -n "$moid" ]] || fail "Cannot apply '$id': object '$name' not found in org"
    log "Updating [$id] $name (moid=$moid)"
    apply_policy "$id" "$moid"
  done

  log "Provisioning completed."
}

main "$@"
