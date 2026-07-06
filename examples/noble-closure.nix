# Exposes ONLY the debClosureGenerator output (the generated fetchurl-closure .nix)
# for the Noble package set, so we can inspect what the resolver selected without
# building a full disk image. `packages` comes from the shared assembler
# (../lib/image-packages.nix), so this gate resolves EXACTLY the set that
# noble-bootable.nix installs — the two cannot drift.
{ vmTools, callPackage }:

let
  noble = callPackage ../lib/noble-distro.nix { };
  packages = callPackage ../lib/image-packages.nix { };
in
# debClosureGenerator returns a derivation that builds "<name>.nix": a Nix
# expression listing every .deb (with fetchurl) in the resolved closure.
(vmTools.debClosureGenerator {
  name = "ubuntu-24.04-noble-amd64";
  inherit (noble) packagesLists urlPrefix;
  inherit packages;
})
