# PHASE 2 (OpenStack/KVM): bootable MBR qcow2 disk from the phase-1 os-image.
# Flake output `noble-stemcell-disk`. Output: $out/root.qcow2
{ callPackage }:
let
  osImage = callPackage ../rootfs/os-image.nix { };
  mkBootableDisk = callPackage ./bootable-disk.nix { };
in
mkBootableDisk {
  inherit osImage;
  name = "noble-stemcell";
}
