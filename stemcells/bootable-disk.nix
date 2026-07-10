# MBR dos-partitioned bootable qcow2 disk image with dual grub (BIOS + UEFI)
# Runs in a Linux VM sandbox (runInLinuxVM) to:
#  1. Create MBR dos partition table with ESP (0xEF, 48 MiB) and root (0x83)
#  2. Extract osImage rootfs.tar.gz into root partition
#  3. Install dual grub (x86_64-efi + i386-pc) with exact BOSH kernel cmdline
#  4. Convert raw disk to qcow2
# Output: $out/root.qcow2
{
  vmTools
, stdenv
, lib
, systemdMinimal
, util-linux
, dosfstools
, e2fsprogs
, qemu
, gnutar
, replaceVars
}:
{ osImage, name ? "noble-stemcell", size ? 2560 }:

vmTools.runInLinuxVM (stdenv.mkDerivation {
  inherit name;
  
  preVM = vmTools.createEmptyImage { inherit size; fullName = name; };

  buildCommand = builtins.readFile (replaceVars ./bootable-disk.sh {
    inherit util-linux dosfstools e2fsprogs qemu gnutar systemdMinimal;
    osImage = "${osImage}";
  });
  
  nativeBuildInputs = [ systemdMinimal util-linux dosfstools e2fsprogs qemu gnutar ];
})
