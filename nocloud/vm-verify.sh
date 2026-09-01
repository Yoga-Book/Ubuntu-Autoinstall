#!/bin/sh
set -eu

exec > /var/log/yogabook-vm-verify.log 2>&1
test "$(uname -r)" = @@YOGABOOK_KERNEL_RELEASE@@
test -z "$(dpkg --audit)"
apt-get --no-download check
test "$(dpkg-query -W -f='${Status}' ubuntu-desktop-minimal)" = "install ok installed"
if dpkg-query -W -f='${Status}\n' ubuntu-desktop 2>/dev/null \
  | grep -Fxq 'install ok installed'; then
  echo "Error: the full ubuntu-desktop profile is installed." >&2
  exit 1
fi
dpkg-query -W @@YOGABOOK_PACKAGES@@
grep -Fxq 'GRUB_TOP_LEVEL=/boot/vmlinuz-@@YOGABOOK_KERNEL_RELEASE@@' /etc/default/grub.d/60-yogabook.cfg
printf 'YOGABOOK_VM_TEST_PASS kernel=%s\n' "$(uname -r)" | tee /dev/ttyS0
systemctl poweroff
