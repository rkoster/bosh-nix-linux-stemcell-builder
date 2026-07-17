# PHASE 1 base: the deb closure as a rootfs tarball ($out/rootfs.tar.gz),
# BEFORE config stages. Flake output `noble-rootfs`. os-image.nix folds the
# stages onto this.
{
  callPackage,
  release ? "noble",
}:
let
  aptPins = callPackage ../ubuntu/apt-pins.nix { inherit release; };
  mkRootfsTarball = callPackage ./tarball.nix { };
in
mkRootfsTarball {
  inherit aptPins;
  packages = (callPackage ../ubuntu/deb-sets.nix { inherit release; }).image;
  size = 16384;
}
