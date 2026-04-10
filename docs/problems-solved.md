# Problems solved during microvm PoC

Chronological list of problems encountered and fixed during the prototype.

## 1. QEMU binary not found / wrong binary

**Problem**: The QEMU microvm binary at `/usr/libexec/qemu-kvm-microvm` was a 147-byte wrapper script, not the actual binary. The real binary was at `/usr/libexec/qemu-kvm-microvm.real`.

**Fix**: Replaced the wrapper with the actual 77MB ELF binary and restored the SELinux label:
```bash
cp /usr/libexec/qemu-kvm-microvm.real /usr/libexec/qemu-kvm-microvm
restorecon /usr/libexec/qemu-kvm-microvm
```

## 2. SELinux permission denied

**Problem**: Binary at `/var/tmp` had `tmp_t` label. SELinux denied execution.

**Fix**: Copied to `/usr/libexec/` which gets `qemu_exec_t` label via `restorecon`.

## 3. vIOMMU not supported by microvm

**Problem**: Default Kata config has `enable_iommu=true`. microvm does not support intel-iommu device.

**Fix**: Config drop-in with:
```toml
enable_iommu = false
enable_iommu_platform = false
```

## 4. Firmware files not found

**Problem**: `qemu: could not load PC BIOS 'bios-microvm.bin'` and `Failed to open file "linuxboot_dma.bin"`.

The upstream QEMU binary looks for firmware in `/usr/share/qemu/` (resolved from its compiled-in path `/usr/libexec/../share/qemu`), not in `/usr/share/qemu-kvm/` where RHEL puts its firmware.

**Fix**: Copy firmware files to the correct location:
```bash
mkdir -p /usr/share/qemu
cp bios-microvm.bin linuxboot_dma.bin /usr/share/qemu/
```

## 5. Invalid config key `firmware_path`

**Problem**: `error applying key 'hypervisor.qemu.firmware_path'` -- the Kata config parser does not recognize `firmware_path` as a valid drop-in key.

**Fix**: Removed `firmware_path` from the config drop-in. Firmware discovery is handled by placing files in QEMU's expected path.

## 6. Rootless config conflict

**Problem**: A leftover `10-rootless.toml` config drop-in from earlier testing conflicted with microvm.

**Fix**: `rm /etc/kata-containers/config.d/10-rootless.toml`

## 7. ACPI hang with 4+ virtio-mmio devices (UNRESOLVED)

**Problem**: The RHEL 5.14 kernel hangs at `ACPI: Core revision 20221020` when QEMU microvm has 4 or more virtio-mmio devices. The Kata shim needs 6 devices.

**Root cause**: QEMU microvm auto-enables a second IOAPIC (`ioapic2`) when ACPI is on. The MADT describes two IOAPICs. The RHEL 5.14 kernel cannot handle this. See kata-containers#1983.

**Workarounds tried**:
- `ioapic2=off` -- still hangs
- `kernel_irqchip=split` -- still hangs
- `pcie=on` with PCI devices -- still hangs
- `acpi=off` + `auto-kernel-cmdline=on` -- kernel boots but LAPIC interrupts are masked, vsock times out

**Status**: Unresolved. Needs upstream fix in QEMU DSDT/MADT generation for microvm, or kernel fix for multi-IOAPIC MADT parsing.

## 8. Shim uses wrong transport for microvm (NOT a problem)

The Kata shim code already has microvm awareness. When `machine_type = "microvm"`:
- Uses MMIO transport (`virtio-*-device` instead of `virtio-*-pci`)
- No PCI bridges (returns nil from `bridges()`)
- No NUMA/DIMM support
- No memory hotplug
- No NVDIMM
- No iommu device

This all works correctly. The shim generates a valid microvm command line.
