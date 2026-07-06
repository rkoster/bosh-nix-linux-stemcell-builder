# Usrmerge-safe reimplementation of vmTools.{fillDiskWithDebs,makeImageFromDebDist}.
#
# WHY THIS EXISTS
# ---------------
# The upstream fork's fillDiskWithDebs unpacks every .deb with a raw
# `dpkg-deb --extract "$deb" /mnt`. Under the hood that is GNU tar WITHOUT
# `--keep-directory-symlink`. On a usrmerged distro (Ubuntu Noble):
#
#   1. `base-files` ships `./sbin -> usr/sbin` (a symlink) and `./usr/sbin/`.
#      Extracting it creates /mnt/sbin as a symlink to usr/sbin.
#   2. A later package that still ships a REAL `./sbin/` DIRECTORY entry
#      (in the Noble stemcell set: gdisk, iproute2, net-tools, xfsprogs,
#      quota, ifupdown, apparmor, runit) makes tar REPLACE the /mnt/sbin
#      symlink with a real directory containing only that package's files.
#
# fillDiskWithDebs then runs a debootstrap-style diversion around dpkg
# configuration that does `mv /mnt/sbin/start-stop-daemon ...`. After the
# clobber, /mnt/sbin is a real dir that does NOT contain start-stop-daemon
# (no Noble package ships it; createRootFS seeds it at /usr/sbin), so the
# `mv` dies with "cannot stat" and the whole build fails.
#
# Real dpkg is usrmerge-aware and never does this. The faithful fix is to
# extract the same way: `--keep-directory-symlink`, which routes a package's
# ./sbin/* into /usr/sbin via the preserved symlink instead of clobbering it.
#
# Everything else is copied verbatim from the fork's fillDiskWithDebs /
# makeImageFromDebDist (pinned, read-only in the Nix store) so behaviour is
# otherwise identical. Only the extraction command on the marked line changed.
{ vmTools, stdenv, lib, dpkg, glibc, xz, gnutar, util-linux, fetchurl }:

let
  storeDir = builtins.storeDir;

  fillDiskWithDebs =
    { size ? 4096, debs, name, fullName, postInstall ? null
    , createRootFS ? vmTools.defaultCreateRootFS
    , QEMU_OPTS ? "", memSize ? 512, ... }@args:

    vmTools.runInLinuxVM (stdenv.mkDerivation ({
      inherit name postInstall QEMU_OPTS memSize;

      debs = (lib.intersperse "|" debs);

      preVM = vmTools.createEmptyImage { inherit size fullName; };

      buildCommand = ''
        ${createRootFS}

        PATH=$PATH:${lib.makeBinPath [ dpkg glibc xz gnutar ]}
        set -o pipefail

        # Unpack the .debs.  We do this to prevent pre-install scripts
        # (which have lots of circular dependencies) from barfing.
        echo "unpacking Debs..."

        for deb in $debs; do
          if test "$deb" != "|"; then
            echo "$deb..."
            # >>> usrmerge-safe extraction (the one change vs. upstream) <<<
            # `--keep-directory-symlink` stops a package's real ./sbin (or
            # ./bin, ./lib) directory entry from replacing the /sbin ->
            # usr/sbin symlink base-files created. See file header.
            dpkg-deb --fsys-tarfile "$deb" \
              | tar -C /mnt -xf - --keep-directory-symlink
          fi
        done

        # Make the Nix store available in /mnt, because that's where the .debs live.
        mkdir -p /mnt/inst${storeDir}
        ${util-linux}/bin/mount -o bind ${storeDir} /mnt/inst${storeDir}
        ${util-linux}/bin/mount -o bind /proc /mnt/proc
        ${util-linux}/bin/mount -o bind /dev /mnt/dev

        # Misc. files/directories assumed by various packages.
        echo "initialising Dpkg DB..."
        touch /mnt/etc/shells
        touch /mnt/var/lib/dpkg/status
        touch /mnt/var/lib/dpkg/available
        touch /mnt/var/lib/dpkg/diversions

        # Now install the .debs.  This is basically just to register
        # them with dpkg and to make their pre/post-install scripts
        # run.
        echo "installing Debs..."

        export DEBIAN_FRONTEND=noninteractive

        oldIFS="$IFS"
        IFS="|"
        for component in $debs; do
          IFS="$oldIFS"
          echo
          echo ">>> INSTALLING COMPONENT: $component"
          debs=
          for i in $component; do
            debs="$debs /inst/$i";
          done
          chroot=$(type -tP chroot)

          # Create a fake start-stop-daemon script, as done in debootstrap.
          mv "/mnt/sbin/start-stop-daemon" "/mnt/sbin/start-stop-daemon.REAL"
          echo "#!/bin/true" > "/mnt/sbin/start-stop-daemon"
          chmod 755 "/mnt/sbin/start-stop-daemon"

          PATH=/usr/bin:/bin:/usr/sbin:/sbin $chroot /mnt \
            /usr/bin/dpkg --install --force-all $debs < /dev/null || true

          # Move the real start-stop-daemon back into its place.
          mv "/mnt/sbin/start-stop-daemon.REAL" "/mnt/sbin/start-stop-daemon"
        done

        echo "running post-install script..."
        eval "$postInstall"

        rm /mnt/.debug

        ${util-linux}/bin/umount /mnt/inst${storeDir}
        ${util-linux}/bin/umount /mnt/proc
        ${util-linux}/bin/umount /mnt/dev
        ${util-linux}/bin/umount /mnt
      '';

      passthru = { inherit fullName; };
    } // args));

  makeImageFromDebDist =
    { name, fullName, size ? 4096, urlPrefix
    , packagesList ? "", packagesLists ? [ packagesList ]
    , packages, extraPackages ? [], postInstall ? ""
    , extraDebs ? [], createRootFS ? vmTools.defaultCreateRootFS
    , QEMU_OPTS ? "", memSize ? 512, ... }@args:

    let
      expr = vmTools.debClosureGenerator {
        inherit name packagesLists urlPrefix;
        packages = packages ++ extraPackages;
      };
    in
    (fillDiskWithDebs ({
      inherit name fullName size postInstall createRootFS QEMU_OPTS memSize;
      debs = import expr { inherit fetchurl; } ++ extraDebs;
    } // args)) // { inherit expr; };
in
{ inherit makeImageFromDebDist fillDiskWithDebs; }
