{ stageAssets }:
{
  name = "systemd-services";
  script = ''
    # bosh_monit: monit.service + enable
    mkdir -p "$root/lib/systemd/system"
    cat > "$root/lib/systemd/system/monit.service" <<'EOF'
[Unit]
Description=Monit service
After=network.target
ConditionPathExists=/var/vcap/data/sys/run

[Service]
ExecStart=/bin/bash -c 'PATH=/var/vcap/bosh/bin:$PATH exec nice -n -10 /var/vcap/bosh/bin/monit -I -c /var/vcap/bosh/etc/monitrc'
Restart=always
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    # bosh_monit: enable monit.service
    mkdir -p "$root/lib/systemd/system/multi-user.target.wants"
    ln -sf /lib/systemd/system/monit.service "$root/lib/systemd/system/multi-user.target.wants/monit.service"

    # bosh_ntp: chrony drop-in override (prevent mount locking)
    mkdir -p "$root/etc/systemd/system/chronyd.service.d"
    cat > "$root/etc/systemd/system/chronyd.service.d/prevent_mount_locking.conf" <<'EOF'
[Service]
InaccessiblePaths=-/var/vcap/store
EOF

    # bosh_systemd: RemoveIPC=no in logind.conf
    echo 'RemoveIPC=no' >> "$root/etc/systemd/logind.conf"

    # bosh_systemd_resolved: add-container-listener-address config
    mkdir -p "$root/etc/systemd/resolved.conf.d"
    cat > "$root/etc/systemd/resolved.conf.d/add-container-listener-address.conf" <<'EOF'
[Resolve]
DNSStubListenerExtra=169.254.0.53
EOF

    # bosh_systemd_resolved: create-systemd-resolved-listener-address.service + enable
    cat > "$root/lib/systemd/system/create-systemd-resolved-listener-address.service" <<'EOF'
[Unit]
Description=Add 169.254.0.53 address so systemd-resolvconf can be accessed by container namespaces

DefaultDependencies=no
After=systemd-sysctl.service systemd-sysusers.service
Before=systemd-resolved.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if ! ip addr show dev lo | grep -q 169.254.0.53; then ip addr add 169.254.0.53 dev lo; fi'

[Install]
RequiredBy=systemd-resolved.service
EOF

    # bosh_systemd_resolved: enable create-systemd-resolved-listener-address.service
    mkdir -p "$root/lib/systemd/system/systemd-resolved.service.requires"
    ln -sf /lib/systemd/system/create-systemd-resolved-listener-address.service \
      "$root/lib/systemd/system/systemd-resolved.service.requires/create-systemd-resolved-listener-address.service"

    # bosh_sysstat: sysstat default config
    mkdir -p "$root/etc/default"
    cat > "$root/etc/default/sysstat" <<'EOF'
# Run system activity accounting tool.
ENABLED="true"
EOF

    # base_ubuntu_firstboot: firstboot.service + enable
    cat > "$root/etc/systemd/system/firstboot.service" <<'EOF'
[Unit]
Description=Run first boot tasks
ConditionPathExists=!/root/firstboot_done
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/root/firstboot.sh
ExecStartPost=/usr/bin/touch /root/firstboot_done

[Install]
WantedBy=multi-user.target
EOF

    # base_ubuntu_firstboot: enable firstboot.service
    mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/firstboot.service \
      "$root/etc/systemd/system/multi-user.target.wants/firstboot.service"

    # base_file_permission: gshadow and shadow (setuid binaries handled separately)
    chmod 0000 "$root/etc/gshadow" || true
    chown root:root "$root/etc/gshadow" 2>/dev/null || true

    chmod 0000 "$root/etc/shadow" || true
    chown root:root "$root/etc/shadow" 2>/dev/null || true
  '';
}
