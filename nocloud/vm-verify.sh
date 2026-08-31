#!/bin/sh
set -eu

exec > /var/log/yogabook-vm-verify.log 2>&1
test "$(uname -r)" = 7.2.0-yogabook-20260831-153058
test -z "$(dpkg --audit)"
apt-get --no-download check
test "$(dpkg-query -W -f='${Status}' ubuntu-desktop-minimal)" = "install ok installed"
if dpkg-query -W -f='${Status}\n' ubuntu-desktop 2>/dev/null \
  | grep -Fxq 'install ok installed'; then
  echo "Error: the full ubuntu-desktop profile is installed." >&2
  exit 1
fi
dpkg-query -W \
  alsa-ucm-conf-yogabook \
  linux-headers-7.2.0-yogabook-20260831-153058 \
  linux-image-7.2.0-yogabook-20260831-153058 \
  sof-topology-yogabook \
  halo-keyboard \
  yogabook-sensors \
  yogabook-camera \
  yogabook-gnss \
  yogabook-validator \
  gnome-control-center \
  gnome-control-center-data \
  gir1.2-mutter-18 \
  libmutter-18-0 \
  mutter-common \
  mutter-common-bin
grep -Fxq 'GRUB_TOP_LEVEL=/boot/vmlinuz-7.2.0-yogabook-20260831-153058' /etc/default/grub.d/60-yogabook.cfg
printf 'YOGABOOK_VM_TEST_PASS kernel=%s\n' "$(uname -r)" | tee /dev/ttyS0
systemctl poweroff
