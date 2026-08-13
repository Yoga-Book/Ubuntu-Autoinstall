#!/bin/sh
set -eu

MODE="${1:?missing guard mode}"
TARGET_DISK="${2:?missing target disk}"

fail() {
  echo "AUTOINSTALL SAFETY ABORT: $*" >&2
  exit 1
}

[ -b "$TARGET_DISK" ] || fail "$TARGET_DISK is not a block device"

if [ "$MODE" = test ]; then
  case "$TARGET_DISK" in
    /dev/vd[a-z]|/dev/sd[a-z]) ;;
    *) fail "test mode target is not a whole virtio or SCSI disk" ;;
  esac
  echo "Test-only target accepted: $TARGET_DISK"
  exit 0
fi

[ "$MODE" = production ] || fail "unknown guard mode $MODE"
[ "$TARGET_DISK" = /dev/mmcblk0 ] || fail "production target must be /dev/mmcblk0"

PRODUCT_NAME="$(tr -d '\000\r\n' < /sys/class/dmi/id/product_name)"
[ "$PRODUCT_NAME" = "Lenovo YB1-X91L" ] \
  || fail "DMI product is '$PRODUCT_NAME', expected 'Lenovo YB1-X91L'"

REMOVABLE="$(cat /sys/class/block/mmcblk0/removable)"
[ "$REMOVABLE" = 0 ] || fail "/dev/mmcblk0 is marked removable"

EMMC_MODEL="$(tr -d '[:space:]' < /sys/class/block/mmcblk0/device/name)"
[ "$EMMC_MODEL" = CWBD3R ] || fail "eMMC model is '$EMMC_MODEL', expected 'CWBD3R'"

command -v mokutil >/dev/null 2>&1 \
  || fail "mokutil is unavailable; cannot verify Secure Boot state"
SECURE_BOOT_STATE="$(mokutil --sb-state 2>/dev/null)" \
  || fail "could not determine Secure Boot state"
if printf '%s\n' "$SECURE_BOOT_STATE" | grep -qi 'SecureBoot enabled'; then
  fail "Secure Boot is enabled; 6.17.4-yogabook1 is unsigned"
fi
printf '%s\n' "$SECURE_BOOT_STATE" | grep -qi 'SecureBoot disabled' \
  || fail "Secure Boot state is not explicitly disabled"

echo "Yoga Book hardware, eMMC, and Secure Boot checks passed for $TARGET_DISK"
