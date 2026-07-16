# Determinism guard for the deterministic disk-image refactor.
#
# Emits the assembled disk image's sha256 into $out as a stable, inspectable
# fingerprint of the built disk. Building this check (`nix flake check` or
# `nix build .#checks.<system>.disk-determinism-*`) forces the disk to be built
# and records its content hash, which you can compare across independent builds
# or environments to detect drift.
#
# IMPORTANT: `nix build <this-check> --rebuild` only re-runs the sha256sum step
# and REUSES the cached disk -- Nix's --rebuild rebuilds only the requested
# top-level derivation, not its dependencies. The genuine same-machine byte
# determinism gate is therefore run against the DISK packages directly:
#
#   nix build .#noble-stemcell-disk     --rebuild   # OpenStack qcow2
#   nix build .#noble-stemcell-aws-disk --rebuild   # AWS raw
#
# Both must exit 0 with no "output differs"; a regression (RC1-RC6) fails there.
#
# Usage (see flake.nix checks): pass the disk package and its output filename.
{
  runCommand,
  disk,
  diskFile,
}:
runCommand "disk-determinism-${disk.name}" { } ''
  sha256sum ${disk}/${diskFile} | cut -d' ' -f1 > "$out"
''
