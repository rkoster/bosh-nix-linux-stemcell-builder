# shellcheck shell=bash
# No shebang: this file is not executed standalone. It is embedded into the
# VM builder script via `replaceVars` (bootable-rootfs.nix), which already
# supplies its own shebang/bash invocation.
#
# PHASE A of the deterministic disk-image refactor: generate all root-fs
# *files* (initramfs, grub.cfg, i386-pc modules + core.img, EFI binary) inside
# a VM chroot, canonicalize them, and emit them as a byte-deterministic
# canonical tarball (rootfs-staged.tar.gz) plus the staged ESP tree. NO
# partitioning, NO mkfs of a target fs, NO mount of a target fs, NO qemu-img.
#
# $out is the standard Nix build output path, provided by the enclosing
# derivation's builder environment, not assigned in this fragment.
# shellcheck disable=SC2154
set -exuo pipefail

export SOURCE_DATE_EPOCH=0

# Plain staging directory. The VM's root is a small tmpfs (memSize RAM), far
# too small for the ~3 GB rootfs, so back the staging dir with the attached
# scratch disk (/dev/vda). We carve a tiny FAT partition (p1) for the EFI
# grub-install (which insists on a real vfat EFI partition) and use the rest
# (p2, ext4) for the root staging tree. This layout is SCRATCH ONLY: nothing
# from the on-disk block layout leaks into the deterministic interface --
# determinism comes from canonicalizing the files and repacking them with a
# sorted, mtime-pinned tar (root tree) / copying files out ($out/esp) below.
stage=/build/stage

@util-linux@/bin/sfdisk /dev/vda <<EOF
label: dos
unit: sectors

start=2048, size=98304, type=ef
start=100352, type=83
EOF
@util-linux@/bin/partx -u /dev/vda
sleep 1

@dosfstools@/bin/mkfs.vfat -F32 -n ESP -i 44444444 /dev/vda1
# Give the scratch root fs the SAME fixed UUID the Phase B target ext4 will use
# (44444444-...). grub-mkconfig probes the mounted root device's superblock
# UUID and bakes it into grub.cfg (search --fs-uuid + root=UUID=). Using the
# real target UUID here makes grub.cfg both deterministic and correct.
@e2fsprogs@/bin/mkfs.ext4 -q -F -U 44444444-4444-4444-4444-444444444444 /dev/vda2

mkdir -p "$stage"
@util-linux@/bin/mount -t ext4 /dev/vda2 "$stage"

# Extract osImage rootfs tarball into the staging dir.
@gnutar@/bin/tar -xf @osImage@/rootfs.tar.gz --acls --xattrs -C "$stage"

# Prepare chroot: bind /proc, /sys, /dev for grub/initramfs tooling and udev.
mkdir -p "$stage"/{proc,sys,dev}
@util-linux@/bin/mount -t proc proc "$stage/proc"
@util-linux@/bin/mount -t sysfs sysfs "$stage/sys"
@util-linux@/bin/mount --bind /dev "$stage/dev"

# Start udev daemon so grub/initramfs tooling can detect devices.
@systemdMinimal@/lib/systemd/systemd-udevd &
@systemdMinimal@/bin/udevadm trigger
@systemdMinimal@/bin/udevadm settle

# Mount the scratch FAT partition as the staging ESP for the EFI grub-install.
# Its files are copied out to $out/esp afterwards (Nix normalizes metadata), so
# the FAT layout never leaks into the deterministic interface.
mkdir -p "$stage/staging-esp"
@util-linux@/bin/mount -t vfat /dev/vda1 "$stage/staging-esp"

# Create /etc/fstab (label-based).
cat >"$stage/etc/fstab" <<FSTAB
LABEL=root / ext4 defaults 0 1
LABEL=ESP /boot/efi vfat defaults 0 2
FSTAB

# Chroot and generate all bootloader files (no MBR/device write).
chroot "$stage" /bin/bash -exuo pipefail <<'CHROOT'
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Generate a reproducible initramfs (deterministic cpio order + gzip -n).
export SOURCE_DATE_EPOCH=0
if [ ! -f /boot/initrd.img ]; then
  update-initramfs -k all -c
fi
# Rebuild each initrd deterministically in case initramfs-tools ignored
# SOURCE_DATE_EPOCH: re-pack the cpio with sorted names, pin every extracted
# entry's mtime to @0 (fixes initramfs mtime non-determinism), and gzip -n.
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
  # Pin mtimes of all extracted entries before repacking.
  find "$tmpd" -mindepth 1 -exec touch --no-dereference -d "@0" {} +
  ( cd "$tmpd" && find . -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z \
      | cpio -o -H newc --quiet -0 --owner=0:0 \
      | gzip -n -9 > "$img" )
  rm -rf "$tmpd"
done

# Set grub defaults with BOSH-compatible kernel cmdline.
cat > /etc/default/grub <<EOF
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX="vconsole.keymap=us net.ifnames=0 biosdevname=0 crashkernel=auto selinux=0 plymouth.enable=0 console=ttyS0,115200n8 earlyprintk=ttyS0 rootdelay=300 audit=1 cgroup_enable=memory swapaccount=1 apparmor=1 security=apparmor"
GRUB_CMDLINE_LINUX_DEFAULT=""
EOF

mkdir -p /boot/grub

# Ensure grub-mkconfig generates root=UUID=... (not root=/dev/vda2).
# grub's 10_linux script uses the UUID form only when /dev/disk/by-uuid/<uuid>
# exists at grub-mkconfig time (it uses `test -e`, which follows the link, so
# the target must exist). The scratch root fs already carries the fixed target
# UUID 44444444-..., so point the by-uuid link at the mounted root device.
mkdir -p /dev/disk/by-uuid
ln -sf /dev/vda2 "/dev/disk/by-uuid/44444444-4444-4444-4444-444444444444"

# Generate BIOS (i386-pc) grub files WITHOUT writing any MBR/device.
# --grub-setup=/bin/true skips the actual MBR embed while still producing
# /boot/grub/i386-pc/*.mod and /boot/grub/i386-pc/core.img.
grub-install --target=i386-pc --boot-directory=/boot --grub-setup=/bin/true \
  --no-floppy /dev/vda || true

if [ ! -f /boot/grub/i386-pc/core.img ]; then
  # Fallback: generate core.img directly with grub-mkimage and copy modules.
  echo "core.img missing after grub-install; falling back to grub-mkimage" >&2
  mkdir -p /boot/grub/i386-pc
  cp -a /usr/lib/grub/i386-pc/*.mod /boot/grub/i386-pc/ 2>/dev/null || true
  cp -a /usr/lib/grub/i386-pc/*.lst /boot/grub/i386-pc/ 2>/dev/null || true
  cp -a /usr/lib/grub/i386-pc/*.img /boot/grub/i386-pc/ 2>/dev/null || true
  grub-mkimage --directory=/usr/lib/grub/i386-pc --format=i386-pc \
    --output=/boot/grub/i386-pc/core.img --prefix='(,msdos2)/boot/grub' \
    biosdisk part_msdos ext2 configfile normal
  echo "GRUB_BIOS_PATH=grub-mkimage-fallback" > /boot/grub/.bios-path
else
  echo "GRUB_BIOS_PATH=grub-setup-bin-true" > /boot/grub/.bios-path
fi

# Generate EFI (x86_64-efi) grub files into the staging ESP (no NVRAM write).
mkdir -p /staging-esp
grub-install --target=x86_64-efi --efi-directory=/staging-esp \
  --boot-directory=/boot --removable --no-nvram --no-floppy

# Generate grub.cfg from /etc/default/grub.
update-grub

# Strip any embedded build time from generated grub artifacts.
find /boot/grub \( -name '*.mod' -o -name 'grub.cfg' -o -name 'core.img' \) \
  -exec touch -d "@$SOURCE_DATE_EPOCH" {} +
CHROOT

# Report which BIOS grub path was used.
cat "$stage/boot/grub/.bios-path" || true
rm -f "$stage/boot/grub/.bios-path"

# Copy the staged ESP tree out to $out/esp while it is still mounted, then
# unmount and remove the mountpoint so it does not pollute the rootfs tarball.
mkdir -p "$out/esp"
cp -r "$stage/staging-esp/." "$out/esp/"
@util-linux@/bin/umount "$stage/staging-esp"
rmdir "$stage/staging-esp"

# Unmount binds in reverse order.
@util-linux@/bin/umount "$stage/dev" 2>/dev/null || true
@util-linux@/bin/umount "$stage/sys" 2>/dev/null || true
@util-linux@/bin/umount "$stage/proc" 2>/dev/null || true

# Wipe volatile state that would break byte-reproducibility.
rm -rf "$stage"/run/* "$stage"/tmp/* "$stage"/var/cache/ldconfig/* \
  "$stage"/var/lib/systemd/random-seed

# Pin every remaining mtime under the stage.
find "$stage" -exec touch --no-dereference -d "@0" {} +

# Emit the deterministic interface: canonical rootfs tarball. ($out/esp was
# already populated above; Nix normalizes its file metadata on store import.)
( cd "$stage" && @gnutar@/bin/tar --numeric-owner --xattrs --acls \
    --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
    -czf "$out/rootfs-staged.tar.gz" . )
