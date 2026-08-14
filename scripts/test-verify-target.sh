#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/../nocloud/verify-target-lib.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
SYS_BLOCK="$TEST_DIR/sys/class/block"
mkdir -p "$SYS_BLOCK"

add_card() {
  NAME="$1"
  MODEL="$2"
  REMOVABLE="$3"
  WITH_BOOT="$4"
  mkdir -p "$SYS_BLOCK/$NAME/device"
  printf '%s\n' "$MODEL" > "$SYS_BLOCK/$NAME/device/name"
  printf '%s\n' "$REMOVABLE" > "$SYS_BLOCK/$NAME/removable"
  if [ "$WITH_BOOT" = 1 ]; then
    mkdir -p "$SYS_BLOCK/${NAME}boot0" "$SYS_BLOCK/${NAME}boot1"
  fi
}

add_card mmcblk0 ED4QT 0 0
add_card mmcblk1 CJNB4R 0 1
[ "$(find_production_target "$SYS_BLOCK")" = /dev/mmcblk1 ]

CONFIG="$TEST_DIR/autoinstall.yaml"
printf '%s\n' 'path: /dev/yogabook-emmc' > "$CONFIG"
patch_autoinstall_target "$CONFIG" /dev/mmcblk1
grep -Fxq 'path: /dev/mmcblk1' "$CONFIG"

rm -rf "$SYS_BLOCK"
mkdir -p "$SYS_BLOCK"
add_card mmcblk0 CJNB4R 0 1
add_card mmcblk1 ED4QT 0 0
[ "$(find_production_target "$SYS_BLOCK")" = /dev/mmcblk0 ]

rm -rf "$SYS_BLOCK"
mkdir -p "$SYS_BLOCK"
add_card mmcblk0 ED4QT 0 0
add_card mmcblk1 CJNB4R 0 1
rm -rf "$SYS_BLOCK/mmcblk1boot1"
if (find_production_target "$SYS_BLOCK") >/dev/null 2>&1; then
  echo "Error: target discovery accepted an eMMC without both boot devices." >&2
  exit 1
fi

mkdir -p "$SYS_BLOCK/mmcblk1boot1"
add_card mmcblk2 CJNB4R 0 1
if (find_production_target "$SYS_BLOCK") >/dev/null 2>&1; then
  echo "Error: target discovery accepted an ambiguous pair of eMMC devices." >&2
  exit 1
fi

echo "Verified dynamic CJNB4R eMMC discovery, microSD exclusion, boot-device checks, and target patching."
