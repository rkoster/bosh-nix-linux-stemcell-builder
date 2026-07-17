# PHASE 2 (AWS): bootable MBR raw disk from the phase-1 AWS os-image.
# Flake output `noble-stemcell-aws-disk`. Output: $out/root.img
# Two-phase build: Phase A (bootable-rootfs) emits a canonical rootfs tarball +
# staged ESP; Phase B (bootable-disk) assembles them into a deterministic disk.
{
  callPackage,
  release ? "noble",
}:
let
  desc = import ../ubuntu/release.nix { inherit release; };
  infra = import ../infra { infrastructure = "aws"; };
  mkBootableDisk = callPackage ./bootable-disk.nix { };
  rootfsTree = callPackage ./aws-rootfs.nix { inherit release; };
in
mkBootableDisk {
  inherit rootfsTree;
  name = "${desc.release}-stemcell${infra.nameSuffix}";
  diskFormat = infra.diskFormat;
}
