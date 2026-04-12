#!/bin/bash
# Reproducer: QEMU microvm hangs at ACPI init with 4+ virtio-mmio devices
#
# Environment: RHEL 9.4, kernel 5.14.0-427.x
# Tested with: QEMU 9.2.0 and 10.2.2 (upstream)
# Reported by: Jens Freimann <jfreiman@redhat.com>
# Date: 2026-04-10
#
# The RHEL 9.4 kernel hangs during ACPI initialization when QEMU microvm
# has 4 or more virtio-mmio devices. The kernel stops at:
#   "ACPI: Core revision 20221020"
# and never progresses to APIC setup. With 3 or fewer devices it boots fine.
#
# Root cause hypothesis: QEMU microvm auto-enables ioapic2 when ACPI is on.
# The MADT describes two IOAPICs. The RHEL 5.14 kernel cannot handle this.
# See also: https://github.com/kata-containers/kata-containers/issues/1983
#
# Prerequisites:
#   - RHEL 9.4 or RHCOS with kernel 5.14.0-427.x
#   - Upstream QEMU built with microvm support (9.2.0 or 10.2.2 tested)
#   - KVM enabled (nested virt or bare metal)
#   - A Linux kernel + initrd (the RHEL host kernel works)
#
# Quick setup on a RHEL 9.4 VM with KVM:
#   curl -sL https://download.qemu.org/qemu-10.2.2.tar.xz | xz -d | tar x
#   cd qemu-10.2.2 && mkdir build && cd build
#   ../configure --target-list=x86_64-softmmu --enable-kvm
#   make -j$(nproc) && strip build/qemu-system-x86_64
#   cd ../..
#   ./reproduce-acpi-bug.sh qemu-10.2.2/build/qemu-system-x86_64 \
#       /boot/vmlinuz-$(uname -r) /boot/initramfs-$(uname -r).img
#
# Usage:
#   ./reproduce-acpi-bug.sh /path/to/qemu-system-x86_64 /path/to/vmlinuz /path/to/initrd.img

set -euo pipefail

QEMU=${1:?Usage: $0 <qemu-binary> <kernel> <initrd>}
KERNEL=${2:?}
INITRD=${3:?}

echo "QEMU:   $QEMU"
echo "Kernel: $KERNEL"
echo "Initrd: $INITRD"
echo ""

run_test() {
    local name=$1
    shift
    local logfile="/tmp/microvm-acpi-test-${name}.log"
    rm -f "$logfile"

    timeout 12 "$QEMU" \
        -machine microvm,accel=kvm \
        -cpu host -m 256M \
        -kernel "$KERNEL" \
        -initrd "$INITRD" \
        -append "console=ttyS0 panic=1 selinux=0" \
        -serial file:"$logfile" \
        "$@" \
        -nodefaults -nographic -no-reboot -daemonize 2>/dev/null

    sleep 10

    local pid=$(pgrep -f "microvm-acpi-test-${name}" 2>/dev/null || true)
    local lines=$(wc -l < "$logfile" 2>/dev/null || echo 0)
    local last=$(tail -1 "$logfile" 2>/dev/null || echo "")

    if grep -q "Run /init" "$logfile" 2>/dev/null; then
        echo "PASS  $name  ($lines lines, kernel boots)"
    elif echo "$last" | grep -q "ACPI: Core revision"; then
        echo "FAIL  $name  ($lines lines, HANGS at ACPI init)"
    else
        echo "FAIL  $name  ($lines lines, last: $last)"
    fi

    # Clean up
    if [ -n "$pid" ]; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    pkill -9 -f "microvm-acpi-test-${name}" 2>/dev/null || true
    sleep 1
}

echo "=== Test 1: 1 virtio-mmio device (should PASS) ==="
run_test "1dev" \
    -device vhost-vsock-device,guest-cid=12345

echo ""
echo "=== Test 2: 2 virtio-mmio devices (should PASS) ==="
run_test "2dev" \
    -device vhost-vsock-device,guest-cid=12345 \
    -device virtio-serial-device,id=serial0

echo ""
echo "=== Test 3: 3 virtio-mmio devices (should PASS) ==="
run_test "3dev" \
    -device vhost-vsock-device,guest-cid=12345 \
    -device virtio-serial-device,id=serial0 \
    -device virtio-scsi-device,id=scsi0

echo ""
echo "=== Test 4: 4 virtio-mmio devices (should FAIL - ACPI hang) ==="
run_test "4dev" \
    -device vhost-vsock-device,guest-cid=12345 \
    -device virtio-serial-device,id=serial0 \
    -device virtio-scsi-device,id=scsi0 \
    -object rng-random,id=rng0,filename=/dev/urandom \
    -device virtio-rng-device,rng=rng0

echo ""
echo "=== Test 5: 4 devices with acpi=off (should PASS - bypasses bug) ==="
run_test "4dev-noacpi" \
    -machine auto-kernel-cmdline=on \
    -device vhost-vsock-device,guest-cid=12346 \
    -device virtio-serial-device,id=serial0 \
    -device virtio-scsi-device,id=scsi0 \
    -object rng-random,id=rng0,filename=/dev/urandom \
    -device virtio-rng-device,rng=rng0

# For test 5, override the kernel cmdline to include acpi=off
# Need to re-run with modified append
pkill -9 -f "microvm-acpi-test-4dev-noacpi" 2>/dev/null || true
sleep 1
rm -f /tmp/microvm-acpi-test-4dev-noacpi.log
timeout 12 "$QEMU" \
    -machine microvm,accel=kvm,auto-kernel-cmdline=on \
    -cpu host -m 256M \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "acpi=off console=ttyS0 panic=1 selinux=0" \
    -serial file:/tmp/microvm-acpi-test-4dev-noacpi.log \
    -device vhost-vsock-device,guest-cid=12346 \
    -device virtio-serial-device,id=serial0 \
    -device virtio-scsi-device,id=scsi0 \
    -object rng-random,id=rng0,filename=/dev/urandom \
    -device virtio-rng-device,rng=rng0 \
    -nodefaults -nographic -no-reboot -daemonize 2>/dev/null
sleep 10
if grep -q "Run /init" /tmp/microvm-acpi-test-4dev-noacpi.log 2>/dev/null; then
    echo "PASS  4dev-noacpi  (kernel boots with acpi=off)"
else
    echo "FAIL  4dev-noacpi"
fi
pkill -9 -f "microvm-acpi-test-4dev-noacpi" 2>/dev/null || true

echo ""
echo "=== Expected results ==="
echo "Tests 1-3: PASS (3 or fewer virtio-mmio devices)"
echo "Test 4:    FAIL (4 devices, kernel hangs at ACPI init)"
echo "Test 5:    PASS (4 devices, acpi=off bypasses the bug)"
echo ""
echo "The kernel hangs at 'ACPI: Core revision 20221020' and never"
echo "reaches 'APIC: Switch to symmetric I/O mode setup'."
echo ""
echo "QEMU microvm auto-enables ioapic2 when ACPI is on."
echo "The MADT describes two IOAPICs. The RHEL 5.14 kernel"
echo "cannot handle this during ACPI initialization."
echo ""
echo "See: https://github.com/kata-containers/kata-containers/issues/1983"
echo ""
echo "Console logs saved to /tmp/microvm-acpi-test-*.log"
