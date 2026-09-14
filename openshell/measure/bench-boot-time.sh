#!/bin/bash
# Benchmark Kata VM cold start time with phase breakdown.
#
# Measures wall-clock pod startup time and extracts per-phase timestamps
# from the kata shim journal and guest /dev/kmsg (BENCH markers).
#
# Usage: ./bench-boot-time.sh [runs] [kubeconfig]
# Default: 10 runs

set -euo pipefail

RUNS="${1:-10}"
KUBECONFIG="${2:-${KUBECONFIG:-$HOME/kubeconfig.virtlab725}}"
NODE="virtlab725.virt.eng.rdu2.dc.redhat.com"
POD_NAME="bench-boot"
RESULTS_DIR="$(dirname "$0")/../results"
mkdir -p "$RESULTS_DIR"
OUTFILE="$RESULTS_DIR/boot-$(date +%Y%m%d-%H%M%S).csv"

export KUBECONFIG

echo "Kata VM cold start benchmark"
echo "Runs: $RUNS"
echo "Node: $NODE"
echo "Output: $OUTFILE"
echo ""

# CSV header
echo "run,wall_ms,shim_setup_ms,qemu_start_ms,kernel_boot_ms,init_mounts_ms,mod_virtio_console_ms,mod_virtiofs_ms,mod_vsock_ms,mod_virtio_net_ms,mod_ptp_kvm_ms,agent_exec_ms,agent_connect_ms" > "$OUTFILE"

for i in $(seq 1 "$RUNS"); do
    echo "--- Run $i/$RUNS ---"

    # Record wall clock start
    T_WALL_START=$(python3 -c "import time; print(int(time.time()*1000))")

    # Mark journal position
    SINCE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create pod
    oc apply -f - <<'PODSPEC' >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: bench-boot
spec:
  runtimeClassName: kata
  nodeName: virtlab725.virt.eng.rdu2.dc.redhat.com
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "300"]
    resources:
      requests:
        cpu: "100m"
        memory: "64Mi"
      limits:
        cpu: "1"
        memory: "256Mi"
PODSPEC

    # Wait for Running
    for attempt in $(seq 1 60); do
        STATUS=$(oc get pod "$POD_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        [ "$STATUS" = "Running" ] && break
        [ "$STATUS" = "Failed" ] && echo "FAILED" && break
        sleep 0.5
    done

    T_WALL_END=$(python3 -c "import time; print(int(time.time()*1000))")
    WALL_MS=$((T_WALL_END - T_WALL_START))

    if [ "$STATUS" != "Running" ]; then
        echo "  Pod did not reach Running (status=$STATUS), skipping"
        oc delete pod "$POD_NAME" --ignore-not-found --grace-period=0 --force >/dev/null 2>&1
        sleep 3
        continue
    fi

    echo "  Wall clock: ${WALL_MS}ms"

    # Extract sandbox ID from pod
    SANDBOX_ID=$(oc debug "node/$NODE" -- chroot /host bash -c "
        crictl pods --name $POD_NAME -o json 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin)['items'][0]['id'])\" 2>/dev/null
    " 2>/dev/null | grep -v "^Starting\|^Removing\|^To use" | tr -d '[:space:]')

    # Extract shim journal timestamps
    SHIM_DATA=$(oc debug "node/$NODE" -- chroot /host bash -c "
        journalctl -t kata --since '$SINCE' --no-pager 2>/dev/null | grep '$SANDBOX_ID' | grep -E 'loaded configuration|Starting VM|launching.*qemu-kvm|QMP details|VM started|New client|BENCH'
    " 2>/dev/null | grep -v "^Starting\|^Removing\|^To use")

    # Parse timestamps (format: Sep 08 HH:MM:SS.NNNNNNNNN ... time="2026-09-08T13:00:00.123456789Z")
    parse_ts() {
        echo "$SHIM_DATA" | grep "$1" | head -1 | grep -oP 'time="\K[^"]+' | head -1
    }

    TS_CONFIG=$(parse_ts "loaded configuration")
    TS_VM_START=$(parse_ts "Starting VM")
    TS_QEMU_LAUNCH=$(parse_ts "launching.*qemu")
    TS_QMP=$(parse_ts "QMP details")
    TS_VM_STARTED=$(parse_ts "VM started")
    TS_AGENT=$(parse_ts "New client")

    # Parse BENCH markers from guest (in shim journal as console output)
    parse_bench() {
        echo "$SHIM_DATA" | grep "BENCH.*$1" | head -1 | grep -oP 'BENCH \K[0-9.]+' | head -1
    }

    B_INIT=$(parse_bench "init-start")
    B_MOUNTS=$(parse_bench "mounts-done")
    B_MOD_CONSOLE=$(parse_bench "mod-virtio_console")
    B_MOD_VIRTIOFS=$(parse_bench "mod-virtiofs")
    B_MOD_VSOCK=$(parse_bench "mod-vsock")
    B_MOD_VIRTIO_NET=$(parse_bench "mod-virtio_net")
    B_MOD_PTP=$(parse_bench "mod-ptp_kvm")
    B_AGENT_EXEC=$(parse_bench "agent-exec")

    # Convert ISO timestamps to epoch ms
    to_ms() {
        [ -z "$1" ] && echo "" && return
        python3 -c "
from datetime import datetime, timezone
ts = '$1'.replace('Z', '+00:00')
dt = datetime.fromisoformat(ts)
print(int(dt.timestamp() * 1000))
" 2>/dev/null
    }

    # Convert uptime seconds to ms delta
    uptime_delta_ms() {
        [ -z "$1" ] || [ -z "$2" ] && echo "" && return
        python3 -c "print(int(($2 - $1) * 1000))" 2>/dev/null
    }

    MS_CONFIG=$(to_ms "$TS_CONFIG")
    MS_VM_START=$(to_ms "$TS_VM_START")
    MS_QEMU_LAUNCH=$(to_ms "$TS_QEMU_LAUNCH")
    MS_QMP=$(to_ms "$TS_QMP")
    MS_VM_STARTED=$(to_ms "$TS_VM_STARTED")
    MS_AGENT=$(to_ms "$TS_AGENT")

    # Compute deltas
    shim_setup=""
    [ -n "$MS_CONFIG" ] && [ -n "$MS_VM_START" ] && shim_setup=$((MS_VM_START - MS_CONFIG))
    qemu_start=""
    [ -n "$MS_QEMU_LAUNCH" ] && [ -n "$MS_QMP" ] && qemu_start=$((MS_QMP - MS_QEMU_LAUNCH))

    # Guest-side deltas (uptime based, ms)
    kernel_boot=""
    [ -n "$B_INIT" ] && kernel_boot=$(python3 -c "print(int($B_INIT * 1000))" 2>/dev/null)
    init_mounts=""
    [ -n "$B_INIT" ] && [ -n "$B_MOUNTS" ] && init_mounts=$(uptime_delta_ms "$B_INIT" "$B_MOUNTS")
    mod_console=""
    [ -n "$B_MOUNTS" ] && [ -n "$B_MOD_CONSOLE" ] && mod_console=$(uptime_delta_ms "$B_MOUNTS" "$B_MOD_CONSOLE")
    mod_virtiofs=""
    [ -n "$B_MOD_CONSOLE" ] && [ -n "$B_MOD_VIRTIOFS" ] && mod_virtiofs=$(uptime_delta_ms "$B_MOD_CONSOLE" "$B_MOD_VIRTIOFS")
    mod_vsock=""
    [ -n "$B_MOD_VIRTIOFS" ] && [ -n "$B_MOD_VSOCK" ] && mod_vsock=$(uptime_delta_ms "$B_MOD_VIRTIOFS" "$B_MOD_VSOCK")
    mod_virtio_net=""
    [ -n "$B_MOD_VSOCK" ] && [ -n "$B_MOD_VIRTIO_NET" ] && mod_virtio_net=$(uptime_delta_ms "$B_MOD_VSOCK" "$B_MOD_VIRTIO_NET")
    mod_ptp=""
    [ -n "$B_MOD_VIRTIO_NET" ] && [ -n "$B_MOD_PTP" ] && mod_ptp=$(uptime_delta_ms "$B_MOD_VIRTIO_NET" "$B_MOD_PTP")
    agent_exec=""
    [ -n "$B_MOD_PTP" ] && [ -n "$B_AGENT_EXEC" ] && agent_exec=$(uptime_delta_ms "$B_MOD_PTP" "$B_AGENT_EXEC")
    agent_connect=""
    [ -n "$MS_VM_STARTED" ] && [ -n "$MS_AGENT" ] && agent_connect=$((MS_AGENT - MS_VM_STARTED))

    echo "  Shim setup: ${shim_setup:-?}ms  QEMU start: ${qemu_start:-?}ms  Kernel: ${kernel_boot:-?}ms  Agent connect: ${agent_connect:-?}ms"

    # Write CSV row
    echo "$i,$WALL_MS,$shim_setup,$qemu_start,$kernel_boot,$init_mounts,$mod_console,$mod_virtiofs,$mod_vsock,$mod_virtio_net,$mod_ptp,$agent_exec,$agent_connect" >> "$OUTFILE"

    # Cleanup
    oc delete pod "$POD_NAME" --ignore-not-found --grace-period=0 --force >/dev/null 2>&1
    sleep 3
done

echo ""
echo "=== Results ==="
cat "$OUTFILE"
echo ""
echo "=== Summary ==="
python3 -c "
import csv, statistics
with open('$OUTFILE') as f:
    rows = list(csv.DictReader(f))
if not rows:
    print('No data')
    exit()
for col in rows[0].keys():
    if col == 'run':
        continue
    vals = [int(r[col]) for r in rows if r[col]]
    if vals:
        print(f'  {col:25s}  p50={statistics.median(vals):6.0f}ms  mean={statistics.mean(vals):6.0f}ms  min={min(vals):5d}ms  max={max(vals):5d}ms  n={len(vals)}')
"
