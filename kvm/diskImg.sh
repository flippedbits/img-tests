#!/usr/bin/env bash

### WARNING: SUPER ROUGH PROTOTYPE

set -e
set -x

rm -rf root
rm -rf disk.img

fallocate -l 20GB disk.img
parted disk.img << EOF
mklabel GPT
mkpart "Extended Boot Loader Partition" fat32 1MiB 500MiB
mkpart "EFI System Partition" fat32 500MiB 600MiB
mkpart "Serpent OS Root Partition" ext2 600MiB 100%
set 2 esp on
set 1 bls_boot on
type 3 "4f68bce3-e8cd-4db1-96e7-fbcaf984b709"
EOF
LODEVICE=$(losetup -f disk.img --show -P)

mkdir root

mkfs.vfat -F 32 ${LODEVICE}p1
mkfs.vfat -F 32 ${LODEVICE}p2
mkfs.ext4 -F ${LODEVICE}p3

mount ${LODEVICE}p3 root
mkdir root/boot
mkdir root/efi
mount ${LODEVICE}p1 root/boot
mount ${LODEVICE}p2 root/efi
mkdir root/efi/EFI
mkdir root/efi/EFI/systemd
mkdir root/efi/EFI/Boot
# systemd units complain if it doesnt exist.
mkdir root/efi/loader

echo "Loopback is at ${LODEVICE}"
sync

readarray -t PACKAGES < ../pkglist-base
PACKAGES+=($(cat ./pkglist))
# get moss in.
moss -D root/ repo add volatile https://dev.serpentos.com/volatile/x86_64/stone.index
moss -D root/ install "${PACKAGES[@]}" -y

# Fix ldconfig
mkdir -pv root/var/cache/ldconfig
moss-container -u 0 -d root/ -- ldconfig

# Get basic env working
moss-container -u 0 -d root/ -- systemd-sysusers
moss-container -u 0 -d root/ -- systemd-tmpfiles --create
moss-container -u 0 -d root/ -- systemd-firstboot --force --setup-machine-id --delete-root-password --locale=en_US.UTF-8 --timezone=UTC --root-shell=/usr/bin/bash
moss-container -u 0 -d root/ -- systemctl enable systemd-resolved systemd-networkd getty@tty1

# Fix perf issues. Needs packaging/merging by moss
moss-container -u 0 -d root/ -- systemd-hwdb update

# OS kernel assets
mkdir root/boot/com.serpentos
cp root/usr/lib/kernel/com.serpentos.* root/boot/com.serpentos/kernel-static
cp root/usr/lib/kernel/initrd-* root/boot/com.serpentos/initrd-static

mkdir root/boot/loader/entries -p
cp installed-os.conf root/boot/loader/entries/.

# systemd boot
cp root/usr/lib/systemd/boot/efi/systemd-bootx64.efi root/efi/EFI/systemd/systemd-bootx64.efi
cp root/usr/lib/systemd/boot/efi/systemd-bootx64.efi root/efi/EFI/Boot/bootx64.efi

ls -lRa root/boot
ls -lRa root/efi
umount root/boot
umount root/efi
umount root
losetup -d ${LODEVICE}

chmod a+rw disk.img
