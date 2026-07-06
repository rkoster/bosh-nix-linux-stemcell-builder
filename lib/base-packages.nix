# Deb base package list for the Noble image assembler.
#
# PROVENANCE
# ----------
# These are the package names that used to come from
# `vmTools.debDistros.ubuntu2204x86_64.packages` in the lheckemann/nixpkgs fork,
# which expands to `commonDebPackages ++ [ "diffutils" "libc-bin" ]`. We inline
# the list here (transcribed verbatim from nixpkgs
# pkgs/build-support/vm/default.nix `commonDebPackages`) so the POC does not
# depend on nixpkgs' `debDistros` table at all — one less piece of upstream's
# legacy vmTools surface for BOSH to track. This is a plain list of .deb package
# NAME strings; the resolver (deb-closure.pl) turns it into a full closure.
#
# It is the generic Debian/Ubuntu build base (toolchain, dpkg, coreutils, login).
# BOSH-specific packages are layered on top in noble-packages.nix.
[
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
  # Needed because it provides /etc/login.defs, whose absence causes
  # the "passwd" post-installs script to fail.
  "login"
  "passwd"
  # debDistros.ubuntu2204x86_64 appended these two to commonDebPackages:
  "diffutils"
  "libc-bin"
]
