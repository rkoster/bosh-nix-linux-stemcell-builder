# Phase-1 package closure as a rootfs tarball. Same package set + distro coords as the
# M1 boot gate (poc/examples/noble-bootable.nix), but output is $out/rootfs.tar.gz.
{ callPackage }:
let
  noble = callPackage ../lib/noble-distro.nix { };
  mkRootfsTarball = callPackage ../lib/mk-rootfs-tarball.nix { };
in
mkRootfsTarball {
  inherit noble;
  packages = callPackage ../lib/image-packages.nix { };
  size = 16384;
}
