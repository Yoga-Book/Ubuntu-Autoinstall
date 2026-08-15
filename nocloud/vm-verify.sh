#!/bin/sh
set -eu

exec > /var/log/yogabook-vm-verify.log 2>&1
test "$(uname -r)" = 7.2.0-rc7-yogabook1
test -z "$(dpkg --audit)"
apt-get --no-download check
dpkg-query -W \
  alsa-ucm-conf-yogabook \
  linux-headers-7.2.0-rc7-yogabook1 \
  linux-image-7.2.0-rc7-yogabook1 \
  touch-keyboard \
  yogabook-support
grep -Fxq 'GRUB_TOP_LEVEL=/boot/vmlinuz-7.2.0-rc7-yogabook1' /etc/default/grub.d/60-yogabook.cfg
printf 'YOGABOOK_VM_TEST_PASS kernel=%s\n' "$(uname -r)" | tee /dev/ttyS0
systemctl poweroff
