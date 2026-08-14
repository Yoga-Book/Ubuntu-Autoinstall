#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
TEST_MODE="${AUTOINSTALL_TEST_MODE:-0}"
OUTPUT_DIR="${1:-DATA/autoinstall/nocloud}"

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
  "$REPO_ROOT/nocloud/user-data" > "$OUTPUT_DIR/user-data"
install -m 0444 "$REPO_ROOT/nocloud/meta-data" "$OUTPUT_DIR/meta-data"
install -m 0555 "$REPO_ROOT/nocloud/verify-target.sh" "$OUTPUT_DIR/verify-target.sh"
install -m 0444 "$REPO_ROOT/nocloud/verify-target-lib.sh" "$OUTPUT_DIR/verify-target-lib.sh"
install -m 0555 "$REPO_ROOT/nocloud/vm-verify.sh" "$OUTPUT_DIR/vm-verify.sh"
install -m 0444 "$REPO_ROOT/nocloud/yogabook-vm-verify.service" "$OUTPUT_DIR/yogabook-vm-verify.service"
printf '%s\n' "$GUARD_MODE" > "$OUTPUT_DIR/guard-mode"

if grep -Rq '@@[A-Z_][A-Z_]*@@' "$OUTPUT_DIR"; then
  echo "Error: unresolved placeholder in rendered NoCloud data." >&2
  exit 1
fi
echo "Rendered $GUARD_MODE autoinstall data for $TARGET_DISK in $OUTPUT_DIR"
