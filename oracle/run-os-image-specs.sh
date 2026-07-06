#!/usr/bin/env bash
# Runs the retained os_image Serverspec suite against a Nix-built rootfs tarball.
# Usage: run-os-image-specs.sh <os-image.tgz> [rspec args...]
set -euo pipefail

OS_IMAGE_TGZ="$(readlink -f "$1")"; shift || true
REPO_ROOT="$(git rev-parse --show-toplevel)"
SPEC_DIR="$REPO_ROOT/bosh-linux-stemcell-builder/bosh-stemcell"
LIB_SLICE="$REPO_ROOT/poc/oracle/lib-slice"

export OS_IMAGE="$OS_IMAGE_TGZ"
export STEMCELL_INFRASTRUCTURE=openstack   # selects /boot/grub grub_cfg_path (spec_helper.rb)

cd "$SPEC_DIR"
# BUNDLE_GEMFILE points at the POC Gemfile so we use the Nix-provided gems, not the builder's.
export BUNDLE_GEMFILE="$REPO_ROOT/poc/oracle/Gemfile"
bundle install --local || bundle install

# Create a wrapper spec file that preloads bosh/stemcell module before loading ubuntu_spec
WRAPPER_SPEC=$(mktemp)
trap "rm -f $WRAPPER_SPEC" EXIT

cat > "$WRAPPER_SPEC" << 'EOF'
# Wrapper to preload bosh/stemcell module before loading ubuntu_spec
require 'bosh/stemcell'
load ENV['SPEC_DIR'] + '/spec/os_image/ubuntu_spec.rb'
EOF

# Use host sudo instead of Nix sandbox sudo (which lacks setuid bit)
# Set PATH to prioritize /run/wrappers/bin (host sudo)
export PATH="/run/wrappers/bin:/nix/store/*/bin:${PATH}"
export SPEC_DIR="$SPEC_DIR"
exec bundle exec rspec -I "$LIB_SLICE" -I "$SPEC_DIR/spec" -I "$SPEC_DIR/lib" \
  "$WRAPPER_SPEC" "$@"
