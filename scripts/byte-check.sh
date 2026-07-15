#!/usr/bin/env bash
# Same-host reproducibility gate.
#
# Uses `nix build --rebuild`, which re-runs an already-built derivation and
# compares the result against the store path bit-for-bit, keeping the differing
# output at "<out>.check" on mismatch. This is the *real* determinism check.
#
# NOTE: the previous implementation copied the repo to two fresh `path:`
# locations expecting distinct source hashes to force two rebuilds. That does
# NOT work: Nix content-addresses source files (mtimes normalized to epoch 1),
# so identical content yields the same derivation hash and Nix simply returns
# the cached output. Both "builds" resolved to the same store path, so the gate
# reported REPRODUCIBLE unconditionally (a false positive). `--rebuild` is the
# correct primitive.
#
# Usage: scripts/byte-check.sh <flake-target> <artifact-glob-relative-to-out>
#   e.g. scripts/byte-check.sh os-image 'rootfs.tar.gz'
#        scripts/byte-check.sh noble-stemcell-disk 'root.qcow2'
#        scripts/byte-check.sh noble-stemcell 'bosh-stemcell-*.tgz'
set -euo pipefail

target="${1:?usage: byte-check.sh <target> <artifact-glob>}"
artifact_glob="${2:?usage: byte-check.sh <target> <artifact-glob>}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

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

echo "== build ($target) =="
out="$(nix build --no-link --print-out-paths "$repo_root#$target")"
echo "out: $out"

echo "== rebuild + compare ($target) =="
# --rebuild re-runs the build and diffs against $out; --keep-failed retains the
# mismatching output at "$out.check" for diffoscope. Capture Nix's real exit
# code (not a pipe's) so the gate result is trustworthy.
set +e
nix build --rebuild --keep-failed --no-link "$repo_root#$target"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  echo "REPRODUCIBLE: $target ($artifact_glob) is byte-identical across rebuilds"
  exit 0
fi

check="${out}.check"
if [ -d "$check" ]; then
  art="$(resolve_artifact "$out")"
  artc="$(resolve_artifact "$check")"
  echo "NOT REPRODUCIBLE: $target differs on rebuild; running diffoscope" >&2
  echo "  A: $art" >&2
  echo "  B: $artc" >&2
  diffoscope "$art" "$artc" || true
else
  echo "NOT REPRODUCIBLE: $target rebuild failed (rc=$rc) and no .check output found" >&2
fi
exit 1
