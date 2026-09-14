#!/bin/bash
# Build the agent-init stripped initrd for OpenShell.
#
# Run on an OpenShift node with OSC installed:
#   ./build-openshell-initrd.sh
#
# Produces: kata-openshell.initrd alongside the stock kata.initrd.
# The stock initrd is not modified.

set -euo pipefail

KVER="${1:-$(uname -r)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OSBUILDER_DIR="/usr/libexec/kata-containers/osbuilder"
IMAGE_DIR="/var/cache/kata-containers/osbuilder-images/${KVER}"
OUT="${IMAGE_DIR}/kata-openshell.initrd"

echo "Building OpenShell agent-init initrd for kernel ${KVER}"

# Step 1: Install the stripped dracut config
cp "${SCRIPT_DIR}/15-dracut-openshell.conf" \
   "${OSBUILDER_DIR}/dracut/dracut.conf.d/15-dracut.conf"

# Step 2: Patch kata-osbuilder.sh to use agent-init + strip
OSBUILDER="${OSBUILDER_DIR}/kata-osbuilder.sh"
BACKUP="${OSBUILDER}.bak"
cp "${OSBUILDER}" "${BACKUP}"

sed -i "/Calling osbuilder initrd_builder.sh/a\\
    # Agent-init: bash wrapper that loads modules then execs kata-agent\\
    rm -f \${DRACUT_ROOTFS}/init\\
    cat > \${DRACUT_ROOTFS}/init << \"AGENTINIT\"\\
#!/bin/bash\\
export PATH=/sbin:/bin:/usr/sbin:/usr/bin\\
mount -t proc proc /proc 2>/dev/null\\
mount -t sysfs sysfs /sys 2>/dev/null\\
mount -t devtmpfs devtmpfs /dev 2>/dev/null\\
mkdir -p /dev/pts /dev/shm /tmp /run\\
mount -t devpts devpts /dev/pts 2>/dev/null\\
mount -t tmpfs tmpfs /tmp 2>/dev/null\\
mount -t tmpfs tmpfs /run 2>/dev/null\\
modprobe virtio_console 2>/dev/null\\
modprobe virtiofs 2>/dev/null\\
modprobe vmw_vsock_virtio_transport 2>/dev/null\\
modprobe virtio_net 2>/dev/null\\
modprobe ptp_kvm 2>/dev/null\\
/usr/sbin/chronyd 2>/dev/null &\\
exec /usr/bin/kata-agent\\
AGENTINIT\\
    chmod +x \${DRACUT_ROOTFS}/init\\
    # Strip packages not needed without systemd\\
    rm -rf \${DRACUT_ROOTFS}/usr/lib/systemd \${DRACUT_ROOTFS}/usr/lib64/systemd\\
    rm -rf \${DRACUT_ROOTFS}/usr/share \${DRACUT_ROOTFS}/usr/libexec/vi\\
    rm -rf \${DRACUT_ROOTFS}/usr/bin/strace \${DRACUT_ROOTFS}/usr/bin/systemctl \${DRACUT_ROOTFS}/usr/bin/journalctl\\
    rm -rf \${DRACUT_ROOTFS}/usr/bin/dbus-* \${DRACUT_ROOTFS}/usr/bin/busctl \${DRACUT_ROOTFS}/usr/bin/dracut*\\
    rm -rf \${DRACUT_ROOTFS}/usr/lib64/libgnutls* \${DRACUT_ROOTFS}/usr/lib64/libgio-* \${DRACUT_ROOTFS}/usr/lib64/libglib-*\\
    rm -rf \${DRACUT_ROOTFS}/usr/lib64/libgobject-* \${DRACUT_ROOTFS}/usr/lib64/libgmodule-*\\
    rm -rf \${DRACUT_ROOTFS}/usr/lib64/libp11-kit* \${DRACUT_ROOTFS}/usr/lib64/libunistring* \${DRACUT_ROOTFS}/usr/lib64/libidn2*\\
    rm -rf \${DRACUT_ROOTFS}/usr/lib64/libtasn1* \${DRACUT_ROOTFS}/usr/lib64/libnettle* \${DRACUT_ROOTFS}/usr/lib64/libhogweed*\\
    rm -rf \${DRACUT_ROOTFS}/usr/lib64/libffi* \${DRACUT_ROOTFS}/usr/lib64/libtss2* \${DRACUT_ROOTFS}/usr/lib64/libtpm2*\\
    rm -rf \${DRACUT_ROOTFS}/usr/lib64/libdbus* \${DRACUT_ROOTFS}/usr/lib64/libostree*\\
    rm -rf \${DRACUT_ROOTFS}/etc/systemd \${DRACUT_ROOTFS}/etc/dbus-1 \${DRACUT_ROOTFS}/etc/udev\\
    rm -rf \${DRACUT_ROOTFS}/usr/lib/tmpfiles.d \${DRACUT_ROOTFS}/usr/lib/sysctl.d \${DRACUT_ROOTFS}/usr/lib/sysusers.d\\
    rm -rf \${DRACUT_ROOTFS}/usr/lib/udev \${DRACUT_ROOTFS}/usr/lib/modprobe.d" \
  "${OSBUILDER}"

# Step 3: Build
"${OSBUILDER}" 2>&1 | tail -5

# Step 4: Save the result
cp "${IMAGE_DIR}/kata.initrd" "${OUT}"

# Step 5: Restore osbuilder and dracut config, rebuild stock
cp "${BACKUP}" "${OSBUILDER}"
rm "${BACKUP}"
# Restore original dracut config
if [ -f "${OSBUILDER_DIR}/dracut/dracut.conf.d/15-dracut.conf.orig" ]; then
    cp "${OSBUILDER_DIR}/dracut/dracut.conf.d/15-dracut.conf.orig" \
       "${OSBUILDER_DIR}/dracut/dracut.conf.d/15-dracut.conf"
fi
"${OSBUILDER}" 2>&1 | tail -3

echo ""
echo "Built: $(ls -lh "${OUT}" | awk '{print $5}') at ${OUT}"
echo "Stock: $(ls -lh "${IMAGE_DIR}/kata.initrd" | awk '{print $5}') (unchanged)"
