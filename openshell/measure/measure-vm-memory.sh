#!/bin/bash
# Measure per-VM memory cost for a running Kata pod.
# Run from a machine with oc access to the cluster.
#
# Usage: ./measure-vm-memory.sh <pod-name> [kubeconfig]

set -euo pipefail

POD="${1:?Usage: $0 <pod-name> [kubeconfig]}"
KUBECONFIG="${2:-${KUBECONFIG:-$HOME/.kube/config}}"
NODE=$(KUBECONFIG="$KUBECONFIG" oc get pod "$POD" -o jsonpath='{.spec.nodeName}')

echo "Pod: $POD"
echo "Node: $NODE"
echo ""

# Host-side measurement
KUBECONFIG="$KUBECONFIG" oc debug "node/$NODE" -- chroot /host bash -c "
SANDBOX=\$(crictl pods --name $POD -o json 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin)['items'][0]['id'])\" 2>/dev/null)

echo '=== Per-process memory ==='
for PID in \$(pgrep -f \"\$SANDBOX\"); do
  CMD=\$(cat /proc/\$PID/comm 2>/dev/null)
  RSS=\$(awk '/^Rss:/{sum+=\$2} END{print sum}' /proc/\$PID/smaps 2>/dev/null)
  PSS=\$(awk '/^Pss:/{sum+=\$2} END{print sum}' /proc/\$PID/smaps 2>/dev/null)
  PD=\$(awk '/^Private_Dirty:/{sum+=\$2} END{print sum}' /proc/\$PID/smaps 2>/dev/null)
  echo \"PID=\$PID CMD=\$CMD RSS=\${RSS}kB PSS=\${PSS}kB Private_Dirty=\${PD}kB\"
done

echo ''
echo '=== QEMU memory breakdown ==='
QEMU_PID=\$(pgrep -f \"qemu-kvm.*\$SANDBOX\" | head -1)
awk '/^[0-9a-f]/{region=\$0} /^Rss:/{rss=\$2; if(rss>0) print rss\" kB  \"region}' /proc/\$QEMU_PID/smaps | sort -rn | head -10

echo ''
echo '=== QEMU smaps_rollup ==='
cat /proc/\$QEMU_PID/smaps_rollup
" 2>&1 | grep -v "^Starting\|^Removing\|^To use"

echo ""
echo "=== Guest meminfo ==="
KUBECONFIG="$KUBECONFIG" oc exec "$POD" -- cat /proc/meminfo 2>/dev/null | \
  grep -E "MemTotal|MemFree|Cached|Slab|PageTables|KernelStack|Percpu|AnonPages|Shmem|VmallocUsed"
