# Determinism guard for the deterministic disk-image refactor.
#
# Emits a built artifact's sha256 into $out as a stable, inspectable fingerprint
# (works for the whole-disk image or the Phase A rootfs tarball). Building this
# check (`nix flake check` or `nix build .#checks.<system>.*-determinism-*`)
# forces the artifact to be built and records its content hash, which you can
# compare across independent builds or environments to detect drift.
#
# IMPORTANT: `nix build <this-check> --rebuild` only re-runs the sha256sum step
# and REUSES the cached artifact -- Nix's --rebuild rebuilds only the requested
# top-level derivation, not its dependencies. The genuine same-machine byte
# determinism gate is therefore run against the PACKAGES directly. Because the
# disk build reuses the cached Phase A rootfs, BOTH layers must be rebuilt to
# cover all root causes (RC1-RC4/RC6 live in the disk; RC5/RC7 live in Phase A):
#
#   nix build .#noble-stemcell-rootfs     --rebuild   # Phase A (RC5/RC7)
#   nix build .#noble-stemcell-aws-rootfs --rebuild
#   nix build .#noble-stemcell-disk       --rebuild   # Phase B (RC1-RC4/RC6)
#   nix build .#noble-stemcell-aws-disk   --rebuild
#
# All must exit 0 with no "output differs"; a regression fails there.
#
# Usage (see flake.nix checks): pass the package and its output filename.
{
  runCommand,
  artifact,
  file,
}:
runCommand "determinism-${artifact.name}" { } ''
  sha256sum ${artifact}/${file} | cut -d' ' -f1 > "$out"
''
