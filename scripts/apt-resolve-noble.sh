#!/usr/bin/env bash
# Computes apt's resolved install set for the same top-level packages, inside a
# throwaway noble container, to compare against the Nix resolver's closure.
set -euo pipefail

PKGS="$(nix eval --impure --raw --expr '
  builtins.concatStringsSep " " (import ./poc/lib/noble-packages.nix)
')"
# Read the SAME boot-essentials list the Nix image uses, so the comparison feeds
# apt exactly the top-level packages the assembler adds on top of the base.
BOOT="$(nix eval --impure --raw --expr '
  builtins.concatStringsSep " " (import ./poc/lib/boot-packages.nix).bootEssentials
')"

docker run --rm ubuntu:noble bash -c "
  set -e
  apt-get update -qq
  apt-get install -y --no-install-recommends --print-uris $PKGS $BOOT \
    | grep -oP \"'[^']+\\.deb'\" | sed \"s:.*/::;s:_.*::\" | sort -u
" > /tmp/apt-closure.txt
wc -l /tmp/apt-closure.txt
