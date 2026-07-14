# Debootstrap-faithful base seed: every Priority:required and Essential:yes
# package in the distro's `main` Packages index. debClosureGenerator only
# resolves Depends: closures, so essentials with no reverse-dep (e.g. hostname)
# must be seeded explicitly, exactly as debootstrap does.
#
#   1. decompress the sha256-pinned Packages.xz (main) — the one xz step;
#   2. a PURE Nix parse selects Priority:required / Essential:yes stanzas.
# Deterministic function of the pinned index (readFile = IFD, like
# debClosureGenerator itself).
{
  lib,
  runCommand,
  xz,
  aptPins,
}:

let
  mainIndex = builtins.head aptPins.packagesLists;

  indexText = runCommand "noble-main-packages-index" { } ''
    ${xz}/bin/xz -dc ${mainIndex} > $out
  '';

  raw = builtins.readFile indexText;
  stanzas = lib.splitString "\n\n" raw;

  isSeed =
    s:
    let
      s' = "\n" + s;
    in
    lib.hasInfix "\nPriority: required" s' || lib.hasInfix "\nEssential: yes" s';

  nameOf =
    s:
    let
      pkgLines = lib.filter (lib.hasPrefix "Package: ") (lib.splitString "\n" s);
    in
    if pkgLines == [ ] then null else lib.removePrefix "Package: " (lib.head pkgLines);

  names = lib.filter (n: n != null) (map nameOf (lib.filter isSeed stanzas));
in
lib.sort (a: b: a < b) (lib.unique names)
