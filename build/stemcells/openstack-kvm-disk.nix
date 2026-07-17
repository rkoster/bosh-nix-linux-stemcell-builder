# PHASE 2 (OpenStack/KVM): bootable MBR qcow2 disk from the phase-1 os-image.
# Flake output `noble-stemcell-disk`. Output: $out/root.qcow2
# Two-phase build: Phase A (bootable-rootfs) emits a canonical rootfs tarball +
# staged ESP; Phase B (bootable-disk) assembles them into a deterministic disk.
{
  callPackage,
  release ? "noble",
}:
let
  desc = import ../ubuntu/release.nix { inherit release; };
  infra = import ../infra { infrastructure = "openstack"; };
  mkBootableDisk = callPackage ./bootable-disk.nix { };
  rootfsTree = callPackage ./openstack-kvm-rootfs.nix { inherit release; };
in
mkBootableDisk {
  inherit rootfsTree;
  name = "${desc.release}-stemcell${infra.nameSuffix}";
  diskFormat = infra.diskFormat;
}
