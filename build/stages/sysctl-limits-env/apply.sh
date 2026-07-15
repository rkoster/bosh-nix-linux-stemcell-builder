#!/bin/bash
set -eu

# $root is exported by build/rootfs/apply-stages.nix (the rootfs tree target).
# shellcheck disable=SC2154

# Configure kernel parameters and resource limits. Targets are written into the
# rootfs tree at "$root"; sysctl values are NOT applied at build time (that would
# affect the build host and is meaningless for an offline rootfs).

# bosh_sysctl: install sysctl drop-ins
mkdir -p "$root/etc/sysctl.d"
cp "$STAGE_DIR"/60-bosh-sysctl.conf "$root/etc/sysctl.d/60-bosh-sysctl.conf"
chmod 0644 "$root/etc/sysctl.d/60-bosh-sysctl.conf"
cp "$STAGE_DIR"/60-bosh-sysctl-neigh-fix.conf "$root/etc/sysctl.d/60-bosh-sysctl-neigh-fix.conf"
chmod 0644 "$root/etc/sysctl.d/60-bosh-sysctl-neigh-fix.conf"

# bosh_limits
echo '*               hard    core            0' >>"$root/etc/security/limits.conf"

# bosh_environment
touch "$root/etc/environment"
sed -i '/^PATH/d' "$root/etc/environment"
echo 'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/var/vcap/bosh/bin"' >>"$root/etc/environment"
