#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © 2020-2023 Serpent OS Developers
#
# SPDX-License-Identifier: MPL-2.0
#
# Serpent OS prototype linux-desktop ISO image generator

die () {
    echo -e "$*"
    exit 1
}

# Add escape codes for color
RED='\033[0;31m'
RESET='\033[0m'

# Pkg list check
test -f ./pkglist || die "\nThis script MUST be run from within the desktop/ dir with the ./pkglist file.\n"
test -f ../pkglist-base || die "\nThis script MUST be able to find the ../pkglist-base file.\n"

# start with a common base of packages
readarray -t PACKAGES < ../pkglist-base

# add linux-desktop specific packages
PACKAGES+=($(cat ./pkglist))

#echo -e "List of packages:\n${PACKAGES[@]}\n"
#exit 1

test -f ./initrdlist || die "initrd package list is absent"
readarray -t initrd < initrdlist

# Root check
if [[ "${UID}" -ne 0 ]]; then
    die "\nThis script MUST be run as root.\n"
fi

BINARIES=(
    e2fsck
    fallocate
    mkfs.ext3
    mkfs.vfat
    moss
    moss-container
    mount
    resize2fs
    sync
    xorriso
)
# up front check for necessary binaries
BINARY_NOT_FOUND=0
echo -e "\nChecking for necessary prerequisites..."
# 'all entries in the BINARIES array'
for b in ${BINARIES[@]}; do
    command -v ${b} > /dev/null 2>&1
    if [[ ! ${?} -eq 0 ]]; then
        echo -e "- ${b} ${RED}not found${RESET} in \$PATH."
        BINARY_NOT_FOUND=1
    else
        echo "- found ${b}"
    fi
done

if [[ ${BINARY_NOT_FOUND} -gt 0 ]]; then
    die "\nNecessary prerequisites not met, please install missing tool(s).\n"
else
    echo -e "\nAll necessary binaries found, generating Serpent OS linux-desktop ISO image...\n"
fi
#die "Exit because this is just a test."

# From here on, exit from script on any non-zero exit status command result
set -e

DIRS=(
    mount
    root
    LiveOS
    boot
    overlay.upper
    overlay.mount
    overlay.work
)

# clean up dirs
for d in ${DIRS[@]}; do
    test -d ${d} && rm -rf ${d}
done
# clean up existing rootfs.img
test -e rootfs.img && rm -f rootfs.img

# Stash boot assets
mkdir -pv boot

# Get it right first time.
mkdir -pv mount
chown -Rc root:root mount
chmod -Rc 00755 mount

# Setup the root image
fallocate -l 4GB rootfs.img
# don't want/need journaling on the fs
mkfs.ext3 -F rootfs.img
mount -o loop rootfs.img mount

# Add repositories
moss -D mount/ repo add volatile https://dev.serpentos.com/volatile/x86_64/stone.index

# Install the PACKAGES
moss -D mount/ install -y "${PACKAGES[@]}"

# Fix ldconfig
mkdir -pv mount/var/cache/ldconfig
moss-container -u 0 -d mount/ -- ldconfig

# Get basic env working
moss-container -u 0 -d mount/ -- systemd-sysusers
moss-container -u 0 -d mount/ -- systemd-tmpfiles --create
moss-container -u 0 -d mount/ -- systemd-firstboot --force --setup-machine-id --delete-root-password --locale=en_US.UTF-8 --timezone=UTC --root-shell=/usr/bin/bash
moss-container -u 0 -d mount/ -- systemctl enable systemd-resolved systemd-networkd getty@tty1

# Fix perf issues. Needs packaging/merging by moss
moss-container -u 0 -d mount/ -- systemd-hwdb update

# Extract assets
cp -v mount/usr/lib/systemd/boot/efi/systemd-bootx64.efi boot/bootx64.efi
cp -v mount/usr/lib/kernel/com.serpentos.* boot/kernel

# Setup the overlay.
mkdir overlay.upper
mkdir overlay.mount
mkdir overlay.work

mount -t overlay -o lowerdir=$(pwd)/mount,upperdir=$(pwd)/overlay.upper,workdir=$(pwd)/overlay.work,redirect_dir=on overlay overlay.mount || die "Failed to mount overlay"

# Install dracut now
moss -D overlay.mount install "${initrd[@]}" -y || die "Failed to install overlay packages"

# Regenerate dracut. BLUH.
kver=$(ls mount/usr/lib/modules)
moss-container -u 0 -d overlay.mount/ -- dracut --early-microcode --hardlink -N --nomdadmconf --nolvmconf --kver ${kver} --add "bash dash systemd lvm dm dmsquash-live" --fwdir /usr/lib/firmware --tmpdir /tmp --zstd --strip /initrd
cp -v overlay.mount/initrd boot/initrd

# Tear it down
umount $(pwd)/overlay.mount

# Cleanup!
rm -rf mount/.moss/cache/downloads/*
umount $(pwd)/mount

# Shrink size to minimum
resize2fs -M rootfs.img -f

# Force a check on it
e2fsck -fy rootfs.img

# Now gen the structure

mkdir -pv LiveOS
mv -v rootfs.img LiveOS/.
mksquashfs LiveOS/ squashfs.img -comp zstd -root-becomes LiveOS -keep-as-directory -all-root
rm -f LiveOS/rootfs.img
mv -v squashfs.img LiveOS/.

mkdir -pv root
mv -v LiveOS root/.

# Create the efi img
fallocate -l 40M efi.img
mkfs.vfat -F 12 efi.img -n EFIBOOTISO
mount -o loop efi.img mount

# Set it up...
mkdir -pv mount/EFI/Boot
cp -v boot/bootx64.efi mount/EFI/Boot/bootx64.efi
sync
mkdir -pv mount/loader/entries
cp -v live-os.conf mount/loader/entries/.
cp -v boot/kernel mount/kernel
cp -v boot/initrd mount/initrd
umount $(pwd)/mount

# Put it in place
mkdir -pv root/EFI/Boot
mv -v efi.img root/EFI/Boot/efiboot.img

# Create the ISO
xorriso -as mkisofs \
    -o snekvalidator.iso \
    -R -J -v -d -N \
    -x snekvalidator.iso \
    -hide-rr-moved \
    -no-emul-boot \
    -eltorito-platform efi \
    -eltorito-boot EFI/Boot/efiboot.img \
    -isohybrid-gpt-basdat \
    -V "SERPENTISO" -A "SERPENTISO" \
    root

# TODO: Generate an ISO
