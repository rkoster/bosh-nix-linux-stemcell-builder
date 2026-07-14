# Hermetic guard: prove no network is reachable before any stage or package
# script runs. This does NOT rely on nix.conf's `sandbox = true` alone -- if
# the sandbox is misconfigured (e.g. built with `--option sandbox false`),
# this turns that into a hard, loud build failure instead of a silent leak.
# The only way artifacts should enter this build is via Nix-tracked inputs.
if timeout 3 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null; then
  echo "HERMETIC VIOLATION: network is reachable inside this build." >&2
  echo "Refusing to continue - stemcell artifacts must come only from Nix-tracked inputs." >&2
  exit 1
fi
