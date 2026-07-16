# PHASE 1 OS image: fold every config stage onto the noble rootfs closure.
# The ordered stage list lives in ../stages/default.nix.
# `infrastructure` selects the IaaS-specific stages; the base deb closure is
# infrastructure-agnostic and shared/cached.
{
  callPackage,
  infrastructure ? "openstack",
}:
let
  applyStages = callPackage ./apply-stages.nix { };
  base = callPackage ./rootfs.nix { };
  stages = callPackage ../stages { inherit infrastructure; };
in
applyStages { inherit base stages; }
