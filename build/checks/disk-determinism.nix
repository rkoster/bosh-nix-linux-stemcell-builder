# Determinism guard for the deterministic disk-image refactor.
#
# Emits the assembled disk image's sha256 into $out. The guard's whole point is
# to make byte drift fail LOUDLY: because this derivation depends on the disk
# derivation, running `nix build <check> --rebuild` forces a real rebuild of the
# disk and Nix compares the two outputs. Any non-deterministic byte (RC1-RC6
# regression) makes the disk `--rebuild` fail, which fails this check.
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
