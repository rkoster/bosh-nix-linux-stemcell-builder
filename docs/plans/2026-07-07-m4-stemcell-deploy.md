# M4 — Nix Stemcell Packaging & End-to-End Deploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package the M3-complete Nix OS image (`os-image` → `rootfs.tar.gz`) into a bootable BOSH stemcell `.tgz`, deploy it to the Incus/`instant-bosh` director, and prove the Nix-built OS booted via `bosh ssh`.

**Architecture:** Three layered artifacts. `mk-bootable-disk.nix` is a `runInLinuxVM` derivation that partitions a scratch disk (MBR, ESP+root — faithful to classic `image_create_efi`), extracts the M3 rootfs tarball, installs dual-target grub (faithful to `image_install_grub`), and emits `root.qcow2`. `mk-stemcell.nix` is a pure derivation that wraps the qcow2 into the strict 6-member BOSH stemcell `.tgz` (faithful to `stemcell_packager.rb`). `deploy-stemcell.sh` is an imperative script that uploads, deploys a jobless manifest (`./nix-stemcell-poc.yml`), and verifies via `bosh vms` + `bosh ssh`.

**Tech Stack:** Nix flakes (`nixos-26.05`), `vmTools.runInLinuxVM`, QEMU, grub2, BOSH CLI v2, Incus `lxd_cpi`.

**Design doc:** `docs/superpowers/specs/2026-07-07-m4-stemcell-deploy-design.md`

**Key conventions from the codebase (do not deviate):**
- Every package file in `poc/examples/` and `poc/pkgs/` is auto-mapped to a flake output by `poc/flake.nix` (`mapDir`): a file `foo.nix` taking `{ ... }` becomes `.#foo`. New `examples/*.nix` files must be `callPackage`-compatible (top-level `{ ... }:` function).
- Inside a Nix `''…''` string, bash `${var}` must be written `''${var}`; single `$var` passes through untouched. `${nixExpr}` is Nix interpolation. Heredocs with `${...}` are still Nix-interpolated regardless of bash quoting.
- `nix` commands run from the repo root as `nix build ./poc#<name>` (the flake lives in `poc/`).
- The proven `runInLinuxVM` + `createEmptyImage` + `/dev/vda` + `partx -u` + udev + grub-install pattern is in `poc/examples/noble-bootable.nix`. The proven bind-mount `/dev` chroot pattern is in `poc/lib/fill-disk-usrmerge.nix`.

---

## Task 1: Verify boot closure has kernel, initramfs, and BIOS grub

The disk stage runs `grub-install --target=i386-pc` inside the chroot (classic dual-boot). That needs the **i386-pc** grub modules, which ship in the `grub-pc-bin` package — the M2 set only has `grub-efi` (see `poc/lib/boot-packages.nix:17`). Without it, the BIOS grub-install fails with "cannot find `.../i386-pc`". Also confirm the kernel + initramfs tooling are present (design R1 hard gate). This task de-risks the disk stage before we write it.

**Files:**
- Modify: `poc/lib/boot-packages.nix:10-21`

- [ ] **Step 1: Inspect the current boot essentials**

Run: `sed -n '9,21p' poc/lib/boot-packages.nix`
Expected: a `bootEssentials` list containing `linux-image-generic`, `initramfs-tools`, `grub-efi` — but **no** `grub-pc-bin`.

- [ ] **Step 2: Add the BIOS grub package**

Edit `poc/lib/boot-packages.nix` — add `grub-pc-bin` immediately after the `grub-efi` line so the i386-pc target is installable:

```nix
    "grub-efi"              # boot loader (UEFI target)
    "grub-pc-bin"           # boot loader (BIOS i386-pc target, for dual-boot fallback)
```

- [ ] **Step 3: Confirm the closure still resolves and includes kernel + both grub targets**

Run: `nix build ./poc#os-image --no-link 2>&1 | tail -5 && echo BUILD_OK`
Expected: ends with `BUILD_OK` (the deb closure re-resolves and the full os-image rebuilds with the added package). This may take several minutes (VM build).

- [ ] **Step 4: Assert kernel, initramfs, and both grub targets are actually in the rootfs**

Run:
```bash
OS=$(nix build ./poc#os-image --no-link --print-out-paths)
tar tzf "$OS/rootfs.tar.gz" | grep -E 'boot/vmlinuz-|usr/lib/grub/i386-pc/|usr/lib/grub/x86_64-efi/|usr/sbin/grub-install' | sort -u | head -20
```
Expected: at least one `./boot/vmlinuz-*` entry, one `./usr/lib/grub/i386-pc/` entry, one `./usr/lib/grub/x86_64-efi/` entry, and `./usr/sbin/grub-install`. If `boot/vmlinuz-*` is absent, STOP — the kernel is not in the closure and the plan's R1 mitigation (add `linux-image-generic`, already present) needs investigation before continuing.

- [ ] **Step 5: Commit**

```bash
git add poc/lib/boot-packages.nix
git commit -m "feat(m4): add grub-pc-bin for BIOS i386-pc dual-boot grub target"
```

---

## Task 2: `mk-bootable-disk.nix` — disk assembly derivation

Create the `runInLinuxVM` derivation that turns `rootfs.tar.gz` into a bootable `root.qcow2`, faithfully replicating `image_create_efi/apply.sh` (partitioning) and `image_install_grub/apply.sh` (grub), then converting with the classic `prepare_qcow2_image_stemcell/apply.sh` flags.

**Deviation notes (intentional, documented in the design):**
- Target disk is `/dev/vda` from `createEmptyImage` (proven in `noble-bootable.nix`), not a file+losetup+kpartx as in the classic host build. The partition **geometry** is identical; only the device-mapping mechanism differs (a real VM block device needs no loopback).
- We bind-mount all of `/dev` into the chroot (matching our proven `fill-disk-usrmerge.nix` VM pattern), rather than the classic's individual device-node binds. The VM chroot needs `/dev/null` etc.; the classic ran on a host with a populated `/dev`. Documented as design G3.

**Files:**
- Create: `poc/lib/mk-bootable-disk.nix`
- Create: `poc/examples/noble-stemcell-disk.nix`

- [ ] **Step 1: Write the disk-assembly library**

Create `poc/lib/mk-bootable-disk.nix`:

```nix
# Turns an M3 os-image rootfs tarball into a bootable openstack qcow2.
# Faithful to the classic image_create_efi (dos-label MBR: ~48MiB ESP + ext4
# root) and image_install_grub (dual x86_64-efi + i386-pc grub, vcap pbkdf2
# superuser, byte-exact GRUB_CMDLINE_LINUX, UUID fstab) stages, then converts
# with the prepare_qcow2_image_stemcell flags (-c -O qcow2 -o compat=0.10).
#
# Deviations vs. classic (see design G1-G4 + §4): /dev/vda target (createEmptyImage,
# as in noble-bootable.nix) instead of losetup/kpartx on a file; full /dev bind
# for the chroot (as in fill-disk-usrmerge.nix) instead of per-node binds.
{ vmTools, stdenv, lib
, util-linux, dosfstools, e2fsprogs, gnutar, qemu, systemdMinimal }:

{ osImage                     # derivation producing $out/rootfs.tar.gz
, diskSizeMiB ? 5120          # openstack image_create_disk_size (infrastructure.rb:71)
, fullName ? "BOSH Noble stemcell disk" }:

vmTools.runInLinuxVM (stdenv.mkDerivation {
  name = "noble-stemcell-disk";
  memSize = 2048;

  # Provides a blank 5120 MiB /dev/vda inside the VM (proven in noble-bootable.nix).
  preVM = vmTools.createEmptyImage {
    size = diskSizeMiB;
    inherit fullName;
  };

  buildCommand = ''
    disk=/dev/vda
    root_dev="$disk"2
    efi_dev="$disk"1

    # --- Partition: dos label, ESP (2048/98304 sectors, type ef, bootable)
    #     + Linux root (100352.., type 83). Faithful to image_create_efi:18-26.
    ${util-linux}/bin/sfdisk $disk <<SFDISK
    label: dos
    unit: sectors

    start=2048, size=98304, type=ef, bootable
    start=100352, type=83
    SFDISK

    ${util-linux}/bin/partx -u "$disk"

    ${dosfstools}/bin/mkfs.vfat "$efi_dev"
    ${e2fsprogs}/bin/mkfs.ext4 "$root_dev"

    # --- Mount + populate from the M3 rootfs tarball (replaces classic rsync -aHA)
    mkdir -p /mnt
    ${util-linux}/bin/mount "$root_dev" /mnt
    mkdir -p /mnt/boot/efi
    ${util-linux}/bin/mount "$efi_dev" /mnt/boot/efi

    ${gnutar}/bin/tar -xpf ${osImage}/rootfs.tar.gz -C /mnt --numeric-owner

    # --- udev so grub can probe the disk; bind proc/sys/dev for the chroot
    ${systemdMinimal}/lib/systemd/systemd-udevd &
    ${systemdMinimal}/bin/udevadm trigger
    ${systemdMinimal}/bin/udevadm settle
    ${util-linux}/bin/mount -t proc none /mnt/proc
    ${util-linux}/bin/mount -t sysfs none /mnt/sys
    ${util-linux}/bin/mount -o bind /dev /mnt/dev

    # --- device.map handshake for the BIOS install (image_install_grub:75-76)
    mkdir -p /mnt/boot/grub
    echo "(hd0) $disk" > /mnt/boot/grub/device.map
    echo "(hd0) $disk" > /mnt/device.map

    # --- Dual grub-install (image_install_grub:79-80)
    chroot /mnt /bin/bash -exuo pipefail <<CHROOT
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot/efi/EFI --removable -v --no-floppy $disk
    grub-install -v --target=i386-pc --grub-mkdevicemap=/device.map --no-floppy $disk
    CHROOT

    # --- Byte-exact GRUB_CMDLINE_LINUX (image_install_grub:98); openstack suffix empty
    cat > /mnt/etc/default/grub <<'GRUBDEF'
    GRUB_CMDLINE_LINUX="vconsole.keymap=us net.ifnames=0 biosdevname=0 crashkernel=auto selinux=0 plymouth.enable=0 console=ttyS0,115200n8 earlyprintk=ttyS0 rootdelay=300 audit=1 cgroup_enable=memory swapaccount=1 apparmor=1 security=apparmor "
    GRUBDEF

    # --- Random pbkdf2 grub password, superuser vcap (image_install_grub:51-107)
    random_password=$(tr -dc A-Za-z0-9_ < /dev/urandom | head -c 16)
    pbkdf2_password=$(chroot /mnt /bin/bash -c "echo -e '$random_password\n$random_password' | grub-mkpasswd-pbkdf2 | grep -Eo 'grub.pbkdf2.sha512.*'")
    cat >> /mnt/etc/grub.d/00_header <<HEADER
    cat << EOF
    set superusers=vcap
    password_pbkdf2 vcap $pbkdf2_password
    EOF
    HEADER

    # --- Unrestricted menuentry so the password only gates editing (…:110)
    sed -i -e 's/--class os/--class os --unrestricted/g' /mnt/etc/grub.d/10_linux

    # --- grub-mkconfig to both UEFI + BIOS locations (…:113-114)
    chroot /mnt /bin/bash -exuo pipefail <<CHROOT2
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    GRUB_DISABLE_RECOVERY=true grub-mkconfig -o /boot/efi/EFI/grub/grub.cfg
    GRUB_DISABLE_RECOVERY=true grub-mkconfig -o /boot/grub/grub.cfg
    CHROOT2

    # --- root=UUID rewrite + UUID fstab (…:116-134)
    uuid_efi=$(${util-linux}/bin/blkid -c /dev/null -sUUID -ovalue "$efi_dev")
    uuid_root=$(${util-linux}/bin/blkid -c /dev/null -sUUID -ovalue "$root_dev")

    sed -i "s%root=$root_dev%root=UUID=$uuid_root%g" /mnt/boot/efi/EFI/grub/grub.cfg
    sed -i "s%root=$root_dev%root=UUID=$uuid_root%g" /mnt/boot/grub/grub.cfg

    rm -f /mnt/boot/grub/device.map /mnt/device.map

    cat > /mnt/etc/fstab <<FSTAB
    # /etc/fstab Created by BOSH Stemcell Builder (Nix POC)
    UUID=$uuid_efi /boot/efi vfat umask=0177 1 1
    UUID=$uuid_root / ext4 defaults 1 1
    FSTAB

    # --- Unmount, then convert /dev/vda → compressed qcow2 (prepare_qcow2:8)
    ${util-linux}/bin/umount /mnt/dev
    ${util-linux}/bin/umount /mnt/sys
    ${util-linux}/bin/umount /mnt/proc
    ${util-linux}/bin/umount /mnt/boot/efi
    ${util-linux}/bin/umount /mnt

    mkdir -p $out
    ${qemu}/bin/qemu-img convert -c -O qcow2 -o compat=0.10 -f raw "$disk" $out/root.qcow2
  '';
})
```

- [ ] **Step 2: Write the flake entry point**

Create `poc/examples/noble-stemcell-disk.nix` (auto-mapped to `.#noble-stemcell-disk`):

```nix
# Entry point: bootable openstack qcow2 built from the M3 os-image rootfs.
{ callPackage }:
callPackage ../lib/mk-bootable-disk.nix { } {
  osImage = callPackage ./os-image.nix { };
}
```

- [ ] **Step 3: Evaluate the derivation (fast fail on Nix syntax / escaping)**

Run: `nix eval ./poc#noble-stemcell-disk.drvPath`
Expected: prints a `/nix/store/….drv` path, no evaluation errors. If it errors with an "undefined variable" or "syntax error", the most likely cause is an unescaped bash `${…}` inside the `''` string — audit for `${` that is not a Nix interpolation.

- [ ] **Step 4: Build the bootable disk**

Run: `nix build ./poc#noble-stemcell-disk --print-out-paths`
Expected: succeeds (long VM build, disk-intensive) and prints an out path. On failure, read the VM console output; common issues: BIOS grub-install failing (means Task 1's `grub-pc-bin` didn't land) or missing kernel (R1).

- [ ] **Step 5: Assert the qcow2 exists and is valid**

Run:
```bash
DISK=$(nix build ./poc#noble-stemcell-disk --no-link --print-out-paths)
ls -la "$DISK/root.qcow2" && nix run nixpkgs#qemu -- qemu-img info "$DISK/root.qcow2"
```
Expected: `root.qcow2` exists; `qemu-img info` reports `file format: qcow2` and `virtual size: 5 GiB (5368709120 bytes)`.

- [ ] **Step 6: Commit**

```bash
git add poc/lib/mk-bootable-disk.nix poc/examples/noble-stemcell-disk.nix
git commit -m "feat(m4): mk-bootable-disk.nix — MBR dual-boot grub disk assembly to qcow2"
```

---

## Task 3: Boot-smoke the qcow2 locally before involving the director

Cheap local proof that the assembled disk boots before we spend director cycles. Reuses the existing `poc/scripts/boot-qemu.sh` (headless QEMU/OVMF, polls the serial log for a `login:` prompt). This validates grub + kernel + initramfs + fstab end-to-end.

**Files:**
- Use (no change): `poc/scripts/boot-qemu.sh`

- [ ] **Step 1: Build the disk and boot it headless via OVMF**

Run:
```bash
DISK=$(nix build ./poc#noble-stemcell-disk --no-link --print-out-paths)
nix develop ./poc --command bash poc/scripts/boot-qemu.sh "$DISK/root.qcow2"
```
Expected: prints `BOOT OK: reached login prompt` and exits 0. (`boot-qemu.sh` boots UEFI via `OVMF_FD`, which the devshell exports.)

- [ ] **Step 2: (If BIOS-path assurance is wanted) boot without OVMF to exercise i386-pc grub**

Run:
```bash
DISK=$(nix build ./poc#noble-stemcell-disk --no-link --print-out-paths)
W=$(mktemp -d); cp --no-preserve=mode "$DISK/root.qcow2" "$W/d.qcow2"
timeout 240 nix run nixpkgs#qemu -- qemu-system-x86_64 \
  -m 2048 -smp 2 -drive file="$W/d.qcow2",if=virtio,format=qcow2 \
  -nographic -serial mon:stdio -display none -net none 2>&1 | tee "$W/bios-boot.log" | grep -m1 'login:' && echo BIOS_BOOT_OK
rm -rf "$W"
```
Expected: prints `login:` then `BIOS_BOOT_OK`. This confirms the BIOS/MBR grub path (no OVMF firmware) also boots — the openstack/kvm stemcell may be booted either way by the CPI.

- [ ] **Step 3: No commit** (verification-only task; no files changed)

Note: if boot fails here, do NOT proceed to packaging. Debug grub/fstab first (systematic-debugging skill). A failed local boot will also fail on the director.

---

## Task 4: `mk-stemcell.nix` — package the 6-member stemcell `.tgz`

Wrap the qcow2 into the strict BOSH stemcell archive, faithful to `stemcell_packager.rb` (6 members, exact order, sha1 of the inner `image`) and the openstack cloud_properties. Pure derivation — no VM.

**Files:**
- Create: `poc/lib/mk-stemcell.nix`
- Create: `poc/examples/noble-stemcell.nix`

- [ ] **Step 1: Write the packaging library**

Create `poc/lib/mk-stemcell.nix`:

```nix
# Pure packaging: qcow2 -> 6-member BOSH stemcell .tgz.
# Faithful to bosh-stemcell/lib/bosh/stemcell/stemcell_packager.rb:
#   inner `image` = tar(gz) of root.img (a hardlink to root.qcow2 for openstack,
#   per prepare_qcow2_image_stemcell:12); stemcell.MF carries sha1(image); the
#   archive contains exactly [stemcell.MF, packages.txt, dev_tools_file_list.txt,
#   image, sbom.spdx.json, sbom.cdx.json] in that order (packager raises on
#   missing OR extra members). Name has NO -go_agent suffix (design D1).
{ stdenv, coreutils, gnutar, gzip }:

{ disk                        # derivation producing $out/root.qcow2
, version ? "0.0.1-nix" }:

let
  stemcellName = "bosh-openstack-kvm-ubuntu-noble";
  archive = "bosh-stemcell-${version}-openstack-kvm-ubuntu-noble.tgz";
in
stdenv.mkDerivation {
  name = "noble-stemcell";
  nativeBuildInputs = [ coreutils gnutar gzip ];
  buildCommand = ''
    mkdir -p work/stemcell
    cd work

    # inner image: root.img is a hardlink to the qcow2 (openstack), tarred as `image`
    cp --no-preserve=mode ${disk}/root.qcow2 root.qcow2
    ln root.qcow2 root.img
    tar zcf stemcell/image root.img

    sha1=$(sha1sum stemcell/image | cut -d' ' -f1)

    cat > stemcell/stemcell.MF <<MF
    ---
    name: ${stemcellName}
    version: ${version}
    bosh_protocol: 1
    api_version: 3
    sha1: $sha1
    operating_system: ubuntu-noble
    stemcell_formats:
    - openstack-qcow2
    - openstack-raw
    cloud_properties:
      name: ${stemcellName}
      version: ${version}
      infrastructure: openstack
      hypervisor: kvm
      disk: 5120
      disk_format: qcow2
      container_format: bare
      os_type: linux
      os_distro: ubuntu
      architecture: x86_64
      auto_disk_config: true
    MF

    : > stemcell/packages.txt
    : > stemcell/dev_tools_file_list.txt
    echo '{}' > stemcell/sbom.spdx.json
    echo '{}' > stemcell/sbom.cdx.json

    mkdir -p $out
    tar -C stemcell -zcf "$out/${archive}" \
      stemcell.MF packages.txt dev_tools_file_list.txt image sbom.spdx.json sbom.cdx.json
  '';
}
```

> Heredoc note: the `<<MF` body carries Nix interpolations `${stemcellName}`/`${version}` (intended) and one bash var `$sha1` (single `$`, untouched by Nix). Keep the body indentation uniform so Nix's `''` common-indent stripping leaves the YAML flush-left with `cloud_properties:` children indented two spaces — Step 3 verifies this parsed correctly.

- [ ] **Step 2: Write the flake entry point**

Create `poc/examples/noble-stemcell.nix` (auto-mapped to `.#noble-stemcell`):

```nix
# Entry point: the deployable BOSH stemcell .tgz.
{ callPackage }:
callPackage ../lib/mk-stemcell.nix { } {
  disk = callPackage ./noble-stemcell-disk.nix { };
}
```

- [ ] **Step 3: Build and assert the archive contract**

Run:
```bash
ST=$(nix build ./poc#noble-stemcell --no-link --print-out-paths)
TGZ=$(ls "$ST"/*.tgz)
echo "archive: $(basename "$TGZ")"
tar tzf "$TGZ"
```
Expected: archive name is `bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz` (NO `-go_agent`), and `tar tzf` lists **exactly** these six, in this order:
```
stemcell.MF
packages.txt
dev_tools_file_list.txt
image
sbom.spdx.json
sbom.cdx.json
```

- [ ] **Step 4: Assert the manifest is valid YAML and its sha1 matches the inner image**

Run:
```bash
ST=$(nix build ./poc#noble-stemcell --no-link --print-out-paths)
TGZ=$(ls "$ST"/*.tgz); W=$(mktemp -d); tar xzf "$TGZ" -C "$W"
grep -E '^name: bosh-openstack-kvm-ubuntu-noble$' "$W/stemcell.MF"
grep -E '^operating_system: ubuntu-noble$' "$W/stemcell.MF"
MF_SHA=$(grep -E '^sha1:' "$W/stemcell.MF" | awk '{print $2}')
IMG_SHA=$(sha1sum "$W/image" | cut -d' ' -f1)
test "$MF_SHA" = "$IMG_SHA" && echo "SHA1_MATCH_OK"
rm -rf "$W"
```
Expected: the two `grep`s print their lines (proves the YAML wasn't corrupted by heredoc indentation), and the script prints `SHA1_MATCH_OK`. If `SHA1_MATCH_OK` is absent, the manifest sha1 doesn't match the packaged image — do not upload.

- [ ] **Step 5: Commit**

```bash
git add poc/lib/mk-stemcell.nix poc/examples/noble-stemcell.nix
git commit -m "feat(m4): mk-stemcell.nix — 6-member openstack-kvm-noble stemcell .tgz"
```

---

## Task 5: Jobless deploy manifest at the workspace root

Create the checked-in `./nix-stemcell-poc.yml` the deploy script hands to `bosh deploy`. Jobless (no releases, no jobs) — just enough to make the CPI create one VM from the Nix stemcell. Network / vm_type / az reference the director's **existing** cloud-config (Task 6 validates the names exist and prints the real ones if they differ).

**Files:**
- Create: `./nix-stemcell-poc.yml` (workspace root)

- [ ] **Step 1: Write the manifest**

Create `./nix-stemcell-poc.yml`:

```yaml
---
name: nix-stemcell-poc

# Jobless smoke deployment: proves the Nix-built stemcell boots and its BOSH
# agent registers with the director. No releases, no jobs, no compilation.
# network/vm_type/az below must exist in the director's cloud-config
# (deploy-stemcell.sh validates and prints the real names if these are wrong).

stemcells:
- alias: default
  os: ubuntu-noble
  version: "0.0.1-nix"

instance_groups:
- name: nix-smoke
  instances: 1
  stemcell: default
  vm_type: default
  azs: [z1]
  networks:
  - name: default
  jobs: []

update:
  canaries: 1
  max_in_flight: 1
  canary_watch_time: 30000-600000
  update_watch_time: 30000-600000
  serial: true
```

- [ ] **Step 2: Confirm the file is at the repo root and git-tracked**

Run: `test -f ./nix-stemcell-poc.yml && git status --porcelain nix-stemcell-poc.yml`
Expected: prints `?? nix-stemcell-poc.yml` (untracked, present at root).

- [ ] **Step 3: Commit**

```bash
git add nix-stemcell-poc.yml
git commit -m "feat(m4): jobless deploy manifest for the Nix stemcell smoke test"
```

---

## Task 6: `deploy-stemcell.sh` — upload, deploy, and verify via `bosh ssh`

The imperative deploy step (outside the Nix boundary). Sources `bosh.env`, uploads the stemcell, validates the manifest's cloud-config references, deploys, and runs the three-green-light verification (`bosh vms` running, `bosh ssh -c 'uname -r'`, `os-release`).

**Files:**
- Create: `poc/scripts/deploy-stemcell.sh`

- [ ] **Step 1: Write the deploy script**

Create `poc/scripts/deploy-stemcell.sh`:

```bash
#!/usr/bin/env bash
# End-to-end deploy of the Nix-built stemcell to the instant-bosh director.
# DoD: bosh vms shows the instance running AND bosh ssh prints the kernel version.
#
# Usage (from repo root):
#   source ./bosh.env && bash poc/scripts/deploy-stemcell.sh [path-to.tgz]
#   bash poc/scripts/deploy-stemcell.sh --cleanup   # tear the deployment down
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOYMENT="nix-stemcell-poc"
MANIFEST="$REPO_ROOT/nix-stemcell-poc.yml"

if [ "${1:-}" = "--cleanup" ]; then
  bosh -n -d "$DEPLOYMENT" delete-deployment
  bosh -n clean-up --all
  echo "cleanup done"
  exit 0
fi

# --- Preflight: env + director reachability
: "${BOSH_ENVIRONMENT:?source ./bosh.env first}"
: "${BOSH_CLIENT:?source ./bosh.env first}"
bosh env >/dev/null
echo "director OK: $BOSH_ENVIRONMENT"

# --- Locate or build the stemcell .tgz
TGZ="${1:-}"
if [ -z "$TGZ" ]; then
  echo "building .#noble-stemcell ..."
  ST=$(nix build "$REPO_ROOT/poc#noble-stemcell" --no-link --print-out-paths)
  TGZ=$(ls "$ST"/*.tgz)
fi
test -f "$TGZ" || { echo "stemcell tgz not found: $TGZ" >&2; exit 1; }
echo "stemcell: $TGZ"

# --- Upload
bosh -n upload-stemcell "$TGZ"
bosh stemcells | grep -E 'bosh-openstack-kvm-ubuntu-noble|ubuntu-noble' || true

# --- Validate cloud-config references used by the manifest
CC=$(bosh cloud-config 2>/dev/null || true)
for ref in "network:default:name default" "vm_type:default vm_types" "az:z1 azs"; do
  key=${ref%% *}
  case "$key" in
    network:default:name) grep -q 'name: default' <<<"$CC" || echo "WARN: no 'default' network in cloud-config" ;;
    vm_type:default)      grep -q 'default' <<<"$CC"       || echo "WARN: no 'default' vm_type in cloud-config" ;;
    az:z1)                grep -q 'z1' <<<"$CC"            || echo "WARN: no 'z1' az in cloud-config" ;;
  esac
done
echo "--- cloud-config (edit nix-stemcell-poc.yml if the names above don't match) ---"
echo "$CC" | grep -E 'name:|az|vm_type' | head -40 || true

# --- Deploy (jobless)
bosh -n -d "$DEPLOYMENT" deploy "$MANIFEST"

# --- Verify green light 1: instance running
echo "=== bosh vms ==="
bosh -d "$DEPLOYMENT" vms
bosh -d "$DEPLOYMENT" vms | grep -Eq '\brunning\b' \
  || { echo "FAIL: no running instance" >&2; bosh -d "$DEPLOYMENT" instances --details >&2; exit 1; }

# --- Verify green lights 2 + 3: bosh ssh proves the Nix OS actually booted
echo "=== bosh ssh: uname -r ==="
KVER=$(bosh -d "$DEPLOYMENT" ssh nix-smoke/0 -r -c 'uname -r' --column=Stdout | tr -d '[:space:]')
echo "kernel: $KVER"
test -n "$KVER" || { echo "FAIL: bosh ssh returned no kernel version" >&2; exit 1; }

echo "=== bosh ssh: os-release ==="
bosh -d "$DEPLOYMENT" ssh nix-smoke/0 -r -c 'cat /etc/os-release' --column=Stdout | grep -E 'ubuntu|noble' \
  || { echo "FAIL: os-release did not report ubuntu/noble" >&2; exit 1; }

echo
echo "DEPLOY OK — Nix stemcell booted; agent healthy; kernel $KVER"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x poc/scripts/deploy-stemcell.sh`

- [ ] **Step 3: Shellcheck / syntax gate (no director needed)**

Run: `bash -n poc/scripts/deploy-stemcell.sh && nix run nixpkgs#shellcheck -- poc/scripts/deploy-stemcell.sh || true`
Expected: `bash -n` produces no output (syntax OK). Shellcheck warnings are advisory; fix any error-level findings.

- [ ] **Step 4: Commit**

```bash
git add poc/scripts/deploy-stemcell.sh
git commit -m "feat(m4): deploy-stemcell.sh — upload, jobless deploy, bosh ssh verify"
```

---

## Task 7: End-to-end run against the director + findings doc

Execute the full pipeline against the real `instant-bosh` director and record the outcome. This is the DoD gate and the deliverable's strongest feasibility signal. Per the design, a failure at the deploy/settings step is a **findings result** (especially design R2: lxd_cpi/Incus settings delivery), not necessarily a script bug.

**Files:**
- Create: `docs/superpowers/specs/2026-07-07-m4-deploy-findings.md`

- [ ] **Step 1: Run the full deploy end-to-end**

Run:
```bash
source ./bosh.env
bash poc/scripts/deploy-stemcell.sh 2>&1 | tee /tmp/m4-deploy.log
```
Expected (success): ends with `DEPLOY OK — Nix stemcell booted; agent healthy; kernel <ver>`. Capture the kernel version and the full log either way.

- [ ] **Step 2: If the agent never reaches `running`, investigate settings delivery (R2)**

Only if Step 1 fails at the `running`/agent stage, gather evidence (do not treat as a mere script bug):
```bash
bosh -d nix-stemcell-poc instances --details 2>&1 | tee -a /tmp/m4-deploy.log
bosh -d nix-stemcell-poc task --debug 2>&1 | tail -80 | tee -a /tmp/m4-deploy.log
```
Then check whether the OpenStack `agent.json` settings source (ConfigDrive `config-2` / HTTP `169.254.169.254`) is provided by the Incus `lxd_cpi`. Record what you find — this is the primary open feasibility question for the OpenStack agent settings on Incus.

- [ ] **Step 3: Write the findings doc**

Create `docs/superpowers/specs/2026-07-07-m4-deploy-findings.md` capturing: the outcome (running? kernel version from `bosh ssh`?), each of the three green lights, any R2 settings-delivery findings, deviations hit during implementation (grub-pc-bin, /dev bind, /dev/vda vs losetup), and a verdict on M4 feasibility (VIABLE / VIABLE_WITH_CAVEATS / BLOCKED) with the evidence. Follow the structure of `docs/superpowers/specs/2026-07-07-m3-agent-blobstore-findings.md`.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-07-07-m4-deploy-findings.md
git commit -m "docs(m4): end-to-end deploy findings and feasibility verdict"
```

- [ ] **Step 5: (On success) leave the deployment running or clean up**

Run (optional): `bash poc/scripts/deploy-stemcell.sh --cleanup`
Expected: `cleanup done`. Skip this if you want to leave the VM up for further validation.

---

## Self-Review Checklist (completed by plan author)

**Spec coverage** — every design section maps to a task:
- §4 disk assembly (partition + grub + qcow2) → Task 2; kernel/grub prereq (R1 + grub-pc-bin) → Task 1; local boot proof → Task 3.
- §5 packaging (6-member .tgz, sha1, D1 naming, byte-exact fields) → Task 4.
- §6 deploy (upload, jobless manifest, `bosh vms`, `bosh ssh` uname/os-release) → Tasks 5 + 6.
- §7 verification + risks (R1 Task 1; R2 Task 7 Step 2; R3 Task 2 device.map/deviation notes; R6 Task 4 aux stubs) + findings → Task 7.
- Design corrections folded in: D1 (no `-go_agent`) Task 4; D2 (byte-exact cmdline) Task 2; G1 (device.map) Task 2; G2/G3/G4 documented in Task 2 deviation notes.

**Placeholder scan** — no TBD/TODO; every code step has complete file content; every verification step has an exact command + expected output.

**Type/name consistency** — flake output names (`noble-stemcell-disk`, `noble-stemcell`), derivation arg names (`osImage`, `disk`, `version`), deployment name (`nix-stemcell-poc`), instance group (`nix-smoke`), stemcell version (`0.0.1-nix`), and archive name (`bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz`) are consistent across Tasks 2, 4, 5, and 6.
