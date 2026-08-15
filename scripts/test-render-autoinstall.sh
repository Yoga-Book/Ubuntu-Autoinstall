#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
RENDERER="$SCRIPT_DIR/render-autoinstall.sh"
SOURCE_USER_DATA="$REPO_ROOT/nocloud/user-data"
DEFAULT_HASH='$6$fywbi1lu3Ea97e9V$4hq1EHmuvkk3/lX9TUyuvnr4eleA76apESfZZioPUn2X0FMOCa5guFWvw7i6QS9vOwdFPwgE9hfWfHi7V1HjV.'
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM

rendered_hash() {
  awk '
    $1 == "password:" {
      value = $2
      sub(/^"/, "", value)
      sub(/"$/, "", value)
      print value
      exit
    }
  ' "$1/user-data"
}

command -v mkpasswd >/dev/null 2>&1 || {
  echo "Error: mkpasswd is required to verify the documented default credentials." >&2
  exit 1
}

CALCULATED_HASH="$(printf '%s' yoga | mkpasswd -m sha-512 -s -S fywbi1lu3Ea97e9V)"
[ "$CALCULATED_HASH" = "$DEFAULT_HASH" ] || {
  echo "Error: the tracked hash does not encode the documented yoga password." >&2
  exit 1
}

PRODUCTION_OUTPUT="$TEST_DIR/production"
(
  cd "$TEST_DIR"
  # A stale value left in .env or the process environment must not change the
  # committed default credentials.
  AUTOINSTALL_PASSWORD_HASH=ignored "$RENDERER" "$PRODUCTION_OUTPUT" >/dev/null
)
cmp "$SOURCE_USER_DATA" "$PRODUCTION_OUTPUT/user-data"
[ "$(rendered_hash "$PRODUCTION_OUTPUT")" = "$DEFAULT_HASH" ]
grep -Fxq production "$PRODUCTION_OUTPUT/guard-mode"
grep -Fq '/dev/yogabook-emmc' "$PRODUCTION_OUTPUT/user-data"
grep -Fq 'MODEL" = CJNB4R' "$PRODUCTION_OUTPUT/verify-target-lib.sh"
grep -Fq '${BLOCK_NAME}boot0' "$PRODUCTION_OUTPUT/verify-target-lib.sh"
grep -Fq '${BLOCK_NAME}boot1' "$PRODUCTION_OUTPUT/verify-target-lib.sh"
test -x "$PRODUCTION_OUTPUT/yogabook-graphical-health.sh"
test -f "$PRODUCTION_OUTPUT/yogabook-graphical-health.service"
grep -Fq 'GRUB_TIMEOUT_STYLE=menu' "$PRODUCTION_OUTPUT/user-data"
grep -Fq 'systemctl enable yogabook-graphical-health.service' "$PRODUCTION_OUTPUT/user-data"
grep -Fq "PRODUCT_NAME\" = 'Lenovo YB1-X91L'" "$PRODUCTION_OUTPUT/yogabook-graphical-health.sh"
grep -Fq '[ "$RUNNING_KERNEL" = "$KERNEL" ]' "$PRODUCTION_OUTPUT/yogabook-graphical-health.sh"
grep -Fq 'generic-fallback-configured' "$PRODUCTION_OUTPUT/yogabook-graphical-health.sh"
grep -Fq -- "-name 'vmlinuz-*-generic'" "$PRODUCTION_OUTPUT/yogabook-graphical-health.sh"

VM_OUTPUT="$TEST_DIR/vm"
(
  cd "$TEST_DIR"
  AUTOINSTALL_TEST_MODE=1 AUTOINSTALL_TARGET_DISK=/dev/vda \
    "$RENDERER" "$VM_OUTPUT" >/dev/null 2>&1
)
[ "$(rendered_hash "$VM_OUTPUT")" = "$DEFAULT_HASH" ]
grep -Fq '/dev/vda' "$VM_OUTPUT/user-data"
if grep -Fq '/dev/yogabook-emmc' "$VM_OUTPUT/user-data"; then
  echo "Error: VM rendering retained the production eMMC target." >&2
  exit 1
fi
grep -Fxq test "$VM_OUTPUT/guard-mode"
test -x "$VM_OUTPUT/yogabook-graphical-health.sh"
test -f "$VM_OUTPUT/yogabook-graphical-health.service"

if AUTOINSTALL_TEST_MODE=1 AUTOINSTALL_TARGET_DISK=/dev/mmcblk1 \
  "$RENDERER" "$TEST_DIR/invalid" >/dev/null 2>&1; then
  echo "Error: VM rendering accepted the production eMMC target." >&2
  exit 1
fi

echo "Verified tracked yoga/yoga credentials and production/VM disk rendering."
