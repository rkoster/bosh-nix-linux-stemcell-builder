#!/bin/bash
set -eu

# $root is exported by build/rootfs/apply-stages.nix (the rootfs tree target).
# shellcheck disable=SC2154

# Create user accounts and groups. Content files are asset copies of the exact
# bytes asserted by os_image/ubuntu_spec.rb. Targets are written into the rootfs
# tree at "$root". `cp` onto an existing file preserves that file's mode (same
# behaviour as the original `cat >` heredocs), so only shadow needs an explicit
# mode change.

# /etc/group, /etc/gshadow, /etc/passwd, /etc/shadow — exact bytes.
cp "$STAGE_DIR"/group "$root/etc/group"
cp "$STAGE_DIR"/gshadow "$root/etc/gshadow"
cp "$STAGE_DIR"/passwd "$root/etc/passwd"
cp "$STAGE_DIR"/shadow "$root/etc/shadow"
chmod 000 "$root/etc/shadow"

mkdir -p "$root/home/vcap"
chmod 700 "$root/home/vcap"
chown 1000:1000 "$root/home/vcap" 2>/dev/null || true

# Inline ps1 asset
mkdir -p "$root/etc/profile.d"
cp "$STAGE_DIR"/00-bosh-ps1 "$root/etc/profile.d/00-bosh-ps1"

# Update bashrc + profile for root, vcap, and skel
for home in "$root/root" "$root/home/vcap" "$root/etc/skel"; do
  mkdir -p "$home"
  # $PATH is intentionally literal here — it must expand at login, not build time.
  # shellcheck disable=SC2016
  printf 'export PATH=/var/vcap/bosh/bin:$PATH\nsource /etc/profile.d/00-bosh-ps1\n' >>"$home/.bashrc"
done
grep -q '.bashrc' "$root/root/.profile" 2>/dev/null ||
  printf '\n. ~/.bashrc\n' >>"$root/root/.profile"
