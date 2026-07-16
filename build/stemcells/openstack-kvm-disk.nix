# PHASE 2 (OpenStack/KVM): bootable MBR qcow2 disk from the phase-1 os-image.
# Flake output `noble-stemcell-disk`. Output: $out/root.qcow2
# Two-phase build: Phase A (bootable-rootfs) emits a canonical rootfs tarball +
# staged ESP; Phase B (bootable-disk) assembles them into a deterministic disk.
{ callPackage }:
let
  osImage = callPackage ../rootfs/os-image.nix { };
  mkBootableRootfs = callPackage ./bootable-rootfs.nix { };
  mkBootableDisk = callPackage ./bootable-disk.nix { };
  rootfsTree = mkBootableRootfs { inherit osImage; };
in
mkBootableDisk {
  inherit rootfsTree;
  name = "noble-stemcell";
}
