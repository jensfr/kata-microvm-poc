#!/bin/bash
# Build a minimal ext4 root image for the RHEL automotive kernel (6.12).
#
# The automotive kernel has CONFIG_VIRTIO_BLK=y and CONFIG_EXT4_FS=y built-in,
# so it can mount /dev/vda as root without an initrd. Modules for vsock,
# virtiofs, virtio-net, etc. are loaded by the init script after mount.
#
# Run on the OCP worker node as root:
#   ./build-automotive-rootfs.sh
#
# Produces: /var/cache/kata-containers/kata-automotive.img
#
# Key design decisions:
#   - kata-agent comes from the stock kata Ubuntu image (dynamically linked)
#   - Libraries come from the SAME Ubuntu image (glibc 2.39 matches agent)
#   - bash and kmod come from the RHEL 9 host (forward-compatible with newer glibc)
#   - Modules are .ko.zst from the automotive kernel RPM (kmod has +ZSTD)
#   - /lib64, /bin, /sbin are usr-merge symlinks (like RHEL 9/10)
#   - Rootfs uses MBR partition table so Kata sees root=/dev/vda1
#   - Config needs disable_image_nvdimm=true (automotive lacks CONFIG_BLK_DEV_PMEM)

set -euo pipefail

KVER_AUTO="6.12.0-264.el10iv.x86_64"
IMG="/var/cache/kata-containers/kata-automotive.img"
STOCK_IMG="/opt/kata/share/kata-containers/kata-containers.img"
MODULES_RPM_URL="https://cbs.centos.org/kojifiles/packages/kernel-automotive/6.12.0/264.el10iv/x86_64/kernel-automotive-modules-core-6.12.0-264.el10iv.x86_64.rpm"
WORK=$(mktemp -d /tmp/kata-auto-build.XXXXX)
ROOTFS="$WORK/rootfs"

cleanup() {
    for mp in "$WORK"/mnt-*; do
        mountpoint -q "$mp" 2>/dev/null && umount "$mp"
    done
    for loop in $(losetup -j "$IMG" 2>/dev/null | cut -d: -f1); do
        losetup -d "$loop" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== Building automotive kernel rootfs ==="
mkdir -p "$ROOTFS"/{usr/bin,usr/sbin,usr/lib64,etc,dev,proc,sys,tmp,run,var/run}
mkdir -p "$ROOTFS"/{dev/pts,dev/shm}

# === Step 1: Extract kata-agent and libraries from stock kata image ===
echo ""
echo "--- Step 1: kata-agent and libraries from stock image ---"
SMNT="$WORK/mnt-stock"
mkdir -p "$SMNT"
# Stock image is a partitioned disk, partition 1 starts at sector 6144
mount -o loop,ro,offset=$((6144 * 512)) "$STOCK_IMG" "$SMNT"

cp "$SMNT/usr/bin/kata-agent" "$ROOTFS/usr/bin/"
echo "kata-agent: $(du -sh "$ROOTFS/usr/bin/kata-agent" | cut -f1)"

# Copy Ubuntu ld-linux and all libs needed by kata-agent
UBUNTU_LIBDIR="$SMNT/usr/lib/x86_64-linux-gnu"
cp -L "$UBUNTU_LIBDIR/ld-linux-x86-64.so.2" "$ROOTFS/usr/lib64/"
for lib in $(ldd "$SMNT/usr/bin/kata-agent" 2>/dev/null | grep "=> /" | awk '{print $3}'); do
    libname=$(basename "$lib")
    found=$(find "$SMNT" -name "$libname" -type f 2>/dev/null | head -1)
    [ -n "$found" ] && cp -L "$found" "$ROOTFS/usr/lib64/"
done

# Copy default policy
mkdir -p "$ROOTFS/etc/kata-opa"
if [ -f "$SMNT/etc/kata-opa/default-policy.rego" ]; then
    cp "$SMNT/etc/kata-opa/default-policy.rego" "$ROOTFS/etc/kata-opa/"
fi

umount "$SMNT"

# === Step 2: Host binaries (bash, kmod, mount) ===
echo ""
echo "--- Step 2: host binaries ---"
cp /usr/bin/bash "$ROOTFS/usr/bin/"
cp /usr/bin/kmod "$ROOTFS/usr/bin/"
for link in modprobe depmod insmod lsmod rmmod modinfo; do
    ln -sf kmod "$ROOTFS/usr/bin/$link"
    ln -sf /usr/bin/kmod "$ROOTFS/usr/sbin/$link"
done
cp /usr/bin/mount "$ROOTFS/usr/bin/" 2>/dev/null || true
cp /usr/bin/mkdir "$ROOTFS/usr/bin/" 2>/dev/null || true

# Copy Ubuntu versions of libs needed by host binaries
# (glibc is forward-compatible: RHEL 9 binaries work with Ubuntu 24 glibc)
SMNT2="$WORK/mnt-stock2"
mkdir -p "$SMNT2"
mount -o loop,ro,offset=$((6144 * 512)) "$STOCK_IMG" "$SMNT2"

for bin in /usr/bin/bash /usr/bin/kmod /usr/bin/mount; do
    ldd "$bin" 2>/dev/null | grep "=> /" | awk '{print $3}' | while read lib; do
        libname=$(basename "$lib")
        [ -f "$ROOTFS/usr/lib64/$libname" ] && continue
        found=$(find "$SMNT2" -name "$libname" -type f 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            cp -L "$found" "$ROOTFS/usr/lib64/"
        else
            cp -nL "$lib" "$ROOTFS/usr/lib64/" 2>/dev/null || true
        fi
    done
done

umount "$SMNT2"

# === Step 3: usr-merge symlinks ===
echo ""
echo "--- Step 3: usr-merge symlinks ---"
ln -sf usr/lib64 "$ROOTFS/lib64"
ln -sf usr/bin "$ROOTFS/bin"
ln -sf usr/sbin "$ROOTFS/sbin"

# ld.so config
echo "/usr/lib64" > "$ROOTFS/etc/ld.so.conf"
ldconfig -r "$ROOTFS" 2>/dev/null || true

# === Step 4: Automotive kernel modules ===
echo ""
echo "--- Step 4: kernel modules ---"
cd "$WORK"
echo "Downloading modules RPM..."
curl -sLf -o modules-core.rpm "$MODULES_RPM_URL"
rpm2cpio modules-core.rpm | cpio -idm 2>/dev/null

MODDIR="$ROOTFS/lib/modules/$KVER_AUTO"
mkdir -p "$MODDIR"
SRC_MODDIR=$(find . -path "*/lib/modules/$KVER_AUTO" -type d | head -1)

NEEDED="vmw_vsock_virtio_transport vmw_vsock_virtio_transport_common vsock
virtiofs fuse virtio_net net_failover failover virtio_console
ptp_kvm ptp nf_tables nft_reject nft_reject_inet nf_reject_ipv4
nf_reject_ipv6 veth"

for mod in $NEEDED; do
    src=$(find "$SRC_MODDIR" -name "${mod}.ko*" -type f 2>/dev/null | head -1)
    [ -n "$src" ] && cp "$src" "$MODDIR/" && echo "  $mod"
done

# modules.dep (flat, kmod uses it for dependency resolution)
cat > "$MODDIR/modules.dep" << 'DEPS'
vmw_vsock_virtio_transport.ko.zst: vmw_vsock_virtio_transport_common.ko.zst vsock.ko.zst
vmw_vsock_virtio_transport_common.ko.zst: vsock.ko.zst
vsock.ko.zst:
virtiofs.ko.zst: fuse.ko.zst
fuse.ko.zst:
virtio_net.ko.zst: net_failover.ko.zst failover.ko.zst
net_failover.ko.zst: failover.ko.zst
failover.ko.zst:
virtio_console.ko.zst:
ptp_kvm.ko.zst: ptp.ko.zst
ptp.ko.zst:
nf_tables.ko.zst:
nft_reject.ko.zst: nf_tables.ko.zst
nft_reject_inet.ko.zst: nf_reject_ipv4.ko.zst nf_reject_ipv6.ko.zst nft_reject.ko.zst nf_tables.ko.zst
nf_reject_ipv4.ko.zst:
nf_reject_ipv6.ko.zst:
veth.ko.zst:
DEPS

echo "Modules: $(ls "$MODDIR"/*.ko* 2>/dev/null | wc -l) files, $(du -sh "$MODDIR" | cut -f1)"

# === Step 5: Init script ===
echo ""
echo "--- Step 5: init script ---"
cat > "$ROOTFS/usr/sbin/init" << 'INIT'
#!/usr/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /dev/shm /tmp /run
mount -t devpts devpts /dev/pts 2>/dev/null
mount -t tmpfs tmpfs /tmp 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null

modprobe virtio_console 2>/dev/null
modprobe virtiofs 2>/dev/null
modprobe vmw_vsock_virtio_transport 2>/dev/null
modprobe virtio_net 2>/dev/null
modprobe ptp_kvm 2>/dev/null

exec /usr/bin/kata-agent
INIT
chmod +x "$ROOTFS/usr/sbin/init"
cp "$ROOTFS/usr/sbin/init" "$ROOTFS/init"
chmod +x "$ROOTFS/init"

# === Step 6: Build ext4 disk image ===
echo ""
echo "--- Step 6: ext4 disk image ---"
ROOTFS_SIZE=$(du -sm "$ROOTFS" | awk '{print $1}')
IMG_SIZE=$(( ROOTFS_SIZE + ROOTFS_SIZE / 3 + 16 ))
[ "$IMG_SIZE" -lt 64 ] && IMG_SIZE=64
echo "Rootfs: ${ROOTFS_SIZE}MB, image: ${IMG_SIZE}MB"

dd if=/dev/zero of="$IMG" bs=1M count="$IMG_SIZE" status=none
echo ",,L,*" | sfdisk -q "$IMG"

LOOP=$(losetup --find --show --partscan "$IMG")
PART="${LOOP}p1"
sleep 1; [ -b "$PART" ] || partprobe "$LOOP"; sleep 1

mkfs.ext4 -F -L kata-rootfs -q "$PART"
IMNT="$WORK/mnt-img"
mkdir -p "$IMNT"
mount "$PART" "$IMNT"
cp -a "$ROOTFS"/* "$IMNT/"
sync
umount "$IMNT"
losetup -d "$LOOP"

echo ""
echo "=== Done ==="
echo "Image: $(ls -lh "$IMG" | awk '{print $5}') at $IMG"
echo "Kernel: /var/cache/kata-containers/vmlinuz-automotive"
echo ""
echo "Kata config drop-in (50-automotive.toml):"
echo '  [hypervisor.qemu]'
echo '  kernel = "/var/cache/kata-containers/vmlinuz-automotive"'
echo '  image = "/var/cache/kata-containers/kata-automotive.img"'
echo '  initrd = ""'
echo '  kernel_params = "nr_cpus=1 cgroup_no_v1=all"'
echo '  default_memory = 256'
echo '  disable_image_nvdimm = true'
echo '  block_device_driver = "virtio-blk"'
