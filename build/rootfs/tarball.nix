# Emits the deb closure as a rootfs TARBALL ($out/rootfs.tar.gz), not a disk image.
# Reuses the usrmerge-safe fillDiskWithDebs VM (poc/lib/fill-disk-usrmerge.nix); the only
# difference is the tail: after dpkg install + postInstall, unmount the bind mounts and
# `tar` /mnt into $out instead of keeping the ext4 disk. No grub, no partitions.
{ callPackage, lib, util-linux, e2fsprogs, gnutar, gzip, bash }:
let
  inherit (callPackage ./fill-disk-usrmerge.nix { }) makeImageFromDebDist;
in
{ aptPins, packages, size ? 16384, seedStartStopDaemon ? true }:
makeImageFromDebDist {
  inherit (aptPins) name fullName urlPrefix packagesLists;
  inherit packages size;

  # Since we override createRootFS, we must include the full setup (mirror the default but
  # with the seed for start-stop-daemon at /usr/sbin, which is in a usrmerged location).
  createRootFS = ''
    mkdir /mnt
    ${e2fsprogs}/bin/mkfs.ext4 /dev/vda
    ${util-linux}/bin/mount -t ext4 /dev/vda /mnt

    if test -e /mnt/.debug; then
      exec ${bash}/bin/sh
    fi
    touch /mnt/.debug

    mkdir /mnt/proc /mnt/dev /mnt/sys
  '' + lib.optionalString seedStartStopDaemon ''
    mkdir -p /mnt/usr/sbin
    printf '#!/bin/true\n' > /mnt/usr/sbin/start-stop-daemon
    chmod 755 /mnt/usr/sbin/start-stop-daemon
  '';

  # postInstall runs before fillDiskWithDebs unmounts the bind mounts.
  # We just tar the rootfs; the bind mounts (inst, proc, dev) will be unmounted
  # by fillDiskWithDebs after we return.
  postInstall = ''
    mkdir -p $out
    ${gnutar}/bin/tar --numeric-owner --one-file-system \
      -C /mnt -cf - . | ${gzip}/bin/gzip -1 > $out/rootfs.tar.gz
  '';
}
