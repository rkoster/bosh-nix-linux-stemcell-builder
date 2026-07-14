# shellcheck shell=bash
# No shebang: this file is not executed standalone. It is embedded into the
# VM builder script via `replaceVars` (bootable-disk.nix), which already
# supplies its own shebang/bash invocation.
#
# $out is the standard Nix build output path, provided by the enclosing
# derivation's builder environment, not assigned in this fragment.
# shellcheck disable=SC2154
set -exuo pipefail

export SOURCE_DATE_EPOCH=1700000000

disk=/dev/vda

# Partition the disk using sfdisk with MBR dos label
# Partition 1 (ESP): starts at 2048 sectors, size ~48MiB (98304 sectors), type ef (EFI)
# Partition 2 (root): starts at 100352 sectors, remainder, type 83 (Linux)
@util-linux@/bin/sfdisk "$disk" <<EOF
label: dos
unit: sectors

start=2048, size=98304, type=ef, bootable
start=100352, type=83
EOF

# Refresh partition table
@util-linux@/bin/partx -u "$disk"
sleep 1

# Create filesystems
@dosfstools@/bin/mkfs.vfat -F32 -n ESP -i 44444444 "$disk"1
@e2fsprogs@/bin/mkfs.ext4 "$disk"2 -L root -F \
  -U 44444444-4444-4444-4444-444444444444 \
  -E hash_seed=44444444-4444-4444-4444-444444444444,root_owner=0:0 \
  -O ^dir_index -q

# Mount filesystems
mkdir -p /mnt/root
@util-linux@/bin/mount -t ext4 "$disk"2 /mnt/root
mkdir -p /mnt/root/boot/efi
@util-linux@/bin/mount -t vfat "$disk"1 /mnt/root/boot/efi

# Create /proc, /sys, /dev mount points (will be bind-mounted for grub-install)
mkdir -p /mnt/root/{proc,sys,dev}

# Extract osImage rootfs tarball into root partition
@gnutar@/bin/tar -xf @osImage@/rootfs.tar.gz --acls --xattrs -C /mnt/root

# Prepare chroot: bind /proc, /sys, /dev for grub-install and udev
@util-linux@/bin/mount -t proc proc /mnt/root/proc
@util-linux@/bin/mount -t sysfs sysfs /mnt/root/sys
@util-linux@/bin/mount --bind /dev /mnt/root/dev

# Start udev daemon so grub-install can detect devices
@systemdMinimal@/lib/systemd/systemd-udevd &
@systemdMinimal@/bin/udevadm trigger
@systemdMinimal@/bin/udevadm settle

# Create /etc/fstab
cat > /mnt/root/etc/fstab <<FSTAB
LABEL=root / ext4 defaults 0 1
LABEL=ESP /boot/efi vfat defaults 0 2
FSTAB

# Chroot and install grub + configure bootloader
chroot /mnt/root /bin/bash -exuo pipefail <<'CHROOT'
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Generate a reproducible initramfs (deterministic cpio order + gzip -n).
export SOURCE_DATE_EPOCH=1700000000
if [ ! -f /boot/initrd.img ]; then
  update-initramfs -k all -c
fi
# Rebuild each initrd deterministically in case initramfs-tools ignored
# SOURCE_DATE_EPOCH: re-pack the cpio with sorted names and gzip -n.
for img in /boot/initrd.img-*; do
  [ -e "$img" ] || continue
  tmpd=$(mktemp -d)
  # Detect if the initramfs is gzip compressed or plain cpio.
  if head -c 2 "$img" | od -An -tx1 | grep -q '1f 8b'; then
    # File is gzip compressed, use zcat
    ( cd "$tmpd" && zcat "$img" | cpio -idm --quiet ) || true
  else
    # File is uncompressed cpio or other format, try direct cpio extraction
    ( cd "$tmpd" && cpio -idm --quiet < "$img" ) || true
  fi
  ( cd "$tmpd" && find . -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z \
      | cpio -o -H newc --quiet -0 --owner=0:0 \
      | gzip -n -9 > "$img" )
  rm -rf "$tmpd"
done

# Set grub defaults with BOSH-compatible kernel cmdline
cat > /etc/default/grub <<EOF
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX="vconsole.keymap=us net.ifnames=0 biosdevname=0 crashkernel=auto selinux=0 plymouth.enable=0 console=ttyS0,115200n8 earlyprintk=ttyS0 rootdelay=300 audit=1 cgroup_enable=memory swapaccount=1 apparmor=1 security=apparmor"
GRUB_CMDLINE_LINUX_DEFAULT=""
EOF

# Create /boot/grub directory if it doesn't exist
mkdir -p /boot/grub

# Install grub for EFI (x86_64-efi target)
grub-install --target x86_64-efi --efi-directory /boot/efi --boot-directory /boot --removable --no-floppy /dev/vda

# Install grub for BIOS (i386-pc target) into MBR
grub-install --target i386-pc --boot-directory /boot --no-floppy /dev/vda

# Ensure grub-mkconfig generates root=UUID=... (not root=/dev/vda2).
# grub's 10_linux script uses UUID form only when /dev/disk/by-uuid/<uuid>
# exists at grub-mkconfig time.  In the Nix runInLinuxVM build environment
# udev does not reliably create those symlinks, so create them manually.
# Without this, Incus VMs (which present disks as /dev/sda via virtio-scsi)
# fail to boot with "ALERT! /dev/vda2 does not exist".
ROOT_UUID=$(blkid -s UUID -o value /dev/vda2)
mkdir -p /dev/disk/by-uuid
ln -sf /dev/vda2 "/dev/disk/by-uuid/$ROOT_UUID"

# Generate grub.cfg from /etc/default/grub
update-grub

# Strip any embedded build time from generated grub artifacts.
find /boot/grub -name '*.mod' -o -name 'grub.cfg' | while read -r f; do
  touch -d "@$SOURCE_DATE_EPOCH" "$f"
done

CHROOT

# Unmount everything in reverse order
@util-linux@/bin/umount /mnt/root/dev 2>/dev/null || true
@util-linux@/bin/umount /mnt/root/sys 2>/dev/null || true
@util-linux@/bin/umount /mnt/root/proc 2>/dev/null || true
@util-linux@/bin/umount /mnt/root/boot/efi 2>/dev/null || true
@util-linux@/bin/umount /mnt/root 2>/dev/null || true

# Convert raw disk image to qcow2
mkdir -p "$out"
@qemu@/bin/qemu-img convert -f raw -O qcow2 /dev/vda "$out/root.qcow2"

# Verify qcow2
@qemu@/bin/qemu-img info "$out/root.qcow2"
