# PHASE A (AWS): canonical rootfs tarball + staged ESP from the phase-1 AWS
# os-image. Flake output `noble-stemcell-aws-rootfs`.
# Exposed as its own package so its determinism can be verified directly with
# `nix build .#noble-stemcell-aws-rootfs --rebuild` -- the disk-level --rebuild
# reuses this cached tree and would NOT re-exercise Phase A (RC5/RC7) fixes.
{
  callPackage,
  release ? "noble",
}:
let
  desc = import ../ubuntu/release.nix { inherit release; };
  osImage = callPackage ../rootfs/os-image.nix {
    infrastructure = "aws";
    inherit release;
  };
  mkBootableRootfs = callPackage ./bootable-rootfs.nix { };
in
mkBootableRootfs {
  inherit osImage;
  name = "${desc.release}-stemcell-aws-rootfs";
}
