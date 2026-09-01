#!/usr/bin/env bash
set -euo pipefail

LSBLK_COLUMNS='NAME,PATH,TYPE,TRAN,SIZE,RO,RM,VENDOR,MODEL,SERIAL,MAJ:MIN,MOUNTPOINTS'

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1; run task setup"
}

human_size() {
  numfmt --to=iec-i --suffix=B "$1"
}

production_iso_path() {
  local source basename
  source="${ISO_FILE:-DATA/ISO/official/ubuntu-26.04.1-desktop-amd64.iso}"
  basename="$(basename "$source")"
  [[ "$basename" == *.iso ]] || die "ISO_FILE must end in .iso: $source"
  printf 'DATA/ISO/remastered/%s-autoinstall.iso\n' "${basename%.iso}"
}

read_guard_mode() {
  local iso=$1 temporary_directory
  temporary_directory="$(mktemp -d)"
  if ! xorriso -osirrox on -indev "$iso" \
    -extract /nocloud/guard-mode "$temporary_directory/guard-mode" >/dev/null 2>&1; then
    rm -rf "$temporary_directory"
    return 1
  fi
  tr -d '\r\n' < "$temporary_directory/guard-mode"
  rm -rf "$temporary_directory"
}

validate_production_iso() {
  local iso=$1 sidecar expected actual guard_mode sidecar_name
  sidecar="$iso.sha256"
  [[ -f "$iso" ]] || die "production ISO is missing: $iso; run task build or task iso:build:burn:usb"
  [[ "$(basename "$iso")" != *-test-autoinstall.iso ]] || die "refusing to write a VM-test image: $iso"
  [[ "$(basename "$iso")" == *-autoinstall.iso ]] || die "unexpected production ISO name: $iso"
  [[ -f "$sidecar" ]] || die "ISO checksum sidecar is missing: $sidecar"
  [[ "$(wc -l < "$sidecar")" -eq 1 ]] || die "ISO checksum sidecar must contain exactly one entry: $sidecar"

  read -r expected sidecar_name < "$sidecar"
  sidecar_name="${sidecar_name#\*}"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ && "$sidecar_name" == "$(basename "$iso")" ]] \
    || die "ISO checksum sidecar does not name $(basename "$iso"): $sidecar"
  printf 'Verifying production ISO checksum: %s (%s) ...\n' \
    "$iso" "$(human_size "$(stat --format=%s "$iso")")" >&2
  actual="$(dd if="$iso" bs=4M status=progress | sha256sum | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] \
    || die "ISO checksum mismatch: expected ${expected,,}, calculated ${actual,,}"

  guard_mode="$(read_guard_mode "$iso")" \
    || die "could not read /nocloud/guard-mode from $iso"
  [[ "$guard_mode" == production ]] \
    || die "refusing ISO with guard-mode='$guard_mode'; expected 'production'"
  printf '%s\n' "${expected,,}"
}

load_devices() {
  lsblk --json --bytes --output "$LSBLK_COLUMNS"
}

eligible_devices() {
  local iso_size=$1
  jq -c --argjson iso_size "$iso_size" '
    def descendants: ., ((.children // [])[] | descendants);
    .blockdevices[]
    | select(.type == "disk" and .tran == "usb")
    | select((.path // "") | startswith("/dev/"))
    | select((.ro // false) == false)
    | select((.size // 0) >= $iso_size)
    | select((.["maj:min"] // "") != "")
    | select([descendants | (.mountpoints // [])[] | select(. != null and . != "")] | length == 0)
  '
}

selectable_devices() {
  local iso_size=$1 user_name=$2
  jq -c --argjson iso_size "$iso_size" --arg user_name "$user_name" '
    def descendants: ., ((.children // [])[] | descendants);
    def desktop_mount:
      startswith("/run/media/" + $user_name + "/")
      or startswith("/media/" + $user_name + "/");
    .blockdevices[]
    | select(.type == "disk" and .tran == "usb")
    | select((.path // "") | startswith("/dev/"))
    | select((.ro // false) == false)
    | select((.size // 0) >= $iso_size)
    | select((.["maj:min"] // "") != "")
    | select([descendants | (.mountpoints // [])[] | select(. != null and . != "") | desktop_mount] | all)
  '
}

mounted_paths() {
  jq -r '
    def descendants: ., ((.children // [])[] | descendants);
    [descendants | (.mountpoints // [])[] | select(. != null and . != "")][]
  ' <<< "$1"
}

excluded_devices() {
  local iso_size=$1 user_name=$2
  jq -r --argjson iso_size "$iso_size" --arg user_name "$user_name" '
    def descendants: ., ((.children // [])[] | descendants);
    def desktop_mount:
      startswith("/run/media/" + $user_name + "/")
      or startswith("/media/" + $user_name + "/");
    .blockdevices[]
    | select(.type == "disk" and .tran == "usb")
    | ([descendants | (.mountpoints // [])[] | select(. != null and . != "")] | join(", ")) as $mounts
    | ([descendants | (.mountpoints // [])[] | select(. != null and . != "" and (desktop_mount | not))] | join(", ")) as $unsafe_mounts
    | if (.ro // false) then "\(.path): read-only"
      elif (.size // 0) < $iso_size then "\(.path): too small"
      elif (.["maj:min"] // "") == "" then "\(.path): missing kernel device identity"
      elif $unsafe_mounts != "" then "\(.path): mounted outside the desktop media directory at \($unsafe_mounts)"
      else empty
      end
  '
}

device_description() {
  local mounts
  mounts="$(mounted_paths "$1" | paste -sd, -)"
  jq -r '[(.vendor // ""), (.model // "")] | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != "")) | join(" ")' <<< "$1" \
    | { read -r model; printf '%s  %s  %s  serial=%s removable=%s\n' \
        "$(jq -r .path <<< "$1")" \
        "$(human_size "$(jq -r .size <<< "$1")")" \
        "${model:-unknown model}" \
        "$(jq -r '.serial // "unknown"' <<< "$1")" \
        "$(jq -r 'if .rm then "yes" else "no" end' <<< "$1")"; }
  if [[ -n "$mounts" ]]; then
    printf '     mounted=%s (will be unmounted automatically)\n' "$mounts"
  fi
}

device_fingerprint() {
  jq -c '[.path, .["maj:min"], .size, .tran, .vendor, .model, .serial]' <<< "$1"
}

select_device() {
  local devices_json=$1 iso_size=$2 user_name=$3 answer selection index
  mapfile -t ELIGIBLE_DEVICES < <(selectable_devices "$iso_size" "$user_name" <<< "$devices_json")
  if ((${#ELIGIBLE_DEVICES[@]} == 0)); then
    die "no eligible USB disks were found"
  fi
  printf '\nEligible USB disks:\n'
  for index in "${!ELIGIBLE_DEVICES[@]}"; do
    printf '  %d. ' "$((index + 1))"
    device_description "${ELIGIBLE_DEVICES[$index]}"
  done
  read -r -p 'Select the USB disk number (or press Enter to cancel): ' answer
  [[ "$answer" =~ ^[0-9]+$ ]] || die "USB write cancelled or selection is invalid"
  selection=$((10#$answer))
  ((selection >= 1 && selection <= ${#ELIGIBLE_DEVICES[@]})) \
    || die "USB selection is outside 1..${#ELIGIBLE_DEVICES[@]}"
  SELECTED_DEVICE="${ELIGIBLE_DEVICES[$((selection - 1))]}"
}

confirm_erase() {
  local device=$1 path phrase answer
  path="$(jq -r .path <<< "$device")"
  phrase="ERASE $path"
  printf '\nWARNING: ALL DATA ON THIS DEVICE WILL BE DESTROYED:\n  '
  device_description "$device"
  read -r -p "Type exactly '$phrase' to continue: " answer
  [[ "$answer" == "$phrase" ]] || die "confirmation did not match; USB write cancelled"
}

current_selected_device() {
  local selected=$1 devices_json path
  path="$(jq -r .path <<< "$selected")"
  devices_json="$(load_devices)" || die "could not refresh block-device information"
  jq -c --arg path "$path" '.blockdevices[] | select(.path == $path)' <<< "$devices_json" | head -n 1
}

revalidate_identity() {
  local selected=$1 current
  current="$(current_selected_device "$selected")"
  [[ -n "$current" ]] || die "selected device disappeared: $(jq -r .path <<< "$selected")"
  [[ "$(device_fingerprint "$current")" == "$(device_fingerprint "$selected")" ]] \
    || die "selected device identity changed before writing; reconnect and retry"
  printf '%s\n' "$current"
}

unmount_desktop_filesystems() {
  local selected=$1 user_name=$2 current mountpoint
  current="$(revalidate_identity "$selected")"
  mapfile -t mountpoints < <(mounted_paths "$current")
  for mountpoint in "${mountpoints[@]}"; do
    case "$mountpoint" in
      "/run/media/$user_name/"*|"/media/$user_name/"*) ;;
      *) die "selected device gained a mount outside the desktop media directory: $mountpoint" ;;
    esac
    printf 'Unmounting %s ...\n' "$mountpoint"
    sudo umount -- "$mountpoint" \
      || die "could not unmount $mountpoint; close applications using the USB and retry"
  done
}

require_unmounted_device() {
  local selected=$1 iso_size=$2 current reason
  current="$(revalidate_identity "$selected")"
  reason="$(jq -r --argjson iso_size "$iso_size" '
    def descendants: ., ((.children // [])[] | descendants);
    if (.type != "disk" or .tran != "usb") then "not a whole USB-transport disk"
    elif (.ro // false) then "read-only"
    elif (.size // 0) < $iso_size then "too small"
    elif (.["maj:min"] // "") == "" then "missing kernel device identity"
    elif ([descendants | (.mountpoints // [])[] | select(. != null and . != "")] | length) != 0 then "still mounted"
    else empty
    end
  ' <<< "$current")"
  [[ -z "$reason" ]] || die "selected device is not safe to write: $reason"
}

main() {
  local iso expected_digest iso_size devices_json excluded selected_path actual_digest user_name
  [[ -t 0 && -t 1 ]] || die "USB writing requires an interactive terminal"
  for command_name in jq lsblk xorriso sudo dd blockdev umount head sha256sum numfmt; do
    require_command "$command_name"
  done
  [[ "${AUTOINSTALL_TEST_MODE:-0}" == 0 ]] \
    || die "USB writing is disabled while AUTOINSTALL_TEST_MODE is enabled"

  iso="$(production_iso_path)"
  expected_digest="$(validate_production_iso "$iso")"
  iso_size="$(stat --format=%s "$iso")"
  printf 'Verified production ISO: %s (%s, SHA256 %s)\n' \
    "$iso" "$(human_size "$iso_size")" "$expected_digest"

  devices_json="$(load_devices)" || die "could not read block-device information"
  user_name="${SUDO_USER:-${USER:-}}"
  [[ -n "$user_name" ]] || die "could not determine the desktop user name"
  excluded="$(excluded_devices "$iso_size" "$user_name" <<< "$devices_json")"
  if [[ -n "$excluded" ]]; then
    printf '\nExcluded USB disks:\n%s\n' "$excluded"
  fi
  select_device "$devices_json" "$iso_size" "$user_name"
  confirm_erase "$SELECTED_DEVICE"

  sudo -v || die "sudo authorization failed"
  unmount_desktop_filesystems "$SELECTED_DEVICE" "$user_name"
  require_unmounted_device "$SELECTED_DEVICE" "$iso_size"
  selected_path="$(jq -r .path <<< "$SELECTED_DEVICE")"
  printf '\nWriting %s to %s ...\n' "$iso" "$selected_path"
  if ! sudo dd if="$iso" of="$selected_path" bs=4M status=progress conv=fsync; then
    die "USB write failed; the device may contain a partial or invalid image"
  fi
  sudo blockdev --flushbufs "$selected_path" \
    || die "USB flush failed; the device may contain a partial or invalid image"

  printf 'Reading back and verifying %s ...\n' "$(human_size "$iso_size")"
  actual_digest="$(sudo head --bytes "$iso_size" "$selected_path" \
    | dd bs=4M status=progress \
    | sha256sum \
    | awk '{print $1}')" \
    || die "USB read-back failed; the device may contain a partial or invalid image"
  [[ "$actual_digest" == "$expected_digest" ]] \
    || die "USB read-back checksum mismatch; expected $expected_digest, read $actual_digest"

  printf '\nSUCCESS: wrote and verified %s on %s.\nSHA256: %s\nThe bootable USB is ready; it is safe to remove.\n' \
    "$(human_size "$iso_size")" "$selected_path" "$expected_digest"
}

if [[ "${BURN_USB_LIBRARY_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
