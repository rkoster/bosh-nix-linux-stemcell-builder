# PHASE 2 (AWS): bootable MBR raw disk from the phase-1 AWS os-image.
# Flake output `noble-stemcell-aws-disk`. Output: $out/root.img
{ callPackage }:
let
  osImage = callPackage ../rootfs/os-image.nix { infrastructure = "aws"; };
  mkBootableDisk = callPackage ./bootable-disk.nix { };
in
mkBootableDisk {
  inherit osImage;
  name = "noble-stemcell-aws";
  diskFormat = "raw";
}
