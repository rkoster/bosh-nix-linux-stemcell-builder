# bosh_sysctl, bosh_limits, bosh_environment stages:
# - Copy sysctl conf assets verbatim to /etc/sysctl.d/
# - Append core limit to /etc/security/limits.conf
# - Write /etc/environment with BOSH PATH extension
# Assets are inlined for reproducibility (nested git repo access not available in Nix sandbox).
{ }:
{
  name = "sysctl-limits-env";
  script = ''
    # bosh_sysctl: install 60-bosh-sysctl.conf (inlined verbatim from upstream)
    mkdir -p "$root/etc/sysctl.d"
    cat > "$root/etc/sysctl.d/60-bosh-sysctl.conf" <<'SYSCTL1'
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv6.conf.all.accept_ra=1
net.ipv4.conf.all.log_martians=1

net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.default.secure_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv6.conf.default.accept_ra=1
net.ipv4.conf.default.log_martians=1

net.ipv4.ip_forward=0
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog=1280
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1

net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.route.flush=0

kernel.exec-shield=1

kernel.randomize_va_space=2

fs.suid_dumpable=0

net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=8

kernel.keys.root_maxkeys=1000000
kernel.keys.maxkeys=1000000

kernel.dmesg_restrict=1
SYSCTL1
    chmod 0644 "$root/etc/sysctl.d/60-bosh-sysctl.conf"

    # bosh_sysctl: install 60-bosh-sysctl-neigh-fix.conf (inlined verbatim from upstream)
    cat > "$root/etc/sysctl.d/60-bosh-sysctl-neigh-fix.conf" <<'SYSCTL2'
# Actively delete stale entries from the neighbor table regardless of its size
# (Kernel started using this value in GC loop in commit 2724680).
# http://wiki.wireshark.org/Gratuitous_ARP
# http://linux-ip.net/html/ether-arp.html
net.ipv4.neigh.default.gc_thresh1=0
SYSCTL2
    chmod 0644 "$root/etc/sysctl.d/60-bosh-sysctl-neigh-fix.conf"

    # bosh_limits
    echo '*               hard    core            0' >> "$root/etc/security/limits.conf"

    # bosh_environment
    touch "$root/etc/environment"
    sed -i '/^PATH/d' "$root/etc/environment"
    echo 'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/var/vcap/bosh/bin"' >> "$root/etc/environment"
  '';
}
