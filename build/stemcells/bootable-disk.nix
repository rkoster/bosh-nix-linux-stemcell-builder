# MBR dos-partitioned bootable disk image with dual grub (BIOS + UEFI)
# Runs in a Linux VM sandbox (runInLinuxVM) to:
#  1. Create MBR dos partition table with ESP (0xEF, 48 MiB) and root (0x83)
#  2. Extract osImage rootfs.tar.gz into root partition
#  3. Install dual grub (x86_64-efi + i386-pc) with exact BOSH kernel cmdline
#  4. Convert raw disk to the requested format
# Output: $out/root.<format> (root.qcow2 by default, root.img for raw)
{
  vmTools,
  stdenv,
  lib,
  systemdMinimal,
  util-linux,
  dosfstools,
  e2fsprogs,
  qemu,
  gnutar,
  replaceVars,
  callPackage,
}:
let
  mkVmImage = callPackage ../lib/mkVmImage.nix { };
in
{
  osImage,
  name ? "noble-stemcell",
  size ? 2560,
  diskFormat ? "qcow2",
}:
let
  diskExt = if diskFormat == "qcow2" then "qcow2" else "img";
in
mkVmImage {
  inherit name size;

  buildCommand = builtins.readFile (
    replaceVars ./bootable-disk.sh {
      inherit
        util-linux
        dosfstools
        e2fsprogs
        qemu
        gnutar
        systemdMinimal
        ;
      osImage = "${osImage}";
      inherit diskFormat;
      diskOutput = "root.${diskExt}";
    }
  );

  nativeBuildInputs = [
    systemdMinimal
    util-linux
    dosfstools
    e2fsprogs
    qemu
    gnutar
  ];
}
