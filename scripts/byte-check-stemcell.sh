#!/usr/bin/env bash
# L3 gate: the stemcell bosh-stemcell-*.tgz must be byte-identical across two
# same-host rebuilds. Delegates to the generic double-build gate.
set -euo pipefail
exec "$(dirname "$0")/byte-check.sh" noble-stemcell 'bosh-stemcell-*.tgz'
