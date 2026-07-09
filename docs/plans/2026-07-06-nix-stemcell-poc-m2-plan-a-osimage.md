# M2 Plan A — Phase-1 OS image in Nix → `OS_IMAGE` specs green

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the M1 bootable Noble rootfs into a fully Nix-built **phase-1 OS image** (all `ubuntu_os_stages` config/setup stages applied declaratively) that passes the retained `bosh-stemcell/spec/os_image/ubuntu_spec.rb` Serverspec suite, with any classic-only/infeasible specs explicitly quarantined.

**Architecture:** Emit the M1 package closure as a **rootfs tarball** (store artifact, no disk). Apply the 24 phase-1 config stages as **pure-Nix overlay derivations** (`stdenv.mkDerivation` unpack → edit tree with coreutils/sed → repack; no VM, no chroot). Users/groups and systemd enablement are written declaratively (the spec provides exact expected bytes). Wire a **Nix Ruby devShell** that runs the retained Serverspec harness (`OS_IMAGE=<tarball>` → `sudo tar xf` → chroot) against the produced `os-image.tgz`.

**Tech Stack:** Nix flakes (`nixos-26.05`), `vmTools.runInLinuxVM` (for the closure tarball only), `stdenv.mkDerivation` + `gnused`/`coreutils` (overlays), Ruby + bundler + rspec + serverspec (oracle), the in-repo `bosh-linux-stemcell-builder/stemcell_builder/stages/*/assets` (reused verbatim).

**Prerequisite decisions (from `2026-07-06-nix-stemcell-poc-m2-design.md`):** A2 full-Nix; maximally Nix-native stage application; real Serverspec oracle via Nix Ruby; full-suite-green with documented quarantine.

---

## Scope

**In scope (phase-1 `ubuntu_os_stages`, minus the 4 L0 package stages M1 already covers):**

`base_ubuntu_firstboot`, `bosh_systemd_resolved`, `base_file_permission`, `base_ssh`,
`bosh_sysstat`, `bosh_environment`, `bosh_sysctl`, `bosh_limits`, `bosh_users`, `bosh_monit`,
`bosh_ntp`, `bosh_sudoers`, `bosh_systemd`, `password_policies`, `restrict_su_command`,
`tty_config`, `rsyslog_config`, `system_grub` (config parts), `vim_tiny`, `cron_config`,
`escape_ctrl_alt_del`, `bosh_audit_ubuntu`, `bosh_log_audit_start`, `clean_machine_id`.

**Out of scope (later plans):** phase-2 agent/openstack stages (Plan B/C), disk assembly
`image_create_efi`/`image_install_grub` (Plan C), qcow2 tarball + `STEMCELL_IMAGE` specs (Plan D),
Ruby build-path deletion (Plan E). `base_debootstrap`/`base_apt`/`base_ubuntu_build_essential`/
`base_ubuntu_packages` are already realized by `makeImageFromDebDist` (M1).

**Exit criteria:**
- `nix build .#os-image` produces `os-image.tgz` (a phase-1 rootfs tarball).
- `bundle exec rspec spec/os_image/ubuntu_spec.rb` (via the Nix Ruby devShell, `OS_IMAGE=os-image.tgz`)
  is **green**, with a committed `docs/superpowers/specs/2026-07-06-m2-osimage-quarantine.md`
  listing every quarantined example + justification.
- Baseline (first run, pre-overlay) and final (green) reports are committed for the record.

---

## File Structure

**Create:**
- `poc/lib/mk-rootfs-tarball.nix` — variant of the usrmerge-safe VM builder that emits a rootfs
  **tarball** (`$out/rootfs.tar.gz`) instead of a disk image.
- `poc/lib/mk-overlay.nix` — helper: `applyOverlay { base; name; script; }` → new tarball with
  `script` run against the unpacked tree (pure Nix, no VM).
- `poc/lib/stage-assets.nix` — exposes the in-repo builder asset tree as a Nix path
  (`../../bosh-linux-stemcell-builder/stemcell_builder/stages`) for verbatim reuse.
- `poc/examples/noble-rootfs.nix` — the phase-1 package closure as a tarball (consumes `mk-rootfs-tarball`).
- `poc/examples/os-image.nix` — folds every phase-1 overlay onto `noble-rootfs`, emits `os-image.tgz`.
- `poc/lib/overlays/*.nix` — one file per stage-group (see tasks). Each is
  `{ stageAssets, ... }: { name = "..."; script = ''...''; }`.
- `poc/oracle/` — retained Serverspec runner: `flake`-wired devShell inputs (`Gemfile`,
  `Gemfile.lock`, `run-os-image-specs.sh`).
- `docs/superpowers/specs/2026-07-06-m2-osimage-quarantine.md` — the quarantine ledger.
- `docs/superpowers/specs/2026-07-06-m2-osimage-baseline.md` — first-run triage report.

**Modify:**
- `poc/flake.nix` — add the `oracle` devShell (Ruby/bundler/serverspec + `sudo` note); examples
  auto-map already picks up `noble-rootfs.nix` and `os-image.nix`.

**Reuse verbatim (do NOT copy bytes):**
- `bosh-linux-stemcell-builder/stemcell_builder/stages/<stage>/assets/*` — referenced by path from
  overlays (securetty, sysctl confs, rsyslog assets, sshd cipher/mac drop-ins, monit unit, journald
  override, `bosh-start-logging-and-auditing`, etc.).

---

## Conventions for every task

- **Build:** `nix build ./poc#<attr> -L --keep-failed --out-link /tmp/opencode/<attr>` .
  `-L` stdout from VM tasks is polluted by blank `ubuntu>` lines; read real errors via
  `nix log <drv> | grep -v '^ubuntu> *$'` near the tail.
- **Flakes see only git-tracked files:** `git add` every new POC file before `nix build`/`nix eval`.
- **Oracle run:** `nix develop ./poc#oracle --command bash poc/oracle/run-os-image-specs.sh <os-image.tgz>`
  (needs host `sudo` for `tar xf` + chroot; host has it).
- **Commit** after each task with the message shown in its final step.

---

## Task 1: Emit the phase-1 package closure as a rootfs tarball

**Files:**
- Create: `poc/lib/mk-rootfs-tarball.nix`
- Create: `poc/examples/noble-rootfs.nix`

Rationale: the M1 `makeImageFromDebDist` outputs a *disk image*; overlays and the `OS_IMAGE`
harness both need a plain **rootfs tarball**. We reuse the usrmerge-safe `fillDiskWithDebs` VM
(it already unpacks + runs postinsts into `/mnt`) but replace the disk-output tail with
`tar` of `/mnt` after unmounting the bind mounts.

- [ ] **Step 1: Write `mk-rootfs-tarball.nix`**

```nix
# Emits the deb closure as a rootfs TARBALL ($out/rootfs.tar.gz), not a disk image.
# Reuses the usrmerge-safe fillDiskWithDebs VM (poc/lib/fill-disk-usrmerge.nix); the only
# difference is the tail: after dpkg install + postInstall, unmount the bind mounts and
# `tar` /mnt into $out instead of keeping the ext4 disk. No grub, no partitions.
{ callPackage, lib, util-linux, gnutar, gzip }:
let
  inherit (callPackage ./fill-disk-usrmerge.nix { }) makeImageFromDebDist;
in
{ noble, packages, size ? 8192, seedStartStopDaemon ? true }:
makeImageFromDebDist {
  inherit (noble) name fullName urlPrefix packagesLists;
  inherit packages size;

  # Same start-stop-daemon seed the M1 image uses (see noble-bootable.nix header).
  createRootFS = ''
    ${util-linux}/bin/mount -t ext4 /dev/vda /mnt 2>/dev/null || true
  '' + lib.optionalString seedStartStopDaemon ''
    mkdir -p /mnt/usr/sbin
    printf '#!/bin/true\n' > /mnt/usr/sbin/start-stop-daemon
    chmod 755 /mnt/usr/sbin/start-stop-daemon
  '';

  # postInstall runs (fill-disk-usrmerge.nix:122) with /mnt still mounted and the
  # inst/proc/dev bind mounts active. Unmount those, then tar the clean tree to $out.
  postInstall = ''
    ${util-linux}/bin/umount /mnt/inst${builtins.storeDir} || true
    ${util-linux}/bin/umount /mnt/proc || true
    ${util-linux}/bin/umount /mnt/dev  || true
    mkdir -p $out
    ${gnutar}/bin/tar --numeric-owner --one-file-system \
      -C /mnt -cf - . | ${gzip}/bin/gzip -1 > $out/rootfs.tar.gz
  '';
}
```

> NOTE for implementer: verify `createRootFS` still gets `/mnt` from `defaultCreateRootFS`
> semantics. The M1 `noble-bootable.nix` overrides `createRootFS` and mounts partitions itself.
> Here we want the DEFAULT single-ext4-at-/mnt rootfs. If `defaultCreateRootFS` already mounts
> `/mnt`, drop the explicit `mount` line and keep only the seed. Confirm by reading
> `pkgs/build-support/vm/default.nix` `defaultCreateRootFS` in the pinned nixpkgs
> (`/nix/store/pl75sc81jyq5cz916j9bjwyx7c1w4qk3-source`).

- [ ] **Step 2: Write `noble-rootfs.nix`**

```nix
# Phase-1 package closure as a rootfs tarball. Same package set + distro coords as the
# M1 boot gate (poc/examples/noble-bootable.nix), but output is $out/rootfs.tar.gz.
{ callPackage }:
let
  noble = callPackage ../lib/noble-distro.nix { };
  mkRootfsTarball = callPackage ../lib/mk-rootfs-tarball.nix { };
in
mkRootfsTarball {
  inherit noble;
  packages = callPackage ../lib/image-packages.nix { };
  size = 8192;
}
```

- [ ] **Step 3: git add + build**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
git add poc/lib/mk-rootfs-tarball.nix poc/examples/noble-rootfs.nix
nix build ./poc#noble-rootfs -L --keep-failed --out-link /tmp/opencode/noble-rootfs
```
Expected: build succeeds; `/tmp/opencode/noble-rootfs/rootfs.tar.gz` exists.

- [ ] **Step 4: Sanity-check the tarball is a real rootfs**

Run:
```bash
tar tzf /tmp/opencode/noble-rootfs/rootfs.tar.gz | grep -E '^\./(etc/passwd|bin/bash|var/lib/dpkg/status|usr/sbin/sshd)$' | sort
```
Expected: all four paths present (proves dpkg postinsts ran + core files exist).

- [ ] **Step 5: Commit**

```bash
git add poc/lib/mk-rootfs-tarball.nix poc/examples/noble-rootfs.nix
git commit -m "feat(m2): emit phase-1 package closure as rootfs tarball (noble-rootfs)"
```

---

## Task 2: Overlay helper + in-repo asset path

**Files:**
- Create: `poc/lib/mk-overlay.nix`
- Create: `poc/lib/stage-assets.nix`

Rationale: every config stage is "unpack the previous tarball, edit the tree, repack." One
helper keeps that DRY and VM-free. `stage-assets.nix` exposes the upstream asset tree so
overlays reuse asset files verbatim (convert-in-place).

- [ ] **Step 1: Write `mk-overlay.nix`**

```nix
# Pure-Nix (no VM, no chroot) tarball -> tarball transform.
# Unpacks `base` (a derivation producing $out/rootfs.tar.gz) into a tree, runs `script`
# with $root pointing at the tree, then repacks to $out/rootfs.tar.gz.
{ stdenv, gnutar, gzip, coreutils, gnused, gawk, gnugrep, findutils }:
{ base, name, script }:
stdenv.mkDerivation {
  name = "os-overlay-${name}";
  nativeBuildInputs = [ gnutar gzip coreutils gnused gawk gnugrep findutils ];
  buildCommand = ''
    root=$PWD/root
    mkdir -p "$root"
    tar -xzf ${base}/rootfs.tar.gz -C "$root"

    # --- stage script runs here; $root is the rootfs tree ---
    ${script}
    # --------------------------------------------------------

    mkdir -p $out
    tar --numeric-owner --one-file-system -C "$root" -czf $out/rootfs.tar.gz .
  '';
}
```

- [ ] **Step 2: Write `stage-assets.nix`**

```nix
# The upstream builder's stage asset tree, exposed as a Nix store path so overlays can
# reuse asset files verbatim (convert-in-place). Path is relative to the repo root.
{ lib }:
# NOTE: this pulls the builder subtree into the store. It is large; if closure size becomes
# a problem, replace with a filterSource limited to the assets actually referenced.
../../bosh-linux-stemcell-builder/stemcell_builder/stages
```

> IMPLEMENTER NOTE: the builder tree must be git-tracked for the flake to see it. Confirm with
> `git ls-files bosh-linux-stemcell-builder/stemcell_builder/stages | head`. It is a nested repo;
> if it is a submodule/untracked, add a `filterSource` copy or `builtins.path` with the needed
> asset files only. Resolve this before Task 4.

- [ ] **Step 3: git add + eval-check**

Run:
```bash
git add poc/lib/mk-overlay.nix poc/lib/stage-assets.nix
nix eval --raw ./poc#legacyPackages.x86_64-linux 2>/dev/null || \
  nix eval ./poc --apply 'f: "ok"' 2>/dev/null; echo "eval smoke done"
```
Expected: no eval error referencing the two new files (they are libs, not packages yet).

- [ ] **Step 4: Commit**

```bash
git add poc/lib/mk-overlay.nix poc/lib/stage-assets.nix
git commit -m "feat(m2): add pure-Nix overlay helper + in-repo stage-assets path"
```

---

## Task 3: Nix Ruby oracle devShell + Serverspec runner (baseline)

**Files:**
- Create: `poc/oracle/Gemfile`
- Create: `poc/oracle/run-os-image-specs.sh`
- Modify: `poc/flake.nix` (add `oracle` devShell)
- Create: `docs/superpowers/specs/2026-07-06-m2-osimage-baseline.md`

Rationale: stand up the retained harness against the *bare* `noble-rootfs` tarball first, to
produce a baseline pass/fail report and seed the quarantine list BEFORE any overlay. The harness
model: `OS_IMAGE=<tgz>` → `sudo tar xf` into tmpdir → `ShelloutTypes::Chroot` runs `file()/command()/
package()/service()` against the chroot (see `bosh-stemcell/spec/support/os_image.rb`).

- [ ] **Step 1: Write `poc/oracle/Gemfile`**

```ruby
source "https://rubygems.org"
gem "rspec"
gem "rspec-its"
gem "serverspec"
gem "specinfra"
```

> IMPLEMENTER NOTE: pin versions to what the builder's existing `bosh-stemcell/Gemfile.lock`
> uses for rspec/serverspec/specinfra to match matcher behaviour. Copy those exact versions in,
> then `bundle lock` inside the devShell to generate `poc/oracle/Gemfile.lock`; commit it.

- [ ] **Step 2: Write `poc/oracle/run-os-image-specs.sh`**

```bash
#!/usr/bin/env bash
# Runs the retained os_image Serverspec suite against a Nix-built rootfs tarball.
# Usage: run-os-image-specs.sh <os-image.tgz> [rspec args...]
set -euo pipefail

OS_IMAGE_TGZ="$(readlink -f "$1")"; shift || true
REPO_ROOT="$(git rev-parse --show-toplevel)"
SPEC_DIR="$REPO_ROOT/bosh-linux-stemcell-builder/bosh-stemcell"

export OS_IMAGE="$OS_IMAGE_TGZ"
export STEMCELL_INFRASTRUCTURE=openstack   # selects /boot/grub grub_cfg_path (spec_helper.rb)

cd "$SPEC_DIR"
# BUNDLE_GEMFILE points at the POC Gemfile so we use the Nix-provided gems, not the builder's.
export BUNDLE_GEMFILE="$REPO_ROOT/poc/oracle/Gemfile"
bundle install --local || bundle install
exec bundle exec rspec -I "$SPEC_DIR/spec" -I "$SPEC_DIR/lib" \
  "$SPEC_DIR/spec/os_image/ubuntu_spec.rb" "$@"
```

> IMPLEMENTER NOTE: the harness `require`s `bosh/stemcell/arch`, `shellout_types/*`, and (for
> stemcell specs later) `bosh/stemcell/disk_image`. Those live under `bosh-stemcell/lib` and
> `bosh-stemcell/spec`. The `-I` flags above put both on the load path. If `bosh/stemcell/arch`
> pulls heavy build-only deps, extract only `arch.rb` + `disk_image.rb` + `Bosh::Core::Shell`
> into a `poc/oracle/lib-slice/` and `-I` that instead (this is the "retained minimal lib slice"
> from the design). Decide during this task and record which files were retained.

- [ ] **Step 3: Add the `oracle` devShell to `poc/flake.nix`**

Add inside `perSystem = { pkgs, ... }: { ... }` alongside the existing `devShells.default`:

```nix
      devShells.oracle = pkgs.mkShell {
        packages = with pkgs; [
          ruby_3_3 bundler
          # native gem build + serverspec runtime deps
          gcc gnumake libyaml openssl pkg-config
          gnutar gzip sudo
        ];
        shellHook = ''
          export BUNDLE_PATH="$PWD/.bundle"
          echo "POC oracle devshell: ruby $(ruby -v)"
          echo "Run: bash poc/oracle/run-os-image-specs.sh <os-image.tgz>"
        '';
      };
```

- [ ] **Step 4: git add, build the bare rootfs, run the baseline suite**

Run:
```bash
chmod +x poc/oracle/run-os-image-specs.sh
git add poc/oracle/Gemfile poc/oracle/run-os-image-specs.sh poc/flake.nix
nix build ./poc#noble-rootfs --out-link /tmp/opencode/noble-rootfs
nix develop ./poc#oracle --command bash poc/oracle/run-os-image-specs.sh \
  /tmp/opencode/noble-rootfs/rootfs.tar.gz --no-color 2>&1 | tee /tmp/opencode/osimage-baseline.txt || true
```
Expected: the suite RUNS (harness untars, chroots) and reports many failures (no overlays yet).
The run completing — not passing — is the success condition here.

- [ ] **Step 5: Record the baseline report + seed quarantine**

Write `docs/superpowers/specs/2026-07-06-m2-osimage-baseline.md` summarizing: total examples,
pass/fail counts, and a first pass at which failures are (a) fixable by an overlay (map to a
stage) vs (b) candidate quarantine (classic-build-only / infeasible). Include the raw
`/tmp/opencode/osimage-baseline.txt` tail.

- [ ] **Step 6: Commit**

```bash
git add poc/oracle docs/superpowers/specs/2026-07-06-m2-osimage-baseline.md
git commit -m "feat(m2): wire Nix Ruby Serverspec oracle; record os_image baseline"
```

---

## Task 4: Overlay — SSH hardening (`base_ssh`, `tty_config`)

**Files:**
- Create: `poc/lib/overlays/ssh.nix`
- Modify: `poc/examples/os-image.nix` (created in this task; grown by later tasks)

Targets these `os_image/ubuntu_spec.rb` examples: "installed by base_ssh" (Ciphers/MACs),
"configured by base_ssh" (PermitRootLogin no, MaxAuthTries 3, Banner, host keys, mode 0600),
"/etc/securetty" (restricts root login).

- [ ] **Step 1: Write `poc/lib/overlays/ssh.nix`**

```nix
# base_ssh + tty_config. Reproduces stemcell_builder/stages/base_ssh/apply.sh sed/echo edits
# on $root/etc/ssh/sshd_config, copies the firstboot drop-in + securetty verbatim, and installs
# the cipher/mac hardening the os_image spec asserts.
{ stageAssets }:
{
  name = "ssh";
  script = ''
    cfg="$root/etc/ssh/sshd_config"
    echo "" >> "$cfg"
    for kv in \
      "UseDNS no" "PermitRootLogin no" "X11Forwarding no" "MaxAuthTries 3" \
      "PermitEmptyPasswords no" "Protocol 2" "HostbasedAuthentication no" \
      "Banner /etc/issue.net" "IgnoreRhosts yes" "ClientAliveInterval 180" \
      "LoginGraceTime 60" "Compression delayed" "PermitUserEnvironment no" \
      "ClientAliveCountMax 1" "PasswordAuthentication no" "PrintLastLog yes" \
      "AllowGroups bosh_sshers" "DenyUsers root"; do
      key=''${kv%% *}
      sed -i "/^ *$key/d" "$cfg"
      echo "$kv" >> "$cfg"
    done
    sed -i "/^ *X11DisplayOffset/d" "$cfg"
    # Ciphers + MACs (asserted verbatim by the os_image spec)
    sed -i "/^ *Ciphers/d;/^ *MACs/d" "$cfg"
    echo 'Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr' >> "$cfg"
    echo 'MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com' >> "$cfg"
    # host keys: drop DSA, ensure rsa/ecdsa/ed25519 uncommented
    sed -i "/^[ #]*HostKey \/etc\/ssh\/ssh_host_dsa_key/d" "$cfg"
    for t in rsa ecdsa ed25519; do
      sed -i "s|^[ #]*HostKey /etc/ssh/ssh_host_''${t}_key|HostKey /etc/ssh/ssh_host_''${t}_key|" "$cfg"
    done
    chmod 0600 "$cfg"

    # firstboot drop-in (verbatim asset)
    mkdir -p "$root/lib/systemd/system/ssh.service.d"
    cp ${stageAssets}/base_ssh/assets/10-ssh-firstboot-done.conf \
       "$root/lib/systemd/system/ssh.service.d/10-ssh-firstboot-done.conf"

    # tty_config: securetty (verbatim asset)
    cp ${stageAssets}/tty_config/assets/securetty "$root/etc/securetty"
  '';
}
```

> IMPLEMENTER NOTE: the spec also asserts `/etc/issue.net` banner content ("Unauthorized use is
> strictly prohibited..."). That is written by a different stage (`base_ubuntu_firstboot` or the
> banner asset). If the baseline shows the banner example failing, add the banner copy here or in
> Task 5 — check which stage ships `issue.net` (grep the builder for "Unauthorized use").

- [ ] **Step 2: Create `poc/examples/os-image.nix` with the fold mechanism (ssh only for now)**

```nix
# Phase-1 OS image: fold every config overlay onto the noble-rootfs closure.
# Overlays are added task-by-task; the list order mirrors ubuntu_os_stages where it matters
# (users before anything asserting group membership; ssh after base packages).
{ callPackage, lib }:
let
  stageAssets = callPackage ../lib/stage-assets.nix { };
  applyOverlay = callPackage ../lib/mk-overlay.nix { };
  base = callPackage ./noble-rootfs.nix { };

  overlays = [
    (import ../lib/overlays/ssh.nix { inherit stageAssets; })
  ];

  final = lib.foldl (acc: ov: applyOverlay {
    base = acc; inherit (ov) name script;
  }) base overlays;
in
# Re-expose as os-image.tgz for the oracle harness.
final
```

- [ ] **Step 3: git add + build + run ssh-related specs**

Run:
```bash
git add poc/lib/overlays/ssh.nix poc/examples/os-image.nix
nix build ./poc#os-image --out-link /tmp/opencode/os-image
nix develop ./poc#oracle --command bash poc/oracle/run-os-image-specs.sh \
  /tmp/opencode/os-image/rootfs.tar.gz -e "base_ssh" -e "securetty" --no-color
```
Expected: the "installed by base_ssh", "configured by base_ssh", and "/etc/securetty" examples PASS.

- [ ] **Step 4: Commit**

```bash
git add poc/lib/overlays/ssh.nix poc/examples/os-image.nix
git commit -m "feat(m2): ssh + securetty overlay (base_ssh, tty_config) passes os_image specs"
```

---

## Task 5: Overlay — users & groups (`bosh_users`) — declarative passwd/group/gshadow

**Files:**
- Create: `poc/lib/overlays/users.nix`
- Modify: `poc/examples/os-image.nix` (prepend to overlay list — users first)

Targets: the `/etc/group` and `/etc/gshadow` **exact-content** examples, `/etc/passwd` contains
`/home/vcap:/bin/bash`, `id -gn vcap` == `vcap`, vcap in `bosh_sshers`/`sudo`/`admin`, `~vcap`
mode 700, `.bashrc`/`.profile`/`00-bosh-ps1` files. The spec provides the exact expected
`/etc/group` and `/etc/gshadow` bytes — write them verbatim.

- [ ] **Step 1: Read the classic `bosh_users` stage to get UID/paths + `.bashrc`/ps1 content**

Run:
```bash
sed -n '1,200p' bosh-linux-stemcell-builder/stemcell_builder/stages/bosh_users/apply.sh
ls bosh-linux-stemcell-builder/stemcell_builder/stages/bosh_users/assets 2>/dev/null
```
Capture: vcap UID (1000), group ids, skel/.bashrc content, `/etc/profile.d/00-bosh-ps1*` asset.

- [ ] **Step 2: Write `poc/lib/overlays/users.nix`**

Write the exact `/etc/group` and `/etc/gshadow` from the spec (they are quoted verbatim in
`os_image/ubuntu_spec.rb`), append the vcap/root lines to `/etc/passwd` and `/etc/shadow`,
create `/home/vcap` (mode 700, owned 1000:1000), copy the `00-bosh-ps1` asset, and write the
`.bashrc`/`.profile` lines the spec asserts (`export PATH=/var/vcap/bosh/bin:$PATH`,
`source /etc/profile.d/00-bosh-ps1`). Use a heredoc for the group/gshadow blocks.

```nix
{ stageAssets }:
{
  name = "users";
  script = ''
    # /etc/group — exact bytes asserted by os_image/ubuntu_spec.rb
    cat > "$root/etc/group" <<'GROUP'
    root:x:0:
    daemon:x:1:
    ${"" /* IMPLEMENTER: paste the FULL block from the spec (root..bosh_sudoers), verbatim */}
    GROUP

    cat > "$root/etc/gshadow" <<'GSHADOW'
    ${"" /* IMPLEMENTER: paste the FULL /etc/gshadow block from the spec, verbatim */}
    GSHADOW

    # vcap user (uid/gid 1000), home 700
    getent() { :; }
    grep -q '^vcap:' "$root/etc/passwd" || \
      echo 'vcap:x:1000:1000:BOSH System User:/home/vcap:/bin/bash' >> "$root/etc/passwd"
    grep -q '^vcap:' "$root/etc/shadow" || \
      echo 'vcap:!:19000:0:99999:7:::' >> "$root/etc/shadow"
    mkdir -p "$root/home/vcap"
    chmod 700 "$root/home/vcap"
    chown 1000:1000 "$root/home/vcap"

    cp ${stageAssets}/bosh_users/assets/00-bosh-ps1 "$root/etc/profile.d/00-bosh-ps1" 2>/dev/null || \
      printf '# bosh ps1\n' > "$root/etc/profile.d/00-bosh-ps1"

    for home in "$root/root" "$root/home/vcap" "$root/etc/skel"; do
      mkdir -p "$home"
      printf 'export PATH=/var/vcap/bosh/bin:$PATH\nsource /etc/profile.d/00-bosh-ps1\n' >> "$home/.bashrc"
    done
    grep -q '.bashrc' "$root/root/.profile" 2>/dev/null || \
      printf '\n. ~/.bashrc\n' >> "$root/root/.profile"
  '';
}
```

> IMPLEMENTER NOTE: paste the exact group/gshadow blocks from the spec (they are in this plan's
> research and in `os_image/ubuntu_spec.rb`). Preserve trailing newline — the spec uses
> `should eql(<<~HERE)` (exact match incl. final newline). Strip the leading indentation the
> heredoc adds (use `<<-` with tabs, or a `sed 's/^    //'`, or `.gsub`). Verify byte-equality
> with `diff <(printf '%s' "$expected") "$root/etc/group"`.

- [ ] **Step 3: Put `users` FIRST in the overlay list in `os-image.nix`**

```nix
  overlays = [
    (import ../lib/overlays/users.nix { inherit stageAssets; })
    (import ../lib/overlays/ssh.nix { inherit stageAssets; })
  ];
```

- [ ] **Step 4: build + run users specs**

Run:
```bash
git add poc/lib/overlays/users.nix poc/examples/os-image.nix
nix build ./poc#os-image --out-link /tmp/opencode/os-image
nix develop ./poc#oracle --command bash poc/oracle/run-os-image-specs.sh \
  /tmp/opencode/os-image/rootfs.tar.gz -e "bosh_user" -e "/etc/group" -e "/etc/gshadow" -e "vcap" --no-color
```
Expected: `/etc/group`, `/etc/gshadow`, `/etc/passwd`, `id -gn vcap`, `~vcap` mode, `.bashrc`
examples PASS.

- [ ] **Step 5: Commit**

```bash
git add poc/lib/overlays/users.nix poc/examples/os-image.nix
git commit -m "feat(m2): declarative users/groups overlay (bosh_users) passes os_image specs"
```

---

## Task 6: Overlay — sysctl / limits / environment (`bosh_sysctl`, `bosh_limits`, `bosh_environment`)

**Files:**
- Create: `poc/lib/overlays/sysctl-limits-env.nix`
- Modify: `poc/examples/os-image.nix`

- [ ] **Step 1: Write the overlay**

```nix
{ stageAssets }:
{
  name = "sysctl-limits-env";
  script = ''
    # bosh_sysctl: copy both conf assets verbatim
    install -m0644 ${stageAssets}/bosh_sysctl/assets/60-bosh-sysctl.conf \
      "$root/etc/sysctl.d/60-bosh-sysctl.conf"
    install -m0644 ${stageAssets}/bosh_sysctl/assets/60-bosh-sysctl-neigh-fix.conf \
      "$root/etc/sysctl.d/60-bosh-sysctl-neigh-fix.conf"

    # bosh_limits
    echo '*               hard    core            0' >> "$root/etc/security/limits.conf"

    # bosh_environment
    touch "$root/etc/environment"
    sed -i '/^PATH/d' "$root/etc/environment"
    echo 'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/var/vcap/bosh/bin"' >> "$root/etc/environment"
  '';
}
```

- [ ] **Step 2: add to overlay list, build, run** (append after `ssh`)

Run:
```bash
git add poc/lib/overlays/sysctl-limits-env.nix poc/examples/os-image.nix
nix build ./poc#os-image --out-link /tmp/opencode/os-image
nix develop ./poc#oracle --command bash poc/oracle/run-os-image-specs.sh \
  /tmp/opencode/os-image/rootfs.tar.gz -e "sysctl" -e "limits" -e "environment" --no-color || true
```
Expected: related examples pass (or, if os_image has no direct sysctl assertion, no regressions).

- [ ] **Step 3: Commit**

```bash
git add poc/lib/overlays/sysctl-limits-env.nix poc/examples/os-image.nix
git commit -m "feat(m2): sysctl/limits/environment overlay"
```

---

## Task 7: Overlay — sudoers / su restriction / PAM password policy (`bosh_sudoers`, `restrict_su_command`, `password_policies`)

**Files:**
- Create: `poc/lib/overlays/sudoers-pam.nix`
- Modify: `poc/examples/os-image.nix`

Targets: `/etc/sudoers` (`%bosh_sudoers ALL=(ALL) NOPASSWD: ALL`, `#includedir /etc/sudoers.d`),
`pam_wheel.so use_uid` in `/etc/pam.d/su`, vcap in `sudo` group, PAM `common-password`
(`pam_pwquality.so retry=3 minlen=14 dcredit=-1 ucredit=-1 ocredit=-1 lcredit=-1`, `remember=24`,
`minlen=14`), `common-auth`/`common-account` `pam_faillock.so deny=3`, no `nullok`.

- [ ] **Step 1: Read the classic stages for exact sudoers + PAM edits**

Run:
```bash
cat bosh-linux-stemcell-builder/stemcell_builder/stages/bosh_sudoers/apply.sh
cat bosh-linux-stemcell-builder/stemcell_builder/stages/restrict_su_command/apply.sh
cat bosh-linux-stemcell-builder/stemcell_builder/stages/password_policies/apply.sh
ls bosh-linux-stemcell-builder/stemcell_builder/stages/{bosh_sudoers,password_policies}/assets 2>/dev/null
```
> NOTE: the indexed research showed `bosh_sudoers/apply.sh` = includedir + visudo; the
> `%bosh_sudoers ... NOPASSWD` line + PAM pwquality edits come from the assets / other stages.
> Capture the exact lines here before writing the overlay.

- [ ] **Step 2: Write `poc/lib/overlays/sudoers-pam.nix`** reproducing the captured edits
(sudoers includedir + `%bosh_sudoers` line via `/etc/sudoers.d/` file or sudoers append;
`echo 'auth required pam_wheel.so use_uid' >> /etc/pam.d/su`; add vcap to `sudo` group already
handled in Task 5's group file; strip `nullok` from `/etc/pam.d/*`; write pwquality/faillock lines
into `common-password`/`common-auth`/`common-account`).

- [ ] **Step 3: add to list, build, run PAM/sudoers specs**

Run:
```bash
git add poc/lib/overlays/sudoers-pam.nix poc/examples/os-image.nix
nix build ./poc#os-image --out-link /tmp/opencode/os-image
nix develop ./poc#oracle --command bash poc/oracle/run-os-image-specs.sh \
  /tmp/opencode/os-image/rootfs.tar.gz -e "sudoers" -e "PAM" -e "su command" -e "password" --no-color
```
Expected: sudoers + PAM examples pass.

- [ ] **Step 4: Commit**

```bash
git add poc/lib/overlays/sudoers-pam.nix poc/examples/os-image.nix
git commit -m "feat(m2): sudoers + su restriction + PAM password policy overlay"
```

---

## Task 8: Overlay — rsyslog / journald (`rsyslog_config`)

**Files:**
- Create: `poc/lib/overlays/rsyslog.nix`
- Modify: `poc/examples/os-image.nix`

Targets: `/etc/rsyslog.conf` (`module( load="omrelp" ...)`, `$FileGroup syslog`, `$FileOwner
syslog`, `$FileCreateMode 0600`, `ModLoad imklog`), `syslog` user in `vcap` group (done in Task 5
group file — verify), `wait_for_var_log_to_be_mounted` mode 0755, journald override.

- [ ] **Step 1: Read the stage to enumerate which assets go where**

Run:
```bash
cat bosh-linux-stemcell-builder/stemcell_builder/stages/rsyslog_config/apply.sh
ls bosh-linux-stemcell-builder/stemcell_builder/stages/rsyslog_config/assets
```

- [ ] **Step 2: Write `poc/lib/overlays/rsyslog.nix`** copying each asset to its destination
verbatim (`rsyslog.conf` → `/etc/rsyslog.conf`; `rsyslog_50-default.conf`,
`rsyslog_90-bosh-agent.conf` → `/etc/rsyslog.d/`; `wait_for_var_log_to_be_mounted` →
`/usr/local/bin/` mode 0755; `journal-override.conf` → `/etc/systemd/journald.conf.d/00-override.conf`)
matching the exact `cp` destinations in `apply.sh`.

- [ ] **Step 3: add to list, build, run rsyslog specs**

Run:
```bash
git add poc/lib/overlays/rsyslog.nix poc/examples/os-image.nix
nix build ./poc#os-image --out-link /tmp/opencode/os-image
nix develop ./poc#oracle --command bash poc/oracle/run-os-image-specs.sh \
  /tmp/opencode/os-image/rootfs.tar.gz -e "rsyslog" --no-color
```
Expected: rsyslog examples pass. `rsyslogd -N 1` (exit 0) requires rsyslog binary present in the
chroot — verify it is installed (part of M1 closure).

- [ ] **Step 4: Commit**

```bash
git add poc/lib/overlays/rsyslog.nix poc/examples/os-image.nix
git commit -m "feat(m2): rsyslog + journald overlay (rsyslog_config)"
```

---

## Task 9: Overlay — audit (`bosh_audit_ubuntu`, `bosh_log_audit_start`)

**Files:**
- Create: `poc/lib/overlays/audit.nix`
- Modify: `poc/examples/os-image.nix`

Targets: auditd installed but `should_not be_enabled` (no systemd enable symlink), audit rules
files at asserted paths/modes (`/etc/audit/rules.d/audit.rules` 0640, `/etc/audit/audit.rules`
0640, `/var/log/audit` 0750 owned root:root), `auditd.service` `ExecStartPost=-/sbin/augenrules
--load`, `bosh-start-logging-and-auditing` (0755, contains `service auditd start`).

- [ ] **Step 1: Read `bosh_audit` shared functions to reproduce the rules**

Run:
```bash
cat bosh-linux-stemcell-builder/stemcell_builder/stages/bosh_audit/shared_functions.bash
ls bosh-linux-stemcell-builder/stemcell_builder/stages/bosh_audit*/assets 2>/dev/null
```
Capture `write_shared_audit_rules`, `record_use_of_privileged_binaries`,
`override_default_audit_variables` output.

- [ ] **Step 2: Write `poc/lib/overlays/audit.nix`**: write the audit.rules content the shared
functions produce, set the asserted modes/owners, ensure auditd is **not** enabled
(remove any `/etc/systemd/system/multi-user.target.wants/auditd.service` symlink), copy
`bosh-start-logging-and-auditing` (0755) from `bosh_log_audit_start/assets`.

> IMPLEMENTER NOTE: `chown root:root /var/log/audit` — in the pure-Nix build tree, chown to
> 0:0 is fine (build runs as a uid that can chown within its own tree only if fakeroot). If chown
> fails in the sandbox, wrap the repack in `fakeroot` (add `fakeroot` to `mk-overlay.nix`
> nativeBuildInputs and `fakeroot bash -c '... tar ...'`). Serverspec checks ownership via
> `stat` in the chroot, so the tar must record uid/gid 0. Decide + apply the fakeroot approach
> here and backport to `mk-overlay.nix` if needed.

- [ ] **Step 3: add to list, build, run audit specs**

Run:
```bash
git add poc/lib/overlays/audit.nix poc/examples/os-image.nix
nix build ./poc#os-image --out-link /tmp/opencode/os-image
nix develop ./poc#oracle --command bash poc/oracle/run-os-image-specs.sh \
  /tmp/opencode/os-image/rootfs.tar.gz -e "audit" -e "auditd" --no-color
```
Expected: audit examples pass (or quarantine `dpkg -V audit` if dpkg-verify is infeasible under
the overlay — record justification).

- [ ] **Step 4: Commit**

```bash
git add poc/lib/overlays/audit.nix poc/examples/os-image.nix
git commit -m "feat(m2): audit overlay (bosh_audit_ubuntu, bosh_log_audit_start)"
```

---

## Task 10: Overlay — grub/vim/cron/ctrl-alt-del/machine-id (`system_grub`, `vim_tiny`, `cron_config`, `escape_ctrl_alt_del`, `clean_machine_id`)

**Files:**
- Create: `poc/lib/overlays/misc-os.nix`
- Modify: `poc/examples/os-image.nix`

Targets: `/boot/grub/{unicode.pf2,menu.lst,gfxblacklist.txt}` present, `/usr/bin/vim` →
`/usr/bin/vim.tiny`, `/etc/cron.daily/man-db` absent + `/etc/apt/apt.conf.d/02periodic` content,
`/etc/init/control-alt-delete.override` content, `/etc/machine-id` empty +
`/var/lib/dbus/machine-id` absent.

- [ ] **Step 1: Write `poc/lib/overlays/misc-os.nix`**

```nix
{ stageAssets }:
{
  name = "misc-os";
  script = ''
    # system_grub: menu.lst placeholder (grub2 pkg already installed in M1 closure).
    mkdir -p "$root/boot/grub"
    touch "$root/boot/grub/menu.lst"

    # vim_tiny
    ln -sf /usr/bin/vim.tiny "$root/usr/bin/vim"

    # cron_config: man-db removal + apt periodic disable
    rm -f "$root/etc/cron.weekly/man-db" "$root/etc/cron.daily/man-db" "$root/etc/cron.daily/man-db.cron"
    mkdir -p "$root/etc/apt/apt.conf.d"
    cat > "$root/etc/apt/apt.conf.d/02periodic" <<'EOF'
    APT::Periodic {
      Enable "0";
    }
    EOF
    # anacrontab RANDOM_DELAY (cron_config)
    if [ -f "$root/etc/anacrontab" ]; then
      grep -v RANDOM_DELAY "$root/etc/anacrontab" > "$root/etc/anacrontab.new"
      sed -i -e '1 a RANDOM_DELAY=60' "$root/etc/anacrontab.new"
      mv "$root/etc/anacrontab.new" "$root/etc/anacrontab"
    fi

    # escape_ctrl_alt_del
    mkdir -p "$root/etc/init"
    echo 'exec /usr/bin/logger -p security.info "Control-Alt-Delete pressed"' \
      > "$root/etc/init/control-alt-delete.override"

    # clean_machine_id
    echo "" > "$root/etc/machine-id"
    rm -f "$root/var/lib/dbus/machine-id"
  '';
}
```

> IMPLEMENTER NOTE: `unicode.pf2`/`gfxblacklist.txt` are shipped by the `grub2` package into
> `/boot/grub` only when grub runs; the spec asserts they exist. If missing in the closure, either
> copy them from the `grub-common`/`grub-pc-bin` package payload or quarantine those two file
> examples (they are truly produced by `grub-install`, which is Plan C). Prefer quarantine with a
> note pointing to Plan C, since removable-grub install happens at disk assembly.

- [ ] **Step 2: strip the `<<'EOF'` heredoc indentation** (the leading 4 spaces) — use `sed`
inside the script or a tab-based `<<-`. Verify `/etc/apt/apt.conf.d/02periodic` matches the
spec's `<<~EOF` block exactly.

- [ ] **Step 3: add to list, build, run**

Run:
```bash
git add poc/lib/overlays/misc-os.nix poc/examples/os-image.nix
nix build ./poc#os-image --out-link /tmp/opencode/os-image
nix develop ./poc#oracle --command bash poc/oracle/run-os-image-specs.sh \
  /tmp/opencode/os-image/rootfs.tar.gz -e "system_grub" -e "vim_tiny" -e "cron_config" \
  -e "control alt delete" -e "machine id" --no-color
```
Expected: these examples pass (grub .pf2/.gfxblacklist possibly quarantined per note).

- [ ] **Step 4: Commit**

```bash
git add poc/lib/overlays/misc-os.nix poc/examples/os-image.nix
git commit -m "feat(m2): grub/vim/cron/ctrl-alt-del/machine-id overlay"
```

---

## Task 11: Overlay — systemd units & enablement (`bosh_monit`, `bosh_ntp`, `bosh_systemd`, `bosh_systemd_resolved`, `bosh_sysstat`, `base_ubuntu_firstboot`, `base_file_permission`)

**Files:**
- Create: `poc/lib/overlays/systemd-services.nix`
- Modify: `poc/examples/os-image.nix`

Targets: `/lib/systemd/system/monit.service` (`Restart=always`, `KillMode=process`),
`systemd-networkd` enabled, `create-systemd-resolved-listener-address.service`
(`ip addr add 169.254.0.53 dev lo`), chrony ("an os with chrony" shared example),
firstboot service, and file permissions from `base_file_permission`.

- [ ] **Step 1: Read each stage + assets to enumerate unit files and enable/disable actions**

Run:
```bash
for s in bosh_monit bosh_ntp bosh_systemd bosh_systemd_resolved bosh_sysstat base_ubuntu_firstboot base_file_permission; do
  echo "===== $s ====="; cat bosh-linux-stemcell-builder/stemcell_builder/stages/$s/apply.sh
  ls bosh-linux-stemcell-builder/stemcell_builder/stages/$s/assets 2>/dev/null
done
```

- [ ] **Step 2: Write `poc/lib/overlays/systemd-services.nix`**: copy each `.service`/unit asset
to `/lib/systemd/system/`, and reproduce enable/disable **declaratively** as
`multi-user.target.wants/` (or appropriate `.target.wants/`) symlinks — enabling monit,
systemd-networkd, chrony, firstboot; NOT enabling auditd (Task 9). Apply `base_file_permission`
chmod/chown edits.

> IMPLEMENTER NOTE: `systemctl enable X` = create `WantedBy` symlink under the unit's target
> `.wants` dir (read the unit's `[Install] WantedBy=`). Reproduce exactly that symlink; the
> `service("X") { should be_enabled }` matcher checks for the symlink presence in the chroot.

- [ ] **Step 3: add to list, build, run service specs**

Run:
```bash
git add poc/lib/overlays/systemd-services.nix poc/examples/os-image.nix
nix build ./poc#os-image --out-link /tmp/opencode/os-image
nix develop ./poc#oracle --command bash poc/oracle/run-os-image-specs.sh \
  /tmp/opencode/os-image/rootfs.tar.gz -e "monit" -e "networkd" -e "chrony" -e "resolved" -e "cron" --no-color
```
Expected: service-enabled/unit-content examples pass.

- [ ] **Step 4: Commit**

```bash
git add poc/lib/overlays/systemd-services.nix poc/examples/os-image.nix
git commit -m "feat(m2): systemd units + declarative enablement overlay"
```

---

## Task 12: Full `OS_IMAGE` suite → green + finalize quarantine

**Files:**
- Modify: `poc/examples/os-image.nix` (final overlay order review)
- Create: `docs/superpowers/specs/2026-07-06-m2-osimage-quarantine.md`

- [ ] **Step 1: Run the ENTIRE `os_image/ubuntu_spec.rb` suite**

Run:
```bash
nix build ./poc#os-image --out-link /tmp/opencode/os-image
nix develop ./poc#oracle --command bash poc/oracle/run-os-image-specs.sh \
  /tmp/opencode/os-image/rootfs.tar.gz --no-color 2>&1 | tee /tmp/opencode/osimage-final.txt
```
Expected: 0 unexpected failures. Remaining failures must be *explicitly quarantined*.

- [ ] **Step 2: Quarantine the irreducible failures**

For each still-failing example that is classic-build-only or infeasible under the tarball overlay
(candidates: `apt-key list` "Ubuntu Archive Automatic Signing Key", `dpkg -V audit`, grub
`.pf2`/`gfxblacklist.txt`, anything requiring a booted system), tag it. Prefer a spec-level
`--tag ~quarantine` filter driven by an env, OR a documented exclusion list consumed by
`run-os-image-specs.sh` (add `-e`/`--tag` exclusions). Do NOT edit upstream spec assertions;
exclude by example id/tag only.

- [ ] **Step 3: Write `docs/superpowers/specs/2026-07-06-m2-osimage-quarantine.md`**

For every quarantined example: the example description, the reason (classic-only / needs boot /
produced by a later plan), the plan/stage that would satisfy it (e.g., "grub files → Plan C
`image_install_grub`"), and confidence it is a non-issue for BOSH.

- [ ] **Step 4: Re-run and confirm green (with quarantine applied)**

Run:
```bash
nix develop ./poc#oracle --command bash poc/oracle/run-os-image-specs.sh \
  /tmp/opencode/os-image/rootfs.tar.gz --no-color 2>&1 | tee /tmp/opencode/osimage-green.txt
grep -E "examples?,.*failures?" /tmp/opencode/osimage-green.txt
```
Expected: `... 0 failures` (excluded/quarantined examples reported as pending/filtered).

- [ ] **Step 5: Update the feasibility spec + design finding**

Append to `docs/superpowers/specs/2026-07-06-nix-based-stemcell-feasibility-design.md` a short
"M2 Plan A result" note: phase-1 OS image reproduced as pure-Nix overlays; `OS_IMAGE` suite green
with N quarantined examples; declarative users/groups matched the spec's exact bytes; correction
recorded that `image_create_efi` (not `image_create`) is the OpenStack stage.

- [ ] **Step 6: Commit**

```bash
git add poc/examples/os-image.nix docs/superpowers/specs/2026-07-06-m2-osimage-quarantine.md \
  docs/superpowers/specs/2026-07-06-nix-based-stemcell-feasibility-design.md
git commit -m "feat(m2): phase-1 OS image passes OS_IMAGE Serverspec suite (green + quarantine)"
```

---

## Open risks / implementer decisions carried in this plan

1. **rootfs tree extraction (Task 1):** confirm `defaultCreateRootFS` mounts `/mnt` and that
   `postInstall` can `tar` it before unmount. If `$out` is not writable inside the VM at
   postInstall time, move the tar to a `postVM` hook instead. **Verify before proceeding past Task 1.**
2. **Ownership in overlays (Task 9/11):** pure-Nix repack may need `fakeroot` so `stat` ownership
   assertions (`root:root`, `syslog:syslog`, mode bits) hold in the chroot. Add `fakeroot` to
   `mk-overlay.nix` if any ownership example fails.
3. **Retained Ruby lib slice (Task 3):** decide whether `-I bosh-stemcell/lib` is enough or a
   trimmed `poc/oracle/lib-slice/` (arch.rb, disk_image.rb, Core::Shell) is needed; record it.
4. **Gemfile.lock pinning (Task 3):** match rspec/serverspec/specinfra versions to the builder's
   existing lock to avoid matcher drift.
5. **`stage-assets` closure size (Task 2):** if pulling the whole stages tree is too large, switch
   to `builtins.path` filtering to only-referenced assets.
6. **Quarantine boundary (Task 12):** grub `.pf2`/`gfxblacklist.txt`, `apt-key`, `dpkg -V` are the
   likely quarantines; justify each against BOSH need.

## Self-Review (author checklist — completed)

- **Spec coverage:** all 24 phase-1 `ubuntu_os_stages` config stages map to Tasks 4–11; the
  oracle (design §6) = Task 3+12; rootfs-tree/OS-image-as-fixture (design §2 #5) = Task 1;
  Nix-native overlays (design §2 #4) = Tasks 4–11; quarantine pass bar (design §2 #3) = Task 12.
- **Placeholder scan:** remaining `IMPLEMENTER NOTE`s are genuine investigation points with a
  concrete method + verification (not vague TODOs); exact byte blocks for `/etc/group`,
  `/etc/gshadow` are sourced verbatim from `os_image/ubuntu_spec.rb` and must be pasted in Task 5.
- **Type/name consistency:** overlay contract `{ name; script; }` + `applyOverlay { base; name;
  script; }` used identically across Tasks 2, 4–11; `os-image.nix` `overlays` list order
  documented (users first).
