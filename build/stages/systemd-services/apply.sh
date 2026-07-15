#!/bin/bash
set -eu

# $root is exported by build/rootfs/apply-stages.nix (the rootfs tree target).
# shellcheck disable=SC2154

# Install systemd service units and related config inside the rootfs tree ("$root").

# bosh_monit: monit.service + enable (asset)
mkdir -p "$root/lib/systemd/system"
cp "$STAGE_DIR"/monit.service "$root/lib/systemd/system/monit.service"

# bosh_monit: enable monit.service. Create the want symlink in
# /etc/systemd/system/ (mirrors `systemctl enable`; symlinks in
# /lib/systemd/system/ are considered "static" and not reported as "enabled").
mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/monit.service "$root/etc/systemd/system/multi-user.target.wants/monit.service"

# bosh_ntp: chrony drop-in override (prevent mount locking) (asset)
mkdir -p "$root/etc/systemd/system/chronyd.service.d"
cp "$STAGE_DIR"/prevent_mount_locking.conf "$root/etc/systemd/system/chronyd.service.d/prevent_mount_locking.conf"

# bosh_systemd: RemoveIPC=no in logind.conf
echo 'RemoveIPC=no' >>"$root/etc/systemd/logind.conf"

# bosh_systemd_resolved: add-container-listener-address config (asset)
mkdir -p "$root/etc/systemd/resolved.conf.d"
cp "$STAGE_DIR"/add-container-listener-address.conf "$root/etc/systemd/resolved.conf.d/add-container-listener-address.conf"

# bosh_systemd_resolved: create-systemd-resolved-listener-address.service + enable (asset)
cp "$STAGE_DIR"/create-systemd-resolved-listener-address.service "$root/lib/systemd/system/create-systemd-resolved-listener-address.service"
mkdir -p "$root/lib/systemd/system/systemd-resolved.service.requires"
ln -sf /lib/systemd/system/create-systemd-resolved-listener-address.service \
  "$root/lib/systemd/system/systemd-resolved.service.requires/create-systemd-resolved-listener-address.service"

# base_ubuntu_packages: enable systemd-networkd (mirrors upstream
# `systemctl enable systemd-networkd`). Without this the agent-written
# /etc/systemd/network/10_eth0.network is never applied, so static-network
# validation fails with "no interface configured with that name (eth0)".
mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
mkdir -p "$root/etc/systemd/system/sockets.target.wants"
ln -sf /lib/systemd/system/systemd-networkd.service \
  "$root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
ln -sf /lib/systemd/system/systemd-networkd.socket \
  "$root/etc/systemd/system/sockets.target.wants/systemd-networkd.socket"
ln -sf /lib/systemd/system/systemd-networkd.service \
  "$root/etc/systemd/system/dbus-org.freedesktop.network1.service"

# bosh_sysstat: sysstat default config (asset)
mkdir -p "$root/etc/default"
cp "$STAGE_DIR"/sysstat "$root/etc/default/sysstat"

# base_ubuntu_firstboot: firstboot.service + enable (asset)
cp "$STAGE_DIR"/firstboot.service "$root/etc/systemd/system/firstboot.service"
mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/firstboot.service \
  "$root/etc/systemd/system/multi-user.target.wants/firstboot.service"

# base_ubuntu_firstboot: firstboot.sh (asset). Regenerates per-VM SSH host keys
# (ssh-keygen -A) and reconfigures sysstat. WITHOUT this, firstboot.service
# ExecStart fails, /root/firstboot_done is never created, and ssh.service's
# ConditionPathExists=/root/firstboot_done never passes -> SSH unusable.
cp "$STAGE_DIR"/firstboot.sh "$root/root/firstboot.sh"
chmod 0755 "$root/root/firstboot.sh"
chown 0:0 "$root/root/firstboot.sh"

# base_file_permission: gshadow and shadow
chmod 0000 "$root/etc/gshadow" || true
chown root:root "$root/etc/gshadow" 2>/dev/null || true
chmod 0000 "$root/etc/shadow" || true
chown root:root "$root/etc/shadow" 2>/dev/null || true
