#!/bin/sh
set -eu

command -v qemu-system-x86_64 >/dev/null 2>&1 || {
  echo "Error: qemu-system-x86_64 is required for the VM test." >&2
  exit 1
}
command -v qemu-img >/dev/null 2>&1 || {
  echo "Error: qemu-img is required for the VM test." >&2
  exit 1
}

ISO_BASENAME="$(basename "$ISO_FILE")"
ISO_NAME="${ISO_BASENAME%.iso}"
TEST_ISO="DATA/ISO/remastered/${ISO_NAME}-test-autoinstall.iso"
VM_DIR=DATA/VM
VM_TEST_NAME="${VM_TEST_NAME:-yogabook-test}"
VM_TEST_DISPLAY="${VM_TEST_DISPLAY:-none}"

case "$VM_TEST_NAME" in
  *[!A-Za-z0-9._-]*|'')
    echo "Error: VM_TEST_NAME may contain only letters, digits, dot, underscore, and hyphen." >&2
    exit 1
    ;;
esac

DISK="$VM_DIR/$VM_TEST_NAME.qcow2"
if [ "$VM_TEST_NAME" = yogabook-test ]; then
  # Preserve the original headless-test log names for existing workflows.
  INSTALL_LOG="$VM_DIR/install-serial.log"
  BOOT_LOG="$VM_DIR/boot-serial.log"
else
  INSTALL_LOG="$VM_DIR/$VM_TEST_NAME-install-serial.log"
  BOOT_LOG="$VM_DIR/$VM_TEST_NAME-boot-serial.log"
fi

[ -f "$TEST_ISO" ] || {
  echo "Error: $TEST_ISO is missing; run task build-vm-test." >&2
  exit 1
}
mkdir -p "$VM_DIR"
rm -f "$DISK" "$INSTALL_LOG" "$BOOT_LOG"
qemu-img create -f qcow2 "$DISK" 64G

ACCEL=tcg
CPU=max
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  ACCEL=kvm
  CPU=host
fi

echo "Running NIC-less unattended installation with QEMU acceleration: $ACCEL"
if [ "$VM_TEST_DISPLAY" != none ]; then
  echo "Opening the QEMU $VM_TEST_DISPLAY display; the test remains fully unattended."
  echo "Closing the window aborts the test. A second window opens for installed-system verification."
fi
echo "Installer serial log: $INSTALL_LOG"
timeout 90m qemu-system-x86_64 \
  -machine "q35,accel=$ACCEL" -cpu "$CPU" -m 4096 -smp 2 \
  -drive "file=$DISK,format=qcow2,if=virtio" \
  -cdrom "$TEST_ISO" -boot once=d \
  -nic none -display "$VM_TEST_DISPLAY" -serial "file:$INSTALL_LOG" -no-reboot

echo "Installer powered off; booting the installed disk without the ISO"
echo "Installed-system serial log: $BOOT_LOG"
timeout 15m qemu-system-x86_64 \
  -machine "q35,accel=$ACCEL" -cpu "$CPU" -m 4096 -smp 2 \
  -drive "file=$DISK,format=qcow2,if=virtio" \
  -boot c -nic none -display "$VM_TEST_DISPLAY" -serial "file:$BOOT_LOG" -no-reboot

grep -Fq 'YOGABOOK_VM_TEST_PASS kernel=7.2.0-rc7-yogabook1' "$BOOT_LOG"
echo "NIC-less VM installation powered off, booted the installed disk, selected the Yoga Book kernel, and passed package checks"
