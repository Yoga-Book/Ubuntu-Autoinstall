#!/bin/sh
set -u

STATE_DIR=/var/lib/yogabook-graphical-health
LOG_DIR=/var/log/yogabook-graphical-health
LOG_FILE=$LOG_DIR/boot.log
FALLBACK_STAMP=$STATE_DIR/generic-fallback-configured
GRUB_SELECTION=/etc/default/grub.d/60-yogabook.cfg
GRUB_SELECTION_NEW=$GRUB_SELECTION.fallback

mkdir -p "$STATE_DIR" "$LOG_DIR"
exec >> "$LOG_FILE" 2>&1

log() {
  printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"
}

connector_ready() {
  for CONNECTOR in /sys/class/drm/card*-DSI-*; do
    [ -d "$CONNECTOR" ] || continue
    [ "$(cat "$CONNECTOR/status" 2>/dev/null)" = connected ] || continue
    if [ -f "$CONNECTOR/enabled" ] \
      && [ "$(cat "$CONNECTOR/enabled" 2>/dev/null)" != enabled ]; then
      continue
    fi
    return 0
  done
  return 1
}

graphical_ready() {
  connector_ready \
    && systemctl is-active --quiet gdm.service \
    && pgrep -x gnome-shell >/dev/null 2>&1
}

capture_diagnostics() {
  log "Capturing graphical boot diagnostics"
  printf '%s\n' '--- uname ---'
  uname -a
  printf '%s\n' '--- kernel command line ---'
  cat /proc/cmdline
  printf '%s\n' '--- display manager ---'
  systemctl status gdm.service --no-pager || true
  printf '%s\n' '--- DRM devices and connectors ---'
  ls -l /dev/dri /sys/class/drm 2>&1 || true
  for CONNECTOR in /sys/class/drm/card*-DSI-*; do
    [ -d "$CONNECTOR" ] || continue
    printf '%s\n' "$CONNECTOR"
    for ATTRIBUTE in status enabled modes; do
      if [ -f "$CONNECTOR/$ATTRIBUTE" ]; then
        printf '%s: ' "$ATTRIBUTE"
        cat "$CONNECTOR/$ATTRIBUTE"
      fi
    done
  done
  printf '%s\n' '--- GNOME processes ---'
  ps -ef | grep -E '[g]dm|[g]nome-shell' || true
  printf '%s\n' '--- GDM journal ---'
  journalctl -b -u gdm.service --no-pager || true
  printf '%s\n' '--- kernel DRM/i915/DSI messages ---'
  journalctl -b -k --no-pager \
    | grep -Ei 'drm|i915|dsi|panel|framebuffer|firmware|error|fail' || true
}

RUNNING_KERNEL=$(uname -r)
PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
KERNEL=$RUNNING_KERNEL
log "Checking product=$PRODUCT_NAME kernel=$RUNNING_KERNEL"

[ "$PRODUCT_NAME" = 'Lenovo YB1-X91L' ] || {
  log "Skipping fallback on an unexpected system"
  exit 0
}

case "$RUNNING_KERNEL" in
  *-yogabook-*) ;;
  *)
    log "Generic or other kernel is running; leaving the boot selection unchanged"
    exit 0
    ;;
esac

ATTEMPT=0
while [ "$ATTEMPT" -lt 24 ]; do
  if graphical_ready; then
    log "PASS: connected DSI, active GDM, and gnome-shell detected"
    exit 0
  fi
  ATTEMPT=$((ATTEMPT + 1))
  sleep 5
done

capture_diagnostics

if [ -e "$FALLBACK_STAMP" ]; then
  log "The generic-kernel fallback was already configured; refusing a reboot loop"
  exit 0
fi

GENERIC_KERNEL=$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*-generic' \
  | sort -V | tail -n 1)
[ -n "$GENERIC_KERNEL" ] && [ -s "$GENERIC_KERNEL" ] || {
  log "No generic Ubuntu kernel is available; retaining the custom kernel"
  exit 0
}

log "Graphical health failed; selecting $GENERIC_KERNEL for a one-shot recovery"
printf 'GRUB_TOP_LEVEL=%s\n' "$GENERIC_KERNEL" > "$GRUB_SELECTION_NEW"
mv "$GRUB_SELECTION_NEW" "$GRUB_SELECTION"
if ! update-grub; then
  log "update-grub failed; restoring the custom-kernel selection without rebooting"
  printf 'GRUB_TOP_LEVEL=/boot/vmlinuz-%s\n' "$KERNEL" > "$GRUB_SELECTION_NEW"
  mv "$GRUB_SELECTION_NEW" "$GRUB_SELECTION"
  update-grub || true
  exit 1
fi

printf 'custom=%s\nfallback=%s\ntime=%s\n' \
  "$KERNEL" "$GENERIC_KERNEL" "$(date --iso-8601=seconds)" > "$FALLBACK_STAMP"
sync
log "Rebooting once into the preserved generic Ubuntu kernel"
systemctl reboot
