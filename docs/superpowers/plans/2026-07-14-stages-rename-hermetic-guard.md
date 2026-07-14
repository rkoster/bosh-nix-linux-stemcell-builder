# Rename overlays to stages, relocate to build/stages/, add hermetic guard - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the "overlay" concept to "stage" throughout the repo, relocate `build/rootfs/overlays/` to `build/stages/`, and add a self-verifying network-namespace guard so the build fails loudly (instead of silently) if network is ever reachable during rootfs/stage assembly.

**Architecture:** Mechanical `git mv` + text rename across the stage definitions, the stage-application derivation, and docs, followed by a new shared shell snippet (`build/lib/hermetic-guard.sh`) injected into the two places that build the rootfs (`apply-stages.nix` and `tarball.nix`'s `createRootFS`).

**Tech Stack:** Nix, bash, git.

---

## Reference: Design Spec

Full rationale and investigation findings: `docs/superpowers/specs/2026-07-14-stages-rename-hermetic-guard-design.md`

---

### Task 1: Move directories and files with git mv

**Files:**
- Move: `build/rootfs/overlays/` → `build/stages/`
- Move: `build/rootfs/apply-overlays.nix` → `build/rootfs/apply-stages.nix`
- Move: `build/lib/mkOverlay.nix` → `build/lib/mkStage.nix`

- [ ] **Step 1: Move the stages directory**

```bash
cd /home/ruben/workspace/bosh-nix-linux-stemcell-builder
git mv build/rootfs/overlays build/stages
```

- [ ] **Step 2: Move the stage-application file**

```bash
git mv build/rootfs/apply-overlays.nix build/rootfs/apply-stages.nix
```

- [ ] **Step 3: Move the stage-composition helper**

```bash
git mv build/lib/mkOverlay.nix build/lib/mkStage.nix
```

- [ ] **Step 4: Verify the moves**

```bash
git status --short
```

Expected output (all renames, no content changes yet):

```
R  build/lib/mkOverlay.nix -> build/lib/mkStage.nix
R  build/rootfs/apply-overlays.nix -> build/rootfs/apply-stages.nix
R  build/rootfs/overlays/agent.nix -> build/stages/agent.nix
R  build/rootfs/overlays/audit.nix -> build/stages/audit.nix
R  build/rootfs/overlays/audit.sh -> build/stages/audit.sh
R  build/rootfs/overlays/blobstore-clis.nix -> build/stages/blobstore-clis.nix
R  build/rootfs/overlays/debug-ssh-keys.nix -> build/stages/debug-ssh-keys.nix
R  build/rootfs/overlays/debug-ssh-root-login.nix -> build/stages/debug-ssh-root-login.nix
R  build/rootfs/overlays/debug-ssh-root-login.sh -> build/stages/debug-ssh-root-login.sh
R  build/rootfs/overlays/default.nix -> build/stages/default.nix
R  build/rootfs/overlays/misc-os.nix -> build/stages/misc-os.nix
R  build/rootfs/overlays/misc-os.sh -> build/stages/misc-os.sh
R  build/rootfs/overlays/openstack-agent-settings.nix -> build/stages/openstack-agent-settings.nix
R  build/rootfs/overlays/openstack-agent-settings.sh -> build/stages/openstack-agent-settings.sh
R  build/rootfs/overlays/rsyslog.nix -> build/stages/rsyslog.nix
R  build/rootfs/overlays/rsyslog.sh -> build/stages/rsyslog.sh
R  build/rootfs/overlays/ssh.nix -> build/stages/ssh.nix
R  build/rootfs/overlays/ssh.sh -> build/stages/ssh.sh
R  build/rootfs/overlays/sudoers-pam.nix -> build/stages/sudoers-pam.nix
R  build/rootfs/overlays/sudoers-pam.sh -> build/stages/sudoers-pam.sh
R  build/rootfs/overlays/sysctl-limits-env.nix -> build/stages/sysctl-limits-env.nix
R  build/rootfs/overlays/sysctl-limits-env.sh -> build/stages/sysctl-limits-env.sh
R  build/rootfs/overlays/systemd-services.nix -> build/stages/systemd-services.nix
R  build/rootfs/overlays/systemd-services.sh -> build/stages/systemd-services.sh
R  build/rootfs/overlays/users.nix -> build/stages/users.nix
R  build/rootfs/overlays/users.sh -> build/stages/users.sh
```

(Exact order may differ; the important thing is every file shows as a rename, `R`, with no unstaged content diff yet.)

- [ ] **Step 5: Commit the pure move**

```bash
git commit -m "Move build/rootfs/overlays to build/stages (pure rename, no content changes)"
```

---

### Task 2: Fix the 10 templated stage files (import path + wording)

Ten stage files share an identical template that references `mkOverlay.nix` via a path that is now one directory level shallower (`build/stages/` instead of `build/rootfs/overlays/`), and mentions "overlay" in prose.

**Files:**
- Modify: `build/stages/sysctl-limits-env.nix`, `build/stages/systemd-services.nix`, `build/stages/debug-ssh-root-login.nix`, `build/stages/misc-os.nix`, `build/stages/users.nix`, `build/stages/ssh.nix`, `build/stages/openstack-agent-settings.nix`, `build/stages/rsyslog.nix`, `build/stages/audit.nix`, `build/stages/sudoers-pam.nix`

- [ ] **Step 1: Run the substitution**

```bash
cd /home/ruben/workspace/bosh-nix-linux-stemcell-builder
sed -i \
  -e 's/overlay: fragment/stage: fragment/' \
  -e 's/apply-overlays\.nix/apply-stages.nix/' \
  -e 's#\.\./\.\./lib/mkOverlay\.nix#../lib/mkStage.nix#' \
  build/stages/sysctl-limits-env.nix \
  build/stages/systemd-services.nix \
  build/stages/debug-ssh-root-login.nix \
  build/stages/misc-os.nix \
  build/stages/users.nix \
  build/stages/ssh.nix \
  build/stages/openstack-agent-settings.nix \
  build/stages/rsyslog.nix \
  build/stages/audit.nix \
  build/stages/sudoers-pam.nix
```

- [ ] **Step 2: Verify one file's full content**

```bash
cat build/stages/ssh.nix
```

Expected output:

```nix
# ssh stage: fragment externalized to ssh.sh (byte-identical to the previous
# inline string). Applied by rootfs/apply-stages.nix inside the shared fakeroot
# session with $root bound and the ambient PATH.
{ }:
import ../lib/mkStage.nix {
  name = "ssh";
  src = ./ssh.sh;
}
```

- [ ] **Step 3: Verify no file still references the old path or mkOverlay**

```bash
grep -rn "mkOverlay\|apply-overlays\.nix\|overlay:" build/stages/*.nix
```

Expected output: (empty — no matches)

- [ ] **Step 4: Commit**

```bash
git add build/stages/sysctl-limits-env.nix build/stages/systemd-services.nix \
  build/stages/debug-ssh-root-login.nix build/stages/misc-os.nix build/stages/users.nix \
  build/stages/ssh.nix build/stages/openstack-agent-settings.nix build/stages/rsyslog.nix \
  build/stages/audit.nix build/stages/sudoers-pam.nix
git commit -m "Fix mkStage import path and wording in templated stage files"
```

---

### Task 3: Fix build/stages/default.nix (pkgs path + wording)

`default.nix` references `build/pkgs/*.nix` two directory levels up from the old location; from the new `build/stages/` location it's only one level up. It also has "overlay" wording in its header comment.

**Files:**
- Modify: `build/stages/default.nix`

- [ ] **Step 1: Read current content to confirm starting point**

```bash
cat build/stages/default.nix
```

Expected (this is the pre-edit content, moved as-is by Task 1):

```nix
# Ordered overlay list applied by rootfs/apply-overlays.nix. Order mirrors the
# upstream ubuntu_os_stages where it matters (users before group-membership
# asserts; ssh after base packages; agent + blobstore CLIs late; the
# IaaS-specific agent-settings last).
#
# Interpolating overlays (agent, blobstore-clis) receive their source-built
# store paths here; the debug-* overlays are intentionally omitted (emergency
# use only — see 2026-07-08 findings).
{ callPackage }:
let
  bosh-agent = callPackage ../../pkgs/bosh-agent.nix { };
  monit = callPackage ../../pkgs/monit.nix { };
  blob = callPackage ../../pkgs/blobstore-clis.nix { };
in
[
  (import ./users.nix { })
  (import ./ssh.nix { })
  (import ./sysctl-limits-env.nix { })
  (import ./sudoers-pam.nix { })
  (import ./rsyslog.nix { })
  (import ./audit.nix { })
  (import ./misc-os.nix { })
  (import ./systemd-services.nix { })
  (import ./agent.nix { inherit bosh-agent monit; })
  (import ./blobstore-clis.nix {
    inherit (blob) davcli s3cli gcscli azureStorageCli;
  })
  (import ./openstack-agent-settings.nix { })
]
```

- [ ] **Step 2: Apply the edit**

Use the Edit tool with:

oldString:
```
# Ordered overlay list applied by rootfs/apply-overlays.nix. Order mirrors the
# upstream ubuntu_os_stages where it matters (users before group-membership
# asserts; ssh after base packages; agent + blobstore CLIs late; the
# IaaS-specific agent-settings last).
#
# Interpolating overlays (agent, blobstore-clis) receive their source-built
# store paths here; the debug-* overlays are intentionally omitted (emergency
# use only — see 2026-07-08 findings).
{ callPackage }:
let
  bosh-agent = callPackage ../../pkgs/bosh-agent.nix { };
  monit = callPackage ../../pkgs/monit.nix { };
  blob = callPackage ../../pkgs/blobstore-clis.nix { };
in
```

newString:
```
# Ordered stage list applied by rootfs/apply-stages.nix. Order mirrors the
# upstream ubuntu_os_stages where it matters (users before group-membership
# asserts; ssh after base packages; agent + blobstore CLIs late; the
# IaaS-specific agent-settings last).
#
# Interpolating stages (agent, blobstore-clis) receive their source-built
# store paths here; the debug-* stages are intentionally omitted (emergency
# use only — see 2026-07-08 findings).
{ callPackage }:
let
  bosh-agent = callPackage ../pkgs/bosh-agent.nix { };
  monit = callPackage ../pkgs/monit.nix { };
  blob = callPackage ../pkgs/blobstore-clis.nix { };
in
```

- [ ] **Step 3: Verify**

```bash
cat build/stages/default.nix
grep -n "\.\./\.\./pkgs\|overlay" build/stages/default.nix
```

Expected: file content matches the newString above followed by the unchanged `[ ... ]` list; the grep produces no matches.

- [ ] **Step 4: Commit**

```bash
git add build/stages/default.nix
git commit -m "Fix build/pkgs import depth and wording in build/stages/default.nix"
```

---

### Task 4: Fix wording in agent.nix and debug-ssh-keys.nix

These two stage files define `{ name; script; }` directly (they don't use `mkStage.nix`), so they need no path fix, only a one-line wording change each.

**Files:**
- Modify: `build/stages/agent.nix:95`
- Modify: `build/stages/debug-ssh-keys.nix:2`

- [ ] **Step 1: Edit agent.nix**

Use the Edit tool on `build/stages/agent.nix` with:

oldString:
```
    # empty agent conf (overwritten by openstack-agent-settings overlay)
```

newString:
```
    # empty agent conf (overwritten by openstack-agent-settings stage)
```

- [ ] **Step 2: Edit debug-ssh-keys.nix**

Use the Edit tool on `build/stages/debug-ssh-keys.nix` with:

oldString:
```
# This overlay is temporary and should be removed from production stemcells.
```

newString:
```
# This stage is temporary and should be removed from production stemcells.
```

- [ ] **Step 3: Verify**

```bash
grep -n "overlay" build/stages/agent.nix build/stages/debug-ssh-keys.nix
```

Expected output: (empty — no matches)

- [ ] **Step 4: Commit**

```bash
git add build/stages/agent.nix build/stages/debug-ssh-keys.nix
git commit -m "Fix overlay wording in agent.nix and debug-ssh-keys.nix comments"
```

---

### Task 5: Rewrite build/lib/mkStage.nix

**Files:**
- Modify: `build/lib/mkStage.nix` (currently still has the pre-move `mkOverlay.nix` content, moved as-is by Task 1)

- [ ] **Step 1: Verify starting content**

```bash
cat build/lib/mkStage.nix
```

Expected:

```nix
# Turn a pure overlay definition into the { name; script; } record that
# rootfs/apply-overlays.nix consumes. `script = builtins.readFile src` is
# byte-identical to the previous inline `script = ''…''` string, so the
# assembled fakeroot buildCommand — and thus the os-image output — is unchanged.
#
# Only pure overlays (no Nix store-path interpolation) use this. Overlays that
# must embed store paths (agent, blobstore-clis, debug-ssh-keys) stay inline and
# return { name; script; } directly.
{ name, src }:
{
  inherit name;
  script = builtins.readFile src;
}
```

- [ ] **Step 2: Apply the edit**

Use the Edit tool with:

oldString:
```
# Turn a pure overlay definition into the { name; script; } record that
# rootfs/apply-overlays.nix consumes. `script = builtins.readFile src` is
# byte-identical to the previous inline `script = ''…''` string, so the
# assembled fakeroot buildCommand — and thus the os-image output — is unchanged.
#
# Only pure overlays (no Nix store-path interpolation) use this. Overlays that
# must embed store paths (agent, blobstore-clis, debug-ssh-keys) stay inline and
# return { name; script; } directly.
```

newString:
```
# Turn a pure stage definition into the { name; script; } record that
# rootfs/apply-stages.nix consumes. `script = builtins.readFile src` is
# byte-identical to the previous inline `script = ''…''` string, so the
# assembled fakeroot buildCommand — and thus the os-image output — is unchanged.
#
# Only pure stages (no Nix store-path interpolation) use this. Stages that
# must embed store paths (agent, blobstore-clis, debug-ssh-keys) stay inline and
# return { name; script; } directly.
```

- [ ] **Step 3: Verify**

```bash
grep -n "overlay" build/lib/mkStage.nix
```

Expected output: (empty — no matches)

- [ ] **Step 4: Commit**

```bash
git add build/lib/mkStage.nix
git commit -m "Rename overlay wording to stage in mkStage.nix"
```

---

### Task 6: Rewrite build/rootfs/apply-stages.nix (identifier rename only, no guard yet)

**Files:**
- Modify: `build/rootfs/apply-stages.nix`

- [ ] **Step 1: Verify starting content**

```bash
cat build/rootfs/apply-stages.nix
```

Expected: the pre-move `apply-overlays.nix` content (still says `overlays`, `ov`, `runOverlays` — Task 1 only renamed the file, not its contents).

- [ ] **Step 2: Replace the whole file**

Use the Write tool to write `build/rootfs/apply-stages.nix` with this exact content:

```nix
# Pure-Nix (no VM, no chroot) rootfs transform that applies MANY stages in a
# SINGLE fakeroot session: extract the base rootfs.tar.gz once, run every stage
# script in order (each in an isolated subshell), then repack once.
#
# This replaces the previous per-stage mk-stage.nix folded 11x, which
# extracted + gzip-recompressed the full ~3 GB rootfs on every stage. Here the
# expensive extract/repack happens exactly once.
#
# Ownership: the Nix store normalizes file ownership, but the BOSH rootfs needs
# real uid/gid 0 (and package-created users). A single continuous `fakeroot`
# session holds that ownership state end-to-end; the final `tar --numeric-owner`
# serializes it so it survives the store boundary (same guarantee mk-stage.nix
# gave, without re-deriving it 11 times). See the auditd/sshd/sudo "not owned by
# root" failure mode this prevents.
#
# Compression: intermediate gzip is not load-bearing (tar -xf auto-detects), so
# the single final repack uses parallel `pigz -1`.
{ stdenv, fakeroot, gnutar, pigz, coreutils, gnused, gawk, gnugrep, findutils }:
{ base, stages }:
let
  runStages = builtins.concatStringsSep "\n" (map (st: ''
    echo "=== stage: ${st.name} ==="
    ( set -euxo pipefail
      ${st.script}
    )
  '') stages);
in
stdenv.mkDerivation {
  name = "os-image";
  nativeBuildInputs = [ fakeroot gnutar pigz coreutils gnused gawk gnugrep findutils ];
  buildCommand = ''
    fakeroot bash -euxo pipefail <<'IN_FAKEROOT'
    root="$PWD/root"
    mkdir -p "$root"
    tar -xzf ${base}/rootfs.tar.gz -C "$root"

    # --- stage scripts run here in order; $root is the rootfs tree ---
    ${runStages}
    # ------------------------------------------------------------------

    # Note: do NOT add a blanket "chmod u+r" here.  fakeroot's chmod only
    # updates the fakeroot metadata database; the real file permissions are
    # never changed.  tar reads files via the real permissions (always
    # accessible) and records the fakeroot-reported modes in the archive,
    # so mode-0000 security files (gshadow, shadow) are correctly packed
    # without any workaround.  A previous "-perm /000 -exec chmod u+r"
    # invocation used the wrong find predicate (-perm /000 with mask 000
    # matches ALL files) and silently reset every file to at least mode 0400,
    # breaking the gshadow/shadow security-mode tests.

    mkdir -p "$out"
    tar --numeric-owner --one-file-system -C "$root" -cf - . | pigz -1 > "$out/rootfs.tar.gz"
    IN_FAKEROOT
  '';
}
```

- [ ] **Step 3: Verify**

```bash
grep -n "overlay" build/rootfs/apply-stages.nix
```

Expected output: (empty — no matches)

- [ ] **Step 4: Commit**

```bash
git add build/rootfs/apply-stages.nix
git commit -m "Rename overlay identifiers to stage in apply-stages.nix"
```

---

### Task 7: Rewrite build/rootfs/os-image.nix

**Files:**
- Modify: `build/rootfs/os-image.nix`

- [ ] **Step 1: Verify starting content**

```bash
cat build/rootfs/os-image.nix
```

Expected:

```nix
# PHASE 1 OS image: fold every config overlay onto the noble rootfs closure.
# The ordered overlay list lives in ./overlays/default.nix.
{ callPackage }:
let
  applyOverlays = callPackage ./apply-overlays.nix { };
  base = callPackage ./rootfs.nix { };
  overlays = callPackage ./overlays/default.nix { };
in
applyOverlays { inherit base overlays; }
```

(This still says `apply-overlays.nix` and `./overlays/default.nix` because Task 1 didn't touch this file's content — only the files it points to.)

- [ ] **Step 2: Replace the whole file**

Use the Write tool to write `build/rootfs/os-image.nix` with this exact content:

```nix
# PHASE 1 OS image: fold every config stage onto the noble rootfs closure.
# The ordered stage list lives in ../stages/default.nix.
{ callPackage }:
let
  applyStages = callPackage ./apply-stages.nix { };
  base = callPackage ./rootfs.nix { };
  stages = callPackage ../stages/default.nix { };
in
applyStages { inherit base stages; }
```

- [ ] **Step 3: Verify**

```bash
grep -n "overlay" build/rootfs/os-image.nix
```

Expected output: (empty — no matches)

- [ ] **Step 4: Commit**

```bash
git add build/rootfs/os-image.nix
git commit -m "Rename overlay identifiers to stage in os-image.nix"
```

---

### Task 8: Update flake.nix treefmt exclude path

**Files:**
- Modify: `flake.nix:26`

- [ ] **Step 1: Apply the edit**

Use the Edit tool on `flake.nix` with:

oldString:
```
        settings.formatter.shfmt.excludes = [ "build/rootfs/overlays/*.sh" ];
```

newString:
```
        settings.formatter.shfmt.excludes = [ "build/stages/*.sh" ];
```

- [ ] **Step 2: Verify**

```bash
grep -n "overlays\|stages" flake.nix
```

Expected output:

```
26:        settings.formatter.shfmt.excludes = [ "build/stages/*.sh" ];
```

- [ ] **Step 3: Commit**

```bash
git add flake.nix
git commit -m "Update treefmt shfmt excludes path for build/stages"
```

---

### Task 9: Checkpoint — verify the rename-only state builds

This is the first real "test" of the mechanical rename: no behavior should have changed yet (no hermetic guard added), so the flake must evaluate and build exactly as before.

- [ ] **Step 1: Flake check**

```bash
cd /home/ruben/workspace/bosh-nix-linux-stemcell-builder
nix flake check
```

Expected: exits 0, no errors.

- [ ] **Step 2: Dry-run the os-image build**

```bash
nix build .#os-image --dry-run -L
```

Expected: exits 0; output lists `os-image` (and its dependencies) as derivations to be built or already built, no eval errors about missing files like `overlays/default.nix` or `apply-overlays.nix`.

- [ ] **Step 3: Confirm no stray "overlay" references remain in build/**

```bash
grep -rIn "overlay" -i build/
```

Expected output: (empty — no matches anywhere under `build/`)

- [ ] **Step 4: Fix anything the checks above surfaced, then re-run Steps 1-3 until clean.**

(No commit for this task — it's a verification checkpoint only.)

---

### Task 10: Create build/lib/hermetic-guard.sh

**Files:**
- Create: `build/lib/hermetic-guard.sh`

- [ ] **Step 1: Write the file**

```sh
# Hermetic guard: prove no network is reachable before any stage or package
# script runs. This does NOT rely on nix.conf's `sandbox = true` alone -- if
# the sandbox is misconfigured (e.g. built with `--option sandbox false`),
# this turns that into a hard, loud build failure instead of a silent leak.
# The only way artifacts should enter this build is via Nix-tracked inputs.
if timeout 3 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null; then
  echo "HERMETIC VIOLATION: network is reachable inside this build." >&2
  echo "Refusing to continue - stemcell artifacts must come only from Nix-tracked inputs." >&2
  exit 1
fi
```

- [ ] **Step 2: Verify the file's standalone syntax**

```bash
bash -n build/lib/hermetic-guard.sh
```

Expected: exits 0, no output (confirms the snippet is syntactically valid bash on its own, since it will later be concatenated into larger scripts).

- [ ] **Step 3: Commit**

```bash
git add build/lib/hermetic-guard.sh
git commit -m "Add hermetic-guard.sh: network-namespace self-check for build hermeticity"
```

---

### Task 11: Wire the hermetic guard into apply-stages.nix

**Files:**
- Modify: `build/rootfs/apply-stages.nix`

- [ ] **Step 1: Apply the edit**

Use the Edit tool on `build/rootfs/apply-stages.nix` with:

oldString:
```
  buildCommand = ''
    fakeroot bash -euxo pipefail <<'IN_FAKEROOT'
    root="$PWD/root"
    mkdir -p "$root"
    tar -xzf ${base}/rootfs.tar.gz -C "$root"
```

newString:
```
  buildCommand = ''
    fakeroot bash -euxo pipefail <<'IN_FAKEROOT'
    ${builtins.readFile ../lib/hermetic-guard.sh}

    root="$PWD/root"
    mkdir -p "$root"
    tar -xzf ${base}/rootfs.tar.gz -C "$root"
```

- [ ] **Step 2: Verify**

```bash
grep -n "hermetic-guard" build/rootfs/apply-stages.nix
```

Expected output:

```
34:    ${builtins.readFile ../lib/hermetic-guard.sh}
```

(Line number may differ slightly.)

- [ ] **Step 3: Commit**

```bash
git add build/rootfs/apply-stages.nix
git commit -m "Wire hermetic guard into apply-stages.nix before stage scripts run"
```

---

### Task 12: Wire the hermetic guard into tarball.nix's createRootFS

**Files:**
- Modify: `build/rootfs/tarball.nix`

- [ ] **Step 1: Verify starting content**

```bash
cat build/rootfs/tarball.nix
```

Expected (unchanged by any prior task):

```nix
# Emits the deb closure as a rootfs TARBALL ($out/rootfs.tar.gz), not a disk image.
# Reuses the usrmerge-safe fillDiskWithDebs VM (poc/lib/fill-disk-usrmerge.nix); the only
# difference is the tail: after dpkg install + postInstall, unmount the bind mounts and
# `tar` /mnt into $out instead of keeping the ext4 disk. No grub, no partitions.
{ callPackage, lib, util-linux, e2fsprogs, gnutar, gzip, bash }:
let
  inherit (callPackage ./fill-disk-usrmerge.nix { }) makeImageFromDebDist;
in
{ aptPins, packages, size ? 16384, seedStartStopDaemon ? true }:
makeImageFromDebDist {
  inherit (aptPins) name fullName urlPrefix packagesLists;
  inherit packages size;

  # Since we override createRootFS, we must include the full setup (mirror the default but
  # with the seed for start-stop-daemon at /usr/sbin, which is in a usrmerged location).
  createRootFS = ''
    mkdir /mnt
    ${e2fsprogs}/bin/mkfs.ext4 /dev/vda
    ${util-linux}/bin/mount -t ext4 /dev/vda /mnt

    if test -e /mnt/.debug; then
      exec ${bash}/bin/sh
    fi
    touch /mnt/.debug

    mkdir /mnt/proc /mnt/dev /mnt/sys
  '' + lib.optionalString seedStartStopDaemon ''
    mkdir -p /mnt/usr/sbin
    printf '#!/bin/true\n' > /mnt/usr/sbin/start-stop-daemon
    chmod 755 /mnt/usr/sbin/start-stop-daemon
  '';

  # postInstall runs before fillDiskWithDebs unmounts the bind mounts.
  # We just tar the rootfs; the bind mounts (inst, proc, dev) will be unmounted
  # by fillDiskWithDebs after we return.
  postInstall = ''
    mkdir -p $out
    ${gnutar}/bin/tar --numeric-owner --one-file-system \
      -C /mnt -cf - . | ${gzip}/bin/gzip -1 > $out/rootfs.tar.gz
  '';
}
```

- [ ] **Step 2: Apply the edit**

Use the Edit tool with:

oldString:
```
  # Since we override createRootFS, we must include the full setup (mirror the default but
  # with the seed for start-stop-daemon at /usr/sbin, which is in a usrmerged location).
  createRootFS = ''
    mkdir /mnt
```

newString:
```
  # Since we override createRootFS, we must include the full setup (mirror the default but
  # with the seed for start-stop-daemon at /usr/sbin, which is in a usrmerged location).
  #
  # The hermetic guard runs FIRST, before mkfs/dpkg-install, so this VM-based
  # deb-install step self-verifies the same "no network reachable" guarantee
  # as apply-stages.nix, rather than depending solely on ambient nix.conf
  # sandbox settings.
  createRootFS = ''
    ${builtins.readFile ../lib/hermetic-guard.sh}

    mkdir /mnt
```

- [ ] **Step 3: Verify**

```bash
grep -n "hermetic-guard" build/rootfs/tarball.nix
```

Expected output:

```
16:    ${builtins.readFile ../lib/hermetic-guard.sh}
```

(Line number may differ slightly.)

- [ ] **Step 4: Commit**

```bash
git add build/rootfs/tarball.nix
git commit -m "Wire hermetic guard into tarball.nix's createRootFS before dpkg-install"
```

---

### Task 13: Verify a full build still succeeds and is byte-identical

This proves the hermetic guard doesn't break the build or its determinism under normal (sandboxed) conditions.

- [ ] **Step 1: Build os-image**

```bash
cd /home/ruben/workspace/bosh-nix-linux-stemcell-builder
nix build .#os-image --no-link -L
```

Expected: exits 0. Build log shows no "HERMETIC VIOLATION" message (the guard passes silently when there's genuinely no network).

- [ ] **Step 2: Run the L1 reproducibility gate**

```bash
bash scripts/byte-check-osimage.sh
```

Expected: prints `REPRODUCIBLE: os-image (rootfs.tar.gz) is byte-identical` (or equivalent success message) and exits 0.

- [ ] **Step 3: Build the full stemcell**

```bash
nix build .#noble-stemcell --no-link -L
```

Expected: exits 0.

- [ ] **Step 4: If any step fails, diagnose before proceeding**

If Step 1 fails with "command not found: timeout" or "command not found: bash" inside the VM build, this means the guest VM environment (used by `tarball.nix`'s `createRootFS`) doesn't have `coreutils`/`bash` on `PATH` at that point. Fix by adding `coreutils` to `build/rootfs/tarball.nix`'s function arguments (`{ callPackage, lib, util-linux, e2fsprogs, gnutar, gzip, bash, coreutils }:`) and changing the guard invocation in `createRootFS` to use `${coreutils}/bin/timeout` and `${bash}/bin/bash` explicitly instead of bare `timeout`/`bash`. Re-run Steps 1-3 after any fix.

(No commit for this task — it's a verification checkpoint only, unless Step 4's fix was needed, in which case commit that fix with message "Fix hermetic guard tool paths for VM build environment".)

---

### Task 14: Smoke-test that the guard actually fires

This proves the guard is load-bearing — not dead code that always silently passes.

- [ ] **Step 1: Attempt to build with sandboxing disabled**

```bash
cd /home/ruben/workspace/bosh-nix-linux-stemcell-builder
nix build .#os-image --no-link -L --option sandbox false
```

Expected ONE of:
- The build now **fails**, and the log contains `HERMETIC VIOLATION: network is reachable inside this build.` — this is the desired outcome, proving the guard is load-bearing.
- The command errors with a permissions message (e.g. "you are not privileged to set sandbox setting") — this means the current user isn't a `trusted-user` in the Nix daemon config. In this case, proceed to Step 2 instead.

- [ ] **Step 2 (fallback, only if Step 1 was rejected for permissions): standalone smoke test**

```bash
mkdir -p /tmp/opencode/hermetic-guard-smoke-test
cat > /tmp/opencode/hermetic-guard-smoke-test/test.nix <<'EOF'
derivation {
  name = "hermetic-guard-smoke-test";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = [ "-c" ''
    set -e
    if timeout 3 bash -c "exec 3<>/dev/tcp/1.1.1.1/443" 2>/dev/null; then
      echo "HERMETIC VIOLATION: network is reachable inside this build." >&2
      exit 1
    fi
    echo ok > $out
  '' ];
}
EOF
nix-build /tmp/opencode/hermetic-guard-smoke-test/test.nix --no-out-link --option sandbox false
```

Expected: this build **fails** with `HERMETIC VIOLATION: network is reachable inside this build.` printed to the log — proving the guard's underlying logic correctly detects network access when the sandbox is off. Note this doesn't require `trusted-user` for a throwaway derivation outside the flake (depending on daemon config); if it's still rejected, document in the task's outcome that the guard's load-bearing nature was verified by code inspection and the earlier empirical sandbox-network test from the design phase, rather than a live rebuild.

- [ ] **Step 3: Record the outcome**

No file changes in this task — it's a verification-only step. Note the result (which of Step 1 / Step 2 / the inspection fallback applied) when reporting task completion.

---

### Task 15: Update README.md

**Files:**
- Modify: `README.md:59-60`

- [ ] **Step 1: Verify starting content**

```bash
grep -n "overlay" -i README.md
```

Expected output:

```
59:| `build/lib/` | Build library: distro/source pinning (`noble-source.nix`, `noble-distro.nix`), package sets (`base-`, `boot-`, `essential-`, `image-`, `noble-packages.nix`), and the assembly helpers (`mk-rootfs-tarball.nix`, `mk-bootable-disk.nix`, `mk-stemcell.nix`, `mk-apply-overlays.nix`). |
60:| `build/lib/overlays/` | Post-unpack filesystem overlays that reproduce the upstream shell stages (ssh, sudoers/pam, audit, rsyslog, sysctl, systemd services, users, agent, OpenStack agent settings, blobstore CLIs). |
```

- [ ] **Step 2: Apply the edit**

Use the Edit tool on `README.md` with:

oldString:
```
| `build/lib/` | Build library: distro/source pinning (`noble-source.nix`, `noble-distro.nix`), package sets (`base-`, `boot-`, `essential-`, `image-`, `noble-packages.nix`), and the assembly helpers (`mk-rootfs-tarball.nix`, `mk-bootable-disk.nix`, `mk-stemcell.nix`, `mk-apply-overlays.nix`). |
| `build/lib/overlays/` | Post-unpack filesystem overlays that reproduce the upstream shell stages (ssh, sudoers/pam, audit, rsyslog, sysctl, systemd services, users, agent, OpenStack agent settings, blobstore CLIs). |
```

newString:
```
| `build/lib/` | Build library: distro/source pinning (`noble-source.nix`, `noble-distro.nix`), package sets (`base-`, `boot-`, `essential-`, `image-`, `noble-packages.nix`), and the assembly helpers (`mk-rootfs-tarball.nix`, `mk-bootable-disk.nix`, `mk-stemcell.nix`, `mk-apply-stages.nix`). |
| `build/stages/` | Post-unpack filesystem stages (ssh, sudoers/pam, audit, rsyslog, sysctl, systemd services, users, agent, OpenStack agent settings, blobstore CLIs) mirroring the upstream shell stage names. |
```

Note: the `build/lib/` row's other filenames (`noble-source.nix`, `mk-rootfs-tarball.nix`, etc.) were already inaccurate/stale before this change (per the prior `move-nix-sources-into-build-dir` design's documented precedent) — leave them as-is; only the "overlay" wording is in scope here.

- [ ] **Step 3: Verify**

```bash
grep -n "overlay" -i README.md
```

Expected output: (empty — no matches)

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "Update README.md for overlays-to-stages rename"
```

---

### Task 16: Bulk word-substitution in docs/ARCHITECTURE.md

**Files:**
- Modify: `docs/ARCHITECTURE.md`

- [ ] **Step 1: Run the ordered substitution**

```bash
cd /home/ruben/workspace/bosh-nix-linux-stemcell-builder
sed -i \
  -e 's#build/rootfs/overlays#build/stages#g' \
  -e 's/overlay/stage/g' \
  -e 's/Overlay/Stage/g' \
  docs/ARCHITECTURE.md
```

(Order matters: the path-prefix substitution runs first, while the literal text `build/rootfs/overlays` still exists; it collapses the `rootfs/` segment. The two generic word substitutions then run second, catching every remaining "overlay"/"Overlay" occurrence — including turning `apply-overlays.nix` into `apply-stages.nix` and `mkOverlay.nix` into `mkStage.nix` as a side effect, since "overlay"/"Overlay" is a substring of both.)

- [ ] **Step 2: Verify no stray lowercase/capitalized "overlay" remains**

```bash
grep -n -i "overlay" docs/ARCHITECTURE.md
```

Expected output: (empty — no matches)

- [ ] **Step 3: Spot-check a few transformed lines**

```bash
grep -n "apply-stages\.nix\|mkStage\.nix\|Configuration Stages\|build/stages/ssh\.nix" docs/ARCHITECTURE.md
```

Expected: several matches, e.g. `## Configuration Stages`, `[\`build/stages/ssh.nix\`](../build/stages/ssh.nix)`, `[\`build/rootfs/apply-stages.nix\`](../build/rootfs/apply-stages.nix)`.

- [ ] **Step 4: Commit**

```bash
git add docs/ARCHITECTURE.md
git commit -m "Bulk-rename overlay wording to stage in ARCHITECTURE.md"
```

---

### Task 17: Fix the ARCHITECTURE.md tree-diagram structure

The bulk sed in Task 16 fixed wording everywhere, but the ASCII file tree under "Files & Organization" has no literal `build/rootfs/overlays` path string per line (paths are implied by indentation), so the sed's path-prefix rule didn't touch it — it only renamed the word "overlay" to "stage" in place, leaving `stages/` still nested under `rootfs/` in the diagram. This task fixes the nesting to show `stages/` as a sibling of `rootfs/`.

**Files:**
- Modify: `docs/ARCHITECTURE.md` (the "Files & Organization" tree block)

- [ ] **Step 1: Verify the current (post-Task-16) state of this block**

```bash
sed -n '589,625p' docs/ARCHITECTURE.md
```

Expected:

```
├── build/
│   ├── ubuntu/
│   │   ├── apt-pins.nix               # APT coordinates (snapshot URL + index hashes)
│   │   ├── deb-sets.nix               # Package lists (bootEssentials, bosh, image)
│   │   └── essential.nix              # Essential package seed (pure-Nix parsing)
│   ├── rootfs/
│   │   ├── os-image.nix               # Entry point (base + stages) → L1 output
│   │   ├── rootfs.nix                 # Tarball builder (calls tarball.nix)
│   │   ├── tarball.nix                # Deterministic tar + gzip → rootfs.tar.gz
│   │   ├── fill-disk-usrmerge.nix     # In-VM dpkg extraction (usrmerge-safe fork)
│   │   ├── apply-stages.nix         # Stage application (single fakeroot session)
│   │   └── stages/
│   │       ├── default.nix            # Stage orchestration
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
│   └── lib/
│       ├── mkVmImage.nix              # VM image creation utilities
│       └── mkStage.nix                # Stage composition utilities
├── scripts/
```

(If the exact spacing differs slightly from sed's substitution, adjust the oldString in Step 2 to match what Step 1 actually printed.)

- [ ] **Step 2: Apply the restructuring edit**

Use the Edit tool on `docs/ARCHITECTURE.md` with:

oldString:
```
│   ├── rootfs/
│   │   ├── os-image.nix               # Entry point (base + stages) → L1 output
│   │   ├── rootfs.nix                 # Tarball builder (calls tarball.nix)
│   │   ├── tarball.nix                # Deterministic tar + gzip → rootfs.tar.gz
│   │   ├── fill-disk-usrmerge.nix     # In-VM dpkg extraction (usrmerge-safe fork)
│   │   ├── apply-stages.nix         # Stage application (single fakeroot session)
│   │   └── stages/
│   │       ├── default.nix            # Stage orchestration
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
```

newString:
```
│   ├── rootfs/
│   │   ├── os-image.nix               # Entry point (base + stages) → L1 output
│   │   ├── rootfs.nix                 # Tarball builder (calls tarball.nix)
│   │   ├── tarball.nix                # Deterministic tar + gzip → rootfs.tar.gz
│   │   ├── fill-disk-usrmerge.nix     # In-VM dpkg extraction (usrmerge-safe fork)
│   │   └── apply-stages.nix           # Stage application (single fakeroot session)
│   ├── stages/
│   │   ├── default.nix                # Stage orchestration
│   │   ├── ssh.nix                    # SSH key generation and config
│   │   ├── sudoers-pam.sh             # Sudoers and PAM setup
│   │   ├── audit.sh                   # Audit daemon configuration
│   │   ├── systemd-services.nix       # Systemd unit definitions
│   │   ├── sysctl-limits-env.nix      # Kernel parameters and limits
│   │   ├── misc-os.sh                 # Packages.txt, SBOM, locale, network
│   │   ├── openstack-agent-settings.nix  # OpenStack cloud-init
│   │   ├── users.nix                  # User account creation
│   │   ├── debug-ssh-root-login.nix   # Debug SSH access
│   │   └── blobstore-clis.nix         # Blobstore tools (S3, Azure, etc.)
│   ├── stemcells/
```

- [ ] **Step 3: Add the new hermetic-guard.sh entry under lib/**

Use the Edit tool on `docs/ARCHITECTURE.md` with:

oldString:
```
│   └── lib/
│       ├── mkVmImage.nix              # VM image creation utilities
│       └── mkStage.nix                # Stage composition utilities
```

newString:
```
│   └── lib/
│       ├── mkVmImage.nix              # VM image creation utilities
│       ├── mkStage.nix                # Stage composition utilities
│       └── hermetic-guard.sh          # Network-namespace probe: fails the build if network is reachable
```

- [ ] **Step 4: Verify**

```bash
sed -n '589,627p' docs/ARCHITECTURE.md
```

Expected: `stages/` now appears as a direct child of `build/` (same indentation level as `rootfs/`, `stemcells/`, `pkgs/`, `lib/`), and `lib/` lists three files including `hermetic-guard.sh`.

- [ ] **Step 5: Commit**

```bash
git add docs/ARCHITECTURE.md
git commit -m "Fix ARCHITECTURE.md tree diagram: stages/ as sibling of rootfs/, add hermetic-guard.sh"
```

---

### Task 18: Final full verification

- [ ] **Step 1: Repo-wide check for stray "overlay" references**

```bash
cd /home/ruben/workspace/bosh-nix-linux-stemcell-builder
grep -rIn "overlay" -i . \
  --include="*.nix" --include="*.sh" --include="*.md" \
  | grep -v "^\./docs/specs/\|^\./docs/plans/\|^\./docs/superpowers/specs/\|^\./docs/superpowers/plans/"
```

Expected output: (empty — no matches outside the historical dated docs, which are intentionally left untouched)

- [ ] **Step 2: nix flake check**

```bash
nix flake check
```

Expected: exits 0.

- [ ] **Step 3: Full builds**

```bash
nix build .#os-image -L --no-link
nix build .#noble-stemcell -L --no-link
```

Expected: both exit 0.

- [ ] **Step 4: Reproducibility gates**

```bash
bash scripts/byte-check-osimage.sh
bash scripts/byte-check-stemcell.sh
```

Expected: both report byte-identical / reproducible, exit 0.

- [ ] **Step 5: Confirm git history is clean**

```bash
git status --short
git log --oneline -20
```

Expected: working tree clean; the log shows the sequence of commits made across Tasks 1-17.
