# PHASE 1 base: the Noble deb closure as a rootfs tarball ($out/rootfs.tar.gz),
# BEFORE config overlays. Flake output `noble-rootfs`. os-image.nix folds the
# overlays onto this.
{ callPackage }:
let
  aptPins = callPackage ../ubuntu/apt-pins.nix { };
  mkRootfsTarball = callPackage ./tarball.nix { };
in
mkRootfsTarball {
  inherit aptPins;
  packages = (callPackage ../ubuntu/deb-sets.nix { }).image;
  size = 16384;
}
