#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/verify-target-lib.sh"

MODE="${1:?missing guard mode}"
REQUESTED_TARGET="${2:?missing target disk}"

if [ "$MODE" = test ]; then
  [ -b "$REQUESTED_TARGET" ] || fail "$REQUESTED_TARGET is not a block device"
  case "$REQUESTED_TARGET" in
    /dev/vd[a-z]|/dev/sd[a-z]) ;;
    *) fail "test mode target is not a whole virtio or SCSI disk" ;;
  esac
  echo "Test-only target accepted: $REQUESTED_TARGET"
  exit 0
fi

[ "$MODE" = production ] || fail "unknown guard mode $MODE"

PRODUCT_NAME="$(tr -d '\000\r\n' < /sys/class/dmi/id/product_name)"
[ "$PRODUCT_NAME" = "Lenovo YB1-X91L" ] \
  || fail "DMI product is '$PRODUCT_NAME', expected 'Lenovo YB1-X91L'"

TARGET_DISK="$(find_production_target /sys/class/block)"
[ -b "$TARGET_DISK" ] || fail "$TARGET_DISK is not a block device"
case "$REQUESTED_TARGET" in
  /dev/yogabook-emmc|"$TARGET_DISK") ;;
  *) fail "production target request '$REQUESTED_TARGET' does not match discovered eMMC $TARGET_DISK" ;;
esac

command -v mokutil >/dev/null 2>&1 \
  || fail "mokutil is unavailable; cannot verify Secure Boot state"
SECURE_BOOT_STATE="$(mokutil --sb-state 2>/dev/null)" \
  || fail "could not determine Secure Boot state"
if printf '%s\n' "$SECURE_BOOT_STATE" | grep -qi 'SecureBoot enabled'; then
  fail "Secure Boot is enabled; 7.2.0-yogabook-20260901-232318 is unsigned"
fi
printf '%s\n' "$SECURE_BOOT_STATE" | grep -qi 'SecureBoot disabled' \
  || fail "Secure Boot state is not explicitly disabled"

patch_autoinstall_target /autoinstall.yaml "$TARGET_DISK"
echo "Yoga Book hardware, CJNB4R eMMC $TARGET_DISK, and Secure Boot checks passed"
