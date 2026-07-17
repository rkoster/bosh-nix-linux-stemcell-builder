# PHASE A of the deterministic disk-image refactor.
# Runs in a Linux VM sandbox (runInLinuxVM) to generate all root-fs *files*
# (initramfs, grub.cfg, i386-pc modules + core.img, EFI binary) via a chroot,
# canonicalize them (wipe volatile state, pin mtimes), and emit them as a
# byte-deterministic canonical tarball. NO partitioning, mkfs, mount of a
# target fs, or qemu-img conversion happens here -- that is Phase B.
#
# Output:
#   $out/rootfs-staged.tar.gz  canonical root tree (--numeric-owner --xattrs
#                              --acls, so non-root ownership + setuid survive)
#   $out/esp/                  staged EFI System Partition tree (BOOTX64.EFI)
{
  systemdMinimal,
  util-linux,
  dosfstools,
  e2fsprogs,
  gnutar,
  replaceVars,
  callPackage,
}:
let
  mkVmImage = callPackage ../lib/mkVmImage.nix { };
in
{
  osImage,
  name ? "noble-stemcell-rootfs",
  size ? 2560,
}:
mkVmImage {
  inherit name size;

  # The createEmptyImage/preVM scratch disk lands at $out/disk-image.qcow2. It
  # is the non-deterministic ext4/vfat working disk (UUIDs + block layout +
  # ephemeral state) and is NOT part of the deterministic interface, so delete
  # it on the host after qemu exits -- otherwise it breaks `nix build --rebuild`.
  postVM = ''
    rm -f $out/disk-image.qcow2
  '';

  buildCommand = builtins.readFile (
    replaceVars ./bootable-rootfs.sh {
      inherit
        util-linux
        dosfstools
        e2fsprogs
        gnutar
        systemdMinimal
        ;
      osImage = "${osImage}";
    }
  );

  nativeBuildInputs = [
    systemdMinimal
    util-linux
    dosfstools
    e2fsprogs
    gnutar
  ];
}
