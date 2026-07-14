# Move Nix Build Sources into build/ Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the six pure-Nix source directories (`lib/`, `pkgs/`, `rootfs/`, `stemcells/`, `ubuntu/`, `examples/`) into a new top-level `build/` directory, updating every reference so the flake and docs still resolve correctly, with zero functional change.

**Architecture:** `git mv` the six directories as a unit into `build/` (their relative cross-references to each other are unaffected since they move together as siblings). Update the 10 `callPackage`/import paths and 1 treefmt exclude in `flake.nix` to add the `build/` prefix. Update path references in `README.md` and `docs/ARCHITECTURE.md` to match.

**Tech Stack:** Nix flakes, git, bash, sed

**Spec:** `docs/superpowers/specs/2026-07-14-move-nix-sources-into-build-dir-design.md`

---

### Task 1: Move directories into `build/`

**Files:**
- Move: `lib/` → `build/lib/`
- Move: `pkgs/` → `build/pkgs/`
- Move: `rootfs/` → `build/rootfs/`
- Move: `stemcells/` → `build/stemcells/`
- Move: `ubuntu/` → `build/ubuntu/`
- Move: `examples/` → `build/examples/`

- [ ] **Step 1: Create the `build/` directory**

```bash
mkdir build
```

- [ ] **Step 2: Move the six directories with `git mv`**

```bash
git mv lib pkgs rootfs stemcells ubuntu examples build/
```

- [ ] **Step 3: Verify the moves and that internal cross-references still point at real files**

```bash
ls build
```
Expected: `examples  lib  pkgs  rootfs  stemcells  ubuntu`

```bash
test -f build/lib/mkOverlay.nix && \
test -f build/rootfs/overlays/default.nix && \
test -f build/ubuntu/deb-sets.nix && \
echo OK
```
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: move Nix build sources into build/"
```

---

### Task 2: Update `flake.nix` paths

**Files:**
- Modify: `flake.nix:31-58` (packages block)
- Modify: `flake.nix:26` (treefmt shfmt excludes)

- [ ] **Step 1: Update the `packages` block's `callPackage` paths**

Replace:

```nix
      packages =
        let
          blobstoreClis = pkgs.callPackage ./pkgs/blobstore-clis.nix { };
          openstack-kvm = pkgs.callPackage ./stemcells/openstack-kvm.nix { };
        in
        {
          # PHASE 1: OS image (rootfs tarball)
          os-image = pkgs.callPackage ./rootfs/os-image.nix { };
          noble-rootfs = pkgs.callPackage ./rootfs/rootfs.nix { };

          # PHASE 2 (OpenStack/KVM)
          noble-stemcell-disk = pkgs.callPackage ./stemcells/openstack-kvm-disk.nix { };
          noble-stemcell = openstack-kvm;
          openstack-kvm = openstack-kvm;

          # Demos / diagnostics
          noble-bootable = pkgs.callPackage ./examples/noble-bootable.nix { };
          noble-closure = pkgs.callPackage ./examples/noble-closure.nix { };
          hello-vm = pkgs.callPackage ./examples/hello-vm.nix { };

          # Source-built components (names preserved from the old auto-discovery)
          bosh-agent = pkgs.callPackage ./pkgs/bosh-agent.nix { };
          monit = pkgs.callPackage ./pkgs/monit.nix { };
          bosh-davcli = blobstoreClis.davcli;
          bosh-s3cli = blobstoreClis.s3cli;
          bosh-gcscli = blobstoreClis.gcscli;
          bosh-azure-storage-cli = blobstoreClis.azureStorageCli;
        };
```

With:

```nix
      packages =
        let
          blobstoreClis = pkgs.callPackage ./build/pkgs/blobstore-clis.nix { };
          openstack-kvm = pkgs.callPackage ./build/stemcells/openstack-kvm.nix { };
        in
        {
          # PHASE 1: OS image (rootfs tarball)
          os-image = pkgs.callPackage ./build/rootfs/os-image.nix { };
          noble-rootfs = pkgs.callPackage ./build/rootfs/rootfs.nix { };

          # PHASE 2 (OpenStack/KVM)
          noble-stemcell-disk = pkgs.callPackage ./build/stemcells/openstack-kvm-disk.nix { };
          noble-stemcell = openstack-kvm;
          openstack-kvm = openstack-kvm;

          # Demos / diagnostics
          noble-bootable = pkgs.callPackage ./build/examples/noble-bootable.nix { };
          noble-closure = pkgs.callPackage ./build/examples/noble-closure.nix { };
          hello-vm = pkgs.callPackage ./build/examples/hello-vm.nix { };

          # Source-built components (names preserved from the old auto-discovery)
          bosh-agent = pkgs.callPackage ./build/pkgs/bosh-agent.nix { };
          monit = pkgs.callPackage ./build/pkgs/monit.nix { };
          bosh-davcli = blobstoreClis.davcli;
          bosh-s3cli = blobstoreClis.s3cli;
          bosh-gcscli = blobstoreClis.gcscli;
          bosh-azure-storage-cli = blobstoreClis.azureStorageCli;
        };
```

- [ ] **Step 2: Update the treefmt shfmt excludes**

Replace:

```nix
        settings.formatter.shfmt.excludes = [ "rootfs/overlays/*.sh" ];
```

With:

```nix
        settings.formatter.shfmt.excludes = [ "build/rootfs/overlays/*.sh" ];
```

- [ ] **Step 3: Sanity-check the flake still parses**

```bash
nix flake show
```
Expected: succeeds and lists `packages.x86_64-linux.{os-image,noble-rootfs,noble-stemcell-disk,noble-stemcell,openstack-kvm,noble-bootable,noble-closure,hello-vm,bosh-agent,monit,bosh-davcli,bosh-s3cli,bosh-gcscli,bosh-azure-storage-cli}` and `devShells.x86_64-linux.{default,repro}` — no path errors.

- [ ] **Step 4: Commit**

```bash
git add flake.nix
git commit -m "refactor: point flake.nix at build/ for moved Nix sources"
```

---

### Task 3: Update `README.md` repository layout table

**Files:**
- Modify: `README.md:58-65`

- [ ] **Step 1: Update the path column of the layout table**

Replace:

```markdown
| Path | Role |
|------|------|
| `flake.nix` | Flake entry point. Pins `nixpkgs` (`nixos-26.05`); one package per file in `examples/` and `pkgs/`. |
| `examples/` | Buildable image derivations: `os-image.nix`, `noble-stemcell.nix`, `noble-bootable.nix`, `noble-stemcell-disk.nix`, etc. |
| `lib/` | Build library: distro/source pinning (`noble-source.nix`, `noble-distro.nix`), package sets (`base-`, `boot-`, `essential-`, `image-`, `noble-packages.nix`), and the assembly helpers (`mk-rootfs-tarball.nix`, `mk-bootable-disk.nix`, `mk-stemcell.nix`, `mk-apply-overlays.nix`). |
| `lib/overlays/` | Post-unpack filesystem overlays that reproduce the upstream shell stages (ssh, sudoers/pam, audit, rsyslog, sysctl, systemd services, users, agent, OpenStack agent settings, blobstore CLIs). |
| `pkgs/` | Source-built components: the BOSH `agent`, blobstore CLIs (`s3cli`, `gcscli`, `davcli`, `azure-storage-cli`), and `monit` 5.2.5 (built from the vendored tarball). |
| `scripts/` | `deploy-stemcell.sh` (end-to-end director validation), `apt-resolve-noble.sh`, QEMU/OVMF boot smoke tests. |
| `manifests/`, `*.yml` | Validation manifests: `zookeeper.yml` (e2e deployment), `nix-stemcell-poc.yml` (jobless boot), `upstream-jobless-poc.yml` (upstream baseline). |
| `docs/specs/`, `docs/plans/` | Dated feasibility findings and milestone plans (the research trail M0–M6). |
```

With:

```markdown
| Path | Role |
|------|------|
| `flake.nix` | Flake entry point. Pins `nixpkgs` (`nixos-26.05`); one package per file in `build/examples/` and `build/pkgs/`. |
| `build/examples/` | Buildable image derivations: `os-image.nix`, `noble-stemcell.nix`, `noble-bootable.nix`, `noble-stemcell-disk.nix`, etc. |
| `build/lib/` | Build library: distro/source pinning (`noble-source.nix`, `noble-distro.nix`), package sets (`base-`, `boot-`, `essential-`, `image-`, `noble-packages.nix`), and the assembly helpers (`mk-rootfs-tarball.nix`, `mk-bootable-disk.nix`, `mk-stemcell.nix`, `mk-apply-overlays.nix`). |
| `build/lib/overlays/` | Post-unpack filesystem overlays that reproduce the upstream shell stages (ssh, sudoers/pam, audit, rsyslog, sysctl, systemd services, users, agent, OpenStack agent settings, blobstore CLIs). |
| `build/pkgs/` | Source-built components: the BOSH `agent`, blobstore CLIs (`s3cli`, `gcscli`, `davcli`, `azure-storage-cli`), and `monit` 5.2.5 (built from the vendored tarball). |
| `scripts/` | `deploy-stemcell.sh` (end-to-end director validation), `apt-resolve-noble.sh`, QEMU/OVMF boot smoke tests. |
| `manifests/`, `*.yml` | Validation manifests: `zookeeper.yml` (e2e deployment), `nix-stemcell-poc.yml` (jobless boot), `upstream-jobless-poc.yml` (upstream baseline). |
| `docs/specs/`, `docs/plans/` | Dated feasibility findings and milestone plans (the research trail M0–M6). |
```

Note: descriptions are left exactly as-is per the design doc, including the pre-existing stale `lib/overlays/` row (real overlays live at `build/rootfs/overlays/`) — fixing that content is out of scope for this move.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README repository layout table for build/ move"
```

---

### Task 4: Update `docs/ARCHITECTURE.md` file tree diagram

**Files:**
- Modify: `docs/ARCHITECTURE.md:583-638`

- [ ] **Step 1: Replace the "Files & Organization" tree diagram**

Replace:

```
├── flake.nix                          # Nix flake entry point (packages, devShells)
│                                       # L1: os-image → rootfs/os-image.nix
│                                       # L2: noble-stemcell-disk → stemcells/openstack-kvm-disk.nix
│                                       # L3: noble-stemcell → stemcells/openstack-kvm.nix
├── flake.lock                         # Reproducible dependency lock (git-tracked)
├── ubuntu/
│   ├── apt-pins.nix                   # APT coordinates (snapshot URL + index hashes)
│   ├── deb-sets.nix                   # Package lists (bootEssentials, bosh, image)
│   └── essential.nix                  # Essential package seed (pure-Nix parsing)
├── rootfs/
│   ├── os-image.nix                   # Entry point (base + overlays) → L1 output
│   ├── rootfs.nix                     # Tarball builder (calls tarball.nix)
│   ├── tarball.nix                    # Deterministic tar + gzip → rootfs.tar.gz
│   ├── fill-disk-usrmerge.nix         # In-VM dpkg extraction (usrmerge-safe fork)
│   ├── apply-overlays.nix             # Overlay application (single fakeroot session)
│   └── overlays/
│       ├── default.nix                # Overlay orchestration
│       ├── ssh.nix                    # SSH key generation and config
│       ├── sudoers-pam.sh             # Sudoers and PAM setup
│       ├── audit.sh                   # Audit daemon configuration
│       ├── systemd-services.nix       # Systemd unit definitions
│       ├── sysctl-limits-env.nix      # Kernel parameters and limits
│       ├── misc-os.sh                 # Packages.txt, SBOM, locale, network
│       ├── openstack-agent-settings.nix  # OpenStack cloud-init
│       ├── users.nix                  # User account creation
│       ├── debug-ssh-root-login.nix   # Debug SSH access
│       └── blobstore-clis.nix         # Blobstore tools (S3, Azure, etc.)
├── stemcells/
│   ├── bootable-disk.sh               # Disk builder (L2) → root.qcow2
│   ├── bootable-disk.nix              # Wrapper calling bootable-disk.sh
│   ├── openstack-kvm-disk.nix         # Disk packaging for OpenStack/KVM
│   ├── openstack-kvm.nix              # L3 stemcell packaging → bosh-stemcell-*.tgz
│   └── package.nix                    # Stemcell archive creation (tar/gzip determinism)
├── scripts/
│   ├── byte-check.sh                  # Generic 2-build reproducibility gate
│   ├── byte-check-osimage.sh          # L1 gate wrapper
│   ├── byte-check-disk.sh             # L2 gate wrapper
│   └── byte-check-stemcell.sh         # L3 gate wrapper
├── docs/
│   ├── ARCHITECTURE.md                # This file
│   └── superpowers/specs/
│       └── 2026-07-14-binary-reproducibility-findings.md
├── pkgs/
│   ├── bosh-agent.nix                 # BOSH agent build
│   ├── monit.nix                      # Monit process monitor
│   └── blobstore-clis.nix             # Blobstore CLI tools
├── lib/
│   ├── mkVmImage.nix                  # VM image creation utilities
│   └── mkOverlay.nix                  # Overlay composition utilities
├── examples/
│   ├── noble-bootable.nix             # Standalone bootable disk example
│   ├── noble-closure.nix              # Dependency resolver inspection
│   └── hello-vm.nix                   # Minimal hello world VM
└── .gitignore                         # Ignores bosh.env (secrets), results/, ...
```

With:

```
├── flake.nix                          # Nix flake entry point (packages, devShells)
│                                       # L1: os-image → build/rootfs/os-image.nix
│                                       # L2: noble-stemcell-disk → build/stemcells/openstack-kvm-disk.nix
│                                       # L3: noble-stemcell → build/stemcells/openstack-kvm.nix
├── flake.lock                         # Reproducible dependency lock (git-tracked)
├── build/
│   ├── ubuntu/
│   │   ├── apt-pins.nix               # APT coordinates (snapshot URL + index hashes)
│   │   ├── deb-sets.nix               # Package lists (bootEssentials, bosh, image)
│   │   └── essential.nix              # Essential package seed (pure-Nix parsing)
│   ├── rootfs/
│   │   ├── os-image.nix               # Entry point (base + overlays) → L1 output
│   │   ├── rootfs.nix                 # Tarball builder (calls tarball.nix)
│   │   ├── tarball.nix                # Deterministic tar + gzip → rootfs.tar.gz
│   │   ├── fill-disk-usrmerge.nix     # In-VM dpkg extraction (usrmerge-safe fork)
│   │   ├── apply-overlays.nix         # Overlay application (single fakeroot session)
│   │   └── overlays/
│   │       ├── default.nix            # Overlay orchestration
│   │       ├── ssh.nix                 # SSH key generation and config
│   │       ├── sudoers-pam.sh          # Sudoers and PAM setup
│   │       ├── audit.sh                # Audit daemon configuration
│   │       ├── systemd-services.nix    # Systemd unit definitions
│   │       ├── sysctl-limits-env.nix   # Kernel parameters and limits
│   │       ├── misc-os.sh              # Packages.txt, SBOM, locale, network
│   │       ├── openstack-agent-settings.nix  # OpenStack cloud-init
│   │       ├── users.nix               # User account creation
│   │       ├── debug-ssh-root-login.nix # Debug SSH access
│   │       └── blobstore-clis.nix      # Blobstore tools (S3, Azure, etc.)
│   ├── stemcells/
│   │   ├── bootable-disk.sh           # Disk builder (L2) → root.qcow2
│   │   ├── bootable-disk.nix          # Wrapper calling bootable-disk.sh
│   │   ├── openstack-kvm-disk.nix     # Disk packaging for OpenStack/KVM
│   │   ├── openstack-kvm.nix          # L3 stemcell packaging → bosh-stemcell-*.tgz
│   │   └── package.nix                # Stemcell archive creation (tar/gzip determinism)
│   ├── pkgs/
│   │   ├── bosh-agent.nix             # BOSH agent build
│   │   ├── monit.nix                  # Monit process monitor
│   │   └── blobstore-clis.nix         # Blobstore CLI tools
│   ├── lib/
│   │   ├── mkVmImage.nix              # VM image creation utilities
│   │   └── mkOverlay.nix              # Overlay composition utilities
│   └── examples/
│       ├── noble-bootable.nix         # Standalone bootable disk example
│       ├── noble-closure.nix          # Dependency resolver inspection
│       └── hello-vm.nix               # Minimal hello world VM
├── scripts/
│   ├── byte-check.sh                  # Generic 2-build reproducibility gate
│   ├── byte-check-osimage.sh          # L1 gate wrapper
│   ├── byte-check-disk.sh             # L2 gate wrapper
│   └── byte-check-stemcell.sh         # L3 gate wrapper
├── docs/
│   ├── ARCHITECTURE.md                # This file
│   └── superpowers/specs/
│       └── 2026-07-14-binary-reproducibility-findings.md
└── .gitignore                         # Ignores bosh.env (secrets), results/, ...
```

- [ ] **Step 2: Commit**

```bash
git add docs/ARCHITECTURE.md
git commit -m "docs: update ARCHITECTURE.md tree diagram for build/ move"
```

---

### Task 5: Update `docs/ARCHITECTURE.md` inline path references

**Files:**
- Modify: `docs/ARCHITECTURE.md` (all remaining `ubuntu/`, `rootfs/`, `stemcells/`, `pkgs/`, `lib/`, `examples/` path mentions outside the tree diagram already handled in Task 4)

This file has ~35 markdown links of the form `` [`rootfs/foo.nix`](../rootfs/foo.nix) `` plus one bare mention `` `ubuntu/apt-pins.nix` `` (line 566) that all need a `build/` prefix inserted. Two things must NOT be touched:
- The `snapshot.ubuntu.com/ubuntu/...` URLs (not repo paths).
- The `../nixos/lib/build-vms.nix` reference on the `nixos/nixpkgs` GitHub URL (upstream repo, not ours).
- The code excerpt at line 167 (`packages = (callPackage ../ubuntu/deb-sets.nix { }).image;`) — this reflects `build/rootfs/rootfs.nix`'s actual unchanged relative import to `build/ubuntu/deb-sets.nix` and must stay exactly as printed.

- [ ] **Step 1: Confirm the two sed patterns only touch markdown link syntax**

```bash
grep -nE '`(ubuntu|rootfs|stemcells|pkgs|lib|examples)/' docs/ARCHITECTURE.md | grep -v 'build/'
```
Expected: lists exactly the ~35 backtick-wrapped path mentions (link text) plus the line 566 bare mention — no snapshot/nixos-upstream lines.

```bash
grep -nE '\]\(\.\./(ubuntu|rootfs|stemcells|pkgs|lib|examples)/' docs/ARCHITECTURE.md
```
Expected: lists exactly the matching link targets (same line numbers as above, minus line 566 which has no link).

- [ ] **Step 2: Apply the two substitutions**

```bash
sed -i -E 's#`(ubuntu|rootfs|stemcells|pkgs|lib|examples)/#`build/\1/#g' docs/ARCHITECTURE.md
sed -i -E 's#\]\(\.\./(ubuntu|rootfs|stemcells|pkgs|lib|examples)/#](../build/\1/#g' docs/ARCHITECTURE.md
```

- [ ] **Step 3: Verify no stray unprefixed repo-path mentions remain, and the protected lines are untouched**

```bash
grep -nE '`(ubuntu|rootfs|stemcells|pkgs|lib|examples)/' docs/ARCHITECTURE.md | grep -v 'build/'
```
Expected: no output (every mention now has `build/`).

```bash
grep -n 'callPackage ../ubuntu/deb-sets.nix' docs/ARCHITECTURE.md
```
Expected: `167:  packages = (callPackage ../ubuntu/deb-sets.nix { }).image;` — unchanged.

```bash
grep -n 'snapshot.ubuntu.com' docs/ARCHITECTURE.md | head -3
```
Expected: URLs still read `snapshot.ubuntu.com/ubuntu/20260101T000000Z...` — unchanged (not touched, since these aren't preceded by a backtick or `](../`).

- [ ] **Step 4: Commit**

```bash
git add docs/ARCHITECTURE.md
git commit -m "docs: update ARCHITECTURE.md path references for build/ move"
```

---

### Task 6: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Run flake check**

```bash
nix flake check
```
Expected: exits 0 (evaluates all outputs, runs treefmt check with the updated `build/rootfs/overlays/*.sh` exclude).

- [ ] **Step 2: Dry-run build the L1 output**

```bash
nix build .#os-image --dry-run
```
Expected: succeeds in planning the build (prints derivations to build, no "error: getting status of" / no-such-file errors) — confirms `build/rootfs/os-image.nix` → `build/ubuntu/*.nix` import chain resolves.

- [ ] **Step 3: Dry-run build the L3 output**

```bash
nix build .#noble-stemcell --dry-run
```
Expected: succeeds in planning the build — confirms `build/stemcells/openstack-kvm.nix` → `build/stemcells/openstack-kvm-disk.nix` → `build/rootfs/os-image.nix` → `build/lib/mkVmImage.nix` import chain resolves.

- [ ] **Step 4: Confirm git history was preserved on the moved files**

```bash
git log --follow --oneline -- build/lib/mkOverlay.nix | head -3
```
Expected: shows commit history from before the move (e.g. `refactor: move overlays into rootfs/overlays/ + add default.nix`), confirming `--follow` tracks the rename.

- [ ] **Step 5: Confirm working tree is clean**

```bash
git status --short
```
Expected: no output (everything committed).
