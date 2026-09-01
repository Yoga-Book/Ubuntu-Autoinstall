#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
SELECTOR="$ROOT_DIR/nocloud/yogabook-select-kernel"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
SYSROOT="$TEST_DIR/root"
UPDATE_LOG="$TEST_DIR/update.log"
mkdir -p "$SYSROOT/sys/class/dmi/id" "$SYSROOT/boot" \
  "$SYSROOT/etc/default/grub.d" "$SYSROOT/var/lib/yogabook-graphical-health"
printf 'Lenovo YB1-X91L\n' > "$SYSROOT/sys/class/dmi/id/product_name"
printf 'old\n' > "$SYSROOT/boot/vmlinuz-7.2.0-yogabook-20260830-230352"
printf 'new\n' > "$SYSROOT/boot/vmlinuz-7.2.0-yogabook-20260831-033805"
printf 'generic\n' > "$SYSROOT/boot/vmlinuz-7.0.0-30-generic"
printf 'GRUB_TOP_LEVEL=/boot/vmlinuz-7.2.0-yogabook-20260830-230352\n' \
  > "$SYSROOT/etc/default/grub.d/60-yogabook.cfg"

fake_update="$TEST_DIR/update-grub"
printf '#!/bin/sh\nprintf "update\\n" >> "$YBV_UPDATE_LOG"\nexit "${YBV_UPDATE_RESULT:-0}"\n' \
  > "$fake_update"
chmod +x "$fake_update"

selector_env=(
  YBV_SYSROOT="$SYSROOT"
  YBV_UPDATE_GRUB="$fake_update"
  YBV_UPDATE_LOG="$UPDATE_LOG"
)
env "${selector_env[@]}" "$SELECTOR" >/dev/null
grep -Fxq 'GRUB_TOP_LEVEL=/boot/vmlinuz-7.2.0-yogabook-20260831-033805' \
  "$SYSROOT/etc/default/grub.d/60-yogabook.cfg"
[[ $(grep -c '^update$' "$UPDATE_LOG") -eq 1 ]]

printf 'GRUB_TOP_LEVEL=/boot/vmlinuz-7.2.0-yogabook-20260830-230352\n' \
  > "$SYSROOT/etc/default/grub.d/60-yogabook.cfg"
: > "$UPDATE_LOG"
env "${selector_env[@]}" YBV_DEFER_UPDATE_GRUB=1 "$SELECTOR" \
  7.2.0-yogabook-20260831-033805 "$SYSROOT/boot/vmlinuz-7.2.0-yogabook-20260831-033805" \
  >/dev/null
grep -Fxq 'GRUB_TOP_LEVEL=/boot/vmlinuz-7.2.0-yogabook-20260831-033805' \
  "$SYSROOT/etc/default/grub.d/60-yogabook.cfg"
[[ ! -s $UPDATE_LOG ]]

hook="$TEST_DIR/zz-00-yogabook-default"
cp "$SELECTOR" "$hook"
chmod +x "$hook"
printf 'GRUB_TOP_LEVEL=/boot/vmlinuz-7.2.0-yogabook-20260830-230352\n' \
  > "$SYSROOT/etc/default/grub.d/60-yogabook.cfg"
: > "$UPDATE_LOG"
env "${selector_env[@]}" "$hook" \
  7.2.0-yogabook-20260831-033805 "$SYSROOT/boot/vmlinuz-7.2.0-yogabook-20260831-033805" \
  >/dev/null
grep -Fxq 'GRUB_TOP_LEVEL=/boot/vmlinuz-7.2.0-yogabook-20260831-033805' \
  "$SYSROOT/etc/default/grub.d/60-yogabook.cfg"
[[ ! -s $UPDATE_LOG ]]

printf 'GRUB_TOP_LEVEL=/boot/vmlinuz-7.0.0-30-generic\n' \
  > "$SYSROOT/etc/default/grub.d/60-yogabook.cfg"
touch "$SYSROOT/var/lib/yogabook-graphical-health/generic-fallback-configured"
env "${selector_env[@]}" "$SELECTOR" >/dev/null 2>&1
grep -Fxq 'GRUB_TOP_LEVEL=/boot/vmlinuz-7.0.0-30-generic' \
  "$SYSROOT/etc/default/grub.d/60-yogabook.cfg"
rm "$SYSROOT/var/lib/yogabook-graphical-health/generic-fallback-configured"

printf 'GRUB_TOP_LEVEL=/boot/vmlinuz-7.2.0-yogabook-20260830-230352\n' \
  > "$SYSROOT/etc/default/grub.d/60-yogabook.cfg"
: > "$UPDATE_LOG"
if env "${selector_env[@]}" YBV_UPDATE_RESULT=1 "$SELECTOR" >/dev/null 2>&1; then
  printf 'FAIL: selector accepted an update-grub failure\n' >&2
  exit 1
fi
grep -Fxq 'GRUB_TOP_LEVEL=/boot/vmlinuz-7.2.0-yogabook-20260830-230352' \
  "$SYSROOT/etc/default/grub.d/60-yogabook.cfg"
[[ $(grep -c '^update$' "$UPDATE_LOG") -eq 2 ]]

rm "$SYSROOT/etc/default/grub.d/60-yogabook.cfg"
: > "$UPDATE_LOG"
if env "${selector_env[@]}" YBV_UPDATE_RESULT=1 "$SELECTOR" >/dev/null 2>&1; then
  printf 'FAIL: selector accepted an update-grub failure without a prior selection\n' >&2
  exit 1
fi
[[ ! -e $SYSROOT/etc/default/grub.d/60-yogabook.cfg ]]
[[ $(grep -c '^update$' "$UPDATE_LOG") -eq 2 ]]

printf 'Verified dynamic Yoga Book kernel selection, fallback preservation and rollback.\n'
