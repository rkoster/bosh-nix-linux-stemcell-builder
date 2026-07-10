#!/run/current-system/sw/bin/sh
# Build the `os-image` (or given) target through the `path:` fetcher on a
# .git-free copy (the local git+file fetcher is broken on this virtiofs mount)
# and print the sha256 of its rootfs.tar.gz. Used as the byte-identity guard.
set -euo pipefail

target="${1:-os-image}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

scratch="$(mktemp -d /tmp/opencode/byte-check.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT

cp -a "$repo_root/." "$scratch/src"
rm -rf "$scratch/src/.git"

out="$(nix build --no-link --print-out-paths "path:$scratch/src#$target")"
sha256sum "$out/rootfs.tar.gz"
