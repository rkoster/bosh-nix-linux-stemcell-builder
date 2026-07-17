# PHASE A (OpenStack/KVM): canonical rootfs tarball + staged ESP from the
# phase-1 os-image. Flake output `noble-stemcell-rootfs`.
# Exposed as its own package so its determinism can be verified directly with
# `nix build .#noble-stemcell-rootfs --rebuild` -- the disk-level --rebuild
# reuses this cached tree and would NOT re-exercise Phase A (RC5/RC7) fixes.
{ callPackage }:
let
  osImage = callPackage ../rootfs/os-image.nix { };
  mkBootableRootfs = callPackage ./bootable-rootfs.nix { };
in
mkBootableRootfs { inherit osImage; }
