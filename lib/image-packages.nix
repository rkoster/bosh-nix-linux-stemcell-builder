# Single source of truth for the full top-level package set installed into the
# Noble image. Imported by BOTH noble-closure.nix (resolver-fidelity gate) and
# noble-bootable.nix (the image), so the gate validates EXACTLY what ships.
# Returns a plain list of package-name strings (what makeImageFromDebDist and
# debClosureGenerator expect for `packages`).
{ lib, callPackage }:

let
  noble = callPackage ./noble-distro.nix { };
  bosh = import ./noble-packages.nix;
  boot = import ./boot-packages.nix;
in
lib.filter (p: !lib.elem p boot.dropFromBase) noble.basePackages
++ boot.bootEssentials
++ bosh
