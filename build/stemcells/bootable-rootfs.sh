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
# too small to hold the extracted rootfs, so back the staging dir with the
# attached scratch disk (/dev/vda, `size` MiB -- 2560 by default, of which the
# ~2.5 GiB ext4 partition holds the tree with tight headroom). We carve a tiny
# FAT partition (p1) for the EFI grub-install (which insists on a real vfat EFI
# partition) and use the rest (p2, ext4) for the root staging tree. This layout
# is SCRATCH ONLY: nothing from the on-disk block layout leaks into the
# deterministic interface -- determinism comes from canonicalizing the files
# and repacking them with a sorted, mtime-pinned tar (root tree) / copying
# files out ($out/esp) below.
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
# SOURCE_DATE_EPOCH: re-pack the main initramfs cpio with sorted names, pin
# every extracted entry's mtime to @0 (fixes initramfs mtime non-determinism,
# RC5), and gzip -n.
#
# CRITICAL: Ubuntu initrds are MULTI-SEGMENT. One or more *uncompressed* early
# cpio archives (CPU microcode / firmware, magic 070701) are concatenated in
# front of the *compressed* main initramfs (the part that actually contains
# /init and the modules needed to mount root). A naive `cpio -idm < img` reads
# only the FIRST cpio segment (the microcode) and silently stops at its
# TRAILER, discarding every later segment -- including the entire main
# initramfs. The resulting initrd is microcode-only, has no /init, and the
# kernel falls through to its built-in mounter which cannot resolve
# root=UUID=... -> "Waiting <rootdelay> sec" -> panic. This broke boot for
# every image.
#
# Fix: locate the early/main boundary with the same header-walk logic as
# unmkinitramfs(8), keep the early (microcode) bytes VERBATIM -- they are
# already deterministic and re-encoding them risks the microcode loader -- and
# re-pack ONLY the decompressed main initramfs deterministically, then
# concatenate early + normalized-main back together.

# Read an ASCII-hex header field (newc fields are stored as hex text). Returns
# non-zero (no match) when the bytes are not valid hex, e.g. compressed data.
readhex() { dd < "$1" bs=1 skip="$2" count="$3" 2>/dev/null | LANG=C grep -E "^[0-9A-Fa-f]{$3}\$"; }
# True when the byte at the given offset is a zero (cpio archive padding/EOF).
checkzero() { dd < "$1" bs=1 skip="$2" count=1 2>/dev/null | LANG=C grep -q -z '^$'; }
# Byte offset where the compressed main initramfs begins (== total size of all
# leading uncompressed early cpio archives). 0 when there is no early segment.
main_offset() {
  local img=$1 start=0 end magic namesize filesize
  while :; do
    end=$start
    while :; do
      if checkzero "$img" "$end"; then
        end=$((end + 4))
        while checkzero "$img" "$end"; do end=$((end + 4)); done
        break
      fi
      magic=$(readhex "$img" "$end" 6) || break
      { [ "$magic" = 070701 ] || [ "$magic" = 070702 ]; } || break
      namesize=0x$(readhex "$img" $((end + 94)) 8)
      filesize=0x$(readhex "$img" $((end + 54)) 8)
      end=$((end + 110))
      end=$(((end + namesize + 3) & ~3))
      end=$(((end + filesize + 3) & ~3))
    done
    [ "$end" -eq "$start" ] && break
    start=$end
  done
  printf '%s\n' "$start"
}

for img in /boot/initrd.img-*; do
  [ -e "$img" ] || continue
  off=$(main_offset "$img")
  tmpd=$(mktemp -d)
  root="$tmpd/root"
  mkdir -p "$root"
  if [ "$off" -gt 0 ]; then
    # Preserve the uncompressed early (microcode) segment(s) byte-for-byte.
    dd if="$img" of="$tmpd/early.bin" bs=1M iflag=count_bytes count="$off" 2>/dev/null
    dd if="$img" of="$tmpd/main.z"   bs=1M iflag=skip_bytes  skip="$off" 2>/dev/null
  else
    : > "$tmpd/early.bin"
    cp "$img" "$tmpd/main.z"
  fi
  # Decompress the main initramfs by magic (Ubuntu default is gzip). A bare
  # cpio (magic 070701) main is passed through uncompressed.
  magic=$(head -c 4 "$tmpd/main.z" | od -An -tx1 | tr -d ' \n')
  case "$magic" in
    1f8b*)     gzip -d -c "$tmpd/main.z" ;;
    28b52ffd)  zstd -q -d -c "$tmpd/main.z" ;;
    fd377a58*) xz -d -c "$tmpd/main.z" ;;
    30373037*) cat "$tmpd/main.z" ;;
    *) echo "FATAL: unknown main initramfs compression magic '$magic' in $img" >&2; exit 1 ;;
  esac | ( cd "$root" && cpio -idm --quiet )
  # Pin mtimes of all extracted entries before repacking the main.
  find "$root" -mindepth 1 -exec touch --no-dereference -d "@0" {} +
  ( cd "$root" && find . -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z \
      | cpio -o -H newc --quiet -0 --owner=0:0 \
      | gzip -n -9 ) > "$tmpd/main.new.gz"
  # Reassemble: verbatim early segment(s) + deterministically repacked main.
  cat "$tmpd/early.bin" "$tmpd/main.new.gz" > "$img"
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
  --no-floppy /dev/vda

# Assert the BIOS grub artifacts exist. We deliberately do NOT fall back to a
# hand-rolled `grub-mkimage` here: its prefix/module set is NOT guaranteed to
# match what grub-install produces, so a fallback core.img could differ between
# builds (breaking determinism) or embed a wrong prefix (breaking BIOS boot).
# If the tested primary path ever fails, fail LOUDLY rather than emit a
# divergent artifact. (normal.mod is checked too so a partial install -- core.img
# without modules, or vice versa -- cannot silently pass.)
if [ ! -f /boot/grub/i386-pc/core.img ] || [ ! -f /boot/grub/i386-pc/normal.mod ]; then
  echo "FATAL: grub-install did not produce i386-pc/core.img + normal.mod" >&2
  ls -la /boot/grub/i386-pc/ >&2 || true
  exit 1
fi
echo "GRUB_BIOS_PATH=grub-setup-bin-true" > /boot/grub/.bios-path

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
# --xattrs forces PAX format, whose per-entry extended headers otherwise record
# the volatile atime/ctime -- strip them so the tarball is byte-reproducible.
(cd "$stage" && @gnutar@/bin/tar --numeric-owner --xattrs --acls \
  --pax-option='delete=atime,delete=ctime' \
  --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
  -czf "$out/rootfs-staged.tar.gz" .)
