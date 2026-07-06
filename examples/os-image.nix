# Phase-1 OS image: fold every config overlay onto the noble-rootfs closure.
# Overlays are added task-by-task; the list order mirrors ubuntu_os_stages where it matters
# (users before anything asserting group membership; ssh after base packages).
{ callPackage, lib }:
let
  stageAssets = callPackage ../lib/stage-assets.nix { };
  applyOverlay = callPackage ../lib/mk-overlay.nix { };
  base = callPackage ./noble-rootfs.nix { };

  overlays = [
    (import ../lib/overlays/ssh.nix { inherit stageAssets; })
  ];

  final = lib.foldl (acc: ov: applyOverlay {
    base = acc; inherit (ov) name script;
  }) base overlays;
in
# Re-expose as os-image.tgz for the oracle harness.
final
