#!/bin/bash
# Manual QEMU microvm boot test
# Run this on the cluster node (via oc debug node/)
# This test uses 1 virtio-mmio device (vsock) and works reliably.

QEMU=/usr/libexec/qemu-kvm-microvm
KERNEL=/var/cache/kata-containers/vmlinuz.container
INITRD=/var/cache/kata-containers/kata-containers-initrd.img
LOG=/tmp/microvm-boot.log

rm -f "$LOG"

$QEMU \
  -machine microvm,accel=kvm \
  -cpu host \
  -m 256 \
  -kernel "$KERNEL" \
  -initrd "$INITRD" \
  -append "console=ttyS0 agent.log=debug" \
  -serial file:"$LOG" \
  -device vhost-vsock-device,guest-cid=12345 \
  -nodefaults -nographic -no-reboot -daemonize

sleep 8

echo "=== QEMU process ==="
ps aux | grep qemu-kvm-microvm | grep -v grep

echo "=== Agent status ==="
if grep -q "ttRPC server started" "$LOG"; then
    echo "PASS: Agent started on vsock://-1:1024"
    grep "ttRPC server started" "$LOG"
else
    echo "FAIL: Agent did not start"
    tail -10 "$LOG"
fi

echo ""
echo "=== CPU usage (should be ~0%) ==="
ps -p $(pgrep -f qemu-kvm-microvm | head -1) -o pcpu= 2>/dev/null

echo ""
echo "Kill with: pkill -9 -f qemu-kvm-microvm"
