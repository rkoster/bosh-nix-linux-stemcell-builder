# Ubuntu Resolute (26.04 LTS) release descriptor. Pure data consumed by
# build/ubuntu/release.nix. Snapshot + index hashes prefetched from
# snapshot.ubuntu.com (snapshot 20260701T000000Z; Resolute GA 2026-04-23).
# Package deltas transcribed from the reference bosh-linux-stemcell-builder
# `ubuntu-resolute` branch base_ubuntu_packages/apply.sh.
{
  release = "resolute";
  codename = "resolute";
  osVersion = "resolute";
  version = "26.04";
  name = "ubuntu-26.04-resolute-amd64";
  fullName = "Ubuntu 26.04 Resolute (amd64)";

  # PER-RELEASE snapshot pin (snapshot.ubuntu.com timestamp).
  snapshot = "20260701T000000Z";

  # sha256 (base32) of each Packages.xz at the snapshot above.
  packagesListHashes = {
    main = "096gfgfwvg9g9cp4yk7rbzxy4w35qlnp9806bb6axvv3n8fc96pd";
    universe = "07jqmnk3h83nwan97mr4ixf6kgbmkw80wpi14lim8f3dss3bx1qm";
    multiverse = "1jd1h5vm6g2cngx81fq56046dbg2r4a7gg41a0nnpyn1y8vnr7k4";
  };

  # Behavioral toggles consumed by stages.
  # runit = false: Resolute RFC #1498 removed runit; the package is omitted from
  #   boshPackages below and the _runit-log account is absent from the resolute
  #   user assets. No supervision rework (systemd units already drive bosh-agent
  #   and monit). This toggle documents intent; correctness is structural.
  # pamLastlog2 = "package": Resolute ships libpam-lastlog2, so the sudoers-pam
  #   stage emits an ACTIVE pam_lastlog2 line (+ multiarch symlink bridge)
  #   instead of Noble's commented-out placeholder.
  features = {
    runit = false;
    pamLastlog2 = "package";
  };

  # Authoritative BOSH package set. Derived from Noble's list with the reference
  # `ubuntu-resolute` deltas applied: libxml2->libxml2-16; drop rng-tools,
  # traceroute, mg, module-assistant, runit, rsyslog-openssl, systemd-timesyncd;
  # add libpam-lastlog2.
  boshPackages = [
    "libssl-dev"
    "lsof"
    "strace"
    "bind9-host"
    "dnsutils"
    "tcpdump"
    "iputils-arping"
    "curl"
    "wget"
    "bison"
    "libreadline6-dev"
    "libxml2-16"
    "libxml2-dev"
    "libxslt1.1"
    "libxslt1-dev"
    "zip"
    "unzip"
    "flex"
    "psmisc"
    "apparmor-utils"
    "iptables"
    "nftables"
    "sysstat"
    "rsync"
    "openssh-server"
    "libncurses5-dev"
    "quota"
    "libaio1t64"
    "gdb"
    "libcap2-bin"
    "libcap2-dev"
    "libbz2-dev"
    "cmake"
    "uuid-dev"
    "libgcrypt-dev"
    "ca-certificates"
    "htop"
    "debhelper"
    "parted"
    "cloud-guest-utils"
    "anacron"
    "software-properties-common"
    "xfsprogs"
    "gdisk"
    "chrony"
    "dbus"
    "nvme-cli"
    "fdisk"
    "ethtool"
    "libpam-pwquality"
    "libpam-lastlog2"
    "gpg-agent"
    "libcurl4"
    "libcurl4-openssl-dev"
    "resolvconf"
    "net-tools"
    "ifupdown"
    "rsyslog"
    "rsyslog-gnutls"
    "rsyslog-relp"
    "auditd"
    "sudo"
    "cron"
    "grub2"
    "zlib1g-dev"
    "build-essential"
  ];
}
