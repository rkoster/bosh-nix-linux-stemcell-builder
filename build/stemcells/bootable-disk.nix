# PHASE B of the deterministic disk-image refactor.
# Runs in a Linux VM sandbox (runInLinuxVM) AS REAL ROOT to assemble the final
# bootable MBR disk OFFLINE and DETERMINISTICALLY from the Phase A staging
# tarball (rootfsTree/rootfs-staged.tar.gz) + staged ESP tree (rootfsTree/esp):
#  1. Fixed-size whole-disk raw with a FIXED MBR disk id (0x44444444)
#  2. mkfs.ext4 -d (offline, under faketime) for a deterministic root fs
#  3. mkfs.vfat -i + mcopy (offline, SOURCE_DATE_EPOCH) for a deterministic ESP
#  4. grub-bios-setup to embed BIOS grub, then qemu-img convert
# Real root (NOT fakeroot) is required to preserve non-root ownerships +
# setuid/setgid + security.capability xattrs; faketime pins fs timestamps.
# Output: $out/root.<format> (root.qcow2 by default, root.img for raw)
{
  vmTools,
  stdenv,
  util-linux,
  dosfstools,
  e2fsprogs,
  libfaketime,
  mtools,
  grub2,
  qemu,
  gnutar,
  replaceVars,
  callPackage,
}:
let
  mkVmImage = callPackage ../lib/mkVmImage.nix { };
in
{
  rootfsTree,
  name ? "noble-stemcell",
  size ? 2560,
  diskFormat ? "qcow2",
}:
let
  diskExt = if diskFormat == "qcow2" then "qcow2" else "img";
in
mkVmImage {
  inherit name;

  # The target disk is `size` MiB (@sizeMib@), but Phase B needs scratch room
  # for the extracted root tree + whole-disk raw + root/esp partition images
  # simultaneously. Give the VM's /dev/vda scratch disk 4x headroom.
  size = size * 4;

  # The createEmptyImage/preVM scratch disk lands at $out/disk-image.qcow2 (the
  # non-deterministic working disk). Delete it on the host after qemu exits so
  # `nix build --rebuild` stays clean.
  postVM = ''
    rm -f $out/disk-image.qcow2
  '';

  buildCommand = builtins.readFile (
    replaceVars ./bootable-disk.sh {
      inherit
        util-linux
        dosfstools
        e2fsprogs
        libfaketime
        mtools
        grub2
        qemu
        gnutar
        ;
      rootfsTree = "${rootfsTree}";
      sizeMib = toString size;
      inherit diskFormat;
      diskOutput = "root.${diskExt}";
    }
  );

  nativeBuildInputs = [
    util-linux
    dosfstools
    e2fsprogs
    libfaketime
    mtools
    grub2
    qemu
    gnutar
  ];
}
