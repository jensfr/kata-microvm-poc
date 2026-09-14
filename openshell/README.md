# OpenShell VM Density Optimization

Scripts, configs, and documentation for reducing Kata VM memory
footprint and cold start latency for OpenShell workloads on OSC.

## Quick start (works today, no rebuild needed)

Apply annotations to your SandboxTemplate to reduce per-VM memory
by ~46 MB. See `templates/sandbox-template-basic.yaml`.

## Full optimization (needs initrd rebuild)

Build the agent-init stripped initrd and create the kata-openshell
RuntimeClass. A controlled benchmark (10 alternating pairs, 2048 MB
guest RAM) measured a median Starting VM to Container is started
interval of 2540ms vs 5842ms for stock systemd.

Separately, agent-init combined with reduced guest RAM (256 MB) and
nr_cpus=1 measured 255 MB QEMU Private_Dirty vs 381 MB stock. These
are distinct measurements from the startup benchmark.

On an OpenShift node with OSC installed:

```bash
sudo ./osbuilder/build-openshell-initrd.sh
sudo cp config/kata-openshell.toml /etc/kata-containers/config.d/50-openshell.toml
sudo oc apply -f config/runtimeclass-kata-openshell.yaml
```

Then use `templates/sandbox-template-fast.yaml`.

## What's here

```
openshell/
  openshell-vm-density-findings.md   Full report with all measurements
  osbuilder/
    build-openshell-initrd.sh        Builds the agent-init stripped initrd
    15-dracut-openshell.conf         Stripped dracut module list
  config/
    kata-openshell.toml              Kata config drop-in for the RuntimeClass
    runtimeclass-kata-openshell.yaml RuntimeClass manifest
  templates/
    sandbox-template-basic.yaml      Annotation-only (works today)
    sandbox-template-fast.yaml       With agent-init RuntimeClass
  measure/
    measure-vm-memory.sh             Measure per-VM memory (smaps + meminfo)
    bench-boot-time.sh               Cold start benchmark with phase breakdown
  results/
    benchmark-combined-summary.txt   Combined benchmark results (20 runs)
    run-*-journal.txt                Raw shim journal per run
```

## Measured results (virtlab725, bare metal, OCP 4.21)

### Memory (idle pods, single measurements)

| Configuration | Per-VM (Private_Dirty) |
|---|---|
| Stock OSC | 381 MB |
| Annotations only (nr_cpus=4, mem=512) | 335 MB |
| Agent-init + stripped + 256 MB RAM | 255 MB |
| + Kata 6.18 kernel + virtio-blk root | 179 MB |

### Cold start (controlled benchmark, 2026-09-08, n=10 each)

| Interval | agent-init | systemd |
|---|---|---|
| Starting VM to Container is started | 2540ms median | 5842ms median |
| QEMU launch to VM started | 58ms | 58ms |

See `openshell-vm-density-findings.md` for the full test matrix,
methodology, and caveats.
