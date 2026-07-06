{ vmTools, udev, gptfdisk, util-linux, dosfstools, e2fsprogs, callPackage }:

let
  noble = callPackage ../lib/noble-distro.nix { };
in
vmTools.makeImageFromDebDist {
  inherit (noble) name fullName urlPrefix packagesLists;

  # Full package set from the shared assembler — identical to the set the Task 1.4
  # resolver gate validated (filtered jammy base ++ boot essentials ++ BOSH set).
  packages = callPackage ../lib/image-packages.nix { };

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
    
    # Stub out files that sysvinit-utils postinst will try to move but don't exist yet.
    # This prevents "mv: cannot stat" errors during package installation.
    mkdir -p /mnt/sbin
    touch /mnt/sbin/start-stop-daemon
  '';

  postInstall = ''
    ${udev}/lib/systemd/systemd-udevd &
    ${udev}/bin/udevadm trigger
    ${udev}/bin/udevadm settle

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
