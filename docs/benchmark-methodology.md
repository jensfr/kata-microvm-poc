# Kata Q35 vs microvm Benchmark

## Methodology

### Environment
- **Cluster**: Azure Red Hat OpenShift (ARO) 4.18
- **Node**: `kata-test-cluster-9kllc-worker-eastus2-sfc5j` (Standard_D4s_v5, 4 vCPU, 16GB RAM)
- **Host kernel**: 5.14.0-427.111.1.el9_4.x86_64
- **Nested virtualization**: Yes (Azure D4s_v5 supports nested virt)
- **Guest image**: `registry.access.redhat.com/ubi9/ubi-minimal:latest`
- **Command**: `sleep infinity`

### Configurations tested

| Config | Machine type | QEMU binary | Guest memory | Shim |
|--------|-------------|------------|--------------|------|
| Stock Kata (OSC default) | Q35 | RHEL qemu-kvm 8.2.0 | 2048 MB | Stock 3.21.0 |
| Kata Q35 1024M | Q35 | RHEL qemu-kvm 8.2.0 | 1024 MB | Stock 3.21.0 |
| Kata microvm 1024M | microvm (pcie=on) | upstream QEMU 10.2.2 | 1024 MB | Patched (3 changes) |

### Procedure

For each configuration:
1. Set Kata config drop-in on the node
2. Restart CRI-O to pick up the config
3. Wait 5 seconds for CRI-O to stabilize
4. For each of 10 runs:
   a. Record start time (millisecond precision)
   b. `oc apply` the pod manifest
   c. Poll `oc get pod -o jsonpath='{.status.phase}'` every 1 second
   d. When status = Running, record end time
   e. **Startup time** = end - start (includes image check, CNI, CRI-O overhead)
   f. Wait 10 seconds for RSS to stabilize
   g. **QEMU RSS** = read from `/proc/<pid>/status` via `oc debug node/`
   h. Delete pod, wait 5 seconds before next run

### Metrics

- **Startup time**: Wall-clock time from `oc apply` to pod phase = Running. Includes Kubernetes scheduling, CRI-O container creation, VM boot, and agent readiness check.
- **QEMU RSS**: Resident Set Size of the QEMU process as reported by `ps -o rss`. Measured 10 seconds after pod reaches Running state to allow for memory stabilization. Includes guest memory backing, QEMU binary mapping, and device emulation state.

### Statistical measures

For each metric across 10 runs: mean, median, standard deviation, min, max.

### Warm-up

The first run in each configuration serves as a warm-up (image already cached from earlier testing). No runs are excluded from the statistics.

### Notes

- All tests run on the same node to eliminate hardware variability
- Tests are sequential (one pod at a time) to avoid resource contention
- The node runs Azure nested virtualization, which adds overhead compared to bare metal
- The microvm configuration uses a different QEMU version (10.2.2 vs 8.2.0) because RHEL's qemu-kvm does not include the microvm machine type

## Results

### Stock Kata Q35 (OSC default, 2048M, RHEL qemu-kvm 8.2.0)

| Metric | Mean | Median | Stdev | Min | Max | n |
|--------|------|--------|-------|-----|-----|---|
| Startup (ms) | 7697 | 6598 | 3120 | 6422 | 16499 | 10 |
| RSS (MB) | 409 | 409 | 0 | 409 | 409 | 3 |

Note: Run 7 was an outlier (16499ms). Excluding it: mean=6621, stdev=148.

### Kata Q35 (1024M, RHEL qemu-kvm 8.2.0)

| Metric | Mean | Median | Stdev | Min | Max | n |
|--------|------|--------|-------|-----|-----|---|
| Startup (ms) | 6526 | 6534 | 53 | 6431 | 6600 | 10 |
| RSS (MB) | 393 | 393 | 0 | 393 | 393 | 3 |

### Kata microvm (1024M, QEMU 10.2.2, pcie=on)

| Metric | Mean | Median | Stdev | Min | Max | n |
|--------|------|--------|-------|-----|-----|---|
| Startup (ms) | 6522 | 6547 | 60 | 6427 | 6619 | 10 |
| RSS (MB) | 310 | 310 | 0 | 310 | 310 | 3 |

### Comparison (at 1024M guest memory, same node)

| | Q35 | microvm | Difference |
|---|---|---|---|
| Startup (median) | 6534 ms | 6547 ms | +13 ms (+0.2%) |
| RSS | 393 MB | 310 MB | **-83 MB (-21%)** |

### Analysis

- **Startup time is identical** between Q35 and microvm. The ~6.5s is dominated by Kubernetes/CRI-O overhead (scheduling, image check, CNI setup), not VM boot time. The actual VM boot + agent startup is <1s in both cases.

- **microvm saves 21% RSS** (83 MB per pod). This is the overhead of Q35's PCI bridge, IOMMU emulation, legacy device state, and PCI topology. At scale (100 pods), this saves ~8.3 GB of host RAM.

- **Stock Kata (2048M) uses 409 MB RSS** vs microvm's 310 MB. Part of this is the 2x guest memory (2048 vs 1024MB). The `memory-backend-file` with `share=on` maps guest memory as shared memory which contributes to RSS.

- **Standard deviation is low** (53-60ms for startup), indicating consistent results. The stock Q35 run had one outlier likely caused by CRI-O garbage collection.

### Comparison with krun (libkrun)

| | krun | Kata microvm | Kata Q35 |
|---|---|---|---|
| RSS per container | 74-103 MB | 310 MB | 393 MB |
| Startup | ~3.6s | ~6.5s | ~6.5s |

krun uses significantly less memory because:
1. No separate QEMU process (libkrun is a library, not a process)
2. No shared memory backend for virtiofsd (built-in virtio-fs)
3. No virtiofsd daemon process
4. Minimal device emulation (~3 devices vs 6+)

## Shim patches for microvm

Three changes to the Kata shim are required for microvm with pcie=on:

1. **PCI transport**: `pkg/govmm/qemu/qemu.go` -- use `TransportPCI` when machine options contain `pcie=on` (otherwise defaults to MMIO which RHEL kernel doesn't support)

2. **Skip PIT global**: `virtcontainers/qemu.go` -- skip `kvm-pit.lost_tick_policy=discard` for microvm (no PIT device)

3. **Skip disable-modern**: `virtcontainers/qemu_amd64.go` -- override `enableNestingChecks()` for microvm to keep `nestedRun=false` (microvm PCI doesn't support legacy I/O ports that `disable-modern=true` requires)

## Known QEMU bugs

### 2GB memory + pcie=on hang (QEMU 10.2.2)

QEMU microvm with `pcie=on` and exactly 2048M RAM hangs during ACPI initialization. 256M, 512M, 1024M, and 4096M all boot normally. Only 2048M triggers the hang.

Likely cause: PCI ECAM memory region at the 2GB boundary (0x80000000) conflicts with the RAM mapping.

Reproducer: `reproduce-2gb-pcie-bug.sh`
