#!/bin/bash
set -eu

# $root is exported by build/rootfs/apply-stages.nix (the rootfs tree target).
# shellcheck disable=SC2154

# Configure OpenStack agent settings. The agent config lives at
# /var/vcap/bosh/agent.json inside the rootfs tree ("$root").
mkdir -p "$root/var/vcap/bosh"
cp "$STAGE_DIR"/agent.json "$root/var/vcap/bosh/agent.json"
