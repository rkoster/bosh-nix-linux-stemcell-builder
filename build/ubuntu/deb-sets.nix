# Ubuntu Noble deb selection. Pure-data package lists (base/boot/bosh) plus the
# assembled top-level `image` set. Folds base-packages.nix, boot-packages.nix,
# noble-packages.nix, and image-packages.nix.
{
  lib,
  callPackage,
  release ? "noble",
}:

let
  aptPins = callPackage ./apt-pins.nix { };
  essential = callPackage ./essential.nix { inherit aptPins; };

  desc = import ./release.nix { inherit release; };
  bosh = desc.boshPackages;

  # Generic Debian/Ubuntu build base (was base-packages.nix; transcribed from
  # nixpkgs commonDebPackages + debDistros.ubuntu2204x86_64's two extras).
  base = [
    "base-passwd"
    "dpkg"
    "libc6-dev"
    "perl"
    "bash"
    "dash"
    "gzip"
    "bzip2"
    "tar"
    "grep"
    "mawk"
    "sed"
    "findutils"
    "g++"
    "make"
    "curl"
    "patch"
    "locales"
    "coreutils"
    # Needed by checkinstall:
    "util-linux"
    "file"
    "dpkg-dev"
    "pkg-config"
    # /etc/login.defs (passwd post-install):
    "login"
    "passwd"
    # debDistros.ubuntu2204x86_64 extras:
    "diffutils"
    "libc-bin"
  ];

  # Build-only tooling to drop from `base` for a bootable image (was boot-packages).
  dropFromBase = [
    "g++"
    "make"
    "dpkg-dev"
    "pkg-config"
  ];

  # Minimal boot + runtime essentials (was boot-packages.nix).
  bootEssentials = [
    "systemd"
    "init-system-helpers"
    "systemd-sysv"
    "linux-image-generic"
    "initramfs-tools"
    "e2fsprogs"
    "grub-efi"
    "grub-pc-bin"
    "apt"
    "ncurses-base"
    "dbus"
  ];
in
{
  inherit
    base
    dropFromBase
    bootEssentials
    bosh
    ;

  # Single source of truth for the full top-level set installed into the image
  # (was image-packages.nix). Consumed by rootfs/rootfs.nix and the example gates.
  image = lib.unique (
    essential ++ lib.filter (p: !lib.elem p dropFromBase) base ++ bootEssentials ++ bosh
  );
}
