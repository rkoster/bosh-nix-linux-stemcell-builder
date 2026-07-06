# Boot/runtime essentials to add on top of the distro base, and the build-only
# base packages to drop. Kept as pure data (no function args) so BOTH the Nix
# assembler (image-packages.nix) and the apt-reference script (apt-resolve-noble.sh)
# read the identical lists — no drift.
{
  # Build-only tooling in jammy's common base that a bootable image doesn't need.
  dropFromBase = [ "g++" "make" "dpkg-dev" "pkg-config" "sysvinit" ];

  # Minimal packages required to boot, plus a few runtime essentials.
  bootEssentials = [
    "systemd"               # init system
    "init-system-helpers"   # provides update-rc.d used by udev hooks
    "systemd-sysv"          # provides /sbin/init
    "linux-image-generic"   # kernel
    "initramfs-tools"       # initramfs generation
    "e2fsprogs"             # initramfs fsck
    "grub-efi"              # boot loader
    "apt"                   # package manager (for later in-image work)
    "ncurses-base"          # terminfo
    "dbus"                  # networkctl / logind
  ];
}
