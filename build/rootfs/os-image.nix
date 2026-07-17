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
  applyStages = callPackage ./apply-stages.nix { };
  base = callPackage ./rootfs.nix { inherit release; };
  # TODO(Task 7): pass `release` to ../stages once stages/default.nix accepts it.
  stages = callPackage ../stages { inherit infrastructure; };
in
# TODO(Task 7): thread osVersion (from ../ubuntu/release.nix) once apply-stages.nix accepts it.
applyStages { inherit base stages; }
