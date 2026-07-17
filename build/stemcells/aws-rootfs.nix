# PHASE A (AWS): canonical rootfs tarball + staged ESP from the phase-1 AWS
# os-image. Flake output `noble-stemcell-aws-rootfs`.
# Exposed as its own package so its determinism can be verified directly with
# `nix build .#noble-stemcell-aws-rootfs --rebuild` -- the disk-level --rebuild
# reuses this cached tree and would NOT re-exercise Phase A (RC5/RC7) fixes.
{ callPackage }:
let
  osImage = callPackage ../rootfs/os-image.nix { infrastructure = "aws"; };
  mkBootableRootfs = callPackage ./bootable-rootfs.nix { };
in
mkBootableRootfs {
  inherit osImage;
  name = "noble-stemcell-aws-rootfs";
}
