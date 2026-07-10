# Nix-Native Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the standalone `bosh-nix-linux-stemcell-builder` repo to read as Nix-native code (externalized/lintable shell, a directory layout that narrates the two-phase build, denser `.nix` files, explicit flake outputs, `treefmt`) **without changing any build output**.

**Architecture:** Two build-phase dirs — `rootfs/` (phase 1 OS image) and `stemcells/` (phase 2 per-IaaS) — plus `ubuntu/` (deb selection) and `pkgs/` (source-built components). Overlay shell fragments are externalized to `.sh` via `builtins.readFile`, which is byte-for-byte equivalent to today's inline `''…''` strings. The primary regression guard is a **byte-identical `os-image` `rootfs.tar.gz`** before/after every rootfs-touching change.

**Tech Stack:** Nix (flakes, flake-parts, nixpkgs `nixos-26.05`), `vmTools.runInLinuxVM`, bash, treefmt (nixfmt + shfmt + shellcheck).

**Design reference:** `docs/specs/2026-07-10-nix-native-refactor-design.md` (approved).

---

## Conventions used by every byte-check

The local `git+file`/flake fetcher is broken on this virtiofs mount (libgit2 mmap:
`resolving HEAD: failed to mmap`). All builds therefore go through the `path:`
fetcher on a `.git`-free copy. The helper `scripts/byte-check-osimage.sh` (built in
Task 0.1) encapsulates this. It prints the `sha256` of `os-image`'s `rootfs.tar.gz`.

**Rule:** any task that edits code feeding the `os-image` derivation ends with a
byte-check step asserting the sha equals the Task 0.2 baseline. A mismatch halts the
task for root-cause (superpowers:systematic-debugging) — do not proceed.

---

## Deviations from the design doc (read before starting)

1. **Heredoc payloads stay inside each overlay's `.sh`.** The design (§4) suggested
   moving heredoc bodies (securetty, banners, sshd lines, …) into `overlays/assets/`.
   We instead externalize the **whole** overlay fragment — heredocs included —
   verbatim into one `.sh` via `nix eval --raw`. This is provably byte-identical
   (see Task 1.2) and avoids the byte-risk of splitting heredocs. `assets/`
   extraction is deferred (YAGNI; marginal readability gain, real byte risk).
2. **Interpolating overlays are left inline.** `agent.nix`, `blobstore-clis.nix`,
   and `debug-ssh-keys.nix` embed Nix store paths (`${bosh-agent}`, `${davcli}`,
   `${sshPubKey}`). They already return `{ name; script; }` and are NOT externalized
   (that would hardcode store paths or require `replaceVars`+IFD). They keep working
   unchanged; `mkOverlay` is used only by the 10 pure overlays. This is the
   "smallest change that preserves bytes" rule (design §5).
3. **`mkOverlay` takes no `deps`.** The design sketched `deps` to inform PATH. The
   `apply-overlays.nix` driver already supplies the ambient PATH
   (coreutils/gnused/gawk/gnugrep/findutils) to every fragment; adding per-overlay
   PATH would change executed commands and risk the byte guarantee. `mkOverlay` is
   `{ name, src }: { name; script = readFile src; }`.

---

## File Structure (target)

```
flake.nix                         # explicit outputs + treefmt formatter/check
lib/
  mkOverlay.nix                   # NEW  { name; src } -> { name; script }
  mkVmImage.nix                   # NEW  runInLinuxVM + createEmptyImage wrapper (phase 4)
ubuntu/                           # deb selection
  apt-pins.nix                    # was noble-source.nix + noble-distro.nix
  deb-sets.nix                    # was base/boot/noble/image-packages.nix
  essential.nix                   # was essential-packages.nix
pkgs/                             # source-built components
  bosh-agent.nix
  monit.nix  monit-5.2.5.tar.gz
  blobstore-clis.nix              # was mk-blobstore-cli.nix + 4 wrappers
rootfs/                           # PHASE 1
  fill-disk-usrmerge.nix          # moved from lib/
  tarball.nix                     # was mk-rootfs-tarball.nix
  rootfs.nix                      # base tarball target (was examples/noble-rootfs.nix)
  apply-overlays.nix              # was mk-apply-overlays.nix
  os-image.nix                    # was examples/os-image.nix
  overlays/
    <name>.nix / <name>.sh        # 10 pure overlays externalized
    agent.nix blobstore-clis.nix  # interpolating (inline, unchanged)
    debug-ssh-keys.nix debug-ssh-root-login.nix
    default.nix                   # ordered overlay list (was inline in os-image)
stemcells/                        # PHASE 2
  bootable-disk.nix               # was lib/mk-bootable-disk.nix (builder)
  bootable-disk.sh                # externalized VM buildCommand (phase 4)
  package.nix                     # was lib/mk-stemcell.nix (builder)
  openstack-kvm-disk.nix          # was examples/noble-stemcell-disk.nix
  openstack-kvm.nix               # was examples/noble-stemcell.nix
examples/
  noble-bootable.nix noble-closure.nix hello-vm.nix
scripts/
  byte-check-osimage.sh           # NEW
```

Preserved flake output names: `os-image`, `noble-rootfs`, `noble-stemcell-disk`,
`noble-stemcell`, `noble-bootable`, `noble-closure`, `hello-vm`, `bosh-agent`,
`monit`, `bosh-davcli`, `bosh-s3cli`, `bosh-gcscli`, `bosh-azure-storage-cli`. New
alias: `openstack-kvm` (= `noble-stemcell`).

---

## Phase 0 — Baseline & tooling

### Task 0.1: Byte-check helper script

**Files:**
- Create: `scripts/byte-check-osimage.sh`

- [ ] **Step 1: Write the helper**

```bash
#!/usr/bin/env bash
# Build the `os-image` (or given) target through the `path:` fetcher on a
# .git-free copy (the local git+file fetcher is broken on this virtiofs mount)
# and print the sha256 of its rootfs.tar.gz. Used as the byte-identity guard.
set -euo pipefail

target="${1:-os-image}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

scratch="$(mktemp -d /tmp/opencode/byte-check.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT

cp -a "$repo_root/." "$scratch/src"
rm -rf "$scratch/src/.git"

out="$(nix build --no-link --print-out-paths "path:$scratch/src#$target")"
sha256sum "$out/rootfs.tar.gz"
```

- [ ] **Step 2: Make it executable and sanity-check syntax**

Run: `chmod +x scripts/byte-check-osimage.sh && bash -n scripts/byte-check-osimage.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/byte-check-osimage.sh
git commit -m "chore: add os-image byte-identity check helper"
```

### Task 0.2: Capture the baseline hash

**Files:** none (records a value used by every later byte-check).

- [ ] **Step 1: Build baseline and record the hash**

Run: `./scripts/byte-check-osimage.sh os-image | tee /tmp/opencode/osimage-baseline.sha256`
Expected: one line `＜sha256＞  /nix/store/…-os-image/rootfs.tar.gz`. This is the
**baseline**. Every later byte-check must reproduce this exact sha256. Keep
`/tmp/opencode/osimage-baseline.sha256` for the session.

- [ ] **Step 2: Confirm the other targets still build (smoke, once)**

Run: `nix build --no-link path:"$(mktemp -d)"#noble-stemcell 2>/dev/null || echo "run via helper pattern"`
Expected: not required to pass here; the authoritative full-build check is Task 6.3.
(If you want it now, copy the `.git`-free-scratch pattern from the helper.)

---

## Phase 1 — Externalize the 10 pure overlays

The 10 pure overlays contain no Nix interpolation, so their fragment is a fixed
string. Extracting that string with `nix eval --raw` writes exactly the bytes the
current `''…''` produces (Nix indented-string dedent applied), and `mkOverlay`'s
`builtins.readFile` reads them back identically → identical `apply-overlays`
`buildCommand` → identical derivation → identical output.

Pure overlays: `users ssh sysctl-limits-env sudoers-pam rsyslog audit misc-os
systemd-services openstack-agent-settings debug-ssh-root-login`.

### Task 1.1: Add `lib/mkOverlay.nix`

**Files:**
- Create: `lib/mkOverlay.nix`

- [ ] **Step 1: Write mkOverlay**

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

- [ ] **Step 2: Eval-check it in isolation**

Run: `nix eval --raw --expr 'import ./lib/mkOverlay.nix { name = "t"; src = ./flake.nix; }' --apply 'x: x.name'`
Expected: prints `t`.

- [ ] **Step 3: Commit**

```bash
git add lib/mkOverlay.nix
git commit -m "feat: add mkOverlay helper for externalized overlay fragments"
```

### Task 1.2: Externalize each pure overlay (repeat for all 10)

Do this **one overlay at a time**, byte-checking after each. The steps below use
`ssh` as the worked example; repeat verbatim substituting each name from the list
above.

**Files (per overlay `<name>`):**
- Create: `lib/overlays/<name>.sh`
- Modify: `lib/overlays/<name>.nix`

- [ ] **Step 1: Extract the exact fragment bytes to `.sh`**

Run: `nix eval --raw --file lib/overlays/ssh.nix --apply 'f: (f {}).script' > lib/overlays/ssh.sh`
Expected: `lib/overlays/ssh.sh` created; `test -s lib/overlays/ssh.sh` is true.

- [ ] **Step 2: Rewrite the `.nix` to read the `.sh`**

Replace the entire contents of `lib/overlays/ssh.nix` with:

```nix
# ssh overlay: fragment externalized to ssh.sh (byte-identical to the previous
# inline string). Applied by rootfs/apply-overlays.nix inside the shared fakeroot
# session with $root bound and the ambient PATH.
{ }:
import ../mkOverlay.nix {
  name = "ssh";
  src = ./ssh.sh;
}
```

(Substitute `ssh` → `<name>` for the other nine. Preserve each overlay's leading
comment lines above the `{ }:` if you prefer — they do not affect the value.)

- [ ] **Step 3: Verify the string round-trips identically**

Run: `diff <(nix eval --raw --file lib/overlays/ssh.nix --apply 'f: (f {}).script') lib/overlays/ssh.sh && echo IDENTICAL`
Expected: `IDENTICAL` (the `.nix` now yields exactly the `.sh` bytes).

- [ ] **Step 4: Byte-check os-image**

Run: `./scripts/byte-check-osimage.sh os-image`
Expected: sha256 equals the Task 0.2 baseline. If it differs, STOP and debug
(most likely an over-eager text editor touched the `.sh`; re-run Step 1 to
regenerate from the last-known-good `.nix` in git).

- [ ] **Step 5: Commit**

```bash
git add lib/overlays/ssh.nix lib/overlays/ssh.sh
git commit -m "refactor: externalize ssh overlay fragment to ssh.sh"
```

- [ ] **Step 6: Repeat Steps 1–5** for: `users sysctl-limits-env sudoers-pam rsyslog
  audit misc-os systemd-services openstack-agent-settings debug-ssh-root-login`.

> Note: `debug-ssh-root-login` is not in the active overlay list, so its Step 4
> byte-check is covered trivially (os-image unaffected); still run Step 3 to confirm
> the round-trip.

---

## Phase 2 — Restructure directories, collapse thin files, explicit flake outputs

This phase is a large set of `git mv`s + path fixups + three file collapses + a
flake rewrite, landing as **one commit** with a single final byte-check (all the
edits are pure path/wiring changes that preserve the derivation).

### Task 2.1: Collapse `ubuntu/` deb-selection files

**Files:**
- Create: `ubuntu/apt-pins.nix`, `ubuntu/deb-sets.nix`, `ubuntu/essential.nix`
- Delete (after): `lib/noble-source.nix`, `lib/noble-distro.nix`,
  `lib/base-packages.nix`, `lib/boot-packages.nix`, `lib/noble-packages.nix`,
  `lib/image-packages.nix`, `lib/essential-packages.nix`

- [ ] **Step 1: Write `ubuntu/apt-pins.nix`** (folds noble-source + noble-distro; drops the unused `basePackages` alias — `base` now lives in deb-sets)

```nix
# Pinned Ubuntu Noble APT coordinates + Packages.xz indices for
# makeImageFromDebDist. Folds the former noble-source.nix and noble-distro.nix.
#
# snapshot.ubuntu.com was unreachable (503) at build time, so we pin the live
# archive (accepted by the Serverspec oracle). Trade-off: NOT point-in-time
# reproducible — the index hashes float with the live archive.
{ fetchurl }:
let
  urlPrefix = "http://archive.ubuntu.com/ubuntu";
  codename = "noble";
  indexUrl = component:
    "${urlPrefix}/dists/${codename}/${component}/binary-amd64/Packages.xz";
  fetchIndex = component: sha256:
    fetchurl { url = indexUrl component; inherit sha256; };
in
{
  name = "ubuntu-24.04-noble-amd64";
  fullName = "Ubuntu 24.04 Noble (amd64)";
  inherit urlPrefix;

  # main/universe/multiverse indices (order matters: essential.nix scans head=main).
  packagesLists = [
    (fetchIndex "main" "0l94v46rh8q3m8maim1xq2qkagwrjkalcrilrdww599i22g1jsia")
    (fetchIndex "universe" "16jr0mj275yzaii4khfh07hryf451k80hs6jl748qhwi3gx5g45s")
    (fetchIndex "multiverse" "1sjh2wzbwvrxz098l6625igxb0lcdpkm4v9azhmvfjl6w07ld040")
  ];
}
```

- [ ] **Step 2: Write `ubuntu/essential.nix`** (was essential-packages.nix; param `noble` → `aptPins`)

```nix
# Debootstrap-faithful base seed: every Priority:required and Essential:yes
# package in the distro's `main` Packages index. debClosureGenerator only
# resolves Depends: closures, so essentials with no reverse-dep (e.g. hostname)
# must be seeded explicitly, exactly as debootstrap does.
#
#   1. decompress the sha256-pinned Packages.xz (main) — the one xz step;
#   2. a PURE Nix parse selects Priority:required / Essential:yes stanzas.
# Deterministic function of the pinned index (readFile = IFD, like
# debClosureGenerator itself).
{ lib, runCommand, xz, aptPins }:

let
  mainIndex = builtins.head aptPins.packagesLists;

  indexText = runCommand "noble-main-packages-index" { } ''
    ${xz}/bin/xz -dc ${mainIndex} > $out
  '';

  raw = builtins.readFile indexText;
  stanzas = lib.splitString "\n\n" raw;

  isSeed = s:
    let s' = "\n" + s;
    in lib.hasInfix "\nPriority: required" s'
       || lib.hasInfix "\nEssential: yes" s';

  nameOf = s:
    let
      pkgLines = lib.filter (lib.hasPrefix "Package: ") (lib.splitString "\n" s);
    in
      if pkgLines == [ ] then null
      else lib.removePrefix "Package: " (lib.head pkgLines);

  names = lib.filter (n: n != null) (map nameOf (lib.filter isSeed stanzas));
in
lib.sort (a: b: a < b) (lib.unique names)
```

- [ ] **Step 3: Write `ubuntu/deb-sets.nix`** (folds base + boot + noble + image-packages)

```nix
# Ubuntu Noble deb selection. Pure-data package lists (base/boot/bosh) plus the
# assembled top-level `image` set. Folds base-packages.nix, boot-packages.nix,
# noble-packages.nix, and image-packages.nix.
{ lib, callPackage }:

let
  aptPins = callPackage ./apt-pins.nix { };
  essential = callPackage ./essential.nix { inherit aptPins; };

  # Generic Debian/Ubuntu build base (was base-packages.nix; transcribed from
  # nixpkgs commonDebPackages + debDistros.ubuntu2204x86_64's two extras).
  base = [
    "base-passwd" "dpkg" "libc6-dev" "perl" "bash" "dash" "gzip" "bzip2" "tar"
    "grep" "mawk" "sed" "findutils" "g++" "make" "curl" "patch" "locales"
    "coreutils"
    # Needed by checkinstall:
    "util-linux" "file" "dpkg-dev" "pkg-config"
    # /etc/login.defs (passwd post-install):
    "login" "passwd"
    # debDistros.ubuntu2204x86_64 extras:
    "diffutils" "libc-bin"
  ];

  # Build-only tooling to drop from `base` for a bootable image (was boot-packages).
  dropFromBase = [ "g++" "make" "dpkg-dev" "pkg-config" ];

  # Minimal boot + runtime essentials (was boot-packages.nix).
  bootEssentials = [
    "systemd" "init-system-helpers" "systemd-sysv" "linux-image-generic"
    "initramfs-tools" "e2fsprogs" "grub-efi" "grub-pc-bin" "apt"
    "ncurses-base" "dbus"
  ];

  # Authoritative BOSH package set for ubuntu-noble (was noble-packages.nix).
  bosh = [
    "libssl-dev" "lsof" "strace" "bind9-host" "dnsutils" "tcpdump" "iputils-arping"
    "curl" "wget" "bison" "libreadline6-dev" "rng-tools"
    "libxml2" "libxml2-dev" "libxslt1.1" "libxslt1-dev" "zip" "unzip"
    "flex" "psmisc" "apparmor-utils" "iptables" "nftables" "sysstat"
    "rsync" "openssh-server" "traceroute" "libncurses5-dev" "quota"
    "libaio1t64" "gdb" "libcap2-bin" "libcap2-dev" "libbz2-dev"
    "cmake" "uuid-dev" "libgcrypt-dev" "ca-certificates"
    "mg" "htop" "module-assistant" "debhelper" "runit" "parted"
    "cloud-guest-utils" "anacron" "software-properties-common"
    "xfsprogs" "gdisk" "chrony" "dbus" "nvme-cli" "fdisk"
    "ethtool" "libpam-pwquality" "gpg-agent" "libcurl4" "libcurl4-openssl-dev"
    "resolvconf" "net-tools" "ifupdown"
    "rsyslog" "rsyslog-gnutls" "rsyslog-openssl" "rsyslog-relp"
    "auditd" "sudo"
    "cron"
    "systemd-timesyncd"
    "grub2"
    "zlib1g-dev"
    "build-essential"
  ];
in
{
  inherit base dropFromBase bootEssentials bosh;

  # Single source of truth for the full top-level set installed into the image
  # (was image-packages.nix). Consumed by rootfs/rootfs.nix and the example gates.
  image = lib.unique (
    essential
    ++ lib.filter (p: !lib.elem p dropFromBase) base
    ++ bootEssentials
    ++ bosh
  );
}
```

- [ ] **Step 4: `git mv` fill-disk-usrmerge into rootfs/ (needed by tarball/examples)**

```bash
mkdir -p rootfs
git mv lib/fill-disk-usrmerge.nix rootfs/fill-disk-usrmerge.nix
```

(No content change; its callers are fixed in Task 2.3/2.5.)

- [ ] **Step 5: Remove the seven superseded lib files**

```bash
git rm lib/noble-source.nix lib/noble-distro.nix lib/base-packages.nix \
       lib/boot-packages.nix lib/noble-packages.nix lib/image-packages.nix \
       lib/essential-packages.nix
```

(No commit yet — Phase 2 lands as one commit in Task 2.6.)

### Task 2.2: Collapse `pkgs/blobstore-clis.nix`

**Files:**
- Create: `pkgs/blobstore-clis.nix`
- Delete: `lib/mk-blobstore-cli.nix`, `pkgs/bosh-davcli.nix`, `pkgs/bosh-s3cli.nix`,
  `pkgs/bosh-gcscli.nix`, `pkgs/bosh-azure-storage-cli.nix`

The four CLI derivations keep identical attrs (pname/version/src/env/ldflags/
postInstall/meta), so their store paths are unchanged → the blobstore-clis overlay's
embedded `${davcli}/…` paths are unchanged → os-image bytes unchanged.

- [ ] **Step 1: Write `pkgs/blobstore-clis.nix`**

```nix
# The four source-built BOSH blobstore CLIs. Folds the former
# lib/mk-blobstore-cli.nix wrapper and the four per-CLI wrapper files into one
# attrset. Each CLI's derivation attributes are unchanged, so store paths (and
# thus the blobstore-clis overlay output) are identical to before the collapse.
{ lib, buildGoModule, fetchFromGitHub }:

let
  mkCli =
    { pname, version, owner ? "cloudfoundry", repo, rev ? "v${version}"
    , hash, vendorHash, subPackages ? [ "." ], ldflagsVersionVar ? null
    }:
    let
      cliName =
        if lib.hasPrefix "bosh-" pname then lib.removePrefix "bosh-" pname else pname;
    in
    buildGoModule {
      inherit pname version vendorHash subPackages;
      src = fetchFromGitHub { inherit owner repo rev hash; };
      env.CGO_ENABLED = "0";
      doCheck = false;
      ldflags =
        lib.optionals (ldflagsVersionVar != null)
          [ "-s" "-w" "-X" "${ldflagsVersionVar}=${version}" ];
      postInstall = lib.optionalString (subPackages != [ "." ]) ''
        # When subPackages is used, the binary is named after the last component of the package path.
        # Rename it to the CLI name (pname with "bosh-" prefix removed) for consistency.
        for bin in $out/bin/*; do
          [ -f "$bin" ] && mv "$bin" "$out/bin/${cliName}"
        done
      '';
      meta = {
        description = "BOSH blobstore CLI: ${pname}";
        homepage = "https://github.com/${owner}/${repo}";
      };
    };
in
{
  davcli = mkCli {
    pname = "bosh-davcli";
    version = "0.0.486";
    repo = "bosh-davcli";
    hash = "sha256-rCAdyF97WeTvCPoJiiKvmNgCtddAi/30xbaVCrHaHD0=";
    vendorHash = null;
    subPackages = [ "./main" ];
    ldflagsVersionVar = null;
  };
  s3cli = mkCli {
    pname = "bosh-s3cli";
    version = "0.0.413";
    repo = "bosh-s3cli";
    hash = "sha256-sNaByQS5bwd5kSqAYCB/Xq2brDbhfXidHXqoK8V3ahU=";
    vendorHash = null;
    ldflagsVersionVar = "main.version";
  };
  gcscli = mkCli {
    pname = "bosh-gcscli";
    version = "0.0.393";
    repo = "bosh-gcscli";
    hash = "sha256-LwsfF7OAweJBjzvilC5dpkWAnC3dAKgINlDk7Jf//pU=";
    vendorHash = null;
    ldflagsVersionVar = null;
  };
  azureStorageCli = mkCli {
    pname = "bosh-azure-storage-cli";
    version = "0.0.242";
    repo = "bosh-azure-storage-cli";
    hash = "sha256-bAk9dwj5NppeoAOT+LVews/SV7GiWgJobVzQdAzSCmM=";
    vendorHash = null;
    ldflagsVersionVar = null;
  };
}
```

- [ ] **Step 2: Verify store paths are unchanged (before deleting the old files)**

Run:
```bash
old=$(nix eval --raw --file pkgs/bosh-davcli.nix --apply 'p: p' 2>/dev/null || \
      nix build --no-link --print-out-paths "path:$PWD#bosh-davcli")
new=$(nix build --no-link --print-out-paths \
      --expr 'let p = import ./. ; in (import ./pkgs/blobstore-clis.nix {}).davcli' 2>/dev/null || true)
echo "compare davcli store paths manually if the above is noisy"
```
Expected (authoritative check): the `bosh-davcli`/`bosh-s3cli`/`bosh-gcscli`/
`bosh-azure-storage-cli` flake outputs (rewired in Task 2.5) resolve to the SAME
`/nix/store/…` paths as on `main`. The definitive guard is the Task 2.6 os-image
byte-check (the overlay embeds these paths). If os-image bytes match, the CLIs are
identical.

- [ ] **Step 3: Delete the superseded files**

```bash
git rm lib/mk-blobstore-cli.nix pkgs/bosh-davcli.nix pkgs/bosh-s3cli.nix \
       pkgs/bosh-gcscli.nix pkgs/bosh-azure-storage-cli.nix
```

### Task 2.3: Move & rewire the rootfs-phase builders

**Files:**
- `git mv lib/mk-rootfs-tarball.nix rootfs/tarball.nix`
- `git mv lib/mk-apply-overlays.nix rootfs/apply-overlays.nix`
- Create: `rootfs/rootfs.nix`
- `git mv examples/os-image.nix rootfs/os-image.nix`
- `git mv examples/noble-rootfs.nix` → folded into `rootfs/rootfs.nix` (delete original)

- [ ] **Step 1: Move the two builders (no content change yet)**

```bash
git mv lib/mk-rootfs-tarball.nix rootfs/tarball.nix
git mv lib/mk-apply-overlays.nix rootfs/apply-overlays.nix
```

- [ ] **Step 2: Fix `rootfs/tarball.nix` imports and param name**

In `rootfs/tarball.nix`, change the fill-disk import (now same dir) and rename the
`noble` param to `aptPins`:

Old:
```nix
  inherit (callPackage ./fill-disk-usrmerge.nix { }) makeImageFromDebDist;
in
{ noble, packages, size ? 16384, seedStartStopDaemon ? true }:
makeImageFromDebDist {
  inherit (noble) name fullName urlPrefix packagesLists;
```
New:
```nix
  inherit (callPackage ./fill-disk-usrmerge.nix { }) makeImageFromDebDist;
in
{ aptPins, packages, size ? 16384, seedStartStopDaemon ? true }:
makeImageFromDebDist {
  inherit (aptPins) name fullName urlPrefix packagesLists;
```

(The `./fill-disk-usrmerge.nix` path is already correct after Task 2.1 Step 4.)

- [ ] **Step 3: Write `rootfs/rootfs.nix`** (base tarball target; was examples/noble-rootfs.nix)

```nix
# PHASE 1 base: the Noble deb closure as a rootfs tarball ($out/rootfs.tar.gz),
# BEFORE config overlays. Flake output `noble-rootfs`. os-image.nix folds the
# overlays onto this.
{ callPackage }:
let
  aptPins = callPackage ../ubuntu/apt-pins.nix { };
  mkRootfsTarball = callPackage ./tarball.nix { };
in
mkRootfsTarball {
  inherit aptPins;
  packages = (callPackage ../ubuntu/deb-sets.nix { }).image;
  size = 16384;
}
```

- [ ] **Step 4: Remove the old noble-rootfs example**

```bash
git rm examples/noble-rootfs.nix
```

- [ ] **Step 5: Move and rewrite `rootfs/os-image.nix`** (was examples/os-image.nix; overlay list extracted to overlays/default.nix)

```bash
git mv examples/os-image.nix rootfs/os-image.nix
```

Replace its contents with:

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

### Task 2.4: Move overlays into `rootfs/overlays/` + add `default.nix`

**Files:**
- `git mv lib/overlays/* rootfs/overlays/`
- Fix `../mkOverlay.nix` → `../../lib/mkOverlay.nix` in the 10 externalized `.nix`
- Create: `rootfs/overlays/default.nix`

- [ ] **Step 1: Move the overlays dir**

```bash
mkdir -p rootfs/overlays
git mv lib/overlays/* rootfs/overlays/
rmdir lib/overlays 2>/dev/null || true
```

- [ ] **Step 2: Fix the mkOverlay import path in the 10 externalized overlays**

For each of `users ssh sysctl-limits-env sudoers-pam rsyslog audit misc-os
systemd-services openstack-agent-settings debug-ssh-root-login`, change the import
line in `rootfs/overlays/<name>.nix`:

Old: `import ../mkOverlay.nix {`
New: `import ../../lib/mkOverlay.nix {`

(The interpolating overlays `agent.nix`, `blobstore-clis.nix`, `debug-ssh-keys.nix`
have no mkOverlay import — leave them unchanged.)

- [ ] **Step 3: Write `rootfs/overlays/default.nix`** (the ordered list; was inline in os-image.nix)

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

### Task 2.5: Move & rewire the stemcell-phase files

**Files:**
- `git mv lib/mk-bootable-disk.nix stemcells/bootable-disk.nix`
- `git mv lib/mk-stemcell.nix stemcells/package.nix`
- `git mv examples/noble-stemcell-disk.nix stemcells/openstack-kvm-disk.nix`
- `git mv examples/noble-stemcell.nix stemcells/openstack-kvm.nix`

- [ ] **Step 1: Move the four files**

```bash
mkdir -p stemcells
git mv lib/mk-bootable-disk.nix stemcells/bootable-disk.nix
git mv lib/mk-stemcell.nix stemcells/package.nix
git mv examples/noble-stemcell-disk.nix stemcells/openstack-kvm-disk.nix
git mv examples/noble-stemcell.nix stemcells/openstack-kvm.nix
```

(`bootable-disk.nix` and `package.nix` are builders with no relative imports to
other repo files — no content change needed here. `bootable-disk.sh`
externalization is Phase 4.)

- [ ] **Step 2: Rewrite `stemcells/openstack-kvm-disk.nix`** (consumes rootfs os-image → qcow2)

```nix
# PHASE 2 (OpenStack/KVM): bootable MBR qcow2 disk from the phase-1 os-image.
# Flake output `noble-stemcell-disk`. Output: $out/root.qcow2
{ callPackage }:
let
  osImage = callPackage ../rootfs/os-image.nix { };
  mkBootableDisk = callPackage ./bootable-disk.nix { };
in
mkBootableDisk {
  inherit osImage;
  name = "noble-stemcell";
}
```

- [ ] **Step 3: Rewrite `stemcells/openstack-kvm.nix`** (qcow2 → stemcell .tgz)

```nix
# PHASE 2 (OpenStack/KVM): package the bootable qcow2 into a BOSH stemcell .tgz.
# Flake outputs `noble-stemcell` and `openstack-kvm`.
# Output: $out/bosh-stemcell-<version>-openstack-kvm-ubuntu-noble.tgz
{ callPackage }:
let
  bootableDiskDerivation = callPackage ./openstack-kvm-disk.nix { };
  bootableDisk = "${bootableDiskDerivation}/root.qcow2";
  mkStemcell = callPackage ./package.nix { };
in
mkStemcell {
  inherit bootableDisk;
  version = "0.0.5-nix";
  os = "ubuntu";
  osVersion = "noble";
  infrastructure = "openstack";
  hypervisor = "kvm";
}
```

- [ ] **Step 4: Fix example path references** in `examples/noble-bootable.nix` and
  `examples/noble-closure.nix`:

Old (both files):
```nix
  noble = callPackage ../lib/noble-distro.nix { };
```
New:
```nix
  noble = callPackage ../ubuntu/apt-pins.nix { };
```

Old (both files, the packages line — verify exact text):
```nix
  packages = callPackage ../lib/image-packages.nix { };
```
New:
```nix
  packages = (callPackage ../ubuntu/deb-sets.nix { }).image;
```

In `examples/noble-bootable.nix` also fix the fill-disk import:
Old: `callPackage ../lib/fill-disk-usrmerge.nix { }` (or `import ../lib/fill-disk-usrmerge.nix`)
New: `callPackage ../rootfs/fill-disk-usrmerge.nix { }` (match the original call form).

> `noble-bootable.nix` references `noble.name/fullName/urlPrefix/packagesLists` —
> all provided by `apt-pins.nix`. It does not use `basePackages` (only the removed
> `image-packages` did), so dropping that alias is safe.

### Task 2.6: Rewrite `flake.nix` with explicit outputs, then byte-check

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1: Replace the auto-discovery with explicit outputs**

Replace the `packages = let mapDir … in (mapDir ./examples) // (mapDir ./pkgs);`
block with:

```nix
      packages =
        let
          blobstoreClis = pkgs.callPackage ./pkgs/blobstore-clis.nix { };
          openstack-kvm = pkgs.callPackage ./stemcells/openstack-kvm.nix { };
        in
        {
          # PHASE 1
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

(Leave `devShells.default` unchanged. The `lib` arg in the outer `mkFlake` may now
be unused — if `nix flake check` later warns, drop it from the function head.)

- [ ] **Step 2: Eval the flake (catches path/typo errors fast)**

Run: `nix flake show path:"$(d=$(mktemp -d); cp -a . "$d/s"; rm -rf "$d/s/.git"; echo "$d/s")" 2>&1 | head -40`
Expected: lists `os-image`, `noble-rootfs`, `noble-stemcell`, `openstack-kvm`,
`noble-stemcell-disk`, `noble-bootable`, `noble-closure`, `hello-vm`, `bosh-agent`,
`monit`, `bosh-davcli`, `bosh-s3cli`, `bosh-gcscli`, `bosh-azure-storage-cli`.

- [ ] **Step 3: Byte-check os-image (the Phase 2 regression gate)**

Run: `./scripts/byte-check-osimage.sh os-image`
Expected: sha256 equals the Task 0.2 baseline. If it differs, a path rewire changed
a derivation input — bisect the moved files (systematic-debugging).

- [ ] **Step 4: Commit the whole restructure**

```bash
git add -A
git commit -m "refactor: restructure into ubuntu/rootfs/stemcells; collapse thin files; explicit flake outputs"
```

---

## Phase 3 — Full build confirmation of phase 2

### Task 3.1: Build the stemcell end-to-end

**Files:** none.

- [ ] **Step 1: Build noble-stemcell (== openstack-kvm) via the scratch pattern**

Run:
```bash
d=$(mktemp -d); cp -a . "$d/s"; rm -rf "$d/s/.git"
nix build -L --no-link "path:$d/s#noble-stemcell"
nix build -L --no-link "path:$d/s#openstack-kvm"
rm -rf "$d"
```
Expected: both succeed; `openstack-kvm` reuses the same store path as
`noble-stemcell` (alias).

- [ ] **Step 2: Build the demo/diagnostic targets**

Run (same scratch pattern): build `noble-bootable`, `noble-closure`, `hello-vm`,
`bosh-davcli`, `bosh-s3cli`, `bosh-gcscli`, `bosh-azure-storage-cli`.
Expected: all succeed.

---

## Phase 4 — Stemcell-phase helpers (getExe, mkVmImage, externalize bootable-disk.sh)

Not byte-constrained (these layers run in `runInLinuxVM` and were never
byte-reproducible). Guard = successful build only.

### Task 4.1: Externalize `stemcells/bootable-disk.sh` via `replaceVars`

**Files:**
- Create: `stemcells/bootable-disk.sh`
- Modify: `stemcells/bootable-disk.nix`

- [ ] **Step 1: Extract the buildCommand to a `.sh` with `@placeholder@` markers**

Create `stemcells/bootable-disk.sh` from the current `buildCommand` string, replacing
each `${util-linux}` / `${dosfstools}` / `${e2fsprogs}` / `${qemu}` / `${gnutar}` /
`${systemdMinimal}` interpolation with `@util-linux@` … `@systemdMinimal@`. Keep the
inline `<<'CHROOT'` heredoc and all `/dev/vda` logic verbatim.

- [ ] **Step 2: Rewrite `stemcells/bootable-disk.nix` to inject the script**

Replace the `buildCommand = ''…'';` with:

```nix
  buildCommand = builtins.readFile (replaceVars ./bootable-disk.sh {
    inherit util-linux dosfstools e2fsprogs qemu gnutar systemdMinimal;
  });
```

Add `replaceVars` to the function's argument set. (`replaceVars` returns a store
path; `readFile` on it is IFD, acceptable in this VM layer.)

- [ ] **Step 3: Build-check**

Run (scratch pattern): `nix build -L --no-link "path:$d/s#noble-stemcell-disk"`
Expected: succeeds; produces `root.qcow2`.

- [ ] **Step 4: Commit**

```bash
git add stemcells/bootable-disk.nix stemcells/bootable-disk.sh
git commit -m "refactor: externalize bootable-disk VM script via replaceVars"
```

### Task 4.2: (Optional) `lib/mkVmImage.nix`

**Files:**
- Create: `lib/mkVmImage.nix`

- [ ] **Step 1: Extract the shared `runInLinuxVM` + `createEmptyImage` boilerplate**

```nix
# Thin wrapper over vmTools: build `buildCommand` inside a Linux VM with an
# attached empty raw disk of `size` MiB. Shared by stemcells/bootable-disk.nix
# and reusable by examples/noble-bootable.nix.
{ vmTools, stdenv }:
{ name, size ? 2560, buildCommand, nativeBuildInputs ? [ ], memSize ? 512 }:
vmTools.runInLinuxVM (stdenv.mkDerivation {
  inherit name buildCommand nativeBuildInputs memSize;
  preVM = vmTools.createEmptyImage { inherit size; fullName = name; };
})
```

- [ ] **Step 2: Refactor `stemcells/bootable-disk.nix` to use it** (replace the
  inline `vmTools.runInLinuxVM (stdenv.mkDerivation { … preVM = …; })` scaffold with
  a `mkVmImage { name; size; nativeBuildInputs; buildCommand; }` call). Keep the same
  `size = 2560` default.

- [ ] **Step 3: Build-check** `noble-stemcell-disk` (scratch pattern). Expected:
  succeeds.

- [ ] **Step 4: Commit**

```bash
git add lib/mkVmImage.nix stemcells/bootable-disk.nix
git commit -m "refactor: extract mkVmImage wrapper for runInLinuxVM builders"
```

> If Task 4.2 proves awkward (e.g. the udev backgrounding needs the raw scaffold),
> skip it — it is opportunistic (design §10), not required.

---

## Phase 5 — treefmt formatter + flake check

### Task 5.1: Add treefmt

**Files:**
- Modify: `flake.nix`
- Create: `treefmt.nix` (or inline config)

- [ ] **Step 1: Add the treefmt input and wire the formatter/check**

Add to `inputs`:
```nix
    treefmt-nix.url = "github:numtide/treefmt-nix";
```

In `perSystem`, add a treefmt module producing `formatter` + a `checks.treefmt`:
```nix
      treefmt = {
        projectRootFile = "flake.nix";
        programs.nixfmt.enable = true;
        programs.shfmt.enable = true;
        programs.shellcheck.enable = true;
      };
```
(Import `treefmt-nix.flakeModule` in the flake-parts `imports`.) This makes `nix fmt`
run nixfmt+shfmt and `nix flake check` run shellcheck.

- [ ] **Step 2: Configure shellcheck for sourced overlay fragments**

Overlay `.sh` files rely on `$root`/PATH from the driver and are not standalone
scripts. Add a `.shellcheckrc` or per-file `# shellcheck shell=bash` directive plus
`# shellcheck disable=SC2154` (unassigned `$root`) at the top of each
`rootfs/overlays/*.sh`, OR exclude `rootfs/overlays/*.sh` from shellcheck in the
treefmt config and lint only the standalone scripts (`scripts/*.sh`,
`stemcells/bootable-disk.sh`). Prefer the directive approach so fragments are still
linted.

- [ ] **Step 3: Run the formatter**

Run (scratch pattern): `nix fmt path:"$d/s"` then copy formatted files back, OR run
`nix run path:"$d/s#formatter"`. Simpler: install treefmt in the devshell and run
`treefmt` in-place.
Expected: `.nix` reformatted by nixfmt; `.sh` by shfmt.

- [ ] **Step 4: Byte-check os-image after formatting**

Run: `./scripts/byte-check-osimage.sh os-image`
Expected: sha256 still equals baseline. **nixfmt does not alter string values and
shfmt is not applied to overlay fragment *contents as embedded* (the `.sh` bytes are
what `readFile` sees).** If shfmt reformatted an overlay `.sh`, its bytes changed →
os-image WILL differ. If so: exclude `rootfs/overlays/*.sh` from shfmt (they are
byte-locked fragments, not free-form scripts) and re-check.

- [ ] **Step 5: Run flake check**

Run (scratch pattern): `nix flake check "path:$d/s"`
Expected: green (nixfmt + shellcheck pass).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: add treefmt (nixfmt+shfmt+shellcheck) formatter and flake check"
```

---

## Phase 6 — Docs & final verification

### Task 6.1: Update README/docs to the new layout

**Files:**
- Modify: `README.md` (and any doc referencing old paths/targets)

- [ ] **Step 1: Update the repo-layout section, build commands, and target names**
  to reference `ubuntu/`, `rootfs/`, `stemcells/`, `examples/`, and the
  `openstack-kvm` alias. Note the `path:.#<target>` build workaround for the local
  virtiofs quirk.

- [ ] **Step 2: Grep for stale references**

Run: `rg -n 'lib/(noble-|base-|boot-|image-|essential-|mk-)' README.md docs || echo clean`
Expected: `clean` (or only historical mentions in dated specs, which stay as-is).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: update layout and build commands for the nix-native refactor"
```

### Task 6.2: Final byte-check

- [ ] **Step 1:** Run `./scripts/byte-check-osimage.sh os-image`.
  Expected: sha256 == Task 0.2 baseline.

### Task 6.3: Final full build

- [ ] **Step 1:** Build every flake output via the scratch pattern
  (`noble-stemcell`, `openstack-kvm`, `noble-stemcell-disk`, `os-image`,
  `noble-rootfs`, `noble-bootable`, `noble-closure`, `hello-vm`, `bosh-agent`,
  `monit`, `bosh-davcli`, `bosh-s3cli`, `bosh-gcscli`, `bosh-azure-storage-cli`).
  Expected: all succeed.

### Task 6.4: (Optional) End-to-end deploy smoke

- [ ] **Step 1:** `source ./bosh.env`; upload the built `noble-stemcell` to the Incus
  director and run a sample deployment. Not required by the acceptance bar; a final
  confidence signal only.

---

## Self-Review (completed by plan author)

**Spec coverage** (design §§3–9):
- §3 directory structure → Phase 2 (all `git mv`s + collapses). ✓
- §4 bash externalization (byte-critical) → Phase 1 (overlays) + Task 4.1
  (bootable-disk). Deviations documented (heredocs stay in `.sh`; interpolating
  overlays inline). ✓
- §5 upstream helpers → Task 4.1 (`replaceVars`), Task 4.2 (`mkVmImage`); `getExe`
  folded into 4.x as opportunistic. ✓
- §6 local lib → Task 1.1 (`mkOverlay`), Task 4.2 (`mkVmImage`). ✓
- §7 flake + treefmt → Task 2.6 (explicit outputs) + Phase 5. ✓
- §8 verification → Phase 0 baseline + byte-checks after every rootfs-touching task
  + Phase 6 full build. ✓
- §9 sequencing → Phases 1→2→3→4→5→6 match the design's ordering. ✓

**Placeholder scan:** No `TBD`/"add error handling"/"similar to". Overlay bodies are
extracted mechanically via `nix eval --raw` rather than transcribed (deliberate: the
tool guarantees byte-identity where hand-copying would risk it). Baseline sha is
runtime-recorded (Task 0.2) — a legitimate measured value, not a code placeholder.

**Type/name consistency:** `apt-pins` provides `name/fullName/urlPrefix/
packagesLists`; `tarball.nix` consumes exactly those via the renamed `aptPins`
param. `deb-sets.image` replaces every `image-packages.nix` call site
(`rootfs/rootfs.nix`, `noble-bootable`, `noble-closure`). `blobstore-clis` attrset
keys `davcli/s3cli/gcscli/azureStorageCli` match both the overlay `inherit` in
`overlays/default.nix` and the flake `bosh-*` output aliases. `mkOverlay` signature
`{ name, src }` matches all 10 externalized-overlay call sites.
```
