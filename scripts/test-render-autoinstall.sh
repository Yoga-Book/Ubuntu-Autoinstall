#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
RENDERER="$SCRIPT_DIR/render-autoinstall.sh"
SOURCE_USER_DATA="$REPO_ROOT/nocloud/user-data"
SOURCE_VM_VERIFY="$REPO_ROOT/nocloud/vm-verify.sh"
SELECTED_MANIFEST="$REPO_ROOT/manifests/yogabook-selected-packages.tsv"
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
PACKAGE_NAMES="$(cut -f1 "$SELECTED_MANIFEST" | paste -sd ' ' -)"
KERNEL_PACKAGE="$(awk -F '\t' '$1 ~ /^linux-image-.*-yogabook-/ { print $1 }' "$SELECTED_MANIFEST")"
KERNEL_RELEASE=${KERNEL_PACKAGE#linux-image-}
[ -n "$KERNEL_RELEASE" ]
grep -Fq '@@YOGABOOK_PACKAGES@@' "$SOURCE_USER_DATA"
grep -Fq '@@YOGABOOK_KERNEL_RELEASE@@' "$SOURCE_USER_DATA"
grep -Fq '@@YOGABOOK_PACKAGES@@' "$SOURCE_VM_VERIFY"
grep -Fq '@@YOGABOOK_KERNEL_RELEASE@@' "$SOURCE_VM_VERIFY"
if grep -Eq 'linux-(headers|image)-[0-9].*-yogabook-' "$SOURCE_USER_DATA" "$SOURCE_VM_VERIFY"; then
  echo "Error: tracked NoCloud templates hard-code a Yoga Book kernel package." >&2
  exit 1
fi

PRODUCTION_OUTPUT="$TEST_DIR/production"
(
  cd "$TEST_DIR"
  # A stale value left in .env or the process environment must not change the
  # committed default credentials.
  AUTOINSTALL_PASSWORD_HASH=ignored "$RENDERER" "$PRODUCTION_OUTPUT" >/dev/null
)
[ "$(rendered_hash "$PRODUCTION_OUTPUT")" = "$DEFAULT_HASH" ]
if grep -Rq '@@[A-Z_][A-Z_]*@@' "$PRODUCTION_OUTPUT"; then
  echo "Error: production rendering retained a package placeholder." >&2
  exit 1
fi
grep -Fq "install --yes $PACKAGE_NAMES'" "$PRODUCTION_OUTPUT/user-data"
grep -Fq "dpkg-query -W $PACKAGE_NAMES" "$PRODUCTION_OUTPUT/user-data"
grep -Fq "/boot/vmlinuz-$KERNEL_RELEASE" "$PRODUCTION_OUTPUT/user-data"
grep -Fq "test \"\$(uname -r)\" = $KERNEL_RELEASE" "$PRODUCTION_OUTPUT/vm-verify.sh"
grep -Fq "dpkg-query -W $PACKAGE_NAMES" "$PRODUCTION_OUTPUT/vm-verify.sh"
grep -Fq "GRUB_TOP_LEVEL=/boot/vmlinuz-$KERNEL_RELEASE" "$PRODUCTION_OUTPUT/vm-verify.sh"
grep -Fxq production "$PRODUCTION_OUTPUT/guard-mode"
grep -Fq '/dev/yogabook-emmc' "$PRODUCTION_OUTPUT/user-data"
grep -Fq 'MODEL" = CJNB4R' "$PRODUCTION_OUTPUT/verify-target-lib.sh"
grep -Fq '${BLOCK_NAME}boot0' "$PRODUCTION_OUTPUT/verify-target-lib.sh"
grep -Fq '${BLOCK_NAME}boot1' "$PRODUCTION_OUTPUT/verify-target-lib.sh"
test -x "$PRODUCTION_OUTPUT/yogabook-graphical-health.sh"
test -f "$PRODUCTION_OUTPUT/yogabook-graphical-health.service"
test -x "$PRODUCTION_OUTPUT/yogabook-select-kernel"
grep -Fq 'GRUB_TIMEOUT_STYLE=menu' "$PRODUCTION_OUTPUT/user-data"
grep -Fq 'systemctl enable yogabook-graphical-health.service' "$PRODUCTION_OUTPUT/user-data"
grep -Fq 's|http://127.0.0.1/ubuntu-offline|http://archive.ubuntu.com/ubuntu|g' "$PRODUCTION_OUTPUT/user-data"
grep -Fq "PRODUCT_NAME\" = 'Lenovo YB1-X91L'" "$PRODUCTION_OUTPUT/yogabook-graphical-health.sh"
grep -Fq '*-yogabook-*)' "$PRODUCTION_OUTPUT/yogabook-graphical-health.sh"
grep -Fq '/etc/kernel/postinst.d/zz-00-yogabook-default' "$PRODUCTION_OUTPUT/user-data"
grep -Fq 'generic-fallback-configured' "$PRODUCTION_OUTPUT/yogabook-graphical-health.sh"
grep -Fq -- "-name 'vmlinuz-*-generic'" "$PRODUCTION_OUTPUT/yogabook-graphical-health.sh"
while IFS="$(printf '\t')" read -r PACKAGE _VERSION _ARCHITECTURE; do
  grep -Fq "$PACKAGE" "$PRODUCTION_OUTPUT/user-data"
done < "$SELECTED_MANIFEST"
if grep -Eq 'touch-keyboard' "$PRODUCTION_OUTPUT/user-data"; then
  echo "Error: production rendering contains an obsolete Yoga Book package." >&2
  exit 1
fi

VM_OUTPUT="$TEST_DIR/vm"
(
  cd "$TEST_DIR"
  AUTOINSTALL_TEST_MODE=1 AUTOINSTALL_TARGET_DISK=/dev/vda \
    "$RENDERER" "$VM_OUTPUT" >/dev/null 2>&1
)
[ "$(rendered_hash "$VM_OUTPUT")" = "$DEFAULT_HASH" ]
if grep -Rq '@@[A-Z_][A-Z_]*@@' "$VM_OUTPUT"; then
  echo "Error: VM rendering retained a package placeholder." >&2
  exit 1
fi
grep -Fq "install --yes $PACKAGE_NAMES'" "$VM_OUTPUT/user-data"
grep -Fq "test \"\$(uname -r)\" = $KERNEL_RELEASE" "$VM_OUTPUT/vm-verify.sh"
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
