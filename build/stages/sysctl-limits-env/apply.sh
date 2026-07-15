#!/bin/bash
set -eu

# Configure kernel parameters and resource limits
cp "$STAGE_DIR"/60-bosh-sysctl.conf /etc/sysctl.d/60-bosh-sysctl.conf
cp "$STAGE_DIR"/60-bosh-sysctl-neigh-fix.conf /etc/sysctl.d/60-bosh-sysctl-neigh-fix.conf
sysctl -p /etc/sysctl.d/60-bosh-sysctl.conf >/dev/null 2>&1
