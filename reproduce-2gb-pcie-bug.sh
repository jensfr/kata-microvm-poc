#!/bin/bash
# Reproducer: QEMU microvm with pcie=on hangs at exactly 2048M RAM
#
# Environment: QEMU 10.2.2, RHEL 9.4 kernel 5.14.0-427.x
# Reported by: Jens Freimann <jfreiman@redhat.com>
# Date: 2026-04-12
#
# QEMU microvm with pcie=on hangs during ACPI initialization when
# guest RAM is exactly 2048M. Other sizes (256, 512, 1024, 4096) work fine.
#
# Likely cause: 2GB RAM boundary (0x80000000) conflicts with PCI ECAM
# memory mapping when pcie=on is enabled. The RAM region ends exactly
# where the PCI configuration space begins.
#
# Prerequisites:
#   - QEMU 10.2.2 (or similar) with microvm + pcie support
#   - KVM enabled
#   - A Linux kernel + initrd
#
# Usage:
#   ./reproduce-2gb-pcie-bug.sh /path/to/qemu /path/to/vmlinuz /path/to/initrd

set -euo pipefail

QEMU=${1:?Usage: $0 <qemu-binary> <kernel> <initrd>}
KERNEL=${2:?}
INITRD=${3:?}

echo "QEMU:   $($QEMU -version 2>&1 | head -1)"
echo "Kernel: $KERNEL"
echo ""

for MEM in 256 512 1024 2048 4096; do
    printf "%5sM + 5 PCI devices (pcie=on): " "$MEM"
    OUTPUT=$(timeout 10 "$QEMU" \
        -machine microvm,accel=kvm,pcie=on \
        -cpu host -m ${MEM}M \
        -device virtio-serial-pci \
        -device virtio-scsi-pci \
        -object rng-random,id=rng0,filename=/dev/urandom \
        -device virtio-rng-pci,rng=rng0 \
        -device vhost-vsock-pci,guest-cid=$((RANDOM + 1000)) \
        -device virtio-net-pci \
        -kernel "$KERNEL" \
        -initrd "$INITRD" \
        -append "console=ttyS0 panic=1 selinux=0" \
        -serial stdio \
        -nodefaults -nographic -no-reboot 2>&1 || true)

    if echo "$OUTPUT" | grep -q "Run /init"; then
        echo "BOOTS"
    elif echo "$OUTPUT" | grep -q "ACPI: Core revision"; then
        echo "HANGS at ACPI"
    else
        echo "UNKNOWN (last line: $(echo "$OUTPUT" | tail -1))"
    fi
done

echo ""
echo "Expected: 256M-1024M and 4096M BOOT, 2048M HANGS"
echo ""
echo "The 2GB boundary (0x80000000) is where the PCI ECAM memory"
echo "region is typically placed. When RAM is exactly 2048M, it"
echo "conflicts with the ECAM mapping in microvm with pcie=on."
