# PHASE 1 OS image: fold every config overlay onto the noble rootfs closure.
# The ordered overlay list lives in ./overlays/default.nix.
{ callPackage }:
let
  applyOverlays = callPackage ./apply-overlays.nix { };
  base = callPackage ./rootfs.nix { };
  overlays = callPackage ./overlays/default.nix { };
in
applyOverlays { inherit base overlays; }
