# base_ssh + tty_config. Reproduces stemcell_builder/stages/base_ssh/apply.sh sed/echo edits
# on $root/etc/ssh/sshd_config, and installs the cipher/mac hardening the os_image spec asserts.
# Assets are inlined for reproducibility (nested git repo access not available in Nix sandbox).
{}:
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
  '';
}
