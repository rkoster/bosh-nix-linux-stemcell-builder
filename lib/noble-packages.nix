# Authoritative BOSH package set for ubuntu-noble.
# Transcribed verbatim from:
#   bosh-linux-stemcell-builder/stemcell_builder/stages/base_ubuntu_packages/apply.sh
# on branch ubuntu-noble (HEAD 7170566ab).
# Note Noble's 64-bit time_t (t64) ABI transition and PAM change:
#   jammy libaio1        -> noble libaio1t64
#   jammy libpam-cracklib -> noble libpam-pwquality
# rng-tools appears twice in apply.sh (lines 10 and 18); de-duplicated here.
# The rsyslog set is a separate `pkg_mgr install` in apply.sh (line 37).
[
  "libssl-dev" "lsof" "strace" "bind9-host" "dnsutils" "tcpdump" "iputils-arping"
  "curl" "wget" "bison" "libreadline6-dev" "rng-tools"
  "libxml2" "libxml2-dev" "libxslt1.1" "libxslt1-dev" "zip" "unzip"
  "flex" "psmisc" "apparmor-utils" "iptables" "nftables" "sysstat"
  "rsync" "openssh-server" "traceroute" "libncurses5-dev" "quota"
  "libaio1t64" "gdb" "libcap2-bin" "libcap2-dev" "libbz2-dev"
  "cmake" "uuid-dev" "libgcrypt-dev" "ca-certificates"
  "mg" "htop" "module-assistant" "debhelper" "runit" "parted"
  "cloud-guest-utils" "anacron" "software-properties-common"
  "xfsprogs" "gdisk" "chrony" "dbus" "nvme-cli" "fdisk"
   "ethtool" "libpam-pwquality" "gpg-agent" "libcurl4" "libcurl4-openssl-dev"
   "resolvconf" "net-tools" "ifupdown"
   "rsyslog" "rsyslog-gnutls" "rsyslog-openssl" "rsyslog-relp"
   "auditd" "sudo"  # Priority: important; needed for bosh_sudoers passwordless escalation
   "cron"           # spec: crontab command must exist + cron.service enabled
   "systemd-timesyncd"  # spec: /etc/passwd must include systemd-timesync user (uid 996)
   "grub2"          # spec: grub2 package must be installed + /boot/grub/gfxblacklist.txt
]
