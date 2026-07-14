# PHASE 1 OS image: fold every config stage onto the noble rootfs closure.
# The ordered stage list lives in ../stages/default.nix.
{ callPackage }:
let
  applyStages = callPackage ./apply-stages.nix { };
  base = callPackage ./rootfs.nix { };
  stages = callPackage ../stages/default.nix { };
in
applyStages { inherit base stages; }
