# PHASE 2 (OpenStack/KVM): package the bootable qcow2 into a BOSH stemcell .tgz.
# Flake outputs `noble-stemcell` and `openstack-kvm`.
# Output: $out/bosh-stemcell-<version>-openstack-kvm-ubuntu-noble.tgz
{ callPackage }:
let
  bootableDiskDerivation = callPackage ./openstack-kvm-disk.nix { };
  bootableDisk = "${bootableDiskDerivation}/root.qcow2";
  # Same memoized derivation used inside openstack-kvm-disk.nix; provides the
  # generated stemcell metadata members under ${metadata}/metadata/.
  metadata = callPackage ../rootfs/os-image.nix { };
  mkStemcell = callPackage ./package.nix { };
in
mkStemcell {
  inherit bootableDisk metadata;
  version = "0.0.5-nix";
  os = "ubuntu";
  osVersion = "noble";
  infrastructure = "openstack";
  hypervisor = "kvm";
}
