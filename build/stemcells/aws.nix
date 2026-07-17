# PHASE 2 (AWS): package the bootable raw disk into a BOSH aws-raw stemcell .tgz.
# Flake outputs `aws` and `noble-stemcell-aws`.
# Output: $out/bosh-stemcell-<version>-aws-xen-ubuntu-noble.tgz
{
  callPackage,
  release ? "noble",
}:
let
  infra = import ../infra { infrastructure = "aws"; };
  bootableDiskDerivation = callPackage ./aws-disk.nix { inherit release; };
  bootableDisk = "${bootableDiskDerivation}/${infra.diskFilename}";
  # Same memoized AWS os-image derivation used inside aws-disk.nix; provides the
  # generated stemcell metadata members under ${metadata}/metadata/.
  metadata = callPackage ../rootfs/os-image.nix {
    infrastructure = "aws";
    inherit release;
  };
  mkStemcell = callPackage ./package.nix { };
in
mkStemcell {
  inherit bootableDisk metadata release;
  version = "0.0.5-nix";
  os = "ubuntu";
  infrastructure = "aws";
}
