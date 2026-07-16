# shellcheck shell=bash
# No shebang: this file is not executed standalone. It is embedded into the
# VM builder script via `replaceVars` (bootable-disk.nix), which already
# supplies its own shebang/bash invocation.
#
# PHASE B of the deterministic disk-image refactor: assemble the final bootable
# disk OFFLINE and DETERMINISTICALLY from the Phase A staging tarball
# (@rootfsTree@/rootfs-staged.tar.gz) and staged ESP tree (@rootfsTree@/esp).
# NO chroot, NO live mount of the target fs, NO wall-clock: filesystems are
# populated from directories with `mkfs.ext4 -d` / `mcopy` under faketime, then
# laid into a fixed-layout, fixed-MBR-id whole-disk raw image and converted.
#
# Runs as REAL root inside runInLinuxVM (required so the tarball extraction and
# `mkfs.ext4 -d` preserve the non-root ownerships + setuid/setgid + xattrs;
# fakeroot was proven to MASK security.capability xattrs, so it is NOT used).
#
# $out is the standard Nix build output path, provided by the enclosing
# derivation's builder environment, not assigned in this fragment.
# shellcheck disable=SC2154
set -exuo pipefail

export SOURCE_DATE_EPOCH=0

# The VM root is a small tmpfs (memSize RAM), far too small to hold the several
# GiB of working files (extracted tree + whole-disk raw + partition images), so
# back the scratch work with the attached /dev/vda disk. mkVmImage sizes
# /dev/vda LARGER than the target disk (see bootable-disk.nix) precisely so all
# of these fit. Nothing about this scratch fs leaks into the deterministic
# output: the target image is a plain file we build byte-by-byte below.
@e2fsprogs@/bin/mkfs.ext4 -q -F /dev/vda
work=/build/work
mkdir -p "$work"
@util-linux@/bin/mount -t ext4 /dev/vda "$work"

scratch="$work/rootfs"   # extracted Phase A root tree
raw="$work/disk.raw"     # whole-disk target image (assembled in place)
rootimg="$work/root.img" # ext4 root partition image
espimg="$work/esp.img"   # vfat ESP partition image
mkdir -p "$scratch"

# Fixed partition geometry (identical to the current single-pass build).
esp_start=2048
esp_sectors=98304
root_start=100352
disk_sectors=$(( @sizeMib@ * 1024 * 1024 / 512 ))
root_bytes=$(( (disk_sectors - root_start) * 512 ))

# 2. Fixed-size whole-disk raw image.
truncate -s $(( @sizeMib@ * 1024 * 1024 )) "$raw"

# 3. MBR dos partition table with FIXED disk identifier (RC1). Same layout as
#    today: ESP p1 (0xEF, bootable) then root p2 (0x83).
@util-linux@/bin/sfdisk "$raw" <<EOF
label: dos
label-id: 0x44444444
unit: sectors

start=${esp_start}, size=${esp_sectors}, type=ef, bootable
start=${root_start}, type=83
EOF

# 4. Extract the Phase A canonical tarball as root into the scratch dir. This
#    preserves numeric ownerships, ACLs and xattrs (incl. security.capability).
@gnutar@/bin/tar --numeric-owner --xattrs --acls \
  -xzf @rootfsTree@/rootfs-staged.tar.gz -C "$scratch"

# 5. Populate the root ext4 OFFLINE from the directory (RC2/RC3/RC6). Building
#    from a directory with `mkfs.ext4 -d` gives a deterministic block layout
#    (no live kernel allocator, no mount), and faketime pins the superblock
#    timestamps. Flags match today's build (-L root, fixed -U, hash_seed,
#    root_owner, ^dir_index).
@libfaketime@/bin/faketime -f "1970-01-01 00:00:01" \
  @e2fsprogs@/bin/mkfs.ext4 -q -F -L root \
    -U 44444444-4444-4444-4444-444444444444 \
    -E hash_seed=44444444-4444-4444-4444-444444444444,root_owner=0:0 \
    -O ^dir_index \
    -d "$scratch" "$rootimg" "$(( root_bytes / 1024 ))k"

# 6. Build the ESP vfat image OFFLINE (RC4). mkfs.vfat -i fixes the volume id;
#    mcopy honors SOURCE_DATE_EPOCH for directory-entry timestamps.
truncate -s $(( esp_sectors * 512 )) "$espimg"
@dosfstools@/bin/mkfs.vfat -F32 -n ESP -i 44444444 "$espimg"
( cd @rootfsTree@/esp && @mtools@/bin/mcopy -i "$espimg" -s -Q ./* :: )

# 7. Assemble the partition images into the whole disk at their sector offsets.
dd if="$espimg" of="$raw" bs=512 seek=${esp_start} conv=notrunc
dd if="$rootimg" of="$raw" bs=512 seek=${root_start} conv=notrunc

# 8. Embed BIOS grub (boot.img in the MBR + core.img in the post-MBR gap) using
#    the i386-pc modules from the extracted tarball. grub-bios-setup wants a
#    real block device to probe geometry, so attach the raw image via a loop
#    device (we are root in the VM). This step is deterministic: it copies the
#    fixed core.img/boot.img produced in Phase A.
loop=$(@util-linux@/bin/losetup -Pf --show "$raw")
@grub2@/bin/grub-bios-setup \
  --directory="$scratch/boot/grub/i386-pc" \
  --device-map=/dev/null \
  "$loop"
@util-linux@/bin/losetup -d "$loop"

# 9. Convert the assembled raw image to the requested output format.
mkdir -p "$out"
@qemu@/bin/qemu-img convert -f raw -O @diskFormat@ "$raw" "$out/@diskOutput@"
@qemu@/bin/qemu-img info "$out/@diskOutput@"

# Release the scratch fs so it does not linger mounted at VM shutdown.
@util-linux@/bin/umount "$work" 2>/dev/null || true
