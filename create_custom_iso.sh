#!/usr/bin/env bash
set -euo pipefail

# Build a bootable Harvester ISO by replacing the vendor GRUB configuration
# with the reviewed sample in ISO/. Requires curl and xorriso.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_URL="https://releases.rancher.com/harvester/v1.8.2/harvester-v1.8.2-amd64.iso"
OUTPUT_ISO="$SCRIPT_DIR/harvester-v1.8.2-amd64-custom.iso"
MENU_TIMEOUT=15
ALLOW_INSECURE_TLS=false

usage() {
  cat <<'EOF'
Usage: create_custom_iso.sh [options]

Options:
  --source-url URL   Source Harvester ISO URL
  --output PATH      Destination ISO path
  --timeout SECONDS  GRUB menu timeout, from 10 through 30 (default: 15)
  --insecure         Allow curl to download from a server with an untrusted TLS
                     certificate. Use only for a trusted internal source.
  -h, --help         Show this help
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --source-url)
      (($# >= 2)) || die '--source-url requires a URL'
      SOURCE_URL="$2"
      shift 2
      ;;
    --output)
      (($# >= 2)) || die '--output requires a path'
      OUTPUT_ISO="$2"
      shift 2
      ;;
    --timeout)
      (($# >= 2)) || die '--timeout requires a number of seconds'
      MENU_TIMEOUT="$2"
      shift 2
      ;;
    --insecure)
      ALLOW_INSECURE_TLS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ "$MENU_TIMEOUT" =~ ^[0-9]+$ ]] || die 'timeout must be an integer from 10 through 30'
(( MENU_TIMEOUT >= 10 && MENU_TIMEOUT <= 30 )) || die 'timeout must be from 10 through 30 seconds'
[[ "$SOURCE_URL" == https://* ]] || die 'source URL must use HTTPS'
[[ -f "$SCRIPT_DIR/ISO/grub.cfg.yaml" ]] || die 'missing ISO/grub.cfg.yaml sample'
[[ -f "$SCRIPT_DIR/ISO/harvester.cfg.yaml" ]] || die 'missing ISO/harvester.cfg.yaml sample'
[[ ! -e "$OUTPUT_ISO" ]] || die "refusing to overwrite existing output: $OUTPUT_ISO"

for command_name in curl xorriso; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

TMP_ROOT="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "$TMP_ROOT/harvester-iso.XXXXXXXX")" || die 'could not create temporary work directory'
cleanup() {
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

SOURCE_ISO="$WORK_DIR/harvester-source.iso"
CUSTOM_GRUB="$WORK_DIR/grub.cfg"
VERIFY_GRUB="$WORK_DIR/verify-grub.cfg"
VERIFY_HARVESTER="$WORK_DIR/verify-harvester.cfg"

if [[ "$ALLOW_INSECURE_TLS" == true ]]; then
  curl --insecure --fail --location --show-error --output "$SOURCE_ISO" "$SOURCE_URL"
else
  curl --fail --location --show-error --output "$SOURCE_ISO" "$SOURCE_URL"
fi
[[ -s "$SOURCE_ISO" ]] || die 'downloaded source ISO is empty'

# Keep the supplied GRUB content, but make the operator selection window
# configurable and ensure it is visible in both BIOS and UEFI menu use.
awk -v timeout="$MENU_TIMEOUT" '
  BEGIN { replaced = 0 }
  /^[[:space:]]*set[[:space:]]+timeout[[:space:]]*=/ {
    if (!replaced) print "set timeout=" timeout
    replaced = 1
    next
  }
  { print }
  END { if (!replaced) exit 3 }
' "$SCRIPT_DIR/ISO/grub.cfg.yaml" > "$CUSTOM_GRUB" || die 'sample GRUB config must contain one timeout assignment'

grep -Fq "set timeout=$MENU_TIMEOUT" "$CUSTOM_GRUB" || die 'GRUB timeout was not set as requested'
grep -Fq 'set timeout_style=menu' "$CUSTOM_GRUB" || die 'GRUB menu must be visible'
grep -Fq 'source (${root})/boot/grub2/harvester.cfg' "$CUSTOM_GRUB" || die 'GRUB config must source harvester.cfg'
grep -Fq 'menuentry "node1 - Harvester Installer' "$CUSTOM_GRUB" || die 'missing node1 boot option'
grep -Fq 'menuentry "node5 - Harvester Installer' "$CUSTOM_GRUB" || die 'missing node5 boot option'
grep -Eq '^fi[[:space:]]*$' "$CUSTOM_GRUB" || die 'GRUB config has an unterminated conditional block'

if command -v grub2-script-check >/dev/null 2>&1; then
  grub2-script-check "$CUSTOM_GRUB" || die 'GRUB syntax validation failed'
elif command -v grub-script-check >/dev/null 2>&1; then
  grub-script-check "$CUSTOM_GRUB" || die 'GRUB syntax validation failed'
else
  printf 'NOTE: grub-script-check is unavailable; performed required-entry and block-terminator checks only.\n' >&2
fi

mkdir -p "$(dirname -- "$OUTPUT_ISO")"
OUTPUT_ISO="$(cd -- "$(dirname -- "$OUTPUT_ISO")" && pwd)/$(basename -- "$OUTPUT_ISO")"
[[ ! -e "$OUTPUT_ISO" ]] || die "refusing to overwrite existing output: $OUTPUT_ISO"

xorriso \
  -indev "$SOURCE_ISO" \
  -outdev "$OUTPUT_ISO" \
  -map "$CUSTOM_GRUB" /boot/grub2/grub.cfg \
  -map "$SCRIPT_DIR/ISO/harvester.cfg.yaml" /boot/grub2/harvester.cfg \
  -boot_image any replay \
  -commit -end

[[ -s "$OUTPUT_ISO" ]] || die 'xorriso did not create a non-empty ISO'
xorriso -osirrox on -indev "$OUTPUT_ISO" \
  -extract /boot/grub2/grub.cfg "$VERIFY_GRUB" \
  -extract /boot/grub2/harvester.cfg "$VERIFY_HARVESTER" \
  -end >/dev/null
cmp -s "$CUSTOM_GRUB" "$VERIFY_GRUB" || die 'GRUB config in output ISO did not match the customized sample'
cmp -s "$SCRIPT_DIR/ISO/harvester.cfg.yaml" "$VERIFY_HARVESTER" || die 'harvester.cfg in output ISO did not match the supplied sample'

printf 'Created custom Harvester ISO: %s\n' "$OUTPUT_ISO"
printf 'GRUB menu timeout: %s seconds; visible node1-node5 options are available.\n' "$MENU_TIMEOUT"
printf 'The script only creates the ISO; booting it and selecting an installer entry remains an operator action.\n'
