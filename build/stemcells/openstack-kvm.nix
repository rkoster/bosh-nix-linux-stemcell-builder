# PHASE 2 (OpenStack/KVM): package the bootable qcow2 into a BOSH stemcell .tgz.
# Flake outputs `noble-stemcell` and `openstack-kvm`.
# Output: $out/bosh-stemcell-<version>-openstack-kvm-ubuntu-noble.tgz
{
  callPackage,
  release ? "noble",
}:
let
  infra = import ../infra { infrastructure = "openstack"; };
  bootableDiskDerivation = callPackage ./openstack-kvm-disk.nix { inherit release; };
  bootableDisk = "${bootableDiskDerivation}/${infra.diskFilename}";
  # Same memoized derivation used inside openstack-kvm-disk.nix; provides the
  # generated stemcell metadata members under ${metadata}/metadata/.
  metadata = callPackage ../rootfs/os-image.nix { inherit release; };
  mkStemcell = callPackage ./package.nix { };
in
mkStemcell {
  inherit bootableDisk metadata release;
  version = "0.0.5-nix";
  os = "ubuntu";
  infrastructure = "openstack";
}
