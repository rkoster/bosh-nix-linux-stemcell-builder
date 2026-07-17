# Add Ubuntu Resolute (26.04) Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Ubuntu Resolute (26.04 LTS) as a second release alongside Noble in the Nix stemcell builder, producing four working cells (`{noble,resolute} × {openstack,aws}`) while keeping every Noble artifact byte-identical to its Plan 1 baseline.

**Architecture:** Resolute is expressed almost entirely as a pure-data release descriptor (`build/ubuntu/releases/resolute.nix`) consumed through the release selector added in Plan 1. Three behavioral deltas need code: per-release system-account assets (`users` stage), pam_lastlog2 mode (`sudoers-pam` stage), and `tmp.mount` masking (systemd 259). The flake gains an explicit `resolute-*` output block mirroring Noble's. Correctness of the Resolute rootfs is anchored to the upstream `ubuntu-resolute` os_image spec, which asserts the exact `/etc/passwd`, `/etc/group`, `/etc/gshadow` bytes and the `/etc/shadow` shape.

**Tech Stack:** Nix flakes (nixpkgs `nixos-26.05`), `vmTools` deb-image machinery, bash stage scripts, QEMU/OVMF for boot validation, treefmt (nixfmt/shfmt/shellcheck).

---

## Ground-Truth Reference Data (already gathered — use verbatim)

**Resolute snapshot + index hashes** (prefetched from `snapshot.ubuntu.com`, verified 2026-07-17; Release header: `Origin: Ubuntu / Suite: resolute / Version: 26.04 / Codename: resolute / Date: Thu, 23 Apr 2026`):

- `snapshot = "20260701T000000Z"`
- `packagesListHashes.main       = "096gfgfwvg9g9cp4yk7rbzxy4w35qlnp9806bb6axvv3n8fc96pd"`
- `packagesListHashes.universe   = "07jqmnk3h83nwan97mr4ixf6kgbmkw80wpi14lim8f3dss3bx1qm"`
- `packagesListHashes.multiverse = "1jd1h5vm6g2cngx81fq56046dbg2r4a7gg41a0nnpyn1y8vnr7k4"`

**Reference repo (authoritative for account/package data):**
`/home/ruben/workspace/bosh-linux-stemcell-builder`, branch `ubuntu-resolute`.
Spec file (asserts exact rootfs identity): `bosh-stemcell/spec/os_image/ubuntu_spec.rb`.

- `/etc/passwd` exact bytes: spec lines **357–385** (`should eql`).
- `/etc/group` exact bytes: spec lines **427–489** (`should eql`).
- `/etc/gshadow` exact bytes: spec lines **494–556** (`should eql`).
- `/etc/shadow` shape (regex, lastchange is `\d{5}`): spec lines **390–419**.
- runit removed: spec lines **560–578** (`runit` not installed; no `chpst`/`runsv`/`runit` binaries).
- `tmp.mount` masked → symlink to `/dev/null`: spec lines **580–587**.
- pam_lastlog2 **active** line asserted: spec line **202** (`^session\toptional\t\t\tpam_lastlog2.so showfailed`).

**Resolute `boshPackages` deltas vs Noble** (reference `stemcell_builder/stages/base_ubuntu_packages/apply.sh`):
- rename `libxml2` → `libxml2-16`
- remove `rng-tools`, `traceroute`, `mg`, `module-assistant`, `runit`, `rsyslog-openssl`, `systemd-timesyncd`
- add `libpam-lastlog2`
- (rationale for `systemd-timesyncd` removal: Resolute uses `chrony`; the spec `/etc/passwd` has **no** `systemd-timesync` user. Verified in Task 6.)

**Key facts that de-risk this plan:**
- The Nix builder supervises via **systemd units** (`bosh-agent.service`, `monit.service`), NOT runit/chpst. So "runit removal" here means: omit the `runit` package and drop the `_runit-log` account — no supervision rework.
- `base`/`bootEssentials` in `deb-sets.nix` are generic (all present in 26.04) — no per-release override needed. Only `bosh` (the descriptor's `boshPackages`) carries release-specific names.
- The systemd-resolved listener assets already ship in `build/stages/systemd-services/` (handled for Noble). Only `tmp.mount` masking is new.

**Regression oracle for Noble byte-identity:** `docs/plans/baseline-hashes.txt` (6 sha256s). Noble drvPaths/hashes must not change.

---

## Build & Verify Commands (reference)

- Full check (determinism for all cells + treefmt): `nix flake check -L`
- Build a package: `nix build -L .#packages.x86_64-linux.<name>`
- New/untracked `.nix` files are invisible to the flake until staged. **Always `git add` new files before `nix build`/`nix flake check`.**
- Format: `nix fmt` (from repo root).

---

## Task 1: Create the Resolute release descriptor

**Files:**
- Create: `build/ubuntu/releases/resolute.nix`

- [ ] **Step 1: Write the descriptor**

Create `build/ubuntu/releases/resolute.nix` with exactly this content:

```nix
# Ubuntu Resolute (26.04 LTS) release descriptor. Pure data consumed by
# build/ubuntu/release.nix. Snapshot + index hashes prefetched from
# snapshot.ubuntu.com (snapshot 20260701T000000Z; Resolute GA 2026-04-23).
# Package deltas transcribed from the reference bosh-linux-stemcell-builder
# `ubuntu-resolute` branch base_ubuntu_packages/apply.sh.
{
  release = "resolute";
  codename = "resolute";
  osVersion = "resolute";
  version = "26.04";
  name = "ubuntu-26.04-resolute-amd64";
  fullName = "Ubuntu 26.04 Resolute (amd64)";

  # PER-RELEASE snapshot pin (snapshot.ubuntu.com timestamp).
  snapshot = "20260701T000000Z";

  # sha256 (base32) of each Packages.xz at the snapshot above.
  packagesListHashes = {
    main = "096gfgfwvg9g9cp4yk7rbzxy4w35qlnp9806bb6axvv3n8fc96pd";
    universe = "07jqmnk3h83nwan97mr4ixf6kgbmkw80wpi14lim8f3dss3bx1qm";
    multiverse = "1jd1h5vm6g2cngx81fq56046dbg2r4a7gg41a0nnpyn1y8vnr7k4";
  };

  # Behavioral toggles consumed by stages.
  # runit = false: Resolute RFC #1498 removed runit; the package is omitted from
  #   boshPackages below and the _runit-log account is absent from the resolute
  #   user assets. No supervision rework (systemd units already drive bosh-agent
  #   and monit). This toggle documents intent; correctness is structural.
  # pamLastlog2 = "package": Resolute ships libpam-lastlog2, so the sudoers-pam
  #   stage emits an ACTIVE pam_lastlog2 line (+ multiarch symlink bridge)
  #   instead of Noble's commented-out placeholder.
  features = {
    runit = false;
    pamLastlog2 = "package";
  };

  # Authoritative BOSH package set. Derived from Noble's list with the reference
  # `ubuntu-resolute` deltas applied: libxml2->libxml2-16; drop rng-tools,
  # traceroute, mg, module-assistant, runit, rsyslog-openssl, systemd-timesyncd;
  # add libpam-lastlog2.
  boshPackages = [
    "libssl-dev"
    "lsof"
    "strace"
    "bind9-host"
    "dnsutils"
    "tcpdump"
    "iputils-arping"
    "curl"
    "wget"
    "bison"
    "libreadline6-dev"
    "libxml2-16"
    "libxml2-dev"
    "libxslt1.1"
    "libxslt1-dev"
    "zip"
    "unzip"
    "flex"
    "psmisc"
    "apparmor-utils"
    "iptables"
    "nftables"
    "sysstat"
    "rsync"
    "openssh-server"
    "libncurses5-dev"
    "quota"
    "libaio1t64"
    "gdb"
    "libcap2-bin"
    "libcap2-dev"
    "libbz2-dev"
    "cmake"
    "uuid-dev"
    "libgcrypt-dev"
    "ca-certificates"
    "htop"
    "debhelper"
    "parted"
    "cloud-guest-utils"
    "anacron"
    "software-properties-common"
    "xfsprogs"
    "gdisk"
    "chrony"
    "dbus"
    "nvme-cli"
    "fdisk"
    "ethtool"
    "libpam-pwquality"
    "libpam-lastlog2"
    "gpg-agent"
    "libcurl4"
    "libcurl4-openssl-dev"
    "resolvconf"
    "net-tools"
    "ifupdown"
    "rsyslog"
    "rsyslog-gnutls"
    "rsyslog-relp"
    "auditd"
    "sudo"
    "cron"
    "grub2"
    "zlib1g-dev"
    "build-essential"
  ];
}
```

- [ ] **Step 2: Format and stage**

Run: `nix fmt -- build/ubuntu/releases/resolute.nix && git add build/ubuntu/releases/resolute.nix`
Expected: file reformatted (or unchanged) and staged.

- [ ] **Step 3: Commit**

```bash
git add build/ubuntu/releases/resolute.nix
git commit -m "feat(resolute): add Ubuntu 26.04 Resolute release descriptor"
```

---

## Task 2: Register Resolute in the release selector

**Files:**
- Modify: `build/ubuntu/release.nix`

- [ ] **Step 1: Add the registry entry**

In `build/ubuntu/release.nix`, replace:

```nix
  registry = {
    noble = import ./releases/noble.nix;
    # resolute added in a later plan
  };
```

with:

```nix
  registry = {
    noble = import ./releases/noble.nix;
    resolute = import ./releases/resolute.nix;
  };
```

- [ ] **Step 2: Verify both releases resolve**

Run:
```bash
nix eval --impure --expr 'builtins.attrNames (let f = x: (import ./build/ubuntu/release.nix { release = x; }).codename; in { noble = f "noble"; resolute = f "resolute"; })'
```
Expected: `[ "noble" "resolute" ]` (no throw).

- [ ] **Step 3: Verify unknown release still throws**

Run: `nix eval --impure --expr '(import ./build/ubuntu/release.nix { release = "bogus"; }).codename' 2>&1 | head -3`
Expected: error containing `unknown release 'bogus' (known: noble, resolute)`.

- [ ] **Step 4: Commit**

```bash
git add build/ubuntu/release.nix
git commit -m "feat(resolute): register resolute in the release selector"
```

---

## Task 3: Fix `deb-sets.nix` to forward `release` to apt-pins (threading bug)

**Context:** `deb-sets.nix` accepts `release` but calls `apt-pins.nix` with `{ }`, so a Resolute build would fetch Noble's snapshot indices. This is byte-neutral for Noble (default is `noble`).

**Files:**
- Modify: `build/ubuntu/deb-sets.nix:12`

- [ ] **Step 1: Thread release into apt-pins**

In `build/ubuntu/deb-sets.nix`, change line 12 from:

```nix
  aptPins = callPackage ./apt-pins.nix { };
```

to:

```nix
  aptPins = callPackage ./apt-pins.nix { inherit release; };
```

- [ ] **Step 2: Verify Noble image list is unchanged (byte-neutral regression)**

First, `git add` the change so the flake sees it, then emit the Noble `image` set (using the flake-pinned nixpkgs) as a sorted name list:
```bash
git add build/ubuntu/deb-sets.nix
nix eval --impure --json --expr 'let f = builtins.getFlake (toString ./.); p = f.inputs.nixpkgs.legacyPackages.x86_64-linux; in (p.callPackage ./build/ubuntu/deb-sets.nix { release = "noble"; }).image' \
  | python3 -c 'import json,sys; [print(x) for x in sorted(json.load(sys.stdin))]' > /tmp/noble-image-after.txt
wc -l /tmp/noble-image-after.txt
```
Expected: the count and names match the Plan 1 oracle `docs/plans/baseline-image.json`. Compare (normalizing the oracle to one sorted name per line):
```bash
python3 -c 'import json; [print(x) for x in sorted(json.load(open("docs/plans/baseline-image.json")))]' > /tmp/noble-image-baseline.txt
diff /tmp/noble-image-baseline.txt /tmp/noble-image-after.txt
```
Expected: empty diff (identical set). If `baseline-image.json` is nested rather than a flat array, adjust the `json.load` access path, but the resulting name set must be identical.

- [ ] **Step 3: Verify Resolute now selects its own snapshot indices**

Run:
```bash
nix eval --impure --raw --expr 'let f = builtins.getFlake (toString ./.); p = f.inputs.nixpkgs.legacyPackages.x86_64-linux; in (p.callPackage ./build/ubuntu/apt-pins.nix { release = "resolute"; }).urlPrefix'
```
Expected: `https://snapshot.ubuntu.com/ubuntu/20260701T000000Z`

- [ ] **Step 4: Commit**

```bash
git add build/ubuntu/deb-sets.nix
git commit -m "fix(deb-sets): forward release to apt-pins so resolute uses its own snapshot"
```

---

## Task 4: Add explicit `resolute-*` flake outputs and determinism checks

**Context:** Rather than a generic product loop (which risks disturbing Noble's bespoke output names), add an explicit Resolute block mirroring Noble's. All stemcell `.nix` files already accept `release` (Plan 1). Noble bindings are untouched → byte-identical.

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1: Add Resolute layer bindings to the outer `let`**

In `flake.nix`, replace the outer `let` (lines 24–29):

```nix
          let
            noble-stemcell-rootfs = pkgs.callPackage ./build/stemcells/openstack-kvm-rootfs.nix { };
            noble-stemcell-aws-rootfs = pkgs.callPackage ./build/stemcells/aws-rootfs.nix { };
            noble-stemcell-disk = pkgs.callPackage ./build/stemcells/openstack-kvm-disk.nix { };
            noble-stemcell-aws-disk = pkgs.callPackage ./build/stemcells/aws-disk.nix { };
          in
```

with:

```nix
          let
            noble-stemcell-rootfs = pkgs.callPackage ./build/stemcells/openstack-kvm-rootfs.nix { };
            noble-stemcell-aws-rootfs = pkgs.callPackage ./build/stemcells/aws-rootfs.nix { };
            noble-stemcell-disk = pkgs.callPackage ./build/stemcells/openstack-kvm-disk.nix { };
            noble-stemcell-aws-disk = pkgs.callPackage ./build/stemcells/aws-disk.nix { };

            resolute-stemcell-rootfs = pkgs.callPackage ./build/stemcells/openstack-kvm-rootfs.nix { release = "resolute"; };
            resolute-stemcell-aws-rootfs = pkgs.callPackage ./build/stemcells/aws-rootfs.nix { release = "resolute"; };
            resolute-stemcell-disk = pkgs.callPackage ./build/stemcells/openstack-kvm-disk.nix { release = "resolute"; };
            resolute-stemcell-aws-disk = pkgs.callPackage ./build/stemcells/aws-disk.nix { release = "resolute"; };
          in
```

- [ ] **Step 2: Add Resolute determinism checks**

In `flake.nix`, inside the `checks = { ... };` attrset, immediately before the closing `};` (currently line 62), add:

```nix
              rootfs-determinism-resolute-openstack = pkgs.callPackage ./build/checks/disk-determinism.nix {
                artifact = resolute-stemcell-rootfs;
                file = "rootfs-staged.tar.gz";
              };
              rootfs-determinism-resolute-aws = pkgs.callPackage ./build/checks/disk-determinism.nix {
                artifact = resolute-stemcell-aws-rootfs;
                file = "rootfs-staged.tar.gz";
              };
              disk-determinism-resolute-openstack = pkgs.callPackage ./build/checks/disk-determinism.nix {
                artifact = resolute-stemcell-disk;
                file = "root.qcow2";
              };
              disk-determinism-resolute-aws = pkgs.callPackage ./build/checks/disk-determinism.nix {
                artifact = resolute-stemcell-aws-disk;
                file = "root.img";
              };
```

- [ ] **Step 3: Add Resolute packages**

In `flake.nix`, inside the `packages` `let` (lines 68–72), add two bindings after `aws = ...;`:

```nix
                resolute-openstack-kvm = pkgs.callPackage ./build/stemcells/openstack-kvm.nix { release = "resolute"; };
                resolute-aws = pkgs.callPackage ./build/stemcells/aws.nix { release = "resolute"; };
```

Then in the `packages` result attrset, immediately before `# Source-built components` (line 91), add:

```nix
                # PHASE 1/2 (Resolute)
                os-image-resolute = pkgs.callPackage ./build/rootfs/os-image.nix { release = "resolute"; };
                os-image-resolute-aws = pkgs.callPackage ./build/rootfs/os-image.nix {
                  infrastructure = "aws";
                  release = "resolute";
                };
                resolute-stemcell-rootfs = resolute-stemcell-rootfs;
                resolute-stemcell-disk = resolute-stemcell-disk;
                resolute-stemcell = resolute-openstack-kvm;
                resolute-openstack-kvm = resolute-openstack-kvm;
                resolute-stemcell-aws-rootfs = resolute-stemcell-aws-rootfs;
                resolute-stemcell-aws-disk = resolute-stemcell-aws-disk;
                resolute-stemcell-aws = resolute-aws;
                resolute-aws = resolute-aws;
```

- [ ] **Step 4: Update the flake description (cosmetic)**

Change line 2 from:
```nix
  description = "Nix POC: Ubuntu Noble BOSH stemcell (milestones M0-M1)";
```
to:
```nix
  description = "Nix: Ubuntu Noble + Resolute BOSH stemcell build matrix";
```

- [ ] **Step 5: Format, evaluate, and confirm Noble names unchanged**

Run:
```bash
nix fmt -- flake.nix
nix eval --impure --json .#packages.x86_64-linux --apply builtins.attrNames | tr ',' '\n'
```
Expected: attr list includes the original Noble names (`os-image`, `noble-rootfs`, `noble-stemcell`, `openstack-kvm`, `noble-stemcell-aws`, `aws`, etc.) AND the new `resolute-*` / `os-image-resolute*` names. No Noble name removed or renamed.

- [ ] **Step 6: Confirm Noble stemcell drvPaths are unchanged (byte-neutral)**

Run:
```bash
for a in openstack-kvm aws noble-stemcell-disk noble-stemcell-aws-disk; do
  nix eval --raw .#packages.x86_64-linux.$a.drvPath; echo " $a";
done
```
Expected: the four drvPaths match the Plan 1 values (`dz30qfx...` openstack-kvm, `qv93c0h...` aws, `z0j3sji...` noble-stemcell-disk, `n55p8an...` noble-stemcell-aws-disk). If any differ, a Noble binding was accidentally altered — revert and fix.

- [ ] **Step 7: Commit**

```bash
git add flake.nix
git commit -m "feat(resolute): emit resolute-* flake outputs and determinism checks"
```

---

## Task 5: Get the Resolute rootfs building (package-resolution loop)

**Context:** The Resolute rootfs is not yet *correct* (still uses Noble user assets, no pam/tmp.mount deltas) but it must *build*. This task surfaces any unresolved package names from the Resolute snapshot and fixes them in the descriptor.

**Files:**
- Modify (only if the build reports unresolved packages): `build/ubuntu/releases/resolute.nix`

- [ ] **Step 1: Build the Resolute openstack rootfs**

Run: `nix build -L .#packages.x86_64-linux.resolute-stemcell-rootfs`
Expected: SUCCESS.

If it FAILS with a message like `package 'X' not found in ...Packages` or `attribute 'X' missing` from the deb closure generator:
- The offending name `X` is not present in the Resolute snapshot indices.
- Confirm the correct Resolute name:
  ```bash
  ts=20260701T000000Z
  for c in main universe multiverse; do
    url="https://snapshot.ubuntu.com/ubuntu/$ts/dists/resolute/$c/binary-amd64/Packages.xz"
    f=$(nix-prefetch-url "$url" --print-path 2>/dev/null | tail -1)
    xzcat "$f" | grep -E '^Package: ' | grep -i "<stem-of-X>"
  done
  ```
- Edit the offending entry in `build/ubuntu/releases/resolute.nix` `boshPackages` to the resolved name, `git add`, and re-run the build. Repeat until green.

- [ ] **Step 2: Build the Resolute aws rootfs**

Run: `nix build -L .#packages.x86_64-linux.resolute-stemcell-aws-rootfs`
Expected: SUCCESS (same descriptor, so any fixes from Step 1 already apply).

- [ ] **Step 3: Confirm rootfs determinism (both infras)**

Run:
```bash
nix build -L .#checks.x86_64-linux.rootfs-determinism-resolute-openstack
nix build -L .#checks.x86_64-linux.rootfs-determinism-resolute-aws
```
Expected: both SUCCEED (byte-identical rebuild).

- [ ] **Step 4: Commit (only if the descriptor changed)**

```bash
git add build/ubuntu/releases/resolute.nix
git commit -m "fix(resolute): resolve package names against the resolute snapshot"
```
If no descriptor change was needed, skip the commit.

---

## Task 6: Per-release system-account assets for the `users` stage

**Context:** The `users` stage copies static `passwd/shadow/group/gshadow` asset bytes (the exact bytes the upstream spec asserts). Resolute's accounts differ substantially from Noble's (reassigned UIDs; no `_runit-log`; no `systemd-timesync`). Author Resolute assets from the authoritative upstream spec, and select the asset directory by release. Noble assets stay in place → byte-identical.

**Files:**
- Create: `build/stages/users/assets/resolute/passwd`
- Create: `build/stages/users/assets/resolute/group`
- Create: `build/stages/users/assets/resolute/gshadow`
- Create: `build/stages/users/assets/resolute/shadow`
- Modify: `build/stages/users/default.nix`
- Modify: `build/stages/users/apply.sh`
- Modify: `build/stages/default.nix` (thread `release` into the users stage)

- [ ] **Step 1: Generate passwd/group/gshadow from the upstream spec (exact bytes)**

The upstream heredocs are indented 8 spaces; strip exactly that indent. Run:

```bash
REF=/home/ruben/workspace/bosh-linux-stemcell-builder/bosh-stemcell/spec/os_image/ubuntu_spec.rb
mkdir -p build/stages/users/assets/resolute
sed -n '357,385p' "$REF" | sed 's/^        //' > build/stages/users/assets/resolute/passwd
sed -n '427,489p' "$REF" | sed 's/^        //' > build/stages/users/assets/resolute/group
sed -n '494,556p' "$REF" | sed 's/^        //' > build/stages/users/assets/resolute/gshadow
```

Verify no stray leading whitespace and sane first/last lines:
```bash
head -1 build/stages/users/assets/resolute/passwd   # -> root:x:0:0:root:/root:/bin/bash
tail -1 build/stages/users/assets/resolute/passwd   # -> vcap:x:1000:1000:BOSH System User:/home/vcap:/bin/bash
grep -c '^ ' build/stages/users/assets/resolute/passwd  # -> 0
tail -1 build/stages/users/assets/resolute/group    # -> bosh_sudoers:x:1002:
tail -1 build/stages/users/assets/resolute/gshadow  # -> bosh_sudoers:!::
grep -n '_runit-log\|systemd-timesync' build/stages/users/assets/resolute/*  # -> no matches
```
Expected: values as annotated; the last grep returns nothing.

- [ ] **Step 2: Write the Resolute shadow (constructed to satisfy the spec regex, lastchange 19000)**

The upstream `/etc/shadow` assertion is a regex (build-time day value). Author deterministic bytes with `lastchange = 19000` (matching the Noble convention) that satisfy spec lines 390–419. Create `build/stages/users/assets/resolute/shadow` with exactly:

```
root:*:19000:0:99999:7:::
daemon:*:19000:0:99999:7:::
bin:*:19000:0:99999:7:::
sys:*:19000:0:99999:7:::
sync:*:19000:0:99999:7:::
games:*:19000:0:99999:7:::
man:*:19000:0:99999:7:::
lp:*:19000:0:99999:7:::
mail:*:19000:0:99999:7:::
news:*:19000:0:99999:7:::
uucp:*:19000:0:99999:7:::
proxy:*:19000:0:99999:7:::
www-data:*:19000:0:99999:7:::
backup:*:19000:0:99999:7:::
list:*:19000:0:99999:7:::
irc:*:19000:0:99999:7:::
_apt:*:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
systemd-network:!*:19000:::::1:
dhcpcd:!*:19000:::::1:
messagebus:!*:19000::::::
syslog:!:19000::::::
systemd-resolve:!*:19000:::::1:
_chrony:!*:19000::::::
uuidd:!:19000::::::
sshd:!*:19000::::::
tcpdump:!*:19000:::::1:
polkitd:!*:19000::::::
vcap:*:19000:1:99999:7:::
```

- [ ] **Step 3: Validate the shadow against the upstream regex**

Run this Ruby one-liner (Ruby is available via the reference repo's toolchain; if not, skip to the build-time spec gate in Task 12):
```bash
REF=/home/ruben/workspace/bosh-linux-stemcell-builder/bosh-stemcell/spec/os_image/ubuntu_spec.rb
ruby -e '
  spec = File.read(ARGV[0])
  re_src = spec[/END_SHADOW\n(.*?)\n *END_SHADOW/m] ? nil : nil
  # Extract the heredoc body between shadow_match = Regexp.new <<~... and END_SHADOW
  body = spec[/Regexp\.new <<~.END_SHADOW., \[Regexp::MULTILINE\]\n(.*?)\n *END_SHADOW/m, 1]
  body = body.gsub(/^ {8}/, "")
  rx = Regexp.new(body, Regexp::MULTILINE)
  content = File.read(ARGV[1])
  puts(content.match?(rx) ? "SHADOW OK" : "SHADOW MISMATCH")
' "$REF" build/stages/users/assets/resolute/shadow
```
Expected: `SHADOW OK`. If `SHADOW MISMATCH`, compare each line to spec lines 390–419 and fix the offending field.

- [ ] **Step 4: Parameterize `users/default.nix` by release**

Replace the entire contents of `build/stages/users/default.nix` with:

```nix
# users stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session.
# ACCOUNTS_DIR selects the per-release passwd/shadow/group/gshadow asset set;
# Noble uses the top-level assets dir (byte-identical to before), Resolute uses
# assets/resolute. Shared assets (ps1) always come from STAGE_DIR.
{
  release ? "noble",
}:
let
  accountsDir = if release == "resolute" then "${./assets/resolute}" else "${./assets}";
in
{
  name = "users";
  script = ''
    export STAGE_DIR="${./assets}"
    export ACCOUNTS_DIR="${accountsDir}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
```

- [ ] **Step 5: Read account files from `ACCOUNTS_DIR` in `apply.sh`**

In `build/stages/users/apply.sh`, replace lines 13–17:

```bash
# /etc/group, /etc/gshadow, /etc/passwd, /etc/shadow — exact bytes.
cp "$STAGE_DIR"/group "$root/etc/group"
cp "$STAGE_DIR"/gshadow "$root/etc/gshadow"
cp "$STAGE_DIR"/passwd "$root/etc/passwd"
cp "$STAGE_DIR"/shadow "$root/etc/shadow"
```

with (note the added `# shellcheck disable=SC2154` since `ACCOUNTS_DIR` is injected by default.nix):

```bash
# /etc/group, /etc/gshadow, /etc/passwd, /etc/shadow — exact bytes, per-release.
# shellcheck disable=SC2154
cp "$ACCOUNTS_DIR"/group "$root/etc/group"
cp "$ACCOUNTS_DIR"/gshadow "$root/etc/gshadow"
cp "$ACCOUNTS_DIR"/passwd "$root/etc/passwd"
cp "$ACCOUNTS_DIR"/shadow "$root/etc/shadow"
```

- [ ] **Step 6: Thread `release` into the users stage from `stages/default.nix`**

In `build/stages/default.nix`, change:
```nix
  (import ./users { })
```
to:
```nix
  (import ./users { inherit release; })
```

- [ ] **Step 7: Verify Noble users output is byte-identical (drvPath gate)**

Run:
```bash
git add build/stages/users flake.nix build/stages/default.nix
nix eval --raw .#packages.x86_64-linux.noble-stemcell-rootfs.drvPath
```
Expected: matches the value observed at the end of Task 4 for `noble-stemcell-rootfs` (Noble rootfs drvPath unchanged). Because `accountsDir` for `noble` resolves to `${./assets}` and `apply.sh` reads the same bytes, the Noble rootfs derivation must be unchanged.

If the drvPath changed: the `${./assets}` string path or `apply.sh` byte content diverged. Diff against HEAD and restore exact Noble behavior.

- [ ] **Step 8: Build the Resolute rootfs and confirm the correct accounts landed**

Run:
```bash
nix build -L .#packages.x86_64-linux.resolute-stemcell-rootfs -o /tmp/res-rootfs
tar -xzf /tmp/res-rootfs/rootfs-staged.tar.gz -C /tmp --wildcards './etc/passwd' './etc/group' './etc/gshadow' 2>/dev/null || \
  tar -xzf /tmp/res-rootfs/rootfs-staged.tar.gz -C /tmp etc/passwd etc/group etc/gshadow
diff <(sed -n '357,385p' /home/ruben/workspace/bosh-linux-stemcell-builder/bosh-stemcell/spec/os_image/ubuntu_spec.rb | sed 's/^        //') /tmp/etc/passwd
```
Expected: empty diff (Resolute rootfs `/etc/passwd` matches the upstream spec exactly). No `_runit-log`, no `systemd-timesync`.

- [ ] **Step 9: Commit**

```bash
git add build/stages/users build/stages/default.nix
git commit -m "feat(resolute): per-release system-account assets in the users stage"
```

---

## Task 7: pam_lastlog2 mode in the `sudoers-pam` stage

**Context:** Noble emits a *commented* pam_lastlog2 placeholder (`features.pamLastlog2 = "hack"`). Resolute installs `libpam-lastlog2` and must emit an *active* line plus a multiarch symlink bridge (`features.pamLastlog2 = "package"`), matching upstream `password_policies` and the spec assertion at line 202.

**Files:**
- Modify: `build/stages/sudoers-pam/default.nix`
- Modify: `build/stages/sudoers-pam/apply.sh`
- Modify: `build/stages/default.nix` (pass `pamLastlog2` to the stage)

- [ ] **Step 1: Parameterize `sudoers-pam/default.nix`**

Replace the entire contents of `build/stages/sudoers-pam/default.nix` with:

```nix
# sudoers-pam stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session.
# PAM_LASTLOG2 selects how the pam_lastlog2 line is emitted:
#   "hack"    -> Noble: a commented placeholder (util-linux < 2.40 lacks the module)
#   "package" -> Resolute: an active line + multiarch securedir symlink bridge
{
  pamLastlog2 ? "hack",
}:
{
  name = "sudoers-pam";
  script = ''
    export STAGE_DIR="${./assets}"
    export PAM_LASTLOG2="${pamLastlog2}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
```

- [ ] **Step 2: Branch the pam_lastlog2 emission in `apply.sh`**

In `build/stages/sudoers-pam/apply.sh`, replace lines 42–43:

```bash
# Add pam_lastlog2.so comment line
sed -i '/# end of pam-auth-update config/i #session\toptional\t\t\tpam_lastlog2.so showfailed #NOBLE_TODO: this will only work if util-linux =>2.40 which provide pam_lastlog2.so or if users will install it manually' "$root/etc/pam.d/common-password"
```

with:

```bash
# Add pam_lastlog2.so line. Mode is selected by PAM_LASTLOG2 (injected by
# sudoers-pam/default.nix from the release descriptor's features.pamLastlog2).
# shellcheck disable=SC2154
if [ "$PAM_LASTLOG2" = "package" ]; then
  # Resolute: libpam-lastlog2 is installed -> emit an ACTIVE line.
  sed -i '/# end of pam-auth-update config/i session\toptional\t\t\tpam_lastlog2.so showfailed' "$root/etc/pam.d/common-password"
  # libpam-lastlog2 installs pam_lastlog2.so only under the multiarch securedir
  # (/usr/lib/x86_64-linux-gnu/security). PAM also searches /usr/lib/security;
  # bridge the two so the module loads.
  if [ -f "$root/usr/lib/x86_64-linux-gnu/security/pam_lastlog2.so" ] && \
     [ ! -e "$root/usr/lib/security/pam_lastlog2.so" ]; then
    mkdir -p "$root/usr/lib/security"
    ln -sf /usr/lib/x86_64-linux-gnu/security/pam_lastlog2.so "$root/usr/lib/security/pam_lastlog2.so"
  fi
else
  # Noble: util-linux < 2.40 lacks pam_lastlog2.so -> emit a commented placeholder.
  sed -i '/# end of pam-auth-update config/i #session\toptional\t\t\tpam_lastlog2.so showfailed #NOBLE_TODO: this will only work if util-linux =>2.40 which provide pam_lastlog2.so or if users will install it manually' "$root/etc/pam.d/common-password"
fi
```

- [ ] **Step 3: Pass `pamLastlog2` from `stages/default.nix`**

In `build/stages/default.nix`, change:
```nix
  (import ./sudoers-pam { })
```
to:
```nix
  (import ./sudoers-pam { pamLastlog2 = releaseDesc.features.pamLastlog2; })
```

- [ ] **Step 4: Verify Noble output byte-identical (drvPath gate)**

Run:
```bash
git add build/stages/sudoers-pam build/stages/default.nix
nix eval --raw .#packages.x86_64-linux.noble-stemcell-rootfs.drvPath
```
Expected: unchanged from Task 6 Step 7 (Noble takes the `else` branch, emitting the exact same commented line as before). If changed, the Noble branch bytes diverged — restore.

- [ ] **Step 5: Verify the Resolute rootfs emits the active line**

Run:
```bash
nix build -L .#packages.x86_64-linux.resolute-stemcell-rootfs -o /tmp/res-rootfs
tar -xzf /tmp/res-rootfs/rootfs-staged.tar.gz -C /tmp etc/pam.d/common-password
grep -nE '^session\toptional\t\t\tpam_lastlog2\.so showfailed' /tmp/etc/pam.d/common-password
```
Expected: one match (active, uncommented line present).

- [ ] **Step 6: Commit**

```bash
git add build/stages/sudoers-pam build/stages/default.nix
git commit -m "feat(resolute): emit active pam_lastlog2 line + securedir bridge"
```

---

## Task 8: Mask `tmp.mount` for Resolute (systemd 259)

**Context:** systemd 259 (Resolute) ships a static `tmp.mount` that mounts `/tmp` as tmpfs; BOSH sizes `/tmp` itself, so the unit must be masked (symlink to `/dev/null`). Spec lines 580–587. Noble (systemd 255) has no such unit and must not be affected.

**Files:**
- Modify: `build/stages/systemd-services/default.nix`
- Modify: `build/stages/systemd-services/apply.sh`
- Modify: `build/stages/default.nix` (pass a flag to the stage)

- [ ] **Step 1: Read the current systemd-services default.nix**

Run: `cat build/stages/systemd-services/default.nix`
Note how `STAGE_DIR` is exported (mirror that style in Step 2).

- [ ] **Step 2: Add a `maskTmpMount` flag to `systemd-services/default.nix`**

Edit `build/stages/systemd-services/default.nix` to accept `maskTmpMount ? false` and export it. Concretely, change the parameter header `{ }:` (or existing params) to include `maskTmpMount ? false,` and add to the `script` (alongside the existing `export STAGE_DIR=...`):

```nix
    export MASK_TMP_MOUNT="${if maskTmpMount then "1" else "0"}"
```

(Keep every existing line of the stage intact; only add the param and the one export.)

- [ ] **Step 3: Mask tmp.mount in `systemd-services/apply.sh`**

Append to the end of `build/stages/systemd-services/apply.sh`:

```bash
# tmp.mount masking (Resolute / systemd 259). BOSH manages /tmp as a tmpfs of
# its own size; mask systemd's static tmp.mount so it cannot override that.
# shellcheck disable=SC2154
if [ "$MASK_TMP_MOUNT" = "1" ]; then
  mkdir -p "$root/etc/systemd/system"
  ln -sf /dev/null "$root/etc/systemd/system/tmp.mount"
fi
```

- [ ] **Step 4: Pass the flag from `stages/default.nix`**

In `build/stages/default.nix`, change:
```nix
  (import ./systemd-services { })
```
to:
```nix
  (import ./systemd-services { maskTmpMount = !releaseDesc.features.runit; })
```

(`features.runit == false` uniquely identifies Resolute here; this avoids adding another descriptor field. Add a `maskTmpMount` feature later if a release needs the two to diverge.)

- [ ] **Step 5: Verify Noble unchanged (drvPath gate)**

Run:
```bash
git add build/stages/systemd-services build/stages/default.nix
nix eval --raw .#packages.x86_64-linux.noble-stemcell-rootfs.drvPath
```
Expected: unchanged from Task 7 Step 4 (Noble has `runit = true` → `maskTmpMount = false` → `MASK_TMP_MOUNT=0`, the new block is a no-op, and the appended text must not alter existing behavior). If changed, review the appended bytes.

- [ ] **Step 6: Verify Resolute masks tmp.mount**

Run:
```bash
nix build -L .#packages.x86_64-linux.resolute-stemcell-rootfs -o /tmp/res-rootfs
tar -tzf /tmp/res-rootfs/rootfs-staged.tar.gz | grep -E 'etc/systemd/system/tmp.mount'
```
Expected: the entry `./etc/systemd/system/tmp.mount` (a symlink to `/dev/null`) is present.

- [ ] **Step 7: Commit**

```bash
git add build/stages/systemd-services build/stages/default.nix
git commit -m "feat(resolute): mask systemd 259 tmp.mount"
```

---

## Task 9: Build all four Resolute cells + packaged stemcells

**Files:** none (build only)

- [ ] **Step 1: Build both packaged Resolute stemcells**

Run:
```bash
nix build -L .#packages.x86_64-linux.resolute-stemcell     -o /tmp/res-openstack
nix build -L .#packages.x86_64-linux.resolute-stemcell-aws -o /tmp/res-aws
ls -l /tmp/res-openstack/*.tgz /tmp/res-aws/*.tgz
```
Expected: both SUCCEED; each contains a `bosh-stemcell-*-ubuntu-resolute.tgz`.

- [ ] **Step 2: Inspect the packaged manifests**

Run:
```bash
tar -xzOf /tmp/res-openstack/*.tgz stemcell.MF
tar -xzOf /tmp/res-aws/*.tgz stemcell.MF
```
Expected: `operating_system: ubuntu-resolute`, `version` present, and the correct `cloud_properties` per infra (openstack: qcow2/kvm; aws: raw/xen with `root_device_name`/`boot_mode`).

- [ ] **Step 3: Commit (none — build verification only)**

No commit.

---

## Task 10: Full determinism + Noble byte-regression gate

**Files:** none (verification only)

- [ ] **Step 1: Run the full flake check (all cells)**

Run: `nix flake check -L`
Expected: `all checks passed!` — now 9 checks (Noble ×4, Resolute ×4, treefmt) plus any others. Determinism for both Resolute rootfs and disk (openstack + aws) must pass.

- [ ] **Step 2: Confirm all six Noble artifacts are byte-identical to the Plan 1 baseline**

Run:
```bash
nix build -L .#packages.x86_64-linux.noble-stemcell-rootfs     -o /tmp/n-rootfs
nix build -L .#packages.x86_64-linux.noble-stemcell-aws-rootfs -o /tmp/n-aws-rootfs
nix build -L .#packages.x86_64-linux.noble-stemcell-disk       -o /tmp/n-disk
nix build -L .#packages.x86_64-linux.noble-stemcell-aws-disk   -o /tmp/n-aws-disk
nix build -L .#packages.x86_64-linux.noble-stemcell            -o /tmp/n-pkg
nix build -L .#packages.x86_64-linux.noble-stemcell-aws        -o /tmp/n-aws-pkg
sha256sum \
  /tmp/n-rootfs/rootfs-staged.tar.gz \
  /tmp/n-aws-rootfs/rootfs-staged.tar.gz \
  /tmp/n-disk/root.qcow2 \
  /tmp/n-aws-disk/root.img \
  /tmp/n-pkg/*.tgz \
  /tmp/n-aws-pkg/*.tgz
cat docs/plans/baseline-hashes.txt
```
Expected: each sha256 matches the corresponding baseline value:
`06ac48e8…` (openstack rootfs), `33e867b0…` (aws rootfs), `40102976…` (root.qcow2), `0bbf70b1…` (root.img), `191611d1…` (openstack tgz), `e35db3de…` (aws tgz).
If any Noble hash differs, STOP — a Resolute change leaked into the Noble path; bisect via drvPath and fix before proceeding.

- [ ] **Step 3: Commit (none — verification only)**

No commit.

---

## Task 11: Port the upstream os_image assertions into a Resolute gate

**Context:** Lock the Resolute rootfs identity with an automated check mirroring the upstream `ubuntu_spec.rb` assertions (accounts, runit absence, tmp.mount, pam active line). This is the agent-executable stand-in for the upstream RSpec suite.

**Files:**
- Create: `build/checks/resolute-os-image-spec.sh`
- Modify: `flake.nix` (add a `resolute-os-image-spec` check)

- [ ] **Step 1: Write the assertion script**

Create `build/checks/resolute-os-image-spec.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Verify the Resolute rootfs matches the upstream os_image spec assertions.
# Usage: resolute-os-image-spec.sh <rootfs-staged.tar.gz> <ref-spec-file>
tarball="$1"
spec="$2"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

tar -xzf "$tarball" -C "$work" \
  etc/passwd etc/group etc/gshadow etc/pam.d/common-password 2>/dev/null || \
tar -xzf "$tarball" -C "$work" \
  ./etc/passwd ./etc/group ./etc/gshadow ./etc/pam.d/common-password

fail=0

check_eql() {
  local label="$1" want="$2" got="$3"
  if diff -u <(printf '%s' "$want") <(printf '%s' "$got") >/tmp/spec-diff 2>&1; then
    echo "OK   $label"
  else
    echo "FAIL $label"; cat /tmp/spec-diff; fail=1
  fi
}

want_passwd="$(sed -n '357,385p' "$spec" | sed 's/^        //')"
want_group="$(sed -n '427,489p' "$spec" | sed 's/^        //')"
want_gshadow="$(sed -n '494,556p' "$spec" | sed 's/^        //')"

check_eql "/etc/passwd"  "$want_passwd"  "$(cat "$work/etc/passwd")"
check_eql "/etc/group"   "$want_group"   "$(cat "$work/etc/group")"
check_eql "/etc/gshadow" "$want_gshadow" "$(cat "$work/etc/gshadow")"

if grep -qE '^session\toptional\t\t\tpam_lastlog2\.so showfailed' "$work/etc/pam.d/common-password"; then
  echo "OK   pam_lastlog2 active line"
else
  echo "FAIL pam_lastlog2 active line missing"; fail=1
fi

if grep -qE '(^|:)_runit-log(:|$)' "$work/etc/passwd" "$work/etc/group"; then
  echo "FAIL _runit-log present (runit should be removed)"; fail=1
else
  echo "OK   _runit-log absent"
fi

exit "$fail"
```

- [ ] **Step 2: Run it locally against the built rootfs**

Run:
```bash
chmod +x build/checks/resolute-os-image-spec.sh
nix build -L .#packages.x86_64-linux.resolute-stemcell-rootfs -o /tmp/res-rootfs
build/checks/resolute-os-image-spec.sh \
  /tmp/res-rootfs/rootfs-staged.tar.gz \
  /home/ruben/workspace/bosh-linux-stemcell-builder/bosh-stemcell/spec/os_image/ubuntu_spec.rb
```
Expected: all lines `OK`, exit 0. Fix any `FAIL` before continuing.

- [ ] **Step 3 (optional): Wire as a flake check**

If you want it enforced by `nix flake check`, add a derivation-based check. Because the check needs the reference spec file (outside the flake), embed the four expected blobs into the check derivation instead. Minimal approach: add to `flake.nix` `checks`:

```nix
              resolute-os-image-spec = pkgs.runCommand "resolute-os-image-spec" { } ''
                tar -xzf ${resolute-stemcell-rootfs}/rootfs-staged.tar.gz -C . ./etc/passwd ./etc/group ./etc/gshadow ./etc/pam.d/common-password
                grep -qE '^session\toptional\t\t\tpam_lastlog2\.so showfailed' ./etc/pam.d/common-password
                ! grep -qE '(^|:)_runit-log(:|$)' ./etc/passwd ./etc/group
                grep -q '^vcap:x:1000:1000:BOSH System User:/home/vcap:/bin/bash$' ./etc/passwd
                ! grep -q 'systemd-timesync' ./etc/passwd
                touch $out
              '';
```

Run: `git add build/checks/resolute-os-image-spec.sh flake.nix && nix build -L .#checks.x86_64-linux.resolute-os-image-spec`
Expected: SUCCESS.

- [ ] **Step 4: Commit**

```bash
git add build/checks/resolute-os-image-spec.sh flake.nix
git commit -m "test(resolute): gate rootfs identity against upstream os_image spec"
```

---

## Task 12: Boot-validate the Resolute OpenStack disk in QEMU

**Context:** Mirror the Noble Phase 4 boot test. This confirms the Resolute disk boots to multi-user and the bosh-agent unit is present.

**Files:** none (manual validation; record result)

- [ ] **Step 1: Build the disk and enter the boot devshell**

Run:
```bash
nix build -L .#packages.x86_64-linux.resolute-stemcell-disk -o /tmp/res-disk
nix develop .#default --command bash -c 'echo OVMF_FD=$OVMF_FD; ls -l /tmp/res-disk/root.qcow2'
```
Expected: disk built; `OVMF_FD` points to an OVMF firmware file.

- [ ] **Step 2: Boot headless and capture the serial console**

Run (inside `nix develop .#default`):
```bash
cp /tmp/res-disk/root.qcow2 /tmp/res-boot.qcow2 && chmod u+w /tmp/res-boot.qcow2
timeout 180 qemu-system-x86_64 \
  -m 2048 -smp 2 -nographic \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_FD" \
  -drive file=/tmp/res-boot.qcow2,format=qcow2,if=virtio \
  -serial mon:stdio 2>&1 | tee /tmp/res-boot.log || true
grep -iE 'systemd .* running|Reached target|login:' /tmp/res-boot.log | head
```
Expected: evidence of systemd reaching a running/multi-user target (e.g. `Reached target … Multi-User` or a `login:` prompt). Kernel panic or dracut emergency shell = FAIL.

- [ ] **Step 3: Record the result**

Append a short PASS/FAIL note (with the matched log line) to `docs/plans/resolute-boot-validation.txt`.

Run:
```bash
git add docs/plans/resolute-boot-validation.txt
git commit -m "test(resolute): record QEMU boot validation result"
```

---

## Task 13: Operator BOSH deploy runbook (documentation)

**Context:** Full BOSH director deploy is operator-run, not agent-executable. Provide a runbook so an operator can validate the Resolute stemcell end-to-end.

**Files:**
- Create: `docs/runbooks/resolute-bosh-deploy.md`

- [ ] **Step 1: Write the runbook**

Create `docs/runbooks/resolute-bosh-deploy.md` documenting:
- Building the stemcell tarball: `nix build .#packages.x86_64-linux.resolute-stemcell` (openstack) / `resolute-stemcell-aws`.
- `bosh upload-stemcell /tmp/res-openstack/*.tgz`.
- Deploying a smoke manifest (e.g. a single-instance `bosh -d smoke deploy`) pinned to `stemcell: { os: ubuntu-resolute, version: latest }`.
- Post-deploy checks: `bosh instances --ps` (agent responsive, monit up), `bosh ssh` then `systemctl is-system-running`, `lastlog2` availability (`pam_lastlog2` active), and confirm `runit`/`chpst` are absent (`! command -v chpst`).
- Rollback note: prior Noble stemcell remains available and unchanged.

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/resolute-bosh-deploy.md
git commit -m "docs(resolute): operator BOSH deploy runbook"
```

---

## Task 14: Final review, formatting, and docs update

**Files:**
- Modify: `docs/specs/2026-07-17-multi-release-infra-matrix-design.md` (status → implemented)

- [ ] **Step 1: Format the whole tree**

Run: `nix fmt`
Expected: no changes (or only intended reformatting). Re-stage if anything changed.

- [ ] **Step 2: Full check once more**

Run: `nix flake check -L`
Expected: `all checks passed!`.

- [ ] **Step 3: Mark the design spec implemented**

In `docs/specs/2026-07-17-multi-release-infra-matrix-design.md`, change `Status: Approved design, pending implementation` to `Status: Implemented (Noble Plan 1 + Resolute Plan 2)`.

- [ ] **Step 4: Commit**

```bash
git add docs/specs/2026-07-17-multi-release-infra-matrix-design.md
git commit -m "docs: mark multi-release matrix design implemented"
```

---

## Self-Review Checklist (run before handoff)

- [ ] **Spec coverage:** release descriptor (Task 1–2), threading fix (Task 3), flake product (Task 4), package resolution (Task 5), runit removal via absent package + accounts (Task 1/6), pam_lastlog2 package mode (Task 7), tmp.mount/systemd-259 (Task 8), determinism + Noble regression (Task 10), boot validation (Task 12), operator deploy (Task 13). Netplan purge / resolvconf-update units already covered by existing Noble stages (no new task needed) — confirm during Task 11 that `/etc/systemd/system` has no netplan artifacts if a stricter gate is desired.
- [ ] **Byte-identity:** Noble drvPath/hash gates appear after every stage change (Tasks 4,6,7,8) and a final six-artifact hash comparison (Task 10).
- [ ] **No placeholders:** snapshot + hashes are real; account bytes are generated from the exact upstream spec lines; package deltas are enumerated.
- [ ] **Type/name consistency:** `features.pamLastlog2` values `"hack"|"package"`; `features.runit` boolean; env vars `ACCOUNTS_DIR`, `PAM_LASTLOG2`, `MASK_TMP_MOUNT`; flake names `resolute-stemcell{,-aws}{,-disk,-rootfs}`, `resolute-openstack-kvm`, `resolute-aws`, `os-image-resolute{,-aws}`.
```
