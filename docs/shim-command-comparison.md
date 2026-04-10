# QEMU command line: Q35 vs microvm

Captured from running processes on the same ARO 4.18 node.

## Q35 (standard Kata, working)

```
/usr/libexec/qemu-kvm \
  -name sandbox-...,debug-threads=on \
  -uuid ... \
  -machine q35,accel=kvm,kernel_irqchip=split \
  -cpu host,pmu=off \
  -qmp unix:fd=3,server=on,wait=off \
  -m 2048M,slots=10,maxmem=17015M \
  -device pci-bridge,bus=pcie.0,id=pci-bridge-0,chassis_nr=1,shpc=off,addr=2,io-reserve=4k,mem-reserve=1m,pref64-reserve=1m \
  -device virtio-serial-pci,disable-modern=true,id=serial0 \
  -device virtconsole,chardev=charconsole0,id=console0 \
  -chardev socket,id=charconsole0,path=.../console.sock,server=on,wait=off \
  -device intel-iommu,intremap=on,device-iotlb=on,caching-mode=on \
  -device virtio-scsi-pci,id=scsi0,disable-modern=true \
  -object rng-random,id=rng0,filename=/dev/urandom \
  -device virtio-rng-pci,rng=rng0 \
  -device vhost-vsock-pci,disable-modern=true,vhostfd=4,id=vsock-...,guest-cid=... \
  -chardev socket,id=char-...,path=.../vhost-fs.sock \
  -device vhost-user-fs-pci,chardev=char-...,tag=kataShared,queue-size=1024 \
  -netdev tap,id=network-0,vhost=on,vhostfds=5,fds=6 \
  -device driver=virtio-net-pci,netdev=network-0,mac=...,disable-modern=true,mq=on,vectors=4 \
  -rtc base=utc,driftfix=slew,clock=host \
  -global kvm-pit.lost_tick_policy=discard \
  -vga none -no-user-config -nodefaults -nographic --no-reboot \
  -object memory-backend-file,id=dimm1,size=2048M,mem-path=/dev/shm,share=on \
  -numa node,memdev=dimm1 \
  -kernel .../vmlinuz \
  -initrd .../kata-containers-initrd.img \
  -append "tsc=reliable no_timer_check ... intel_iommu=on iommu=pt console=hvc0 console=hvc1 ..." \
  -pidfile .../pid \
  -smp 1,cores=1,threads=1,sockets=4,maxcpus=4
```

## microvm (prototype, shim-generated)

```
/usr/libexec/qemu-kvm-microvm \
  -name sandbox-...,debug-threads=on \
  -uuid ... \
  -machine microvm,accel=kvm \
  -cpu host,pmu=off \
  -qmp unix:fd=3,server=on,wait=off \
  -m 2048M,slots=10,maxmem=17015M \
  -device virtio-serial-device,id=serial0 \
  -device virtconsole,chardev=charconsole0,id=console0 \
  -chardev socket,id=charconsole0,path=.../console.sock,server=on,wait=off \
  -device virtio-scsi-device,id=scsi0 \
  -object rng-random,id=rng0,filename=/dev/urandom \
  -device virtio-rng-device,rng=rng0 \
  -device vhost-vsock-device,vhostfd=4,id=vsock-...,guest-cid=... \
  -chardev socket,id=char-...,path=.../vhost-fs.sock \
  -device vhost-user-fs-device,chardev=char-...,tag=kataShared,queue-size=1024 \
  -netdev tap,id=network-0,vhost=on,vhostfds=5,fds=6 \
  -device driver=virtio-net-device,netdev=network-0,mac=...,mq=on \
  -rtc base=utc,driftfix=slew,clock=host \
  -global kvm-pit.lost_tick_policy=discard \
  -vga none -no-user-config -nodefaults -nographic --no-reboot \
  -object memory-backend-file,id=dimm1,size=2048M,mem-path=/dev/shm,share=on \
  -machine memory-backend=dimm1 \
  -kernel .../vmlinuz \
  -initrd .../kata-containers-initrd.img \
  -append "tsc=reliable no_timer_check ... console=hvc0 console=hvc1 ..." \
  -pidfile .../pid \
  -smp 1,cores=1,threads=1,sockets=4,maxcpus=4
```

## Key differences

| Feature | Q35 | microvm |
|---------|-----|---------|
| Machine type | q35 | microvm |
| Device transport | PCI (`virtio-*-pci`) | MMIO (`virtio-*-device`) |
| PCI bridge | Yes (`pci-bridge,bus=pcie.0`) | None |
| IOMMU | Yes (`intel-iommu`) | None |
| Memory topology | NUMA (`-numa node`) | Simple (`-machine memory-backend=`) |
| kernel_irqchip | split | default (on) |
| disable-modern | true (forces legacy) | N/A (MMIO has no modern/legacy) |
| Legacy devices | USB, serial, IDE, VGA (disabled by flags) | None by default |
