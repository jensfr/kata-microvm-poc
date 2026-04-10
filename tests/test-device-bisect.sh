#!/bin/bash
# Device bisection test for QEMU microvm ACPI bug
# Run this on the cluster node (via oc debug node/)
# Tests adding virtio-mmio devices one at a time to find the threshold.

QEMU=/usr/libexec/qemu-kvm-microvm
KERNEL=/var/cache/kata-containers/vmlinuz.container
INITRD=/var/cache/kata-containers/kata-containers-initrd.img

run_test() {
    local name=$1
    shift
    local logfile="/tmp/microvm-${name}.log"

    pkill -9 -f qemu-kvm-microvm 2>/dev/null
    sleep 1
    rm -f "$logfile"

    $QEMU \
        -machine microvm,accel=kvm \
        -cpu host -m 2048M \
        -object memory-backend-file,id=dimm1,size=2048M,mem-path=/dev/shm,share=on \
        -machine memory-backend=dimm1 \
        -kernel "$KERNEL" \
        -initrd "$INITRD" \
        -append "console=ttyS0 agent.log=debug" \
        -serial file:"$logfile" \
        "$@" \
        -nodefaults -nographic -no-reboot -daemonize

    sleep 12

    local lines=$(wc -l < "$logfile" 2>/dev/null || echo 0)
    if grep -q "ttRPC server started" "$logfile" 2>/dev/null; then
        echo "PASS  $name  (${lines} lines, agent started)"
    else
        local last=$(tail -1 "$logfile" 2>/dev/null)
        echo "FAIL  $name  (${lines} lines, last: ${last})"
    fi

    pkill -9 -f qemu-kvm-microvm 2>/dev/null
    sleep 1
}

echo "=== QEMU microvm device bisection ==="
echo "Testing how many virtio-mmio devices the kernel can handle"
echo ""

echo "--- Test 1: vsock only (1 device) ---"
run_test "1dev" \
    -device vhost-vsock-device,guest-cid=12345

echo "--- Test 2: vsock + serial (2 devices) ---"
run_test "2dev" \
    -device vhost-vsock-device,guest-cid=12345 \
    -device virtio-serial-device,id=serial0

echo "--- Test 3: vsock + serial + scsi (3 devices) ---"
run_test "3dev" \
    -device vhost-vsock-device,guest-cid=12345 \
    -device virtio-serial-device,id=serial0 \
    -device virtio-scsi-device,id=scsi0

echo "--- Test 4: vsock + serial + scsi + rng (4 devices) ---"
run_test "4dev" \
    -device vhost-vsock-device,guest-cid=12345 \
    -device virtio-serial-device,id=serial0 \
    -device virtio-scsi-device,id=scsi0 \
    -object rng-random,id=rng0,filename=/dev/urandom \
    -device virtio-rng-device,rng=rng0

echo ""
echo "Expected: Tests 1-3 PASS, Test 4 FAIL (ACPI hang)"
echo "Root cause: QEMU microvm ioapic2 auto-enables with ACPI,"
echo "RHEL 5.14 kernel cannot handle the second IOAPIC in MADT."
