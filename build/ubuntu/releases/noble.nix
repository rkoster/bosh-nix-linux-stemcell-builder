# Ubuntu Noble (24.04) release descriptor. Pure data consumed by
# build/ubuntu/release.nix. Values transcribed verbatim from the previous
# hardcoded apt-pins.nix + deb-sets.nix so the build stays byte-identical.
{
  release = "noble";
  codename = "noble";
  osVersion = "noble";
  version = "24.04";
  name = "ubuntu-24.04-noble-amd64";
  fullName = "Ubuntu 24.04 Noble (amd64)";

  # PER-RELEASE snapshot pin (snapshot.ubuntu.com timestamp).
  snapshot = "20260101T000000Z";

  # sha256 of each Packages.xz at the snapshot above. Order-free named set.
  packagesListHashes = {
    main = "0l94v46rh8q3m8maim1xq2qkagwrjkalcrilrdww599i22g1jsia";
    universe = "16jr0mj275yzaii4khfh07hryf451k80hs6jl748qhwi3gx5g45s";
    multiverse = "1sjh2wzbwvrxz098l6625igxb0lcdpkm4v9azhmvfjl6w07ld040";
  };

  # Behavioral toggles consumed by stages (Resolute flips these in a later plan).
  # Noble values reproduce current behavior.
  features = {
    runit = true;
    pamLastlog2 = "hack";
  };

  # Authoritative BOSH package set (was deb-sets.nix `bosh`).
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
    "rng-tools"
    "libxml2"
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
    "traceroute"
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
    "mg"
    "htop"
    "module-assistant"
    "debhelper"
    "runit"
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
    "gpg-agent"
    "libcurl4"
    "libcurl4-openssl-dev"
    "resolvconf"
    "net-tools"
    "ifupdown"
    "rsyslog"
    "rsyslog-gnutls"
    "rsyslog-openssl"
    "rsyslog-relp"
    "auditd"
    "sudo"
    "cron"
    "systemd-timesyncd"
    "grub2"
    "zlib1g-dev"
    "build-essential"
  ];
}
