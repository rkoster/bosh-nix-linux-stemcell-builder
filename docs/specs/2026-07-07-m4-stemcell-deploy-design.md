# M4 — Nix Stemcell Packaging & End-to-End Deploy (Design)

**Date:** 2026-07-07
**Status:** APPROVED (self-reviewed against upstream stages + packager; D1/D2 corrected, G1–G4 + R6 folded in)
**Phase:** M4 (end-to-end deploy — bootable stemcell + running BOSH VM)
**Scope:** Package the M3-complete Nix OS image (`rootfs.tar.gz`) into a bootable
BOSH stemcell `.tgz`, upload it to the Incus/`instant-bosh` director, deploy a
jobless VM, and prove the Nix-built OS booted via `bosh ssh`. `ubuntu-noble` +
OpenStack/KVM + qcow2 only; non-FIPS; x86_64.

---

## 1. Goal & Definition of Done

M1–M3 produced a reproducible `os-image` (`rootfs.tar.gz`) containing the base
OS, the source-built BOSH agent + four blobstore CLIs, and OpenStack agent
settings. That tarball is **not** a deployable stemcell. M4 closes the gap:
partition + make bootable, wrap in the strict BOSH stemcell archive contract,
and validate against the real director.

**Definition of Done (all automated in `deploy-stemcell.sh`):**

1. `nix build .#noble-stemcell` produces a valid 6-member stemcell `.tgz`.
2. `bosh upload-stemcell` registers it (`bosh stemcells`).
3. Jobless `bosh deploy` → `bosh vms` shows the instance **`running`**.
4. `bosh ssh -c 'uname -r'` prints a non-empty kernel version.
5. `bosh ssh -c 'cat /etc/os-release'` confirms `ubuntu` / `noble`.

**Explicitly out of scope:** BOSH releases, package compilation, jobs, multi-IaaS
bootability, FIPS. The goal is a *running agent on a Nix-built OS*, nothing more.

---

## 2. Scope (Confirmed Decisions)

| Decision | Choice |
|----------|--------|
| Build approach | **A2 — article-faithful full Nix** (Ruby/Rake build path removed; `bosh-stemcell/spec/` retained as oracle) |
| Target | **ubuntu-noble + OpenStack/KVM + qcow2** only; non-FIPS; x86_64 |
| DoD | **Running BOSH VM** from the Nix stemcell; agent healthy + `bosh ssh` proves kernel booted |
| Disk layout | **Faithfully replicate classic** MBR + dual-boot (`image_create_efi` + `image_install_grub`) |
| Packaging | Real `stemcell.MF` + inner `image`; aux files **minimal/empty stubs** |
| Stemcell version | **`0.0.1-nix`** (synthetic dev version) |
| Aux file format | **Bare minimal**: empty `packages.txt`/`dev_tools_file_list.txt`, `{}` SBOMs |
| Cloud-config | **Reuse the director's existing one**; M4 only writes a jobless manifest |
| Architecture | **Approach 1 — layered Nix derivations**: `mk-bootable-disk.nix` → `mk-stemcell.nix` → `deploy-stemcell.sh` (Nix boundary ends at the `.tgz`) |
| Manifest location | **Workspace root** (`./nix-stemcell-poc.yml`), checked-in file (not inline, not under `poc/`) |

---

## 3. Architecture & Pipeline

```
os-image (M3)                mk-bootable-disk.nix        mk-stemcell.nix          deploy-stemcell.sh
rootfs.tar.gz  ──────────►   runInLinuxVM               pure derivation          imperative (outside Nix)
                             partition + grub           qcow2 → image → .tgz     upload + deploy + ssh
                                   │                          │                        │
                             root.qcow2  ───────────►   6-member .tgz  ─────────► running BOSH VM
```

**Nix boundary ends at the `.tgz`.** Everything reproducible/cacheable is a
derivation; the director interaction (inherently stateful) is an imperative
script. Rationale over the alternatives:

- **vs. monolithic derivation (Approach 2):** layering keeps the qcow2 cacheable
  and lets the disk stage be rebuilt independently of packaging.
- **vs. hybrid script-packaging (Approach 3):** keeps the reproducible Nix
  boundary all the way through the `.tgz`; only the unavoidable stateful deploy
  is imperative.

**Files created:**

| File | Role |
|------|------|
| `poc/lib/mk-bootable-disk.nix` | `runInLinuxVM` disk assembly (MBR + dual-boot grub → qcow2) |
| `poc/examples/noble-stemcell-disk.nix` | Entry point `.#noble-stemcell-disk` (qcow2) |
| `poc/lib/mk-stemcell.nix` | Pure packaging derivation → 6-member `.tgz` |
| `poc/examples/noble-stemcell.nix` | Entry point `.#noble-stemcell` (`.tgz`) |
| `poc/scripts/deploy-stemcell.sh` | Source `bosh.env`, upload, jobless deploy, `bosh ssh` verify |
| `./nix-stemcell-poc.yml` | Checked-in jobless deploy manifest (workspace root) |

**Data contract:** the disk stage consumes `os-image`'s `rootfs.tar.gz`
**directly** (not a fresh deb closure) so the agent + CLIs + settings carry
through unchanged. The disk stage only partitions → extracts → makes bootable.

---

## 4. `mk-bootable-disk.nix` — Disk Assembly

A `runInLinuxVM` derivation (reuses the proven `systemdMinimal` + udev +
`grub-install` pattern from `poc/examples/noble-bootable.nix`, but faithfully
replicates the classic MBR/dual-boot layout instead of GPT/UEFI-only).

**Input:** `rootfs.tar.gz`. **Output:** `$out/root.qcow2`.

Steps inside the VM — mirroring the two classic stages:

1. **Create + partition (from `image_create_efi`):**
   - `dd` a sparse raw file of **5120 MiB** (openstack `image_create_disk_size`).
   - `sfdisk` with **`label: dos`** (MBR), two partitions, classic geometry:
     - P1 ESP: `start=2048, size=98304, type=ef, bootable` (~48 MiB)
     - P2 root: `start=100352, type=83` (rest)
   - `losetup`/`kpartx` map; `mkfs.vfat` ESP, `mkfs.ext4` root.
2. **Populate root:** mount root at `/mnt`, ESP at `/mnt/boot/efi`; extract
   `rootfs.tar.gz` into `/mnt` (`tar -xpf --numeric-owner --acls --xattrs`).
   The classic stage uses `rsync -aHA $chroot/ /mnt` (preserves hardlinks +
   ACLs); the tar flags above are the tarball-input equivalent (G2). The
   initramfs is **already inside `rootfs.tar.gz`** (classic runs
   `update-initramfs` during OS build in `system_kernel_modules`, not here — G4).
3. **Bootloader (from `image_install_grub`):** bind-mount `/proc` + `/sys`
   (sysfs) and the whole-disk + partition-mapper device nodes into `/mnt` (proc
   + sysfs only, matching classic — **not** a wholesale `/dev` mount, G3); start
   udev; then in `chroot /mnt`:
   - **Dual grub-install:** `--target=x86_64-efi --efi-directory=/boot/efi
     --boot-directory=/boot/efi/EFI --removable` **and** `--target=i386-pc`.
   - `/etc/default/grub` with the classic `GRUB_CMDLINE_LINUX` — **hard-coded
     byte-exact** from `image_install_grub/apply.sh:98`:
     `vconsole.keymap=us net.ifnames=0 biosdevname=0 crashkernel=auto
     selinux=0 plymouth.enable=0 console=ttyS0,115200n8 earlyprintk=ttyS0
     rootdelay=300 audit=1 cgroup_enable=memory swapaccount=1 apparmor=1
     security=apparmor` (openstack `grub_suffix` is empty — no suffix appended).
   - **`device.map` handshake (G1):** before the `i386-pc` install, write
     `/boot/grub/device.map` and `/device.map` = `(hd0) <device>`, pass
     `--grub-mkdevicemap=/device.map` to the BIOS grub-install, and remove both
     files afterward — faithful to `image_install_grub/apply.sh:75-76,80,127-128`.
   - grub superuser `vcap` + random pbkdf2 password (appended to 00_header) +
     `10_linux --unrestricted` — byte-faithful to classic.
   - `grub-mkconfig` → both `/boot/efi/EFI/grub/grub.cfg` and `/boot/grub/grub.cfg`.
   - Rewrite `root=` → `root=UUID=<uuid_root>`; write `/etc/fstab` by UUID
     (ESP vfat `umask=0177`, root ext4 `defaults`).
4. **Convert:** `qemu-img convert -c -O qcow2 -o compat=0.10 root.raw
   $out/root.qcow2` (classic `prepare_qcow2_image_stemcell` flags).

**Hard dependency check (R1):** grub-install + `grub-mkconfig` +
`update-initramfs` run *inside the chroot*, so the rootfs must contain the grub
packages, the **kernel** (`/boot/vmlinuz-*`), and initramfs tooling. Verify this
in the overlaid closure **early**; if the kernel package is absent, add it to the
M2 deb set (same closure mechanism — a one-line addition).

---

## 5. `mk-stemcell.nix` — Packaging

A **pure** derivation (no VM) wrapping the qcow2 into the BOSH stemcell `.tgz`.
Mirrors the classic `stemcell_packager.rb` 6-member contract.

**Input:** `root.qcow2`. **Output:**
`$out/bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz`.

> **Naming note (review D1):** the real generator does **not** append
> `-go_agent` (proven by `stemcell_packager_spec.rb:129`;
> `definition.rb:22-33`, `archive_filename.rb:15-22`). The `-go_agent` form seen
> in the repo's README/bosh.io is a *stale doc convention* — `go_agent` is only a
> build-stage name. Per the A2 mandate (emit the real generator's output), the
> registered stemcell name is `bosh-openstack-kvm-ubuntu-noble`.

Steps:

1. **Inner image tarball:** `ln root.qcow2 root.img` (file named `root.img`,
   qcow2 content — matches classic openstack), then `tar zcf image root.img`.
2. **Checksum:** `sha1` of the inner `image` tarball (goes in `stemcell.MF`).
3. **`stemcell.MF`** — rendered for openstack-kvm-noble:
   ```yaml
   name: bosh-openstack-kvm-ubuntu-noble
   version: 0.0.1-nix
   bosh_protocol: 1
   api_version: 3
   sha1: <image sha1>
   operating_system: ubuntu-noble
   stemcell_formats: [openstack-qcow2, openstack-raw]
   cloud_properties:
     name: bosh-openstack-kvm-ubuntu-noble
     version: 0.0.1-nix
     infrastructure: openstack
     hypervisor: kvm
     disk: 5120
     disk_format: qcow2
     container_format: bare
     os_type: linux
     os_distro: ubuntu
     architecture: x86_64
     auto_disk_config: true
   ```
4. **Minimal aux files:** empty `packages.txt`, empty `dev_tools_file_list.txt`,
   `{}` for `sbom.spdx.json` and `sbom.cdx.json`. The packager checks only file
   *presence*, not content (`stemcell_packager.rb:78-82`), so stubs satisfy the
   contract locally; upload-time director behavior is an open risk (R6).
5. **Assemble:** `tar zcf <name>.tgz stemcell.MF packages.txt
   dev_tools_file_list.txt image sbom.spdx.json sbom.cdx.json`. Emit **exactly**
   these 6 members in this order — the classic packager raises on missing *or
   extra* files, so no stray dotfiles.

`version` is a derivation arg (default `"0.0.1-nix"`), configurable in
`noble-stemcell.nix`.

---

## 6. `deploy-stemcell.sh` — Imperative Deploy

Plain shell (`poc/scripts/deploy-stemcell.sh`); the Nix boundary ends at the
`.tgz`, this does director interaction.

1. **Preflight:** `set -euo pipefail`; `source ./bosh.env`; assert `bosh env`
   reaches `instant-bosh`; assert the `.tgz` exists (build via
   `nix build .#noble-stemcell` if missing, or take path as `$1`).
2. **Upload:** `bosh -n upload-stemcell <path>.tgz`; confirm via `bosh stemcells`.
3. **Cloud-config:** reuse the director's existing one; read `bosh cloud-config`
   to discover a usable network / vm_type / az (or pinned script vars with
   env-overridable defaults) referenced by the manifest.
4. **Deploy:** `bosh -n -d nix-stemcell-poc deploy ./nix-stemcell-poc.yml`
   (checked-in manifest at workspace root — jobless: one `instance_group`,
   `instances: 1`, `jobs: []`, stemcell `os: ubuntu-noble` / `version: 0.0.1-nix`,
   discovered network/vm_type/az, `update` block).
5. **Verify (three green lights):**
   - `bosh -d nix-stemcell-poc vms` → instance **`running`**.
   - `bosh -d nix-stemcell-poc ssh -c 'uname -r'` → non-empty kernel version.
     (`bosh ssh` uses agent-driven ephemeral user/key provisioning — needs **no
     job**; a successful `uname -r` proves agent health *and* that the
     Nix-assembled kernel/grub/initramfs booted the real filesystem.)
   - `bosh ssh -c 'cat /etc/os-release'` → `ubuntu` / `noble`.
   - On failure: dump `bosh instances --details` + last task debug for triage.
6. **Cleanup helper:** optional `--cleanup` → `delete-deployment` +
   `bosh clean-up --all` so re-runs are clean.

---

## 7. Verification & Risks

**Verification = the DoD (§1), fully automated in `deploy-stemcell.sh`,** with a
pre-upload assertion that all six `.tgz` members exist and `stemcell.MF` `sha1`
matches the inner `image`.

**Risks — each is a *findings outcome*, not a silent failure:**

| ID | Risk | Mitigation / Handling |
|----|------|-----------------------|
| R1 | Kernel/grub/initramfs not in overlaid closure (**hard gate** — `uname -r` can't pass) | Verify early in §4 impl; add kernel package to M2 deb set if absent |
| R2 | lxd_cpi/Incus settings delivery — OpenStack `agent.json` expects ConfigDrive (`config-2`) or HTTP `169.254.169.254`; unclear if Incus presents either | Primary runtime unknown; failure → investigate CPI settings source, document as finding |
| R3 | MBR/dual-boot grub in `runInLinuxVM` may need device-map/loopback tweaks vs. the proven GPT/UEFI pattern | Concrete step identified: `device.map` handshake for `i386-pc` (§4.3, G1); reuse `noble-bootable.nix` udev/grub scaffolding |
| R4 | Resource/QEMU intensity (M2/M3 hit disk-blocked VM builds) | Sparse raw + compressed qcow2; monitor host disk |
| R5 | `bosh ssh` provisioning fails even if agent is up | Records as a distinct finding (agent up but SSH broken) |
| R6 | Aux-stub content — "director does not read them" is unverified; classic populates SBOMs/`packages.txt` via `sbom_create`/`bosh_package_list` stages. Packager only checks file *presence*, not content | Empty/`{}` stubs satisfy the 6-member contract locally; upload-time director behavior is the open runtime question — treat any rejection as a finding |

**Deliverables:** this design → plan → implementation (5 files) + root
`nix-stemcell-poc.yml` + findings doc
(`docs/superpowers/specs/2026-07-07-m4-*-findings.md`).
