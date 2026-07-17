# PHASE 2 (AWS): bootable MBR raw disk from the phase-1 AWS os-image.
# Flake output `noble-stemcell-aws-disk`. Output: $out/root.img
# Two-phase build: Phase A (bootable-rootfs) emits a canonical rootfs tarball +
# staged ESP; Phase B (bootable-disk) assembles them into a deterministic disk.
{ callPackage }:
let
  mkBootableDisk = callPackage ./bootable-disk.nix { };
  rootfsTree = callPackage ./aws-rootfs.nix { };
in
mkBootableDisk {
  inherit rootfsTree;
  name = "noble-stemcell-aws";
  diskFormat = "raw";
}
