#!/bin/bash
set -eu

# $root is exported by build/rootfs/apply-stages.nix (the rootfs tree target).
# shellcheck disable=SC2154

# Configure rsyslog inside the rootfs tree ("$root").

# Main rsyslog configuration (asset)
cp "$STAGE_DIR"/rsyslog.conf "$root/etc/rsyslog.conf"

# Clear any default rsyslog.d contents and create the directory
if [ -d "$root/etc/rsyslog.d" ]; then
  rm -rf "$root/etc/rsyslog.d"/*
else
  mkdir -p "$root/etc/rsyslog.d"
fi

# Default + bosh-agent drop-ins (assets)
cp "$STAGE_DIR"/50-default.conf "$root/etc/rsyslog.d/50-default.conf"
cp "$STAGE_DIR"/90-bosh-agent.conf "$root/etc/rsyslog.d/90-bosh-agent.conf"

# logrotate config (asset)
mkdir -p "$root/etc/logrotate.d"
cp "$STAGE_DIR"/rsyslog "$root/etc/logrotate.d/rsyslog"

# wait-for-mount helper (asset)
mkdir -p "$root/usr/local/bin"
cp "$STAGE_DIR"/wait_for_var_log_to_be_mounted "$root/usr/local/bin/wait_for_var_log_to_be_mounted"
chmod 755 "$root/usr/local/bin/wait_for_var_log_to_be_mounted"

# Pre-create log files referenced by rsyslog.d/50-default.conf so that the
# os_image spec "secures rsyslog.conf-referenced files" test can stat them.
# rsyslog owns these files (syslog uid/gid 102:102 per the users stage).
mkdir -p "$root/var/log"
for logfile in auth.log syslog cron.log daemon.log kern.log bosh-agent.log; do
  touch "$root/var/log/$logfile"
  chmod 0600 "$root/var/log/$logfile"
  chown 102:102 "$root/var/log/$logfile" 2>/dev/null || true
done

# rsyslog.service.d override (asset)
mkdir -p "$root/etc/systemd/system/rsyslog.service.d"
cp "$STAGE_DIR"/rsyslog-service-override.conf "$root/etc/systemd/system/rsyslog.service.d/00-override.conf"

# journald.conf.d override (asset)
mkdir -p "$root/etc/systemd/journald.conf.d"
cp "$STAGE_DIR"/journald-override.conf "$root/etc/systemd/journald.conf.d/00-override.conf"
