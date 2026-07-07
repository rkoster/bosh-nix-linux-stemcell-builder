# Reproduces the upstream `bosh_go_agent` stage using the source-built agent:
# binary + systemd unit + rc + monit alerts + agent.json placeholder +
# log symlink + cron/at hardening.
{ bosh-agent }:
{
  name = "agent";
  script = ''
    mkdir -p "$root/var/vcap/bosh/bin" "$root/var/vcap/bosh/etc" \
             "$root/var/vcap/bosh/log" "$root/var/vcap/monit" \
             "$root/lib/systemd/system"

    # agent binary + monit-access hardlink
    install -m 0755 ${bosh-agent}/bin/main "$root/var/vcap/bosh/bin/bosh-agent"
    ln -f "$root/var/vcap/bosh/bin/bosh-agent" \
          "$root/var/vcap/bosh/etc/bosh-enable-monit-access"

    # bosh-agent-rc
    cat > "$root/var/vcap/bosh/bin/bosh-agent-rc" <<'EOF'
#!/bin/sh

set -e

if [ -e /dev/sr0 ]; then
  chmod 0660 /dev/sr0
  chown root:root /dev/sr0
fi

if [ -e /dev/shm ]; then
  chmod 0770 /dev/shm
  chown root:vcap /dev/shm
fi
EOF
    chmod 0755 "$root/var/vcap/bosh/bin/bosh-agent-rc"

    # restart_networking helper
    cat > "$root/var/vcap/bosh/bin/restart_networking" <<'EOF'
#!/bin/bash
systemctl restart systemd-networkd
EOF
    chmod 0755 "$root/var/vcap/bosh/bin/restart_networking"

    # monit alerts
    cat > "$root/var/vcap/monit/alerts.monitrc" <<'EOF'
set alert agent@local

set mailserver localhost port 2825
     with timeout 15 seconds

set eventqueue
    basedir /var/vcap/monit/events
    slots 5000

set mail-format {
  from: monit@localhost
  subject: Monit Alert
  message: Service: \$SERVICE
  Event: \$EVENT
  Action: \$ACTION
  Date: \$DATE
  Description: \$DESCRIPTION
}
EOF
    chmod 0600 "$root/var/vcap/monit/alerts.monitrc"
    chown root:root "$root/var/vcap/monit/alerts.monitrc"

    # empty agent conf (overwritten by openstack-agent-settings overlay)
    echo '{}' > "$root/var/vcap/bosh/agent.json"

    # cache dir used by agent/init/create-env
    mkdir -p "$root/var/vcap/micro_bosh/data/cache"

    # bosh-agent.service (byte-faithful copy of stage asset)
    cat > "$root/lib/systemd/system/bosh-agent.service" <<'EOF'
[Unit]
Description=Bosh agent service
After=network.target


[Service]
WorkingDirectory=/var/vcap/bosh
ExecStart=/bin/bash -c 'PATH=/var/vcap/bosh/bin:\$PATH \
    exec nice -n -15 /var/vcap/bosh/bin/bosh-agent \
    -P \$(cat /var/vcap/bosh/etc/operating_system) \
    -C /var/vcap/bosh/agent.json'
Restart=always
KillMode=process
StandardOutput=journal
StandardError=inherit
SyslogIdentifier=bosh-agent

[Install]
WantedBy=multi-user.target
Alias=agent.service
EOF

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
    echo 'vcap' > "$root/etc/cron.allow"
    echo 'vcap' > "$root/etc/at.allow"
    chmod -f og-rwx "$root/etc/at.allow" "$root/etc/cron.allow" \
      "$root/etc/crontab" "$root/etc/cron.hourly" "$root/etc/cron.daily" \
      "$root/etc/cron.weekly" "$root/etc/cron.monthly" "$root/etc/cron.d" \
      2>/dev/null || true
    chown -f root:root "$root/etc/at.allow" "$root/etc/cron.allow" \
      "$root/etc/crontab" "$root/etc/cron.hourly" "$root/etc/cron.daily" \
      "$root/etc/cron.weekly" "$root/etc/cron.monthly" "$root/etc/cron.d" \
      2>/dev/null || true
  '';
}
