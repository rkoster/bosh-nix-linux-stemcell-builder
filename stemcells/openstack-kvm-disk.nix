# Entry point: Build a bootable MBR qcow2 stemcell disk image for OpenStack/KVM
# Usage: nix build ./poc#noble-stemcell-disk -L
# Output: ./result/root.qcow2
{ callPackage, pkgs }:

let
  osImage = callPackage ./os-image.nix { };
  mkBootableDisk = callPackage ../lib/mk-bootable-disk.nix { };
in
mkBootableDisk {
  inherit osImage;
  name = "noble-stemcell";
}
