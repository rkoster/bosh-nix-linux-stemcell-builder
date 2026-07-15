#!/bin/bash
set -eu

# Reproduces the upstream `bosh_go_agent` + `bosh_monit` stages: agent binary,
# monit binary, systemd unit, rc/alerts/sync helpers, agent.json placeholder,
# log symlink, and cron/at hardening. Applied by rootfs/apply-stages.nix inside
# the shared fakeroot session.
#
# $root is exported by build/rootfs/apply-stages.nix (the rootfs tree target).
# STAGE_DIR holds the static asset files; BOSH_AGENT and MONIT are the
# source-built store paths, exported by this stage's default.nix.
# shellcheck disable=SC2154

mkdir -p "$root/var/vcap/bosh/bin" "$root/var/vcap/bosh/etc" \
  "$root/var/vcap/bosh/log" "$root/var/vcap/monit" \
  "$root/lib/systemd/system"

# agent binary + monit-access hardlink
install -m 0755 "$BOSH_AGENT/bin/main" "$root/var/vcap/bosh/bin/bosh-agent"
ln -f "$root/var/vcap/bosh/bin/bosh-agent" \
  "$root/var/vcap/bosh/etc/bosh-enable-monit-access"
# `install` leaves the binary owned by the build user; under fakeroot only
# explicit chowns record uid 0, so force root ownership (real stemcell has
# /var/vcap/bosh/bin/bosh-agent as root:root). The hardlink shares the inode.
chown 0:0 "$root/var/vcap/bosh/bin/bosh-agent"

# monit 5.2.5 (static): the process supervisor the agent drives over its
# 127.0.0.1:2822 HTTP interface. Reproduces bosh_monit stage.
install -m 0755 "$MONIT/bin/monit" "$root/var/vcap/bosh/bin/monit"
chown 0:0 "$root/var/vcap/bosh/bin/monit"

# monitrc (asset, 0700 root): monit's config; the include glob below must be
# non-empty (monit refuses to start otherwise) so seed empty.monitrc too.
install -m 0700 "$STAGE_DIR/monitrc" "$root/var/vcap/bosh/etc/monitrc"
chown 0:0 "$root/var/vcap/bosh/etc/monitrc"

touch "$root/var/vcap/monit/empty.monitrc"
chown 0:0 "$root/var/vcap/monit/empty.monitrc"

# bosh-agent-rc (asset, 0755 root)
install -m 0755 "$STAGE_DIR/bosh-agent-rc" "$root/var/vcap/bosh/bin/bosh-agent-rc"
chown 0:0 "$root/var/vcap/bosh/bin/bosh-agent-rc"

# restart_networking helper (asset, 0755 root)
install -m 0755 "$STAGE_DIR/restart_networking" "$root/var/vcap/bosh/bin/restart_networking"
chown 0:0 "$root/var/vcap/bosh/bin/restart_networking"

# monit alerts (asset, 0600 root)
install -m 0600 "$STAGE_DIR/alerts.monitrc" "$root/var/vcap/monit/alerts.monitrc"
chown root:root "$root/var/vcap/monit/alerts.monitrc" 2>/dev/null || true

# empty agent conf (overwritten by openstack-agent-settings stage)
echo '{}' >"$root/var/vcap/bosh/agent.json"

# platform name consumed by bosh-agent.service `-P $(cat .../operating_system)`
echo 'ubuntu' >"$root/var/vcap/bosh/etc/operating_system"

# cache dir used by agent/init/create-env
mkdir -p "$root/var/vcap/micro_bosh/data/cache"

# bosh-agent.service (asset, 0644 root)
install -m 0644 "$STAGE_DIR/bosh-agent.service" "$root/lib/systemd/system/bosh-agent.service"
chown 0:0 "$root/lib/systemd/system/bosh-agent.service"

# enable bosh-agent.service (declarative wants + Alias symlinks)
mkdir -p "$root/lib/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/bosh-agent.service \
  "$root/lib/systemd/system/multi-user.target.wants/bosh-agent.service"
ln -sf /lib/systemd/system/bosh-agent.service \
  "$root/lib/systemd/system/agent.service"

# agent log symlink target (log file created at runtime)
ln -sf /var/log/bosh-agent.log "$root/var/vcap/bosh/log/current"

# cron/at hardening (bosh_go_agent chroot block)
rm -f "$root/etc/cron.deny" "$root/etc/at.deny"
echo 'vcap' >"$root/etc/cron.allow"
echo 'vcap' >"$root/etc/at.allow"
chmod -f og-rwx "$root/etc/at.allow" "$root/etc/cron.allow" \
  "$root/etc/crontab" "$root/etc/cron.hourly" "$root/etc/cron.daily" \
  "$root/etc/cron.weekly" "$root/etc/cron.monthly" "$root/etc/cron.d" \
  2>/dev/null || true
chown -f root:root "$root/etc/at.allow" "$root/etc/cron.allow" \
  "$root/etc/crontab" "$root/etc/cron.hourly" "$root/etc/cron.daily" \
  "$root/etc/cron.weekly" "$root/etc/cron.monthly" "$root/etc/cron.d" \
  2>/dev/null || true

# bosh_ntp/chrony: sync-time script (stig: V-38620 V-38621), asset, 0755
install -m 0755 "$STAGE_DIR/sync-time" "$root/var/vcap/bosh/bin/sync-time"
chown 0:0 "$root/var/vcap/bosh/bin/sync-time" 2>/dev/null || true
