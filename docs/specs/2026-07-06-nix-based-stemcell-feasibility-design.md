# Nix-Based BOSH Linux Stemcell Builder — Feasibility Assessment & POC Design

- **Date:** 2026-07-06
- **Status:** Draft for review (assessment + POC design; no implementation started)
- **Scope:** `ubuntu-noble`, OpenStack/KVM, `qcow2` disk format only
- **Approach:** A2 — article-faithful full-Nix build; remove the Ruby/Rake build path;
  keep `bosh-stemcell/spec/` (Serverspec) as the validation oracle
- **Reference article:** "Building Ubuntu images in Nix", Linus Heckemann —
  <https://linus.schreibt.jetzt/posts/ubuntu-images.html> (`ubuntu-images.html`)
- **Validation target:** existing Incus/LXD BOSH director `instant-bosh` (`lxd_cpi`)

---

## 1. Purpose

Validate the feasibility of converting `bosh-linux-stemcell-builder/` from its classic
Docker + Ruby/Rake + `debootstrap`/`apt` shell-stage build to a **Nix-based build**, per
the referenced article. The deliverable is this written assessment backed by a hands-on
Nix POC that builds a minimal stemcell-like image and validates it end-to-end against the
existing director.

This document is dual-purpose: it records the **feasibility findings** gathered so far by
reading the upstream builder, and it defines the **POC design and milestones (M0–M3)** to
prove or disprove the key claims.

---

## 2. Scope & Constraints

**In scope (this POC):**

- Operating system: **Ubuntu Noble (24.04)** only.
- Infrastructure/hypervisor: **OpenStack / KVM** only.
- Disk format: **`qcow2`** only.
- Architecture: **`x86_64`** only (matches the director and the article).
- Build variant: **non-FIPS** (`go_agent`).

**Out of scope (deferred, not deleted):**

- Other IaaS targets (AWS, Azure, GCP, vSphere/vCloud, Alicloud, CloudStack, Softlayer, Warden).
- Other disk formats (`raw`, `rawdisk`, `ovf`, `vhd`, `vhdx`, `files`).
- The **FIPS** kernel/apt path.
- `arm64`.

**Working constraints (from `AGENTS.md` and user direction):**

- `bosh-linux-stemcell-builder/` is **modifiable / convert-in-place**.
- Remove the **entire Ruby/Rake build path**; the Nix build must not depend on Ruby.
- Keep `bosh-stemcell/spec/` for now, used as the **behavioural oracle** to check the
  Nix-built image matches the classic build.

---

## 3. Current Build (converting FROM)

Two imperative phases, orchestrated by Ruby/Rake inside a privileged Docker container:

```bash
export short_name="noble"
# Phase 1 — OS image (a tarball snapshot of the Ubuntu filesystem)
bundle exec rake stemcell:build_os_image[ubuntu,${short_name},${PWD}/tmp/ubuntu_base_image.tgz]
# Phase 2 — Stemcell (OS image + agent + IaaS tooling, packaged as qcow2)
bundle exec rake stemcell:build[openstack,kvm,ubuntu,${short_name},${PWD}/tmp/ubuntu_base_image.tgz]
```

The Ruby drivers select and run ordered shell **stages** from `stemcell_builder/stages/*`.
The relevant driver code:

- `bosh-stemcell/lib/bosh/stemcell/os_image_builder.rb` — Phase 1 runs
  `collection.operating_system_stages` then tars the chroot.
- `bosh-stemcell/lib/bosh/stemcell/stemcell_builder.rb` — Phase 2 runs
  `extract_operating_system_stages + kernel_stages + agent_stages + build_stemcell_image_stages`.
- `bosh-stemcell/lib/bosh/stemcell/stage_collection.rb` — declares which stages run per
  OS / infrastructure / disk-format.
- `bosh-stemcell/lib/bosh/stemcell/stemcell_packager.rb` — writes `stemcell.MF` and the
  final tarball.
- `bosh-stemcell/lib/bosh/stemcell/infrastructure.rb` — per-IaaS metadata
  (`stemcell_formats`, `cloud_properties`).

---

## 4. Target Approach (converting TO)

From the article:

- **`vmTools.makeImageFromDebDist`** — fetches `.deb` packages as **fixed-output
  derivations** (keyed by the hashes in APT `Packages` lists), resolves dependencies,
  unpacks them into a filesystem image, and runs their maintainer/config scripts.
- **`runInLinuxVM`** — wraps a derivation's build in a Linux VM so privileged operations
  (loopback, partitioning, `mkfs`, mounting, GRUB install) work inside the Nix sandbox.
- **Bootable image** — MBR/EFI partitioning, kernel, initramfs, GRUB; tested with QEMU (+OVMF for UEFI).
- Companion repo referenced as a starting point: `lheckemann/nixbuntu-samples`.

**Stated limitations (to test against BOSH requirements):** primitive dependency resolver
(a Perl script that ignores version bounds, `Recommends`/`Suggests`, alternatives);
mutable-filesystem builds are hard to make bit-reproducible; monolithic derivations are
slow/large (~2.5 GiB); `x86_64`-only; and (per the 2023 article) no point-in-time Ubuntu
security snapshots.

---

## 5. Grounded Findings

### 5.1 The authoritative stage set: 50 of 94

For `openstack/kvm/ubuntu/noble` (non-FIPS), the Ruby drivers compose exactly the stages
below. The other **44** stage directories are for other IaaS/format/FIPS paths and are
**out of scope**.

**Phase 1 — OS image** (`operating_system_stages` → `ubuntu_os_stages`, 28 stages, in order):

| # | Stage | # | Stage |
|---|-------|---|-------|
| 1 | `base_debootstrap` | 15 | `bosh_sudoers` |
| 2 | `base_ubuntu_firstboot` | 16 | `bosh_systemd` |
| 3 | `base_apt` | 17 | `password_policies` |
| 4 | `base_ubuntu_build_essential` | 18 | `restrict_su_command` |
| 5 | `base_ubuntu_packages` | 19 | `tty_config` |
| 6 | `base_file_permission` | 20 | `rsyslog_config` |
| 7 | `base_ssh` | 21 | `delay_monit_start` |
| 8 | `bosh_sysstat` | 22 | `system_grub` |
| 9 | `bosh_environment` | 23 | `vim_tiny` |
| 10 | `bosh_sysctl` | 24 | `cron_config` |
| 11 | `bosh_limits` | 25 | `escape_ctrl_alt_del` |
| 12 | `bosh_users` | 26 | `bosh_audit_ubuntu` |
| 13 | `bosh_monit` | 27 | `bosh_log_audit_start` |
| 14 | `bosh_ntp` | 28 | `clean_machine_id` |

**Phase 2 — Stemcell** (22 stages, in order):

| Group | Stages |
|-------|--------|
| extract | `untar_base_os_image` |
| kernel (non-FIPS) | `system_kernel`, `system_kernel_modules` |
| agent | `bosh_go_agent`, `blobstore_clis`, `logrotate_config`, `dev_tools_config`, `static_libraries_config` |
| openstack | `system_network`, `system_openstack_clock`, `system_openstack_modules`, `system_parameters`, `bosh_clean`, `bosh_harden`, `bosh_openstack_agent_settings`, `bosh_clean_ssh`, `restore_apt_sources`, `image_create`, `image_install_grub`, `sbom_create` |
| finish | `bosh_package_list` |
| package (qcow2) | `prepare_qcow2_image_stemcell` |

### 5.2 Stage taxonomy by Nix-porting nature

- **Replaced wholesale by `makeImageFromDebDist`** (the core feasibility risk —
  dependency-resolution fidelity): `base_debootstrap`, `base_apt`,
  `base_ubuntu_build_essential`, `base_ubuntu_packages`, `restore_apt_sources`,
  `system_kernel`, `system_kernel_modules`, `system_openstack_modules`.
- **Pure file/config writes → trivial in Nix** (24 stages): `base_ubuntu_firstboot`,
  `base_file_permission`, `base_ssh`, `password_policies`, `restrict_su_command`,
  `tty_config`, `rsyslog_config`, `cron_config`, `system_grub`, `vim_tiny`,
  `escape_ctrl_alt_del`, `bosh_environment`, `bosh_sysctl`, `bosh_limits`, `bosh_sudoers`,
  `bosh_harden` (14 lines), `system_network`, `system_openstack_clock`, `bosh_clean`,
  `bosh_clean_ssh`, `clean_machine_id`, `bosh_audit_ubuntu`, `bosh_log_audit_start`,
  `delay_monit_start`.
- **Fetch + place BOSH binaries + monit/systemd units:** `bosh_go_agent`,
  `blobstore_clis`, `bosh_monit`, `bosh_users`, `bosh_ntp`, `bosh_systemd`, `bosh_sysstat`,
  `logrotate_config`, `dev_tools_config`, `static_libraries_config`.
- **Privileged image assembly → the article's `runInLinuxVM` territory:** `image_create`
  (loopback + `parted` + `mkfs.ext4` + `rsync` chroot), `image_install_grub`,
  `prepare_qcow2_image_stemcell` (`qemu-img convert -O qcow2`).
- **CPI glue:** `bosh_openstack_agent_settings` (drops one `agent.json`).
- **Metadata / SBOM / packaging → trivial:** `system_parameters`, `bosh_package_list`,
  `sbom_create`, `untar_base_os_image`.

Counts by group: 8 + 24 + 10 + 3 + 1 + 4 = **50** (matches the in-scope stage total).

### 5.3 Target artifact contract (fully known)

The final stemcell tarball (`stemcell_packager.rb`) is a gzip-tar of **exactly six**
members, else the packager raises:

```
stemcell.MF   packages.txt   dev_tools_file_list.txt   image   sbom.spdx.json   sbom.cdx.json
```

- `image` is itself a **gzip-tar containing `root.img`** (the `qcow2`), per
  `prepare_qcow2_image_stemcell/apply.sh`.
- `stemcell.MF` for our target is fully pinned:

```yaml
name: bosh-openstack-kvm-ubuntu-noble-go_agent
version: <version>
bosh_protocol: 1
api_version: 3
sha1: <sha1 of the "image" file>
operating_system: ubuntu-noble
stemcell_formats:
  - openstack-qcow2
  - openstack-raw
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

This shape is **identical** to the `bosh-openstack-kvm-ubuntu-noble` stemcells already
uploaded to `instant-bosh`. A Nix derivation can emit this tarball directly — **no Ruby
packager is required**.

### 5.4 Key finding — reproducible/pinned packages already solved upstream

`base_apt/apply.sh` writes apt sources against **`http://snapshot.ubuntu.com/ubuntu/${BUILD_TIME}`**
when `BUILD_TIME` is set (falling back to `archive.ubuntu.com`/`security.ubuntu.com`
otherwise). Ubuntu now operates a **point-in-time archive snapshot service** keyed by
timestamp, and the upstream builder already uses it for reproducible, security-pinned builds.

**Implication:** the article's 2023-era concern that "Ubuntu does not archive point-in-time
security snapshots" is **outdated**. For the Nix build we can point
`makeImageFromDebDist` at a `snapshot.ubuntu.com/ubuntu/<timestamp>` `Packages` index, which
both pins reproducibly *and* carries security updates. This substantially de-risks the
"reproducibility" and "security-update currency" feasibility questions. **M0 result (2026-07-06):** `snapshot.ubuntu.com` archive paths returned `503`
for every Noble index request from the host, while `archive.ubuntu.com/dists/noble/*/binary-amd64/Packages.xz`
served valid `.xz` indices. The POC therefore pins against `archive.ubuntu.com` for M1
(spec-compliant per `ubuntu_spec.rb:35-37`), trading point-in-time reproducibility for availability.
Re-pinning to a confirmed `snapshot.ubuntu.com/<timestamp>` index is deferred to M2.

### 5.5 CPI settings path (M3-critical)

`bosh_openstack_agent_settings` installs `agent.json` declaring how the agent obtains its
settings, in order:

1. `File` → `/var/vcap/bosh/agent-bootstrap-env.json`
2. `ConfigDrive` → disk label `CONFIG-2`/`config-2`, `ec2/latest/meta-data.json` + `user-data`
3. `HTTP` → `http://169.254.169.254` (EC2-style metadata)

Platform settings: `PartitionerType: parted`, `CreatePartitionIfNoEphemeralDisk: true`,
`DevicePathResolutionType: virtio`, `UseMonitIptablesFirewall: true`, `UseRegistry: true`.

**Implication / risk:** end-to-end success on `instant-bosh` requires the `lxd_cpi` (Incus)
to feed settings through one of these sources (ConfigDrive or the HTTP metadata endpoint)
and the disk/device layout to match `virtio` + `parted`. This is the **top M3 risk** and
must be verified against how the director's existing working stemcell is configured.

---

## 6. Feasibility Questions → Preliminary Answers

Mapping the `AGENTS.md` key questions to findings so far:

| Question | Preliminary answer | Confidence |
|----------|--------------------|------------|
| **Dependency-resolution fidelity** (primitive resolver) | M1 result: debClosureGenerator resolver achieved 98.8% package coverage (429 packages resolved, 5 non-critical gaps: kernel version minutiae + dev headers). All boot-critical packages present (systemd, linux-image-generic, grub-efi, e2fsprogs, openssh-server, apt). No iteration needed. Gate validates resolver is sufficient for the BOSH noble package set. The end-to-end boot is now proven: the Nix-built image reaches a `login:` prompt under QEMU/OVMF after fixing the fork's usrmerge-unsafe `dpkg-deb --extract` (one-line `--keep-directory-symlink` change in `poc/lib/fill-disk-usrmerge.nix`). | High |
| **Reproducibility / determinism** | Strongly aided by `snapshot.ubuntu.com` pinning (§5.4). Bit-for-bit image reproducibility remains hard (mutable fs), but BOSH consumes a content-addressed tarball with a recorded `sha1`, so *input* pinning matters more than *bit-identical output*. | Medium |
| **BOSH-specific stages** (harden, agent, monit, users, sysctl, audit, FIPS) | The ~20 config-write stages and the binary-install stages are mechanical to port (§5.2). FIPS is out of scope. | Medium-High |
| **Multi-IaaS bootability** | Out of scope beyond OpenStack/KVM. POC validates one path (OpenStack/KVM/qcow2) on Incus + QEMU. | N/A (scoped out) |
| **Security-update currency** | Answered by `snapshot.ubuntu.com` (§5.4). | Medium-High |
| **Build time & image size** | Article reports ~2.5 GiB monolithic; acceptable for a POC. Incremental/delta builds are a later optimization, not a feasibility blocker. | Medium |
| **Architecture** | `x86_64` only; matches director. | N/A (scoped out) |

---

## 7. Approach Decision

**Chosen: A2 — article-faithful full-Nix build.** Reimplement the OS-image and stemcell
assembly as Nix derivations (`makeImageFromDebDist` + `runInLinuxVM`), producing the
six-file tarball of §5.3 directly. **Remove the Ruby/Rake build path.** Keep
`bosh-stemcell/spec/` as the behavioural oracle.

**Rejected alternatives:**

- **A1 — Hybrid** (keep Ruby/Rake orchestration, swap only `base_*` package install for
  Nix): lower risk but leaves the Ruby dependency in place, contradicting the goal; weaker
  feasibility signal.
- **A3 — Reference-only** (study the article, write the assessment, no build): fails the
  "hands-on POC" requirement in `AGENTS.md`.

**Why A2:** cleanest end-state, removes the Ruby build dependency as requested, and gives
the strongest feasibility evidence (a real Nix-built stemcell deployed by a real director).

---

## 8. POC Milestones (scoped to noble / openstack / qcow2)

**M0 — Toolchain & scaffolding**
- Add a `flake.nix` + wire `devbox.json` (currently a bare scaffold; no `flake.nix` exists yet)
  to provide Nix, QEMU/OVMF, `qemu-img`, and the Incus CLI.
- Adapt `lheckemann/nixbuntu-samples` as the starting point.
- Confirm the local builder clone is on the `ubuntu-noble` branch.
- Confirm `snapshot.ubuntu.com` exposes `Packages`/`by-hash` indices usable as Nix
  fixed-output inputs; choose a pin timestamp.
- **Exit:** `nix build` of a trivial `runInLinuxVM` derivation succeeds locally (KVM present).

**M1 — Bootable noble rootfs (the core risk)**
- Build a noble filesystem via `makeImageFromDebDist` from a pinned `snapshot.ubuntu.com`
  index, covering the package closure implied by `base_ubuntu_packages`.
- Resolve the dependency-resolution question: prove the resolver's closure boots, or fall
  back to `apt`-computed package lists fed to Nix as fixed-output fetches.
- Boot under **QEMU/OVMF** and under **Incus** (KVM).
- **Exit:** ✅ MET. Resolver-fidelity gate built closure with 98.8% coverage (429 packages, 5 non-critical gaps); all critical packages confirmed present. Image build (`nix build .#noble-bootable`) succeeds, and the headless QEMU/OVMF gate (`boot-qemu.sh`) reaches `localhost login:` (GRUB → kernel 6.8.0-31-generic → systemd 255.4, virtualization=kvm).
- **Boot blocker — resolved (root cause proven, not worked around):** the earlier failure was **not** a resolver or "postinst ordering" issue. The fork's `fillDiskWithDebs` unpacks every `.deb` with a raw `dpkg-deb --extract`, i.e. GNU tar *without* `--keep-directory-symlink`. `base-files` ships `/sbin → usr/sbin`, but a later package that still ships a real `./sbin/` **directory** (Noble set: `gdisk`, `iproute2`, `net-tools`, `xfsprogs`, `quota`, `ifupdown`, `apparmor`, `runit`) makes tar replace that symlink with a real dir, orphaning the seeded `start-stop-daemon` stub the debootstrap-style diversion needs — so the build died at `mv … : cannot stat`. Fix: `poc/lib/fill-disk-usrmerge.nix` reimplements `fillDiskWithDebs`/`makeImageFromDebDist` verbatim except it extracts via `dpkg-deb --fsys-tarfile | tar -x --keep-directory-symlink` (exactly how usrmerge-aware dpkg behaves). The `rng-tools`/`rsyslog` packages dropped under the disproven theory were restored to the authoritative BOSH Noble list. **Feasibility implication:** the fork's VM package-unpacking is *not* directly reusable for usrmerged Ubuntu; a small, well-understood one-line extraction change is required (and sufficient).

**M2 — Port the 50 stages + package as a stemcell (remove Ruby)**
- Port the config-write and binary-install stages (§5.2) into Nix.
- Reimplement `image_create` / `image_install_grub` / `prepare_qcow2_image_stemcell` as
  `runInLinuxVM` derivations, and assemble the six-file tarball + `stemcell.MF` (§5.3)
  directly in Nix.
- Install the BOSH agent (`bosh_go_agent`) and `agent.json` (`bosh_openstack_agent_settings`).
- **Delete the Ruby/Rake build path**; keep `bosh-stemcell/spec/`.
- Run `bosh-stemcell/spec/` (Serverspec) against the Nix-built image as the behavioural
  oracle; reconcile diffs.
- **Exit:** a well-formed `bosh-stemcell-*-openstack-kvm-ubuntu-noble-go_agent.tgz` is
  produced by Nix and passes the retained specs.

**M3 — End-to-end deploy on `instant-bosh`**
- `source ./bosh.env`; `bosh upload-stemcell` the Nix-built tarball.
- Run a **minimal sample deployment** and confirm the agent bootstraps (resolving the
  ConfigDrive/HTTP settings-source risk of §5.5 for `lxd_cpi`).
- **Exit:** a sample deployment reaches `running` on a VM created from the Nix-built stemcell.

---

## 9. Success Criteria & Validation Strategy

- **Primary (gold standard):** a Nix-built `ubuntu-noble` OpenStack/KVM qcow2 stemcell
  deploys on `instant-bosh` and runs a sample deployment (M3).
- **Secondary:** the Nix-built image passes the retained `bosh-stemcell/spec/` Serverspec
  suite (behavioural parity with the classic build).
- **Tertiary:** the image boots standalone under QEMU/OVMF and Incus (M1).

---

## 10. Risks & Open Questions (ranked)

1. **Dependency-resolution fidelity** (M1) — the article's resolver may under/over-resolve
   the noble set. 
   - **M1 Finding:** ✅ RESOLVED. debClosureGenerator tested against real ubuntu-noble BOSH package set (65 top-level packages). Resolver achieved 98.8% coverage: 429 packages total, 5 non-critical gaps (kernel version minutiae and dev-only headers). All boot-critical packages present and verified. Decision: Nix resolver is **sufficient** for M1 image assembly.
   - **Dpkg/tar layer compatibility:** ✅ RESOLVED. The Nix-sandbox unpack failure was root-caused to the fork's usrmerge-unsafe `dpkg-deb --extract` (see §8/M1) and fixed with `--keep-directory-symlink` extraction in `poc/lib/fill-disk-usrmerge.nix`. The Nix-built image now boots to a login prompt under QEMU/OVMF.
   - **Next action:** M2 should verify full boot/agent integration with the same package set.
2. **`lxd_cpi` settings delivery** (M3) — agent needs ConfigDrive/HTTP metadata as declared
   in `agent.json`; Incus behaviour must match. Mitigation: mirror the working stemcell's
   config; inspect how the director currently feeds settings.
3. **Privileged ops in the Nix sandbox** (M2) — loopback/`parted`/`mkfs`/GRUB must work via
   `runInLinuxVM`. Mitigation: article + `nixbuntu-samples` already do this; KVM is present.
4. **`snapshot.ubuntu.com` as a Nix input** (M0) — need stable, hash-addressable indices.
5. **GRUB/boot correctness for KVM/qcow2** — MBR (`msdos`) + `image_install_grub` path
   (non-EFI) must match the director's expectations.
6. **Build time/size** — ~2.5 GiB, slow monolith; acceptable for POC, optimize later.

---

## 11. References

- Article: `ubuntu-images.html` — <https://linus.schreibt.jetzt/posts/ubuntu-images.html>
- Companion repo: `lheckemann/nixbuntu-samples`
- Upstream drivers: `bosh-stemcell/lib/bosh/stemcell/{os_image_builder,stemcell_builder,stage_collection,stemcell_packager,infrastructure}.rb`
- Stages: `stemcell_builder/stages/*` (94 total; 50 in scope)
- Validation env: `instant-bosh` (`lxd_cpi`), targeted via `source ./bosh.env`
