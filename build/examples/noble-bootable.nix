# NOTE: use systemdMinimal, not `udev`. In nixos-26.05 `pkgs.udev` aliases
# systemd-minimal-libs (a libs-only output with NO systemd-udevd / udevadm
# binaries); referencing it makes postInstall fail with "No such file or
# directory". systemdMinimal is the smallest package that still ships the udev
# binaries we need to populate /dev for grub-install.
{ vmTools, systemdMinimal, gptfdisk, util-linux, dosfstools, e2fsprogs, callPackage }:

let
  noble = callPackage ../ubuntu/apt-pins.nix { };
  # Usrmerge-safe fork of vmTools.makeImageFromDebDist. Upstream's raw
  # `dpkg-deb --extract` clobbers the /sbin -> usr/sbin symlink when a package
  # ships a real ./sbin directory, which breaks the start-stop-daemon diversion.
  # See poc/lib/fill-disk-usrmerge.nix for the full analysis.
  inherit (callPackage ../rootfs/fill-disk-usrmerge.nix { }) makeImageFromDebDist;
in
makeImageFromDebDist {
  inherit (noble) name fullName urlPrefix packagesLists;

  # Full package set from the shared assembler — identical to the set the Task 1.4
  # resolver gate validated (filtered jammy base ++ boot essentials ++ BOSH set).
  packages = (callPackage ../ubuntu/deb-sets.nix { }).image;

  size = 8192;

  createRootFS = ''
    disk=/dev/vda
    ${gptfdisk}/bin/sgdisk $disk \
      -n1:0:+100M -t1:ef00 -c1:esp \
      -n2:0:0 -t2:8300 -c2:root

    ${util-linux}/bin/partx -u "$disk"
    ${dosfstools}/bin/mkfs.vfat -F32 -n ESP "$disk"1
    part="$disk"2
    ${e2fsprogs}/bin/mkfs.ext4 "$part" -L root
    mkdir /mnt
    ${util-linux}/bin/mount -t ext4 "$part" /mnt
    mkdir -p /mnt/{proc,dev,sys,boot/efi}
    ${util-linux}/bin/mount -t vfat "$disk"1 /mnt/boot/efi
    touch /mnt/.debug

    # The fork's fillDiskWithDebs runs a debootstrap-style no-op diversion around
    # dpkg configuration: it `mv /mnt/sbin/start-stop-daemon .REAL`, drops a
    # `#!/bin/true` in its place, configures, then restores. That assumes the file
    # already exists — but NO package in the Noble set ships start-stop-daemon, so
    # the mv fails ("cannot stat") and the build dies.
    #
    # We must provide it, but NOT by `mkdir /mnt/sbin`: Noble is usrmerged and
    # base-files ships `/sbin` as a symlink -> usr/sbin. Pre-creating /sbin as a
    # real directory makes base-files extraction fail with
    #   tar: ./sbin: Cannot create symlink to 'usr/sbin': File exists
    # Instead, seed the stub at the REAL merged location. Extraction then creates
    # the /sbin -> usr/sbin symlink normally, and the diversion resolves
    # /mnt/sbin/start-stop-daemon through it to this file.
    mkdir -p /mnt/usr/sbin
    printf '#!/bin/true\n' > /mnt/usr/sbin/start-stop-daemon
    chmod 755 /mnt/usr/sbin/start-stop-daemon
  '';

  postInstall = ''
    ${systemdMinimal}/lib/systemd/systemd-udevd &
    ${systemdMinimal}/bin/udevadm trigger
    ${systemdMinimal}/bin/udevadm settle

    ${util-linux}/bin/mount -t sysfs sysfs /mnt/sys

    chroot /mnt /bin/bash -exuo pipefail <<CHROOT
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin

    echo LABEL=root / ext4 defaults > /etc/fstab

    update-initramfs -k all -c

    # Serial console so headless QEMU boot is observable and assertable.
    cat >> /etc/default/grub <<EOF
    GRUB_TIMEOUT=5
    GRUB_CMDLINE_LINUX="console=ttyS0"
    GRUB_CMDLINE_LINUX_DEFAULT=""
    EOF
    sed -i '/TIMEOUT_HIDDEN/d' /etc/default/grub
    # update-grub (grub-mkconfig) writes /boot/grub/grub.cfg.new and needs the
    # directory to pre-exist; grub-install (which would create it) runs later.
    mkdir -p /boot/grub
    update-grub
    # --removable writes /EFI/BOOT/BOOTX64.EFI, which OVMF always tries even
    # without a persisted NVRAM boot entry (required for fresh headless boots).
    grub-install --target x86_64-efi --removable
    cp /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true

    echo root:root | chpasswd
    CHROOT
    ${util-linux}/bin/umount /mnt/boot/efi
    ${util-linux}/bin/umount /mnt/sys
  '';
}
