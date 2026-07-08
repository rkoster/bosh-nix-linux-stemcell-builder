# base_ssh + tty_config. Reproduces stemcell_builder/stages/base_ssh/apply.sh sed/echo edits
# on $root/etc/ssh/sshd_config, and installs the cipher/mac hardening the os_image spec asserts.
# Assets are inlined for reproducibility (nested git repo access not available in Nix sandbox).
# Accepts stageAssets for forward-compatibility with later overlays, though not used here.
{ stageAssets }:
{
  name = "ssh";
  script = ''
    cfg="$root/etc/ssh/sshd_config"
    echo "" >> "$cfg"
    for kv in \
      "UseDNS no" "PermitRootLogin no" "X11Forwarding no" "MaxAuthTries 3" \
      "PermitEmptyPasswords no" "Protocol 2" "HostbasedAuthentication no" \
      "Banner /etc/issue.net" "IgnoreRhosts yes" "ClientAliveInterval 180" \
      "LoginGraceTime 60" "Compression delayed" "PermitUserEnvironment no" \
      "ClientAliveCountMax 1" "PasswordAuthentication no" "PrintLastLog yes" \
      "AllowGroups bosh_sshers" "DenyUsers root"; do
      key=''${kv%% *}
      sed -i "/^ *$key/d" "$cfg"
      echo "$kv" >> "$cfg"
    done
    sed -i "/^ *X11DisplayOffset/d" "$cfg"
    # Ciphers + MACs (asserted verbatim by the os_image spec)
    sed -i "/^ *Ciphers/d;/^ *MACs/d" "$cfg"
    echo 'Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr' >> "$cfg"
    echo 'MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com' >> "$cfg"
    # host keys: drop DSA, ensure rsa/ecdsa/ed25519 uncommented
    sed -i "/^[ #]*HostKey \/etc\/ssh\/ssh_host_dsa_key/d" "$cfg"
    for t in rsa ecdsa ed25519; do
      sed -i "s|^[ #]*HostKey /etc/ssh/ssh_host_''${t}_key|HostKey /etc/ssh/ssh_host_''${t}_key|" "$cfg"
    done
    chmod 0600 "$cfg"

    # firstboot drop-in (inlined asset from base_ssh/assets)
    mkdir -p "$root/lib/systemd/system/ssh.service.d"
    cat > "$root/lib/systemd/system/ssh.service.d/10-ssh-firstboot-done.conf" << 'EOF'
[Unit]
ConditionPathExists=/root/firstboot_done
EOF

    # tty_config: securetty (inlined asset)
    cat > "$root/etc/securetty" << 'EOF'
# Only allow access from consoles in a physically secure location

console
EOF

    # base_ssh: /etc/issue and /etc/issue.net BOSH warning banner (CIS-11.1)
    # Both files must contain the unauthorized-use warning; sshd_config Banner
    # directive points to /etc/issue.net.
    BANNER_TEXT='Unauthorized use is strictly prohibited. All access and activity
is subject to logging and monitoring.'
    printf '%s\n' "$BANNER_TEXT" > "$root/etc/issue"
    chmod 0644 "$root/etc/issue"
    chown root:root "$root/etc/issue" 2>/dev/null || true
    printf '%s\n' "$BANNER_TEXT" > "$root/etc/issue.net"
    chmod 0644 "$root/etc/issue.net"
    chown root:root "$root/etc/issue.net" 2>/dev/null || true

    # base_ssh: empty /etc/motd (CIS-11.1) and disable motd-news
    : > "$root/etc/motd"
    chmod 0644 "$root/etc/motd"
    chown root:root "$root/etc/motd" 2>/dev/null || true
    mkdir -p "$root/etc/default"
    printf 'ENABLED=0\n' > "$root/etc/default/motd-news"
  '';
}
