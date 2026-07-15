{ callPackage }:
let
  # Source-built components that need store-path interpolation
  bosh-agent = callPackage ./pkgs/bosh-agent.nix { };
  monit = callPackage ./pkgs/monit.nix { };
  blob = callPackage ./pkgs/blobstore-clis.nix { };

  # Pure stages (no store-path interpolation): readFile + mkStage pattern
  mkStage = { name, src }:
    {
      inherit name;
      script = builtins.readFile src;
    };
in
[
  # Pure stages (externalized to *.sh files with mkStage wrapper)
  (mkStage { name = "users"; src = ./stages/users/apply.sh; })
  (mkStage { name = "ssh"; src = ./stages/ssh/apply.sh; })
  (mkStage { name = "sysctl-limits-env"; src = ./stages/sysctl-limits-env/apply.sh; })
  (mkStage { name = "sudoers-pam"; src = ./stages/sudoers-pam/apply.sh; })
  (mkStage { name = "rsyslog"; src = ./stages/rsyslog/apply.sh; })
  (mkStage { name = "audit"; src = ./stages/audit/apply.sh; })
  (mkStage { name = "misc-os"; src = ./stages/misc-os/apply.sh; })
  (mkStage { name = "systemd-services"; src = ./stages/systemd-services/apply.sh; })

  # Interpolated stages (embed store paths)
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
      # `install` leaves the binary owned by the build user; under fakeroot only
      # explicit chowns record uid 0, so force root ownership (real stemcell has
      # /var/vcap/bosh/bin/bosh-agent as root:root). The hardlink shares the inode.
      chown 0:0 "$root/var/vcap/bosh/bin/bosh-agent"

      # monit 5.2.5 (static): the process supervisor the agent drives over its
      # 127.0.0.1:2822 HTTP interface. Reproduces bosh_monit stage:
      #   - install the binary to /var/vcap/bosh/bin/monit
      #   - install monitrc (0700) to /var/vcap/bosh/etc/monitrc
      #   - seed /var/vcap/monit/empty.monitrc so monit's `include` glob is
      #     non-empty (monit refuses to start otherwise)
      install -m 0755 ${monit}/bin/monit "$root/var/vcap/bosh/bin/monit"
      chown 0:0 "$root/var/vcap/bosh/bin/monit"

      cat > "$root/var/vcap/bosh/etc/monitrc" <<'EOF'
set daemon 10
set logfile /var/vcap/monit/monit.log

set httpd port 2822 and use address 127.0.0.1
  allow cleartext /var/vcap/monit/monit.user

include /var/vcap/monit/*.monitrc
include /var/vcap/monit/job/*.monitrc
EOF
      chmod 0700 "$root/var/vcap/bosh/etc/monitrc"
      chown 0:0 "$root/var/vcap/bosh/etc/monitrc"

      touch "$root/var/vcap/monit/empty.monitrc"
      chown 0:0 "$root/var/vcap/monit/empty.monitrc"

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
  message: Service: $SERVICE
  Event: $EVENT
  Action: $ACTION
  Date: $DATE
  Description: $DESCRIPTION
}
EOF
      chmod 0600 "$root/var/vcap/monit/alerts.monitrc"
      chown root:root "$root/var/vcap/monit/alerts.monitrc" 2>/dev/null || true

      # empty agent conf (overwritten by openstack-agent-settings stage)
      echo '{}' > "$root/var/vcap/bosh/agent.json"

      # platform name consumed by bosh-agent.service `-P $(cat .../operating_system)`
      echo 'ubuntu' > "$root/var/vcap/bosh/etc/operating_system"

      # cache dir used by agent/init/create-env
      mkdir -p "$root/var/vcap/micro_bosh/data/cache"

      # bosh-agent.service (byte-faithful copy of stage asset)
      cat > "$root/lib/systemd/system/bosh-agent.service" <<'EOF'
[Unit]
Description=Bosh agent service
After=network.target


[Service]
WorkingDirectory=/var/vcap/bosh
ExecStart=/bin/bash -c 'PATH=/var/vcap/bosh/bin:$PATH \
    exec nice -n -15 /var/vcap/bosh/bin/bosh-agent \
    -P $(cat /var/vcap/bosh/etc/operating_system) \
    -C /var/vcap/bosh/agent.json'
Restart=always
KillMode=process
StandardOutput=journal+console
StandardError=journal+console
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

      # bosh_ntp/chrony: sync-time script (stig: V-38620 V-38621)
      # Checked by both "every OS image installed binaries" and "an os with chrony" specs.
      cat > "$root/var/vcap/bosh/bin/sync-time" <<'SYNCTIME'
#!/bin/bash
chronyc reload sources
chronyc waitsync 10
SYNCTIME
      chmod 0755 "$root/var/vcap/bosh/bin/sync-time"
      chown 0:0 "$root/var/vcap/bosh/bin/sync-time" 2>/dev/null || true
    '';
  }

  {
    name = "blobstore-clis";
    script = ''
      mkdir -p "$root/var/vcap/bosh/bin"

      install -m 0755 ${blob.davcli}/bin/davcli                        "$root/var/vcap/bosh/bin/bosh-blobstore-dav"
      install -m 0755 ${blob.s3cli}/bin/bosh-s3cli                     "$root/var/vcap/bosh/bin/bosh-blobstore-s3"
      install -m 0755 ${blob.gcscli}/bin/bosh-gcscli                   "$root/var/vcap/bosh/bin/bosh-blobstore-gcs"
      install -m 0755 ${blob.azureStorageCli}/bin/bosh-azure-storage-cli "$root/var/vcap/bosh/bin/bosh-blobstore-azure-storage"
    '';
  }

  # Pure stage
  (mkStage { name = "openstack-agent-settings"; src = ./stages/openstack-agent-settings/apply.sh; })
]
