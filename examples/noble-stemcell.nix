# Entry point: Build a BOSH stemcell tarball for OpenStack/KVM (ubuntu-noble)
# Consumes the bootable qcow2 from Task 2 (noble-stemcell-disk.nix)
# Usage: nix build ./poc#noble-stemcell -L
# Output: ./result/bosh-stemcell-0.0.4-nix-openstack-kvm-ubuntu-noble.tgz
{ callPackage, pkgs }:

let
  # Get the bootable qcow2 disk from Task 2
  bootableDiskDerivation = callPackage ./noble-stemcell-disk.nix { };
  bootableDisk = "${bootableDiskDerivation}/root.qcow2";
  
  # Load the mk-stemcell packaging derivation
  mkStemcell = callPackage ../lib/mk-stemcell.nix { };
in

mkStemcell {
  inherit bootableDisk;
  version = "0.0.4-nix";
  os = "ubuntu";
  osVersion = "noble";
  infrastructure = "openstack";
  hypervisor = "kvm";
}
