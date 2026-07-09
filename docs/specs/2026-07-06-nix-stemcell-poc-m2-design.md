# M2 Design — Port the 50 stages + package as a stemcell (remove Ruby build path)

- **Date:** 2026-07-06
- **Status:** APPROVED (design) — plan pending
- **Scope:** `ubuntu-noble`, OpenStack/KVM, `qcow2` only; non-FIPS; x86_64
- **Depends on:** M0 (toolchain), M1 (bootable noble rootfs — DONE), fork→upstream switch (DONE)
- **Approach:** A2 — article-faithful full-Nix build; remove the Ruby/Rake **build** path; retain
  `bosh-stemcell/spec/` as the behavioural oracle.

## 1. Goal

Turn the M1 bootable noble rootfs into a **well-formed
`bosh-stemcell-*-openstack-kvm-ubuntu-noble-go_agent.tgz`** produced entirely by Nix, and
validate it against the retained `bosh-stemcell/spec/` Serverspec oracle. Delete the Ruby/Rake
build path while retaining the Ruby **test** harness.

**Exit criteria:**
- Nix emits the six-member stemcell tarball + `stemcell.MF` (§5) matching the classic contract.
- The full retained oracle (`os_image/ubuntu` + `stemcell_image` go_agent/openstack/ubuntu) runs
  **green**, with any classic-only/infeasible specs explicitly **quarantined + justified**.
- The Ruby/Rake build path is deleted; the oracle still runs via a Nix-provided Ruby devShell.

## 2. Decisions (this session)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Oracle execution | **Real Serverspec via Nix-provided Ruby.** Retain a minimal `bosh/stemcell` lib slice (`DiskImage`, `Core::Shell`, `arch`) + serverspec gems. Ruby remains a **test** dependency only. |
| 2 | Disk/boot layout | **Faithfully replicate upstream** `image_create_efi` + `image_install_grub` (msdos label, ~48 MiB ESP + ext4 root, dual BIOS `i386-pc` + removable `x86_64-efi` GRUB). |
| 3 | Oracle pass bar | **Full suite green**, with a documented **quarantine list** for classic-only/infeasible specs (the list is itself a feasibility deliverable). |
| 4 | Stage-application architecture | **Maximally Nix-native**: users/groups, systemd enablement, and all config writes are declarative; `runInLinuxVM` is used **only** for the irreducible disk assembly (loopback/sfdisk/mkfs/grub-install). |
| 5 | OS image artifact | **Degrades to a test fixture.** Nix's derivation graph provides caching/reuse for free, so the OS image is emitted only to feed the `OS_IMAGE` specs; it is **not** a persisted pipeline checkpoint. `untar_base_os_image` becomes a no-op. |

## 3. Corrections to the feasibility spec

- §5.1 / §5.2 list `image_create` for the OpenStack path. The authoritative stage selector
  (`bosh-stemcell/lib/bosh/stemcell/stage_collection.rb:94` `openstack_stages`) uses
  **`image_create_efi`** (msdos + ESP + ext4, dual boot), not `image_create`. This resolves the
  apparent single-vs-two-partition inconsistency between `image_create` and `image_install_grub`.

## 4. Pipeline (Nix derivation graph)

```
L0  M1 rootfs closure (makeImageFromDebDist)                         [DONE]
      │
L1  OS config-writes (24 stages): firstboot, base_file_permission,   pure Nix overlay
      │ base_ssh, password_policies, restrict_su, tty, rsyslog, cron,
      │ system_grub (defaults), vim_tiny, escape_ctrl_alt_del,
      │ bosh_environment, bosh_sysctl, bosh_limits, bosh_sudoers,
      │ bosh_harden, system_network, system_openstack_clock,
      │ bosh_clean, bosh_clean_ssh, clean_machine_id,
      │ bosh_audit_ubuntu, bosh_log_audit_start
      ▼
L2  Declarative state:                                               pure Nix (no chroot)
      │  - users/groups → write /etc/passwd,/etc/shadow,/etc/group   (bosh_users)
      │  - systemd enablement → /etc/systemd/system/*.wants symlinks (bosh_systemd, monit, agent)
      ▼
L3  Agent + blobstore + openstack settings:                         Nix overlay + FODs
      │  - bosh_go_agent: meta4 tool (FOD) + bosh-agent bin (FOD,    → emits os-image.tgz (FIXTURE)
      │    pinned version) + bosh-agent.service + agent.json stub
      │  - blobstore_clis, logrotate_config, dev_tools_config,
      │    static_libraries_config
      │  - bosh_monit, bosh_ntp, bosh_sysstat units + alerts.monitrc
      │  - system_openstack_modules, system_parameters
      │  - bosh_openstack_agent_settings → /var/vcap/bosh/agent.json
      ▼   ────────────────────────────────────►  ORACLE: OS_IMAGE specs (os_image/ubuntu)
L4  image_create_efi:                                               runInLinuxVM
      │  dd; sfdisk (label:dos, ESP 2048+98304 type ef bootable,
      │  root 100352 type 83); kpartx; mkfs.vfat ESP; mkfs.ext4 root;
      │  rsync rootfs store path → mnt
      ▼
L5  image_install_grub:                                             runInLinuxVM
      │  grub-install x86_64-efi (removable) + i386-pc (BIOS);
      │  GRUB_CMDLINE_LINUX (exact); vcap-locked pbkdf2 menu;
      │  grub-mkconfig → /boot/efi/EFI/grub/grub.cfg + /boot/grub/grub.cfg;
      │  UUID rewrite; /etc/fstab (ESP vfat + root ext4 by UUID)
      ▼
L6  prepare_qcow2 + package:                                        Nix + tiny VM step
         qemu-img convert -c -O qcow2 -o compat=0.10 → root.qcow2;
         root.img hardlink; tar zcf image root.img;
         assemble 6-member tarball + stemcell.MF
      ▼   ────────────────────────────────────►  ORACLE: STEMCELL_IMAGE specs (go_agent/openstack/ubuntu)
```

### 4.1 Stage coverage (50 in-scope)
- **L0 (M1, package install ~8):** base_debootstrap, base_apt, base_ubuntu_build_essential,
  base_ubuntu_packages, restore_apt_sources, system_kernel, system_kernel_modules,
  system_openstack_modules(pkg part). Covered by `makeImageFromDebDist`.
- **L1 (24 config-writes):** see graph.
- **L2 (declarative state):** bosh_users, bosh_systemd, systemd enablement for monit/agent.
- **L3 (10 binary/agent + settings):** bosh_go_agent, blobstore_clis, logrotate_config,
  dev_tools_config, static_libraries_config, bosh_monit, bosh_ntp, bosh_sysstat,
  system_parameters, bosh_openstack_agent_settings.
- **L4–L6 (image assembly + package):** image_create_efi, image_install_grub,
  prepare_qcow2_image_stemcell; sbom_create + bosh_package_list metadata.
- **No-op:** untar_base_os_image (direct store-path consumption).

## 5. Target artifact contract (from `stemcell_packager.rb`, `prepare_qcow2_image_stemcell`)

Final tarball = gzip-tar of **exactly six** members:

```
stemcell.MF   packages.txt   dev_tools_file_list.txt   image   sbom.spdx.json   sbom.cdx.json
```

- `image` = gzip-tar containing `root.img` (hardlink to compressed `root.qcow2`,
  `qemu-img convert -c -O qcow2 -o compat=0.10`).
- `stemcell.MF` (fully pinned):

```yaml
name: bosh-openstack-kvm-ubuntu-noble-go_agent
version: <version>
bosh_protocol: 1
api_version: 3
sha1: <sha1 of the "image" file>
operating_system: ubuntu-noble
stemcell_formats: [openstack-qcow2, openstack-raw]
cloud_properties:
  name: bosh-openstack-kvm-ubuntu-noble-go_agent
  version: <version>
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

A Nix derivation emits this directly — **no Ruby packager required**.

## 6. Oracle harness (retained, Nix-driven)

Backend model (`bosh-stemcell/spec/support/os_image.rb`, `stemcell_image.rb`):
- **os_image specs:** `OS_IMAGE=<tarball>` → harness `sudo tar xf` into tmpdir →
  `ShelloutTypes::Chroot.chroot_dir=<dir>`; `file()/command()/package()/service()` resolve
  against that chroot. Fed by the **L3 fixture**.
- **stemcell_image specs:** `STEMCELL_IMAGE=<path>` → `Bosh::Stemcell::DiskImage#mount`
  (loopback-mounts root.img) → chroot at mount point. Fed by the **L6 qcow2/raw**.

Retain: `bosh-stemcell/spec/**`, `shellout_types/**`, and the minimal lib slice
(`Bosh::Stemcell::DiskImage`, `Bosh::Core::Shell`, `bosh/stemcell/arch`). Provide Ruby +
bundler + rspec + serverspec via a Nix devShell. Requires `sudo` for chroot/loopback (host has it).

## 7. Ruby disposition

- **Delete (build path):** Rakefile stemcell build tasks, `stemcell_builder/stages/*`
  (superseded by L1–L6), `ci/docker/os-image-stemcell-builder`.
- **Retain (test path):** `bosh-stemcell/spec/**` + the minimal harness lib slice + a Nix
  Ruby devShell. "Remove the Ruby **build**" ≠ "remove the Ruby **oracle**."

## 8. Risks & open questions (M2)

1. **Declarative side-effects vs. classic chroot** (chosen path, decision #4) — writing
   passwd/shadow/group and systemd `.wants` symlinks by hand risks subtle divergence from
   `useradd`/`systemctl enable`. **Mitigation:** the quarantine list captures unavoidable
   diffs; reconcile boot/agent-critical ones. Highest M2 risk.
2. **`grub-mkpasswd-pbkdf2` / `grub-install` need chroot exec** — the one place L5 cannot be
   declarative; runs in `runInLinuxVM`.
3. **Privileged loopback/sfdisk/mkfs/grub in the Nix sandbox** — mitigated by M1's proven
   `runInLinuxVM` + host `/dev/kvm`.
4. **BOSH agent provenance as FOD** — `meta4` (github release) + `bosh-agent` (metalink) must
   become fixed-output derivations pinned to the version in the builder assets
   (`stemcell_builder/stages/bosh_go_agent/assets/bosh-agent-version`). Faithful + reproducible.
5. **Oracle needs sudo + loopback** — acceptable on the NixOS host; not sandbox-pure. Documented.
6. **`snapshot.ubuntu.com` re-pin** (deferred from M1) — remains on `archive.ubuntu.com`
   snapshot 503 for M2; re-pin is optional and orthogonal to the stemcell contract.

## 9. Task decomposition (subagent-driven; commit per task; branch `master`)

1. **L1 config overlay** + emit `os-image.tgz` fixture → run `OS_IMAGE` specs → seed quarantine list.
2. **L2 declarative** users/groups + systemd enablement.
3. **L3 agent + blobstore FODs** + monit/ntp/sysstat units + openstack settings (agent.json).
4. **L4 `image_create_efi`** (`runInLinuxVM`).
5. **L5 `image_install_grub`** (`runInLinuxVM`).
6. **L6 qcow2 + tarball + `stemcell.MF`** → run `STEMCELL_IMAGE` specs.
7. **Ruby build-path deletion** + Nix Ruby oracle devShell.
8. **Full-suite reconcile** → finalize quarantine list → M2 exit.

## 10. Feasibility findings surfaced by this design

- **Two-phase build collapses into one derivation graph.** Nix content-addressing gives OS-layer
  caching/reuse across IaaS + agent changes for free; the OS image degrades from a pipeline
  checkpoint to a test fixture, and `untar_base_os_image` becomes a no-op.
- **`image_create` → `image_create_efi`** is the real OpenStack stage; the classic
  single-partition `image_create` is unused on this path.
- **The Ruby test oracle is separable from the Ruby build.** The harness resolves everything
  through a chroot/loopback mount, so it runs unchanged against Nix-built artifacts with only a
  thin retained lib slice.
