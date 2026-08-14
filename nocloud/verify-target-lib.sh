#!/bin/sh

fail() {
  echo "AUTOINSTALL SAFETY ABORT: $*" >&2
  exit 1
}

find_production_target() {
  SYS_BLOCK_ROOT="$1"
  MATCH=""
  MATCH_COUNT=0

  for BLOCK_PATH in "$SYS_BLOCK_ROOT"/mmcblk*; do
    [ -d "$BLOCK_PATH" ] || continue
    BLOCK_NAME="${BLOCK_PATH##*/}"
    BLOCK_SUFFIX="${BLOCK_NAME#mmcblk}"
    case "$BLOCK_SUFFIX" in
      ''|*[!0-9]*) continue ;;
    esac
    [ -r "$BLOCK_PATH/removable" ] && [ -r "$BLOCK_PATH/device/name" ] || continue
    [ "$(cat "$BLOCK_PATH/removable")" = 0 ] || continue
    MODEL="$(tr -d '[:space:]' < "$BLOCK_PATH/device/name")"
    [ "$MODEL" = CJNB4R ] || continue
    [ -d "$SYS_BLOCK_ROOT/${BLOCK_NAME}boot0" ] \
      && [ -d "$SYS_BLOCK_ROOT/${BLOCK_NAME}boot1" ] || continue
    MATCH="/dev/$BLOCK_NAME"
    MATCH_COUNT=$((MATCH_COUNT + 1))
  done

  [ "$MATCH_COUNT" -ne 0 ] \
    || fail "no non-removable CJNB4R eMMC with boot0 and boot1 devices was found"
  [ "$MATCH_COUNT" -eq 1 ] \
    || fail "found $MATCH_COUNT matching CJNB4R eMMC devices; refusing an ambiguous target"
  printf '%s\n' "$MATCH"
}

patch_autoinstall_target() {
  CONFIG_PATH="$1"
  TARGET_DISK="$2"
  PLACEHOLDER=/dev/yogabook-emmc
  [ -f "$CONFIG_PATH" ] || fail "autoinstall configuration is unavailable at $CONFIG_PATH"
  if grep -Fq "$PLACEHOLDER" "$CONFIG_PATH"; then
    PATCHED_CONFIG="${CONFIG_PATH}.yogabook-target"
    sed "s|$PLACEHOLDER|$TARGET_DISK|g" "$CONFIG_PATH" > "$PATCHED_CONFIG"
    cat "$PATCHED_CONFIG" > "$CONFIG_PATH"
    rm -f "$PATCHED_CONFIG"
  fi
  grep -Fq "$TARGET_DISK" "$CONFIG_PATH" \
    || fail "autoinstall storage target was not updated to $TARGET_DISK"
  ! grep -Fq "$PLACEHOLDER" "$CONFIG_PATH" \
    || fail "autoinstall storage target placeholder remains unresolved"
}
