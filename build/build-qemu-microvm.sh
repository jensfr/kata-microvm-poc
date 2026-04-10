#!/bin/bash
# Build upstream QEMU v9.2.0 with microvm machine type
# Run this inside a privileged build pod on the target node
#
# Prerequisites: gcc, make, meson, ninja, glib2-devel, pixman-devel,
#                libseccomp-devel, libcap-ng-devel
#
# On RHCOS, use a UBI container with dev tools:
#   oc run qemu-builder --image=registry.access.redhat.com/ubi9/ubi:latest \
#     --overrides='{"spec":{"nodeName":"<node>","containers":[{"name":"qemu-builder","image":"registry.access.redhat.com/ubi9/ubi:latest","command":["sleep","infinity"],"securityContext":{"privileged":true},"volumeMounts":[{"name":"host","mountPath":"/host"}]}],"volumes":[{"name":"host","hostPath":{"path":"/"}}]}}' \
#     --restart=Never

set -euo pipefail

QEMU_VERSION="v9.2.0"
BUILD_DIR="/tmp/qemu-upstream"
INSTALL_PREFIX="/var/tmp/qemu-microvm"

echo "=== Installing build dependencies ==="
dnf install -y gcc make ninja-build python3 python3-pip \
    glib2-devel pixman-devel zlib-devel libseccomp-devel \
    libcap-ng-devel libattr-devel flex bison git diffutils

pip3 install meson

echo "=== Cloning QEMU ${QEMU_VERSION} ==="
git clone --depth 1 --branch "${QEMU_VERSION}" \
    https://gitlab.com/qemu-project/qemu.git "${BUILD_DIR}"

cd "${BUILD_DIR}"
mkdir build && cd build

echo "=== Configuring QEMU ==="
../configure \
    --target-list=x86_64-softmmu \
    --prefix="${INSTALL_PREFIX}" \
    --enable-kvm \
    --enable-vhost-net \
    --enable-vhost-vsock \
    --enable-vhost-user-fs \
    --enable-seccomp \
    --enable-linux-aio \
    --enable-cap-ng \
    --disable-docs \
    --disable-user \
    --disable-guest-agent \
    --disable-gtk \
    --disable-sdl \
    --disable-opengl \
    --disable-virglrenderer \
    --disable-spice \
    --disable-curses \
    --disable-vnc

echo "=== Building QEMU (this will take a while) ==="
make -j$(nproc)

echo "=== Installing to ${INSTALL_PREFIX} ==="
make install

echo "=== Check microvm support ==="
"${INSTALL_PREFIX}/bin/qemu-system-x86_64" -machine help | grep microvm

echo "=== Binary size ==="
ls -lh "${INSTALL_PREFIX}/bin/qemu-system-x86_64"

echo "=== Firmware files ==="
ls -la "${INSTALL_PREFIX}/share/qemu/bios-microvm.bin" \
       "${INSTALL_PREFIX}/share/qemu/linuxboot_dma.bin"

echo ""
echo "=== DONE ==="
echo "Binary: ${INSTALL_PREFIX}/bin/qemu-system-x86_64"
echo "Firmware: ${INSTALL_PREFIX}/share/qemu/"
echo ""
echo "To install on the host node:"
echo "  cp ${INSTALL_PREFIX}/bin/qemu-system-x86_64 /host/usr/libexec/qemu-kvm-microvm"
echo "  restorecon /host/usr/libexec/qemu-kvm-microvm"
echo "  mkdir -p /host/usr/share/qemu"
echo "  cp ${INSTALL_PREFIX}/share/qemu/bios-microvm.bin /host/usr/share/qemu/"
echo "  cp ${INSTALL_PREFIX}/share/qemu/linuxboot_dma.bin /host/usr/share/qemu/"
