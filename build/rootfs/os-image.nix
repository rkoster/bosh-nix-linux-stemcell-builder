# PHASE 1 OS image: fold every config stage onto the noble rootfs closure.
# The ordered stage list lives in ../stages/default.nix.
# `infrastructure` selects the IaaS-specific stages; the base deb closure is
# infrastructure-agnostic and shared/cached.
{
  callPackage,
  infrastructure ? "openstack",
  release ? "noble",
}:
let
  desc = import ../ubuntu/release.nix { inherit release; };
  applyStages = callPackage ./apply-stages.nix { };
  base = callPackage ./rootfs.nix { inherit release; };
  stages = callPackage ../stages { inherit infrastructure release; };
in
applyStages {
  inherit base stages;
  osVersion = desc.osVersion;
}
