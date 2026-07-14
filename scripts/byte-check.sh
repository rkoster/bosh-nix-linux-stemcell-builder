#!/usr/bin/env bash
# Same-host double-build reproducibility gate.
# Builds <target> twice from two separate .git-free `path:` copies of the repo
# (distinct source store paths force Nix to actually rebuild instead of reusing
# cache), resolves <artifact-glob> inside each output, and compares sha256.
# On mismatch, runs diffoscope to localize the differing bytes and exits 1.
#
# Usage: scripts/byte-check.sh <flake-target> <artifact-glob-relative-to-out>
#   e.g. scripts/byte-check.sh os-image 'rootfs.tar.gz'
#        scripts/byte-check.sh noble-stemcell-disk 'root.qcow2'
#        scripts/byte-check.sh noble-stemcell 'bosh-stemcell-*.tgz'
set -euo pipefail

target="${1:?usage: byte-check.sh <target> <artifact-glob>}"
artifact_glob="${2:?usage: byte-check.sh <target> <artifact-glob>}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

build_once() {
  local scratch out
  scratch="$(mktemp -d /tmp/opencode/byte-check.XXXXXX)"
  cp -a "$repo_root/." "$scratch/src"
  rm -rf "$scratch/src/.git"
  out="$(nix build --no-link --print-out-paths "path:$scratch/src#$target")"
  rm -rf "$scratch"
  printf '%s\n' "$out"
}

resolve_artifact() {
  local out="$1" match
  # $artifact_glob is an intentional shell glob pattern (e.g. 'bosh-stemcell-*.tgz');
  # quoting it would break expansion, so disable the quoting/ls warnings below.
  # shellcheck disable=SC2012,SC2086
  match=$(cd "$out" && ls -1 $artifact_glob 2>/dev/null | head -1 || true)
  if [ -z "$match" ]; then
    echo "ERROR: no artifact matching '$artifact_glob' in $out" >&2
    exit 2
  fi
  printf '%s/%s\n' "$out" "$match"
}

echo "== build A ($target) =="
outA="$(build_once)"
artA="$(resolve_artifact "$outA")"
echo "== build B ($target) =="
outB="$(build_once)"
artB="$(resolve_artifact "$outB")"

shaA="$(sha256sum "$artA" | cut -d' ' -f1)"
shaB="$(sha256sum "$artB" | cut -d' ' -f1)"
echo "A: $shaA  $artA"
echo "B: $shaB  $artB"

if [ "$shaA" = "$shaB" ]; then
  echo "REPRODUCIBLE: $target ($artifact_glob) is byte-identical"
  exit 0
fi

echo "NOT REPRODUCIBLE: sha256 differs; running diffoscope" >&2
diffoscope "$artA" "$artB" || true
exit 1
