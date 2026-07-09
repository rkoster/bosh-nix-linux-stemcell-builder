# Debootstrap-faithful base seed: every Priority:required and Essential:yes
# package in the distro's `main` Packages index.
#
# WHY THIS EXISTS
# ---------------
# vmTools.debClosureGenerator only resolves the `Depends:` closure of the seed
# package list. It does NOT include Priority:required / Essential:yes packages
# unless something explicitly Depends: on them. But Debian policy says essential
# packages are ALWAYS present, so packages routinely omit dependencies on them
# (e.g. nothing Depends: on `hostname`, yet the BOSH agent calls `hostname` at
# bootstrap and crashes without it).
#
# `debootstrap` handles this by seeding its base with the full required+essential
# set FIRST, then resolving. This module reproduces that step deterministically:
#
#   1. A decompress-only derivation turns the sha256-pinned Packages.xz (main)
#      into plain text. This is the ONLY impurity-free step pure Nix cannot do
#      itself (xz), and its output is content-addressed by the pinned hash.
#   2. The name list is then built by a PURE Nix expression (lib string ops) that
#      parses the stanzas and selects Priority:required / Essential:yes. No awk,
#      no sort — the result is a deterministic function of the pinned index.
#
# Derived from the index rather than hand-maintained, so it cannot drift from the
# archive. The readFile step is import-from-derivation, exactly like
# debClosureGenerator itself.
{ lib, runCommand, xz, noble }:

let
  # required/essential metadata for the base system lives entirely in `main`.
  # noble-distro.nix lists the indices in component order: main, universe,
  # multiverse — so the first entry is main. Scanning only main also keeps
  # eval fast (universe/multiverse are an order of magnitude larger).
  mainIndex = builtins.head noble.packagesLists;

  # Decompress-only derivation. Deterministic: its single input is the
  # sha256-pinned Packages.xz fetchurl output.
  indexText = runCommand "noble-main-packages-index" { } ''
    ${xz}/bin/xz -dc ${mainIndex} > $out
  '';

  # --- Pure-Nix deterministic parse of the plaintext index ---
  raw = builtins.readFile indexText;

  # Debian control files separate package stanzas with a blank line.
  stanzas = lib.splitString "\n\n" raw;

  # A stanza is part of the base seed iff it declares Priority: required or
  # Essential: yes. Prefix "\n" so the match anchors to a line start even for
  # the stanza's first line.
  isSeed = s:
    let s' = "\n" + s;
    in lib.hasInfix "\nPriority: required" s'
       || lib.hasInfix "\nEssential: yes" s';

  # Extract the value of the `Package:` field from a stanza (or null).
  nameOf = s:
    let
      pkgLines = lib.filter (lib.hasPrefix "Package: ") (lib.splitString "\n" s);
    in
      if pkgLines == [ ] then null
      else lib.removePrefix "Package: " (lib.head pkgLines);

  names = lib.filter (n: n != null) (map nameOf (lib.filter isSeed stanzas));
in
# unique + sorted → stable, deterministic seed list.
lib.sort (a: b: a < b) (lib.unique names)
