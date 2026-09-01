#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
TEST_MODE="${AUTOINSTALL_TEST_MODE:-0}"
OUTPUT_DIR="${1:-DATA/autoinstall/nocloud}"
SELECTED_MANIFEST="$REPO_ROOT/manifests/yogabook-selected-packages.tsv"

PACKAGE_NAMES="$(awk -F '\t' '
  NF != 3 || $1 !~ /^[a-z0-9][a-z0-9+.-]*$/ || $2 == "" || $3 !~ /^[a-z0-9][a-z0-9-]*$/ {
    printf "Error: malformed selected package identity at %s:%d\n", FILENAME, FNR > "/dev/stderr"
    invalid = 1
    next
  }
  seen[$1]++ {
    printf "Error: duplicate selected package %s\n", $1 > "/dev/stderr"
    invalid = 1
    next
  }
  { names = names (names == "" ? "" : " ") $1; count++ }
  END {
    if (count != 15) {
      printf "Error: selected package manifest must contain exactly 15 unique identities; found %d\n", count > "/dev/stderr"
      invalid = 1
    }
    if (!invalid) print names
    exit invalid ? 1 : 0
  }
' "$SELECTED_MANIFEST")"
KERNEL_PACKAGE="$(awk -F '\t' '
  $1 ~ /^linux-image-.*-yogabook-/ { package = $1; count++ }
  END {
    if (count != 1) {
      printf "Error: selected package manifest must contain exactly one Yoga Book kernel image; found %d\n", count > "/dev/stderr"
      exit 1
    }
    print package
  }
' "$SELECTED_MANIFEST")"
KERNEL_RELEASE=${KERNEL_PACKAGE#linux-image-}
awk -F '\t' -v package="linux-headers-$KERNEL_RELEASE" '
  $1 == package { found++ }
  END { exit found == 1 ? 0 : 1 }
' "$SELECTED_MANIFEST" || {
    echo "Error: selected package manifest does not contain headers matching $KERNEL_RELEASE." >&2
    exit 1
  }

case "$TEST_MODE" in
  0)
    TARGET_DISK=/dev/yogabook-emmc
    GUARD_MODE=production
    ;;
  1)
    TARGET_DISK="${AUTOINSTALL_TARGET_DISK:-/dev/vda}"
    case "$TARGET_DISK" in
      /dev/vd[a-z]|/dev/sd[a-z]) ;;
      *)
        echo "Error: test rendering only accepts a whole virtio or SCSI disk (/dev/vdX or /dev/sdX)." >&2
        exit 1
        ;;
    esac
    GUARD_MODE=test
    echo "WARNING: rendering a test-only autoinstall for $TARGET_DISK; do not use it on hardware." >&2
    ;;
  *)
    echo "Error: AUTOINSTALL_TEST_MODE must be 0 or 1." >&2
    exit 1
    ;;
esac

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
DISK_ESCAPED="$(printf '%s' "$TARGET_DISK" | sed 's/[&|]/\\&/g')"
sed \
  -e "s|/dev/yogabook-emmc|$DISK_ESCAPED|g" \
  -e "s|@@YOGABOOK_PACKAGES@@|$PACKAGE_NAMES|g" \
  -e "s|@@YOGABOOK_KERNEL_RELEASE@@|$KERNEL_RELEASE|g" \
  "$REPO_ROOT/nocloud/user-data" > "$OUTPUT_DIR/user-data"
install -m 0444 "$REPO_ROOT/nocloud/meta-data" "$OUTPUT_DIR/meta-data"
install -m 0555 "$REPO_ROOT/nocloud/verify-target.sh" "$OUTPUT_DIR/verify-target.sh"
install -m 0444 "$REPO_ROOT/nocloud/verify-target-lib.sh" "$OUTPUT_DIR/verify-target-lib.sh"
sed \
  -e "s|@@YOGABOOK_PACKAGES@@|$PACKAGE_NAMES|g" \
  -e "s|@@YOGABOOK_KERNEL_RELEASE@@|$KERNEL_RELEASE|g" \
  "$REPO_ROOT/nocloud/vm-verify.sh" > "$OUTPUT_DIR/vm-verify.sh"
chmod 0555 "$OUTPUT_DIR/vm-verify.sh"
install -m 0444 "$REPO_ROOT/nocloud/yogabook-vm-verify.service" "$OUTPUT_DIR/yogabook-vm-verify.service"
install -m 0555 "$REPO_ROOT/nocloud/yogabook-graphical-health.sh" "$OUTPUT_DIR/yogabook-graphical-health.sh"
install -m 0444 "$REPO_ROOT/nocloud/yogabook-graphical-health.service" "$OUTPUT_DIR/yogabook-graphical-health.service"
install -m 0555 "$REPO_ROOT/nocloud/yogabook-select-kernel" "$OUTPUT_DIR/yogabook-select-kernel"
printf '%s\n' "$GUARD_MODE" > "$OUTPUT_DIR/guard-mode"

if grep -Rq '@@[A-Z_][A-Z_]*@@' "$OUTPUT_DIR"; then
  echo "Error: unresolved placeholder in rendered NoCloud data." >&2
  exit 1
fi
echo "Rendered $GUARD_MODE autoinstall data for $TARGET_DISK in $OUTPUT_DIR"
