#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
BURN_USB_LIBRARY_ONLY=1 source "$SCRIPT_DIR/burn-usb.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

DEVICE_JSON='{
  "blockdevices": [
    {"path":"/dev/sdb","type":"disk","tran":"usb","size":16000000000,"ro":false,"rm":true,"vendor":"Test","model":"Flash","serial":"ABC","maj:min":"8:16","mountpoints":[null]},
    {"path":"/dev/sdc","type":"disk","tran":"usb","size":16000000000,"ro":false,"rm":false,"vendor":"USB","model":"SSD","serial":"DEF","maj:min":"8:32","mountpoints":[null]},
    {"path":"/dev/sdd","type":"disk","tran":"usb","size":16000000000,"ro":false,"rm":true,"vendor":"Mounted","model":"Disk","serial":"GHI","maj:min":"8:48","mountpoints":[null],"children":[{"path":"/dev/sdd1","type":"part","mountpoints":["/run/media/USER_NAME/UBUNTU"]}]},
    {"path":"/dev/sde","type":"disk","tran":"usb","size":512,"ro":false,"rm":true,"vendor":"Tiny","model":"Disk","serial":"JKL","maj:min":"8:64","mountpoints":[null]},
    {"path":"/dev/sdf","type":"disk","tran":"usb","size":16000000000,"ro":true,"rm":true,"vendor":"ReadOnly","model":"Disk","serial":"MNO","maj:min":"8:80","mountpoints":[null]},
    {"path":"/dev/sdg","type":"disk","tran":"usb","size":16000000000,"ro":false,"rm":true,"vendor":"Unsafe","model":"Disk","serial":"PQR","maj:min":"8:96","mountpoints":[null],"children":[{"path":"/dev/sdg1","type":"part","mountpoints":["/srv/data"]}]},
    {"path":"/dev/nvme0n1","type":"disk","tran":"nvme","size":1000000000000,"ro":false,"rm":false,"vendor":"System","model":"Disk","serial":"SYS","maj:min":"259:0","mountpoints":["/"]}
  ]
}'
TEST_USER="${USER:-test-user}"
DEVICE_JSON="${DEVICE_JSON//USER_NAME/$TEST_USER}"

mapfile -t eligible < <(eligible_devices 1024 <<< "$DEVICE_JSON")
assert_eq "${#eligible[@]}" 2
assert_eq "$(jq -r .path <<< "${eligible[0]}")" /dev/sdb
assert_eq "$(jq -r .path <<< "${eligible[1]}")" /dev/sdc

mapfile -t selectable < <(selectable_devices 1024 "$TEST_USER" <<< "$DEVICE_JSON")
assert_eq "${#selectable[@]}" 3
assert_eq "$(jq -r .path <<< "${selectable[2]}")" /dev/sdd

excluded="$(excluded_devices 1024 "$TEST_USER" <<< "$DEVICE_JSON")"
grep -Fq '/dev/sde: too small' <<< "$excluded" || fail 'undersized disk was not rejected'
grep -Fq '/dev/sdf: read-only' <<< "$excluded" || fail 'read-only disk was not rejected'
grep -Fq '/dev/sdg: mounted outside the desktop media directory at /srv/data' <<< "$excluded" \
  || fail 'unsafe custom mount was not rejected'
! grep -Fq /dev/sdd <<< "$excluded" || fail 'desktop-auto-mounted disk was rejected'
! grep -Fq /dev/nvme0n1 <<< "$excluded" || fail 'non-USB disk entered USB candidates'

assert_eq "$(device_fingerprint "${eligible[0]}")" '["/dev/sdb","8:16",16000000000,"usb","Test","Flash","ABC"]'

(confirm_erase "${eligible[0]}" <<< 'ERASE /dev/sdb') >/dev/null \
  || fail 'exact erase confirmation was rejected'
if (confirm_erase "${eligible[0]}" <<< 'yes') >/dev/null 2>&1; then
  fail 'incorrect erase confirmation was accepted'
fi

load_devices() { printf '%s\n' "$DEVICE_JSON"; }
revalidate_identity "${eligible[0]}" >/dev/null
CHANGED_DEVICE_JSON="$(jq '(.blockdevices[] | select(.path == "/dev/sdb") | .serial) = "REPLACED"' <<< "$DEVICE_JSON")"
load_devices() { printf '%s\n' "$CHANGED_DEVICE_JSON"; }
if (revalidate_identity "${eligible[0]}") >/dev/null 2>&1; then
  fail 'changed device identity was accepted'
fi

CURRENT_DEVICE_JSON="$DEVICE_JSON"
load_devices() { printf '%s\n' "$CURRENT_DEVICE_JSON"; }
sudo() {
  [[ "$1" == umount && "$2" == -- && "$3" == "/run/media/$TEST_USER/UBUNTU" ]] \
    || fail "unexpected sudo command: $*"
  CURRENT_DEVICE_JSON="$(jq --arg mountpoint "$3" '
    walk(if type == "object" and has("mountpoints")
      then .mountpoints |= map(if . == $mountpoint then null else . end)
      else . end)
  ' <<< "$CURRENT_DEVICE_JSON")"
}
unmount_desktop_filesystems "${selectable[2]}" "$TEST_USER" >/dev/null
require_unmounted_device "${selectable[2]}" 1024

CURRENT_DEVICE_JSON="$(jq --arg mountpoint /srv/late-mount '
  (.blockdevices[] | select(.path == "/dev/sdd") | .children[0].mountpoints) = [$mountpoint]
' <<< "$DEVICE_JSON")"
if (unmount_desktop_filesystems "${selectable[2]}" "$TEST_USER") >/dev/null 2>&1; then
  fail 'late custom mount was unmounted instead of rejected'
fi

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
iso="$temporary_directory/ubuntu-autoinstall.iso"
printf 'verified image' > "$iso"
digest="$(sha256sum "$iso" | awk '{print $1}')"
printf '%s  %s\n' "$digest" "$(basename "$iso")" > "$iso.sha256"
read_guard_mode() { printf 'production'; }
assert_eq "$(validate_production_iso "$iso")" "$digest"

read_guard_mode() { printf 'test'; }
if (validate_production_iso "$iso" >/dev/null 2>&1); then
  fail 'test guard mode was accepted'
fi
test_iso="$temporary_directory/ubuntu-test-autoinstall.iso"
cp "$iso" "$test_iso"
printf '%s  %s\n' "$digest" "$(basename "$test_iso")" > "$test_iso.sha256"
read_guard_mode() { printf 'production'; }
if (validate_production_iso "$test_iso" >/dev/null 2>&1); then
  fail 'VM-test ISO filename was accepted'
fi
printf '%064d  %s\n' 0 "$(basename "$iso")" > "$iso.sha256"
read_guard_mode() { printf 'production'; }
if (validate_production_iso "$iso" >/dev/null 2>&1); then
  fail 'bad ISO checksum was accepted'
fi

grep -Fq 'sudo dd if="$iso" of="$selected_path" bs=4M status=progress conv=fsync' "$SCRIPT_DIR/burn-usb.sh" \
  || fail 'guarded dd invocation changed unexpectedly'
grep -Fq 'sudo head --bytes "$iso_size" "$selected_path"' "$SCRIPT_DIR/burn-usb.sh" \
  || fail 'bounded read-back verification changed unexpectedly'

printf 'Verified USB discovery, safe auto-unmounting, ISO checks, raw write policy, and read-back policy.\n'
