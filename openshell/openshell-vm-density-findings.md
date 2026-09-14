# OpenShell VM Density: What We Found


## Executive summary

A controlled benchmark (10 alternating pairs, identical kernel, QEMU,
RAM, and debug level) measured the combined effect of the agent-init
boot path and a stripped initrd:

| Interval (node clock) | agent-init | systemd | difference |
|---|---|---|---|
| Starting VM to Container is started | 2540ms median | 5842ms median | 3303ms (57%) |
| QEMU launch to VM started | 58ms median | 58ms median | none observed |

The observed QEMU launch-to-VM-started interval (~58ms) is similar in
both configurations and small relative to the total. Nearly the entire
difference falls in the interval after VM started. That interval has
not been decomposed further; it covers guest boot through container
creation.

The benchmark used the stock configuration (2048 MB guest RAM,
nr_cpus=64, enable_debug=true). The PoC initrd does not start
chronyd; the production version will.

Separately, single-run memory measurements show that agent-init
combined with reduced guest RAM and CPU count lowers QEMU
Private_Dirty from 381 MB (stock) to 255 MB (at 256 MB guest RAM,
nr_cpus=1). These are distinct measurements from the startup
benchmark; they were not tested together.

| Configuration | QEMU Private_Dirty | Guest RAM | nr_cpus | Measured |
|---|---|---|---|---|
| Stock | 381 MB | 2048 | 64 | single run |
| Agent-init + stripped initrd | 326 MB | 2048 | 64 | single run |
| + 512 MB RAM, nr_cpus=1 | 268 MB | 512 | 1 | single run |
| + 256 MB RAM | 255 MB | 256 | 1 | single run |

The path from 381 to 255 MB requires three changes: the agent-init
initrd (-55 MB), reduced guest RAM (-58 MB combined with nr_cpus),
and reduced nr_cpus. Each contributes; agent-init alone does not
reach 255 MB.

## Test environment and conditions

Cluster: virtlab725 (single-node OpenShift, bare metal)
- Hardware: Dell PowerEdge, 64-CPU Intel Xeon Gold 5218 @ 2.30GHz, 376 GB RAM
- Platform: OCP 4.21.11, RHCOS 9.6.20260414-0
- QEMU: qemu-kvm-core-9.1.0-15.el9_6.18.x86_64 (RHEL RPM, not custom)
- Kata: kata-containers-3.31.0-6.rhaos4.22.el9.x86_64 (scratch build with virtio_balloon)
- Guest kernel (stock): 5.14.0-570.107.1.el9_6.x86_64 (RHEL 9.6)
- Guest kernel (Kata upstream): vmlinuz-6.18.35-202 (from kata-static-4.1.0 release)
- Dates: 2026-09-01 through 2026-09-08

All memory measurements on idle pods running `sleep 3600` with
runtimeClassName `kata`. Each configuration tested by deploying a
pod, waiting for Ready, then measuring from the host (smaps) and
guest (meminfo). Cluster restored to stock config after each test.

The stock configuration.toml on this cluster matches the RPM default
(verified via `rpm -V kata-containers`). No modifications except the
config drop-ins applied and removed per test.


## Boot time benchmarking methodology

Two measurement methods were used in this investigation:

**Early measurements (2026-09-01 to 2026-09-04):** Boot time measured
with `TestRuntimeClassStartupComparison` from the agent-sandbox test
suite. This measures sandbox creation time. The exact event boundaries
were not documented for these runs. The 5.89s and 2.78s numbers in the
density table come from this method.

**Controlled benchmark (2026-09-08):** 20 runs (10 alternating pairs:
agent-init, systemd, agent-init, ...) with shim journal timestamps
parsed from the node. Comparison interval: Starting VM to Container
is started (from kata shim journalctl -t kata on the node). Both
configurations used identical conditions:

- Kernel: 5.14.0-570.107.1.el9_6.x86_64
- Guest RAM: 2048 MB (stock default)
- SMP: -smp 1,cores=1,threads=1,sockets=64,maxcpus=64
- Debug: enable_debug = true
- Image: registry.access.redhat.com/ubi9/ubi-minimal:latest
- nodeName set (scheduler bypassed)
- Regular pod delete + 5s sleep between runs

Initrd verification: SHA256 hashes recorded per run. Agent-init /init
content verified by extracting from the initrd (bash script, 5
modprobes, exec kata-agent, no chronyd). Stock /init verified as
symlink to usr/lib/systemd/systemd.

Wall-clock measurements (Mac client polling oc get pod) also recorded
but mix Mac and node clocks (skew not measured) and include
k8s/CRI-O/polling overhead. Wall-clock intervals are not subdivided.

Raw data: results/ directory in this repository.


## Cold start benchmark results

Starting VM to Container is started (node clock, 10 runs each):

| | agent-init | systemd |
|---|---|---|
| Median | 2540ms | 5842ms |
| Min | 2268ms | 5405ms |
| Max | 4667ms | 7737ms |
| All values | 2268, 2397, 2470, 2475, 2508, 2571, 2686, 2827, 3303, 4667 | 5405, 5447, 5541, 5695, 5732, 5953, 6097, 6467, 6887, 7737 |

Median difference: 3303ms.

QEMU launch to VM started (node clock, 10 runs each):

| | agent-init | systemd |
|---|---|---|
| Median | 58ms | 58ms |
| Range | 55-77ms | 55-81ms |

The observed QEMU launch-to-VM-started intervals are similar in both
configurations and small relative to the total interval. This does
not cover every contribution of QEMU to the boot path; it is one
logged interval.

The SV-to-Container interval has not been decomposed. It covers
guest boot through container creation. The measurement does not
isolate systemd runtime from other contributors to this interval.

The agent-init initrd used in this benchmark does not start chronyd.
The production version (RHBAS-46) will include chronyd; its startup
cost has not been measured. enable_debug was true for both; production
numbers may differ.

Default runtime baseline (wall clock, Mac polling, n=5, same pod
spec without runtimeClassName; actual CRI-O default runtime not
independently verified):

| | default runtime |
|---|---|
| Median | 3817ms |
| Min | 2765ms |
| Max | 5082ms |
| All values | 2765, 2825, 3817, 4218, 5082 |

Wall clock comparison (Mac polling, all three):

| Runtime | Median | Observed difference vs default |
|---|---|---|
| default | 3817ms | -- |
| kata agent-init | 5188ms | +1371ms |
| kata systemd | 8122ms | +4306ms |

The wall-clock total duration was measured on the Mac. Subdividing it
using node-side timestamps would mix two clocks; the wall-clock values
above are not subdivided. They include k8s, CRI-O, networking, and
runtime startup together.

The early measurements of 2.78s (agent-init) and 5.89s (systemd) used
a different method and measurement boundary. The controlled benchmark
results (2540ms and 5842ms medians) are not directly comparable to
those numbers. Both show a consistent reduction; the magnitude depends
on the measurement interval.


## All configurations tested

Each row is one test run on virtlab725. Cluster restored to stock
between tests. Memory measured after pod reached Ready + 10s settle.

| # | Kernel | Guest RAM | nr_cpus | Init | Initrd/Root | Private_Dirty | Boot time |
|---|--------|-----------|---------|------|-------------|---------------|-----------|
| 1 | RHEL 5.14 | 2048 MB | 64 | systemd | stock 33 MB gzip | 381 MB | 5.89s |
| 2 | RHEL 5.14 | 2048 MB | 1 | systemd | stock 33 MB gzip | 366 MB | -- |
| 3 | RHEL 5.14 | 2048 MB | 64 | agent-init bash | stock+stripped 51 MB cpio | 355 MB | -- |
| 4 | RHEL 5.14 | 512 MB | 1 | agent-init bash | stock+stripped 51 MB cpio | 301 MB | -- |
| 5 | Kata 6.18 | 2048 MB | 64 | systemd | stock 33 MB gzip | 317 MB | -- |
| 6 | Kata 6.18 | 2048 MB | 1 | systemd | stock 33 MB gzip | 296 MB | -- |
| 7 | Kata 6.18 | 2048 MB | 1 | systemd | stripped 29 MB gzip | 281 MB | -- |
| 8 | Kata 6.18 | 2048 MB | 1 | agent-init symlink | stripped 29 MB gzip | 276 MB | -- |
| 9 | Kata 6.18 | 2048 MB | 1 | agent-init symlink | virtio-blk ext4 95 MB | 209 MB | -- |
| 10 | Kata 6.18 | 256 MB | 1 | agent-init symlink | virtio-blk ext4 95 MB | 179 MB | -- |
| 11 | RHEL 5.14 | 2048 MB | 64 | agent-init bash | osbuilder stripped 23 MB gzip | 326 MB | 2.78s |
| 12 | RHEL 5.14 | 512 MB | 1 | agent-init bash | osbuilder stripped 23 MB gzip | 268 MB | -- |
| 13 | RHEL 5.14 | 256 MB | 1 | agent-init bash | osbuilder stripped 23 MB gzip | 255 MB | -- |
| 14 | RHEL 5.14 | 2048 MB | 64 | agent-init bash | osbuilder stripped 52 MB cpio | -- | 2.50s |
| A1 | RHEL 5.14 | 2048 MB | 64 | systemd | stock (annotation nr_cpus=4) | 369 MB | 5.11s |
| A2 | RHEL 5.14 | 512 MB | 4 | systemd | stock (annotations: nr_cpus=4, mem=512) | 335 MB | -- |

Notes:
- #1 is the true stock baseline (no guest_components_procs override).
  Earlier tests with that override showed 4.92s, not 5.89s.
- #3-4 used the kata-microvm-poc/agent-init build (manual cpio).
  Manual cpio rebuilds do not work with the Kata 6.18 kernel.
- #8 required cgroup_no_v1=all on the kernel cmdline (CONFIG_MEMCG_V1=n
  in the Kata 6.18 kernel).
- #9-10 used image= with disable_image_nvdimm=true, block_device_driver=virtio-blk.
  Only works with the Kata 6.18 kernel (VIRTIO_BLK=y built-in).
- #11-14 used the osbuilder pipeline with bash wrapper init + stripping.
  Works on the RHEL kernel.
- A1-A2 used pod annotations (no config changes on the node).
- Boot time measured via TestRuntimeClassStartupComparison. Entries marked
  "--" were not measured for boot time in this test series.
- Boot time at 10 runs (#14 uncompressed): median 2.91s, P10 2.36s, P90 3.31s.


## The question

How much memory does one idle Kata VM actually cost, and where does it go?


## How we measured

From the host, via `oc debug node/ -- chroot /host`:
- `/proc/<QEMU_PID>/smaps_rollup` for RSS, PSS, Private_Dirty
- Per-mapping breakdown via awk on `/proc/<QEMU_PID>/smaps`
- QEMU PID found by `pgrep -f "qemu-kvm.*$SANDBOX_ID"`

From inside the guest, via `oc exec <pod>`:
- `/proc/meminfo` for MemTotal, MemFree, Slab, Percpu, Shmem, Cached

We report QEMU Private_Dirty from smaps_rollup. RSS overcounts shared
library pages; PSS divides them by mapper count. Private_Dirty is a
closer proxy for the per-process memory cost but does not capture all
costs of running a VM (virtiofsd, shim, host kernel structures, file
caches). All memory figures in this report are QEMU Private_Dirty for
an idle sandbox unless stated otherwise.


## Stock configuration

The default Kata VM on OSC runs Q35 with 6 PCI devices, 2048 MB guest
RAM, nr_cpus=64, a systemd-based initrd (33 MB gzip, 79 MB in tmpfs),
and the RHEL 5.14 kernel (15 MB, ~4000 config options).

QEMU Private_Dirty: **381 MB**.

Guest meminfo shows about 198 MB used of 1928 MB MemTotal. The QEMU
smaps breakdown shows ~375 MB in the guest RAM mapping and ~6 MB in
QEMU's own allocations (code, heap, libraries). The 375 MB reflects
pages that were touched at any point during boot and remain resident
on the host. The difference between 375 MB host-resident and 198 MB
guest-used includes kernel boot-time allocations, page cache, and
pages the kernel touched and later freed (which remain host-resident
until the guest reports them via balloon or the VM exits).


## What we changed, one thing at a time

This table uses the Kata 6.18 kernel series (rows 5-10). Each row
changes one variable from the row above. The savings observed here
are specific to this kernel; they do not transfer directly to the
RHEL kernel series (rows 11-13 in the full table). All measured on
the same cluster with idle pods running `sleep 3600`.

| # | Change | QEMU Private_Dirty | Observed difference |
|---|--------|--------------|--------|
| 1 | Stock (RHEL 5.14 kernel) | 381 MB | -- |
| 5 | Kata upstream 6.18 kernel (9 MB, 1459 opts, monolithic) | 317 MB | -64 MB |
| 6 | Add nr_cpus=1 | 296 MB | -21 MB |
| 7 | Strip the initrd | 281 MB | -15 MB |
| 8 | Agent-init (kata-agent as PID 1) | 276 MB | -5 MB |
| 9 | virtio-blk ext4 root (no initrd) | 209 MB | -67 MB |
| 10 | Reduce guest RAM to 256 MB | 179 MB | -30 MB |

Row 1 to row 5 compares two different kernel versions and builds,
not just config option counts. The -64 MB cannot be attributed solely
to config options.

Row 9 eliminates the initrd from tmpfs. This requires a kernel with
CONFIG_VIRTIO_BLK=y (built-in). A modular kernel could achieve the
same result with a small bootstrap initramfs that loads virtio_blk
and ext4, then switches root to a block device. This path has not
been tested.


## The remaining 179 MB

Guest meminfo for configuration #10 (256 MB, virtio-blk, Kata 6.18,
agent-init, nr_cpus=1):

    MemTotal:   166 MB  (kernel reserved 90 MB of the 256 MB configured)
    MemFree:    116 MB
    Guest used:  50 MB  (agent + kernel runtime + page cache)
    Slab:        10 MB
    Cached:      27 MB  (files read from the ext4 root during boot)
    AnonPages:    3 MB
    Percpu:     0.2 MB
    Shmem:     0.02 MB

Host-resident guest RAM: 161 MB. This is a reconstruction from guest
meminfo and host smaps, not a direct decomposition. The difference
between configured RAM and MemTotal (90 MB) does not by itself prove
that amount is currently host-resident.


## What did not work (idle boot)

**Balloon free-page reporting.** virtio_balloon.ko was missing from the
initrd. We added it (Brew scratch build 71717690), confirmed the feature
negotiates and dmesg says "Free page reporting enabled." At idle boot,
only ~4 MB was reclaimable. Lazy allocation already handles untouched
pages; the balloon has little to reclaim when no workload has run.

For long-running sandboxes where workloads allocate and free memory,
free-page reporting should return freed pages to the host. This has
not been tested with an allocate/use/free cycle inside a running
sandbox. The expected behavior (host-resident memory decreasing after
guest free) needs measurement before it can be claimed.

virtio_balloon.ko is now available (Brew scratch build 71717690). To
enable: set reclaim_guest_freed_memory=true in the Kata config.

**VM templating with CoW.** Kata has a template factory that snapshots a
booted VM and restores clones from the same memory file. CoW sharing
requires MAP_PRIVATE. virtiofs uses MAP_SHARED (vhost-user needs direct
access to guest RAM). These are mutually exclusive per QEMU docs. Kata
issue #4766 reports templating consumed more memory, not less.

**KSM.** The kernel's same-page merger rejects VM_SHARED mappings
(mm/ksm.c line 740). Since the current virtiofs configuration uses
share=on, KSM cannot merge Kata guest RAM pages.

These three mechanisms (free-page reporting, CoW templating, KSM)
are affected by the virtiofs share=on requirement, but each has a
different constraint and should be evaluated separately. Free-page
reporting is limited by available reclaimable pages, not blocked by
share=on. CoW and KSM are blocked by the MAP_SHARED mapping.


## Why virtiofs is hard to remove

virtiofs shares the container rootfs from the host into the guest. CRI-O
on the host pulls the container image, unpacks it to a directory, and
virtiofsd shares that directory into the guest.

Without virtiofs, the container rootfs must reach the guest another way.
Kata+Firecracker solves this with the containerd devmapper snapshotter,
which stores image layers as block devices. The shim passes them as
virtio-blk. But CRI-O does not have a devmapper snapshotter. OpenShift
uses CRI-O.

We tested shared_fs="none" on the cluster. The VM boots, the agent
connects, but container creation fails: the shared rootfs directory
does not exist inside the guest (ENOENT).

Options:
- Guest-pull (image-rs/nydus): agent pulls the image inside the guest.
  The CoCo stack uses this path. The next step is reproducing it in
  the current OpenShell configuration and integrating it into the
  deployment path.
- tardev-snapshotter: Kata-specific, produces block devices from tar
  layers. Needs CRI-O integration.
- EROFS snapshotter with virtio-blk: upstream WIP (Kata issue #11163).

Eliminating virtiofs would save ~7 MB per pod (virtiofsd process) and
change the guest memory mapping from MAP_SHARED to MAP_PRIVATE,
which is a prerequisite for CoW templating and KSM.


## Firecracker comparison

Firecracker standalone (no Kata, custom tiny init): ~75 MB total for
a 128 MB guest. This is not a functionally equivalent comparison.
Firecracker standalone provides no container lifecycle, no OCI, no
Kubernetes integration.

Kata+Firecracker has not been measured in this investigation. It
would use the same kata-agent and guest stack with a different VMM.
The QEMU smaps breakdown shows ~6 MB in QEMU's own allocations
(outside the guest RAM mapping); the Firecracker equivalent has not
been measured. A functionally equivalent comparison would require
the same guest configuration, workload, and measurement method.


## Bugs found

**virtio_balloon.ko missing from kata initrd.** The dracut config
(15-dracut.conf) did not include virtio_balloon. Silently breaks
reclaim_guest_freed_memory. Fixed in Brew scratch build 71717690.

**Agent-init crash on Kata 6.18 kernel.** The kernel has
CONFIG_MEMCG_V1=n (cgroup v1 memory controller removed in 6.x). Without
cgroup_no_v1=all on the kernel cmdline, kata-agent reads /proc/cgroups,
finds the memory controller, tries to mount cgroup v1, fails. PID 1
dies. Kernel panics. QEMU exits (--no-reboot). Fix: add cgroup_no_v1=all
to kernel_params. Required for any kernel where CONFIG_MEMCG_V1 is
disabled.

**Kata upstream kernel boot regression.** The Kata 6.18 kernel works
with the stock systemd initrd but not with agent-init unless
cgroup_no_v1=all is present. The RHEL 5.14 kernel has cgroup v1 support
so agent-init works without the extra param.


## What works on the RHEL kernel (and what doesn't)

The product ships the RHEL 5.14 kernel. Measured on the RHEL kernel
(from the full test matrix, single runs):

| # | Change from stock | QEMU Private_Dirty | Observed difference |
|---|---|---|---|
| 1 | Stock (2048 MB, nr_cpus=64, systemd) | 381 MB | -- |
| 11 | Agent-init + stripped initrd | 326 MB | -55 MB |
| 12 | + 512 MB guest RAM, nr_cpus=1 | 268 MB | -58 MB |
| 13 | + 256 MB guest RAM | 255 MB | -13 MB |

Agent-init and initrd stripping were applied together (row 11); their
individual contributions on the RHEL kernel have not been separated.
The -5 MB and -8 MB figures in earlier versions of this report came
from the Kata 6.18 kernel series and are not transferable.

Still blocked on the RHEL kernel:

| Optimization | Why it's blocked | Possible path |
|---|---|---|
| virtio-blk root (no initrd in tmpfs) | CONFIG_VIRTIO_BLK=m. Kernel can't mount /dev/vda without loading the module first. | A small bootstrap initramfs could load virtio_blk and ext4, then switch_root to a block device. This is a standard initramfs use case but has not been tested. |
| Fewer kernel config options | RHEL ships one kernel for all use cases (~4000 options). | A separate kernel-kata package with a stripped config. The RHEL automotive kernel demonstrates this build model. |

Measured on RHEL kernel: **255 MB** QEMU Private_Dirty (at 256 MB
guest RAM, nr_cpus=1, agent-init).
Measured on Kata 6.18 kernel: **179 MB** (at 256 MB, with virtio-blk
root, different kernel version and build).


## Per-CPU overhead and nr_cpus tuning

The stock config sets nr_cpus=64 (the host's CPU count). The kernel
allocates per-CPU data structures for all 64, costing 19 MB. Most
OpenShell workloads need 1-4 vCPUs.

| nr_cpus | Percpu overhead | Saving vs 64 |
|---|---|---|
| 1 | 0.3 MB | 18.7 MB |
| 4 | 1.2 MB | 17.8 MB |
| 8 | 2.4 MB | 16.6 MB |
| 16 | 4.8 MB | 14.2 MB |

Users can tune nr_cpus per sandbox via a Kata annotation. The last
nr_cpus= on the kernel cmdline wins, so the annotation overrides the
base config's nr_cpus=64. Verified on virtlab725: the annotation
produces the correct /sys/devices/system/cpu/possible range and the
correct Percpu allocation.

No Kata code change needed. Works today.


## Balloon free-page reporting

Does not help idle VMs at boot. Lazy allocation already ensures
untouched guest pages are never allocated on the host. We measured
only 4 MB reclaimable at boot.

May help long-running sandboxes where workloads allocate and free
memory. Without free-page reporting, pages touched by a workload
remain host-resident after the guest frees them. With it, the guest
can report freed pages to QEMU for return to the host. This has not
been tested with an actual allocate/use/free workload cycle.

virtio_balloon.ko was missing from the initrd. Fixed in Brew scratch
build 71717690. To enable: set reclaim_guest_freed_memory=true in the
Kata config. The default reporting order is 9 (2 MB minimum block);
lowering page_reporting_order to 0 inside the guest reports all free
pages. On the Kata 6.18 monolithic kernel, virtio_balloon is built-in.


## Recommended SandboxTemplate for OpenShell

This template works today on stock OSC with the kata runtime class.
No initrd changes, no kernel changes, no new RuntimeClass. The
nr_cpus=4 annotation is verified on virtlab725 (Percpu: 19 MB to
1.2 MB). The default_memory=512 annotation was also verified (struct
page array: 32 MB to 8 MB). Combined measurement (both annotations):
335 MB QEMU Private_Dirty vs 381 MB stock.

Note: the template below shows only nr_cpus=4. To also reduce guest
RAM, add the default_memory annotation. The 512 MB setting has been
verified with `sleep 3600` but not with representative OpenShell
workloads. Guest RAM sizing, initial allocation, hotplug behavior,
and Kubernetes resource limits need further investigation.

```yaml
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxTemplate
metadata:
  name: openshell
  namespace: openshell
spec:
  podTemplate:
    metadata:
      annotations:
        io.katacontainers.config.hypervisor.kernel_params: "nr_cpus=4"
        io.katacontainers.config.hypervisor.default_memory: "512"
    spec:
      runtimeClassName: kata
      containers:
      - name: supervisor
        image: <openshell-supervisor-image>
        resources:
          requests:
            cpu: "2"
            memory: "256Mi"
```

With the agent-init initrd (requires the osbuilder patch and a new
kata-openshell RuntimeClass):

```yaml
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxTemplate
metadata:
  name: openshell-fast
  namespace: openshell
spec:
  podTemplate:
    metadata:
      annotations:
        io.katacontainers.config.hypervisor.kernel_params: "nr_cpus=4"
    spec:
      runtimeClassName: kata-openshell
      containers:
      - name: supervisor
        image: <openshell-supervisor-image>
        resources:
          requests:
            cpu: "2"
            memory: "256Mi"
```

The first template with both annotations measured 335 MB QEMU
Private_Dirty (single run, idle workload). The second template uses
the agent-init initrd; its memory and startup characteristics depend
on the guest RAM and nr_cpus settings configured in the RuntimeClass.
The controlled startup benchmark (2540ms median) used 2048 MB and
nr_cpus=64.


## Action recommendations

Ordered by impact relative to effort.

**1. Ship the agent-init initrd (kata-openshell).** Three stories
filed under RHBAS-11: RHBAS-46 (osbuilder patch), RHBAS-47
(RuntimeClass), RHBAS-48 (validation). The controlled benchmark
shows a median reduction of 3.3 seconds in the Starting VM to
Container is started interval. Memory drops from 381 MB to ~255 MB.
This is the biggest win available on the current RHEL kernel.

The production initrd must include chronyd (not present in the PoC
benchmark). chronyd's startup cost has not been measured and should
be included in the Story 3 validation.

**2. Set default_memory to 512 MB for kata-openshell.** Saves ~24 MB
from smaller struct page array (32 MB at 2048 vs 8 MB at 512). Most
OpenShell workloads fit in 512 MB. Document 256 MB as possible but
tight.

**3. Document nr_cpus annotation for users.** Works today, no code
change. Include in the OpenShell deployment guide and SandboxTemplate
examples.

**4. Test virtio-blk root with a bootstrap initramfs.** The RHEL
kernel has CONFIG_VIRTIO_BLK=m. A small initramfs that loads
virtio_blk and ext4, mounts a block device, and calls switch_root
could eliminate the full initrd from tmpfs without changing the
kernel. This is a standard initramfs use case. The potential saving
(removing ~50-70 MB of Shmem) has not been measured on the RHEL
kernel. This should be tested before investing in a new kernel
package.

**5. Investigate a Kata-specific RHEL kernel config.** The Kata 6.18
kernel measured 317 MB vs 381 MB stock (RHEL 5.14), but this
comparison also changes kernel version and build. A controlled
comparison (same version, different config) has not been done. The
RHEL automotive kernel demonstrates the build model: same source
tree, different config, separate package. Repo:
https://gitlab.com/CentOS/automotive/rpms/kernel-automotive.git

## Kernel config comparison

Four kernel configs compared. The key difference: whether virtio
drivers are built-in (=y) or loadable modules (=m). Built-in virtio_blk
unlocks the virtio-blk root optimization (no initrd in tmpfs, -67 MB).

| | RHEL 9.6 | RHEL automotive | Kata upstream | libkrunfw |
|---|---|---|---|---|
| Source | kernel RPM | gitlab.com/CentOS/automotive/rpms/kernel-automotive | kata-static-4.1.0 tarball | github.com/containers/libkrunfw |
| Base kernel | 5.14 | 6.12 | 6.18 | 6.12 |
| Enabled options | 3581 | 2769 | 1373 | 1051 |
| VIRTIO_BLK | m | **y** | **y** | **y** |
| EXT4_FS | m | **y** | **y** | **y** |
| VIRTIO_PCI | y | y | y | not set |
| VIRTIO_MMIO | not set | not set | not set | y |
| VIRTIO_FS | m | m | y | y |
| VIRTIO_NET | m | m | y | y |
| VSOCK | y | y | y | not set |
| MODULES | y | y | not set | not set |
| NR_CPUS | 8192 | 8192 | 240 | 16 |
| PREEMPT_RT | no | yes | no | no |
| KVM | m | m | not set | not set |
| Binary size | 15 MB | ~16 MB | 9 MB | ~5 MB |

The RHEL automotive kernel (RHIVOS/AutoSD) is the closest to what
Kata needs on a RHEL-supported base. It has VIRTIO_BLK=y and
EXT4_FS=y, enabling virtio-blk root without an initrd. It drops
1307 options vs standard RHEL (sound, USB, sensors, HID, NLS,
SCSI) but adds 495 for automotive (DVB, video capture, IR). The
PREEMPT_RT is unnecessary for Kata; its effect on Kata has not been
tested beyond the manual boot described below.

We tested the automotive kernel (6.12.0-264.el10iv from CentOS CBS
build 78070) on 2026-09-04/06. In manual QEMU tests (serial console,
minimal device set), the kernel boots with virtio-blk root (ext4 on
/dev/vda1, no initrd) and starts kata-agent as PID 1. Agent init
succeeds: mounts filesystems, loads vsock/virtiofs/virtio-net modules
from zstd-compressed .ko files, announces on vsock.

The full Kata runtime integration has not been completed. When the
shim launches QEMU with the complete device set, QEMU exits within
~1.7 seconds. The cause has not been determined; a QEMU exit does
not by itself prove a guest kernel panic. The automotive kernel lacks
CONFIG_BLK_DEV_PMEM, requiring disable_image_nvdimm=true. Further
debugging is needed.

Status: manual boot path works, Kata integration incomplete.

The libkrunfw kernel uses MMIO transport (not PCI), has no vsock,
and has no module support. Not compatible with the Kata architecture
without changes.

A purpose-built kernel-kata would need to balance config option count
against RHEL supportability requirements. The feasibility and
actual savings have not been estimated beyond the Kata 6.18 vs RHEL
5.14 comparison above, which also differs in kernel version.


**5. Eliminate virtiofs via guest-pull.** Needs image-rs decoupled
from CoCo attestation. Saves ~7 MB (virtiofsd) and removes the
share=on constraint on guest memory. Without share=on, balloon
free-page reporting works more effectively and VM templating with
CoW becomes possible. KSM is compiled into the RHEL kernel but
disabled by default on RHCOS and has side-channel concerns
(CVE-2021-3714). Biggest architectural change.
