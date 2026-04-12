# Kata Containers QEMU microvm Prototype

Proof-of-concept for running Kata Containers with the QEMU microvm machine type instead of Q35, targeting a reduced attack surface for AI agent sandboxing workloads.

## Background

NVIDIA's security whitepaper rates standard Kata at RTE 2b-2c, partly because Q35 includes a large device emulation attack surface (USB controllers, serial ports, IDE, VGA, legacy PC devices). The upstream QEMU microvm machine type eliminates all of this. Red Hat excluded microvm from qemu-kvm-core because it is not supported by libvirt and lacks enterprise features (hotplug, live migration). OSC does not use libvirt and agent workloads do not need these features.

## What was tested

- **Cluster**: ARO 4.18 (Azure Red Hat OpenShift)
- **Node**: `kata-test-cluster-9kllc-worker-eastus1-q5z7l`
- **Host kernel**: RHEL 5.14.0-427.111.1.el9_4.x86_64
- **Guest kernel**: Same (from kata-containers initrd)
- **QEMU**: Upstream v9.2.0 built from source with microvm enabled
- **Kata**: OSC 1.8 (kata-containers 3.21.0)

## Results

### What works

1. QEMU microvm boots the Kata kernel and initrd
2. kata-agent starts and listens on vsock (`vsock://-1:1024`)
3. The Kata shim correctly generates MMIO device transport for microvm:
   - `virtio-serial-device` (not `-pci`)
   - `virtio-scsi-device`
   - `virtio-rng-device`
   - `vhost-vsock-device`
   - `vhost-user-fs-device`
   - `virtio-net-device`
   - No PCI bridges, no intel-iommu, no NUMA
4. QMP communication between shim and QEMU works
5. Up to 3 virtio-mmio devices work with full ACPI

### The blocker

The RHEL 5.14 kernel hangs during ACPI initialization when microvm has 4+ virtio-mmio devices. The kernel stops at `ACPI: Core revision 20221020` and never progresses to APIC setup.

The Kata shim needs 6 devices (serial, scsi, rng, vsock, virtiofs, net), so it always hits this.

**Root cause**: QEMU microvm auto-enables a second IOAPIC (`ioapic2`) when ACPI is on. The MADT (Multiple APIC Description Table) describes two IOAPICs. The RHEL 5.14 kernel cannot handle this during ACPI initialization. See [kata-containers#1983](https://github.com/kata-containers/kata-containers/issues/1983) filed by Gerd Hoffmann (microvm maintainer).

**Workaround attempted**: `acpi=off` in kernel cmdline with `auto-kernel-cmdline=on` for device discovery. The kernel boots and the agent starts, but LAPIC/MSI interrupts are not configured (all vectors masked), so virtio devices cannot deliver interrupts and vsock connections time out.

### Device bisection results

| Test | Devices | ACPI | Result |
|------|---------|------|--------|
| A | 1 (vsock) | on | boots, agent starts |
| B | 2 (+ serial) | on | boots, agent starts |
| F | 3 (+ scsi) | on | boots, agent starts |
| G | 4 (+ rng) | on | **hangs at ACPI** |
| M | 4 (vsock, serial, scsi, rng) | off | boots, agent starts (but no interrupts) |
| N | 6 (all shim devices) | off | boots, but vsock times out (no interrupts) |

### Minimum required devices

| Device | Required | Purpose |
|--------|----------|---------|
| vhost-vsock-device | Yes | Shim-to-agent ttrpc communication |
| virtio-serial-device | Yes | Console (hvc0) |
| vhost-user-fs-device | Yes | Container rootfs via virtiofs |
| virtio-net-device | Yes | Pod networking |
| virtio-scsi-device | No | Block device hotplug (unused with virtiofs) |
| virtio-rng-device | No | Entropy (kernel has other sources) |

Even with scsi and rng removed, 4 devices are needed, which is exactly the threshold.

## Attack surface comparison: Q35 vs microvm

From the running Q35 process on the same node:

```
# Q35 (current)
-machine q35,accel=kvm,kernel_irqchip=split
-device pci-bridge,bus=pcie.0,chassis_nr=1
-device intel-iommu,intremap=on,device-iotlb=on
-device virtio-serial-pci
-device virtio-scsi-pci
-device virtio-rng-pci
-device vhost-vsock-pci
-device vhost-user-fs-pci
-device virtio-net-pci
-numa node,memdev=dimm1

# microvm (prototype)
-machine microvm,accel=kvm
-device virtio-serial-device
-device virtio-scsi-device
-device virtio-rng-device
-device vhost-vsock-device
-device vhost-user-fs-device
-device virtio-net-device
# No PCI bridges, no IOMMU, no NUMA, no legacy devices
```

Eliminated in microvm:
- PCI bridge and PCI topology
- intel-iommu device emulation
- NUMA memory topology
- USB controllers, serial ports, IDE, VGA, legacy PC devices
- All PCI configuration space handling

## How to reproduce

### 1. Build upstream QEMU with microvm

See [build/build-qemu-microvm.sh](build/build-qemu-microvm.sh). Run this in a privileged pod on the target node.

### 2. Install on node

```bash
# Copy binary to a location with qemu_exec_t SELinux label
cp qemu-system-x86_64 /usr/libexec/qemu-kvm-microvm
restorecon /usr/libexec/qemu-kvm-microvm

# Copy firmware files
mkdir -p /usr/share/qemu
cp bios-microvm.bin linuxboot_dma.bin /usr/share/qemu/
```

### 3. Configure Kata

Place the config drop-in at `/etc/kata-containers/config.d/20-microvm.toml`.
See [config/20-microvm.toml](config/20-microvm.toml).

### 4. Manual boot test (works)

```bash
/usr/libexec/qemu-kvm-microvm \
  -machine microvm,accel=kvm -cpu host -m 256 \
  -kernel /var/cache/kata-containers/vmlinuz.container \
  -initrd /var/cache/kata-containers/kata-containers-initrd.img \
  -append "console=ttyS0 agent.log=debug" \
  -serial file:/tmp/microvm-boot.log \
  -device vhost-vsock-device,guest-cid=12345 \
  -nodefaults -nographic -no-reboot -daemonize
```

Check `/tmp/microvm-boot.log` for:
```
"ttRPC server started" ... "address":"vsock://-1:1024"
```

### 5. Pod test (hits ACPI bug)

```bash
oc apply -f manifests/kata-microvm-test.yaml
# Will fail with: "timed out connecting to vsock"
```

## Next steps

1. **Report the ACPI bug** to QEMU upstream and/or RHEL kernel team. The second IOAPIC in microvm MADT is not handled by RHEL 5.14.
2. **Test with a newer kernel** (6.x) that may have better multi-IOAPIC support.
3. **Reduce device count in Kata shim**: remove virtio-scsi and virtio-rng for microvm to get to 4 devices. Then fix the ACPI issue for 4.
4. **Patch QEMU microvm** to default `ioapic2=off` or reduce `VIRTIO_NUM_TRANSPORTS`.
5. **Test with `pcie=on`**: microvm with PCI devices uses MSI-X instead of MMIO interrupts, which might avoid the IOAPIC issue entirely (needs ACPI fix first).

## Files in this repo

```
README.md                          # This file
build/build-qemu-microvm.sh        # Script to build upstream QEMU with microvm
config/20-microvm.toml              # Kata config drop-in for microvm
manifests/kata-microvm-test.yaml    # Test pod manifest
tests/test-manual-boot.sh           # Manual QEMU boot test (1 device, works)
tests/test-device-bisect.sh         # Device bisection test script
docs/problems-solved.md             # Chronological list of problems solved
docs/shim-command-comparison.md     # Q35 vs microvm command line comparison
```

## Date

2026-04-10

## Update: ACPI bug fixed in QEMU 10.x

Tested on a plain RHEL 9.4 Azure VM (kernel 5.14.0-427.61.1.el9_4.x86_64):

| QEMU version | 4 virtio-mmio devices | Result |
|-------------|----------------------|--------|
| 9.2.0 | Hangs at "ACPI: Core revision" | BUG |
| 10.2.2 | Boots, kernel runs normally | FIXED |

**The bug was in QEMU's microvm ACPI table generation, not the RHEL kernel.**

This means Kata with microvm machine type would work with QEMU 10.x without the pcie=on workaround. The qrun prototype uses pcie=on which works on both QEMU 9.x and 10.x.

Reproducer VM: RHEL 9.4 on Azure (Standard_D4s_v5, nested virt), resource group `jfreiman-qemu-repro`.
