#!/usr/bin/env bash
# L1 gate: the os-image rootfs.tar.gz must be byte-identical across two
# same-host rebuilds. Delegates to the generic double-build gate.
set -euo pipefail
exec "$(dirname "$0")/byte-check.sh" os-image 'rootfs.tar.gz'
