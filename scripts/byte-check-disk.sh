#!/usr/bin/env bash
# L2 gate: the disk root.qcow2 must be byte-identical across two
# same-host rebuilds. Delegates to the generic double-build gate.
set -euo pipefail
exec "$(dirname "$0")/byte-check.sh" noble-stemcell-disk 'root.qcow2'
