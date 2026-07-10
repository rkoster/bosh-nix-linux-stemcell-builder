# Ubuntu Noble deb selection. Pure-data package lists (base/boot/bosh) plus the
# assembled top-level `image` set. Folds base-packages.nix, boot-packages.nix,
# noble-packages.nix, and image-packages.nix.
{ lib, callPackage }:

let
  aptPins = callPackage ./apt-pins.nix { };
  essential = callPackage ./essential.nix { inherit aptPins; };

  # Generic Debian/Ubuntu build base (was base-packages.nix; transcribed from
  # nixpkgs commonDebPackages + debDistros.ubuntu2204x86_64's two extras).
  base = [
    "base-passwd" "dpkg" "libc6-dev" "perl" "bash" "dash" "gzip" "bzip2" "tar"
    "grep" "mawk" "sed" "findutils" "g++" "make" "curl" "patch" "locales"
    "coreutils"
    # Needed by checkinstall:
    "util-linux" "file" "dpkg-dev" "pkg-config"
    # /etc/login.defs (passwd post-install):
    "login" "passwd"
    # debDistros.ubuntu2204x86_64 extras:
    "diffutils" "libc-bin"
  ];

  # Build-only tooling to drop from `base` for a bootable image (was boot-packages).
  dropFromBase = [ "g++" "make" "dpkg-dev" "pkg-config" ];

  # Minimal boot + runtime essentials (was boot-packages.nix).
  bootEssentials = [
    "systemd" "init-system-helpers" "systemd-sysv" "linux-image-generic"
    "initramfs-tools" "e2fsprogs" "grub-efi" "grub-pc-bin" "apt"
    "ncurses-base" "dbus"
  ];

  # Authoritative BOSH package set for ubuntu-noble (was noble-packages.nix).
  bosh = [
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
    "auditd" "sudo"
    "cron"
    "systemd-timesyncd"
    "grub2"
    "zlib1g-dev"
    "build-essential"
  ];
in
{
  inherit base dropFromBase bootEssentials bosh;

  # Single source of truth for the full top-level set installed into the image
  # (was image-packages.nix). Consumed by rootfs/rootfs.nix and the example gates.
  image = lib.unique (
    essential
    ++ lib.filter (p: !lib.elem p dropFromBase) base
    ++ bootEssentials
    ++ bosh
  );
}
