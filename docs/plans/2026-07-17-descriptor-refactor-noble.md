# Descriptor Refactor (Data-Only Release + Infrastructure Axes) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the Noble-only stemcell builder so that release specifics and infrastructure specifics are expressed as pure-data descriptor modules threaded through the build, WITHOUT changing any built bytes.

**Architecture:** Introduce two descriptor axes — `build/ubuntu/releases/*.nix` (release) and `build/infra/*.nix` (infrastructure) — each with a selector. Every existing entry point gains a `release ? "noble"` / `infrastructure ? "openstack"` default and resolves values from the descriptors instead of hardcoding them. `flake.nix` is untouched: because all defaults are Noble/OpenStack, the existing outputs continue to build byte-identically. This lands the abstraction that a follow-up plan uses to add Ubuntu Resolute.

**Tech Stack:** Nix (flake-parts, nixpkgs vmTools), Bash stage scripts, `nix eval` / `nix build --rebuild` for verification.

**Design reference:** `docs/specs/2026-07-17-multi-release-infra-matrix-design.md`

---

## Guiding Constraint: Byte-for-Byte Preservation

This is a **refactor**, not a behavior change. Every task must leave the built
artifacts bit-identical to the pre-refactor baseline. The regression oracle is a
set of `nix eval` snapshots (fast, data-level) plus `nix build --rebuild` output
hashes (slow, byte-level) captured in Task 1 BEFORE any change.

- Use `nix eval` snapshots as the fast unit test after each data extraction.
- Reserve full `nix build` hash comparison for the phase-boundary gates
  (Task 8 and Task 15).

Commit after every task.

## File Structure

New files:
- `build/ubuntu/releases/noble.nix` — Noble release descriptor (pure data)
- `build/ubuntu/release.nix` — release selector (`release ? "noble"`)
- `build/infra/openstack.nix` — OpenStack infrastructure descriptor
- `build/infra/aws.nix` — AWS infrastructure descriptor
- `build/infra/default.nix` — infrastructure selector (`infrastructure ? "openstack"`)

Modified files:
- `build/ubuntu/apt-pins.nix` — consume release descriptor
- `build/ubuntu/deb-sets.nix` — consume `descriptor.boshPackages`
- `build/rootfs/rootfs.nix` — thread `release`
- `build/rootfs/os-image.nix` — thread `release` (+ existing `infrastructure`)
- `build/rootfs/apply-stages.nix` — template SPDX from `osVersion`
- `build/stages/default.nix` — select `infraStageNames` from infra descriptor; pass `codename` to misc-os
- `build/stages/misc-os/default.nix` — accept `codename`
- `build/stages/misc-os/apply.sh` — generate `sources.list` from `$CODENAME`
- `build/stages/misc-os/assets/sources.list` — deleted (replaced by generation)
- `build/stemcells/package.nix` — consume infra + release descriptors
- `build/stemcells/openstack-kvm.nix`, `aws.nix` — thread `release`
- `build/stemcells/openstack-kvm-disk.nix`, `aws-disk.nix` — thread `release`
- `build/stemcells/openstack-kvm-rootfs.nix`, `aws-rootfs.nix` — thread `release`

`flake.nix` is intentionally NOT modified in this plan.

---

## Phase A — Release Descriptor

### Task 1: Capture the regression baseline

**Files:**
- Create: `docs/plans/baseline-hashes.txt`, `docs/plans/baseline-image.json`

- [ ] **Step 1: Capture the assembled image package list (the data oracle for Task 5)**

```bash
cd /home/ruben/workspace/bosh-nix-linux-stemcell-builder
nix eval --json --impure \
  --expr '((import <nixpkgs> {}).callPackage ./build/ubuntu/deb-sets.nix {}).image' \
  | jq -S . > docs/plans/baseline-image.json
wc -l docs/plans/baseline-image.json
```
Expected: a sorted JSON array of package names written to the file.

- [ ] **Step 2: Capture byte-level baseline hashes for all four cells**

```bash
for out in noble-stemcell-rootfs noble-stemcell-aws-rootfs noble-stemcell-disk noble-stemcell-aws-disk; do
  nix build ".#${out}" --no-link --print-out-paths
done | while read -r p; do
  find "$p" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name 'root.*' \) -print0 \
    | xargs -0 sha256sum
done | tee -a docs/plans/baseline-hashes.txt
```

Also capture the packaged stemcell hashes:

```bash
for out in openstack-kvm aws; do
  p=$(nix build ".#${out}" --no-link --print-out-paths)
  sha256sum "$p"/*.tgz
done | tee -a docs/plans/baseline-hashes.txt
```

- [ ] **Step 3: Record the baseline eval values that the descriptors must reproduce**

```bash
{
  echo "== apt-pins name =="; nix eval --raw --impure --expr '((import <nixpkgs> {}).callPackage ./build/ubuntu/apt-pins.nix {}).name'
  echo; echo "== apt-pins fullName =="; nix eval --raw --impure --expr '((import <nixpkgs> {}).callPackage ./build/ubuntu/apt-pins.nix {}).fullName'
  echo; echo "== apt-pins urlPrefix =="; nix eval --raw --impure --expr '((import <nixpkgs> {}).callPackage ./build/ubuntu/apt-pins.nix {}).urlPrefix'
} | tee -a docs/plans/baseline-hashes.txt
```

- [ ] **Step 4: Commit the baseline record**

```bash
git add docs/plans/baseline-hashes.txt docs/plans/baseline-image.json
git commit -m "test: capture pre-refactor byte + data baseline"
```

Expected: baseline files contain sha256 lines for 4 disk/rootfs artifacts, 2
tgz artifacts, the sorted image package list, and the apt-pins identity strings.

---

### Task 2: Create the Noble release descriptor

**Files:**
- Create: `build/ubuntu/releases/noble.nix`

- [ ] **Step 1: Write the descriptor with values transcribed verbatim from the current sources**

The `boshPackages` list is copied EXACTLY from `build/ubuntu/deb-sets.nix`'s
`bosh` list (lines 69-142). The hashes/codename/snapshot come from
`build/ubuntu/apt-pins.nix`.

```nix
# Ubuntu Noble (24.04) release descriptor. Pure data consumed by
# build/ubuntu/release.nix. Values transcribed verbatim from the previous
# hardcoded apt-pins.nix + deb-sets.nix so the build stays byte-identical.
{
  release = "noble";
  codename = "noble";
  osVersion = "noble";
  version = "24.04";
  name = "ubuntu-24.04-noble-amd64";
  fullName = "Ubuntu 24.04 Noble (amd64)";

  # PER-RELEASE snapshot pin (snapshot.ubuntu.com timestamp).
  snapshot = "20260101T000000Z";

  # sha256 of each Packages.xz at the snapshot above. Order-free named set.
  packagesListHashes = {
    main = "0l94v46rh8q3m8maim1xq2qkagwrjkalcrilrdww599i22g1jsia";
    universe = "16jr0mj275yzaii4khfh07hryf451k80hs6jl748qhwi3gx5g45s";
    multiverse = "1sjh2wzbwvrxz098l6625igxb0lcdpkm4v9azhmvfjl6w07ld040";
  };

  # Behavioral toggles consumed by stages (Resolute flips these in a later plan).
  # Noble values reproduce current behavior.
  features = {
    runit = true;
    pamLastlog2 = "hack";
  };

  # Authoritative BOSH package set (was deb-sets.nix `bosh`).
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
    "rng-tools"
    "libxml2"
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
    "traceroute"
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
    "mg"
    "htop"
    "module-assistant"
    "debhelper"
    "runit"
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
    "gpg-agent"
    "libcurl4"
    "libcurl4-openssl-dev"
    "resolvconf"
    "net-tools"
    "ifupdown"
    "rsyslog"
    "rsyslog-gnutls"
    "rsyslog-openssl"
    "rsyslog-relp"
    "auditd"
    "sudo"
    "cron"
    "systemd-timesyncd"
    "grub2"
    "zlib1g-dev"
    "build-essential"
  ];
}
```

- [ ] **Step 2: Verify it evaluates and matches the baseline package list**

```bash
nix eval --json --impure --expr '(import ./build/ubuntu/releases/noble.nix).boshPackages'
```
Expected: JSON array identical (same order) to the `bosh` list in the pre-refactor `deb-sets.nix`.

- [ ] **Step 3: Commit**

```bash
git add build/ubuntu/releases/noble.nix
git commit -m "feat: add Noble release descriptor (pure data)"
```

---

### Task 3: Create the release selector

**Files:**
- Create: `build/ubuntu/release.nix`

- [ ] **Step 1: Write the selector**

```nix
# Release selector. Returns the pure-data descriptor for the requested release.
# Defaults to noble so every existing call site is unchanged.
{ release ? "noble" }:
let
  registry = {
    noble = import ./releases/noble.nix;
    # resolute added in a later plan
  };
in
if registry ? ${release} then
  registry.${release}
else
  throw "build/ubuntu/release.nix: unknown release '${release}' (known: ${builtins.concatStringsSep ", " (builtins.attrNames registry)})";
```

- [ ] **Step 2: Verify default + error path**

```bash
nix eval --raw --expr '(import ./build/ubuntu/release.nix { }).codename'
```
Expected: `noble`

```bash
nix eval --expr '(import ./build/ubuntu/release.nix { release = "bogus"; })' 2>&1 | grep -q "unknown release 'bogus'" && echo OK
```
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add build/ubuntu/release.nix
git commit -m "feat: add release selector defaulting to noble"
```

---

### Task 4: Refactor apt-pins.nix to consume the descriptor

**Files:**
- Modify: `build/ubuntu/apt-pins.nix`

- [ ] **Step 1: Replace the hardcoded body with descriptor-driven values**

```nix
# Pinned Ubuntu APT coordinates + Packages.xz indices for makeImageFromDebDist.
# Coordinates (codename, snapshot, index hashes, names) now come from the
# per-release descriptor via release.nix; defaults to noble so the pinned
# snapshot and indices are byte-identical to before.
{
  fetchurl,
  release ? "noble",
}:
let
  desc = import ./release.nix { inherit release; };
  urlPrefix = "https://snapshot.ubuntu.com/ubuntu/${desc.snapshot}";
  indexUrl = component: "${urlPrefix}/dists/${desc.codename}/${component}/binary-amd64/Packages.xz";
  fetchIndex =
    component: sha256:
    fetchurl {
      url = indexUrl component;
      inherit sha256;
    };
in
{
  inherit (desc) name fullName;
  inherit urlPrefix;

  packagesLists = [
    (fetchIndex "main" desc.packagesListHashes.main)
    (fetchIndex "universe" desc.packagesListHashes.universe)
    (fetchIndex "multiverse" desc.packagesListHashes.multiverse)
  ];
}
```

- [ ] **Step 2: Verify identity strings match the baseline**

```bash
nix eval --raw --impure --expr '((import <nixpkgs> {}).callPackage ./build/ubuntu/apt-pins.nix {}).urlPrefix'
```
Expected: `https://snapshot.ubuntu.com/ubuntu/20260101T000000Z` (matches Task 1 Step 3 baseline).

```bash
nix eval --raw --impure --expr '((import <nixpkgs> {}).callPackage ./build/ubuntu/apt-pins.nix {}).name'
```
Expected: `ubuntu-24.04-noble-amd64`

- [ ] **Step 3: Verify the fetched index derivations are unchanged**

```bash
nix eval --raw --impure --expr 'toString (builtins.head ((import <nixpkgs> {}).callPackage ./build/ubuntu/apt-pins.nix {}).packagesLists)'
```
Expected: a `/nix/store/...-Packages.xz` path (drv resolves; hash unchanged means the store path base is identical to a pre-refactor build).

- [ ] **Step 4: Commit**

```bash
git add build/ubuntu/apt-pins.nix
git commit -m "refactor: drive apt-pins from release descriptor"
```

---

### Task 5: Refactor deb-sets.nix to consume `boshPackages`

**Files:**
- Modify: `build/ubuntu/deb-sets.nix`

- [ ] **Step 1: Replace the inline `bosh` list with the descriptor's `boshPackages`**

Remove the entire literal `bosh = [ ... ];` binding (lines ~68-142) and add the
`release` param + descriptor lookup. Keep `base`, `dropFromBase`,
`bootEssentials` exactly as they are (they are release-shared for now).

Change the function head from:
```nix
{ lib, callPackage }:
```
to:
```nix
{
  lib,
  callPackage,
  release ? "noble",
}:
```

Add near the top of the `let` block (after `essential = ...;`):
```nix
  desc = import ./release.nix { inherit release; };
  bosh = desc.boshPackages;
```

Delete the old `bosh = [ ... ];` literal. Leave the `in { inherit base
dropFromBase bootEssentials bosh; image = ...; }` block unchanged.

- [ ] **Step 2: Verify the assembled image list is byte-identical to baseline**

```bash
nix eval --json --impure --expr '((import <nixpkgs> {}).callPackage ./build/ubuntu/deb-sets.nix {}).image' \
  | jq -S . > /tmp/image-after.json
diff /tmp/image-after.json docs/plans/baseline-image.json && echo IDENTICAL
```
Expected: `IDENTICAL` (compares against the sorted oracle captured in Task 1 Step 1).

- [ ] **Step 3: Commit**

```bash
git add build/ubuntu/deb-sets.nix
git commit -m "refactor: source bosh package set from release descriptor"
```

---

### Task 6: Thread `release` through rootfs.nix and os-image.nix

**Files:**
- Modify: `build/rootfs/rootfs.nix`
- Modify: `build/rootfs/os-image.nix`

- [ ] **Step 1: Add `release` to rootfs.nix and pass it down**

Replace `build/rootfs/rootfs.nix` body:
```nix
# PHASE 1 base: the deb closure as a rootfs tarball ($out/rootfs.tar.gz),
# BEFORE config stages. os-image.nix folds the stages onto this.
{
  callPackage,
  release ? "noble",
}:
let
  aptPins = callPackage ../ubuntu/apt-pins.nix { inherit release; };
  mkRootfsTarball = callPackage ./tarball.nix { };
in
mkRootfsTarball {
  inherit aptPins;
  packages = (callPackage ../ubuntu/deb-sets.nix { inherit release; }).image;
  size = 16384;
}
```

- [ ] **Step 2: Add `release` to os-image.nix and pass it to rootfs + stages**

Replace `build/rootfs/os-image.nix` body:
```nix
# PHASE 1 OS image: fold every config stage onto the rootfs closure.
{
  callPackage,
  infrastructure ? "openstack",
  release ? "noble",
}:
let
  desc = import ../ubuntu/release.nix { inherit release; };
  applyStages = callPackage ./apply-stages.nix { };
  base = callPackage ./rootfs.nix { inherit release; };
  stages = callPackage ../stages { inherit infrastructure release; };
in
applyStages {
  inherit base stages;
  osVersion = desc.osVersion;
}
```

- [ ] **Step 3: Verify the base rootfs derivation still evaluates**

```bash
nix eval --raw '.#noble-rootfs.drvPath'
```
Expected: a `/nix/store/...-os-image.drv` path (evaluation succeeds; hash compared at Task 8).

- [ ] **Step 4: Commit**

```bash
git add build/rootfs/rootfs.nix build/rootfs/os-image.nix
git commit -m "refactor: thread release through rootfs + os-image"
```

---

### Task 7: Template SPDX + sources.list codename

**Files:**
- Modify: `build/rootfs/apply-stages.nix`
- Modify: `build/stages/default.nix`
- Modify: `build/stages/misc-os/default.nix`
- Modify: `build/stages/misc-os/apply.sh`
- Delete: `build/stages/misc-os/assets/sources.list`

- [ ] **Step 1: Add `osVersion` param to apply-stages.nix and template the SPDX strings**

Change the function head:
```nix
{ base, stages }:
```
to:
```nix
{
  base,
  stages,
  osVersion ? "noble",
}:
```

In the `buildCommand` jq blocks, replace the three hardcoded Noble strings so
they interpolate `osVersion`:
- `.documentNamespace = "https://bosh.io/stemcell/ubuntu-noble"` becomes
  `.documentNamespace = "https://bosh.io/stemcell/ubuntu-${osVersion}"`
- `.name = "bosh-stemcell-ubuntu-noble"` becomes
  `.name = "bosh-stemcell-ubuntu-${osVersion}"`
- Any CycloneDX equivalent lines below line 179 that contain `ubuntu-noble`
  (inspect lines 180-191) get the same `${osVersion}` treatment.

For `osVersion = "noble"` these render byte-identical.

- [ ] **Step 2: Make misc-os accept a codename**

Replace `build/stages/misc-os/default.nix`:
```nix
# misc-os stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ codename ? "noble" }:
{
  name = "misc-os";
  script = ''
    export STAGE_DIR="${./assets}"
    export CODENAME="${codename}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
```

- [ ] **Step 3: Generate sources.list from `$CODENAME` in apply.sh**

In `build/stages/misc-os/apply.sh`, replace the `cp "$STAGE_DIR"/sources.list ...`
block (lines 40-46) with generation:
```bash
# base_apt: create /etc/apt/sources.list with the Ubuntu deb lines for the
# active release codename. Byte-identical to the previous static asset for noble.
cat > "$root/etc/apt/sources.list" <<EOF
deb http://archive.ubuntu.com/ubuntu ${CODENAME} main universe multiverse
deb http://archive.ubuntu.com/ubuntu ${CODENAME}-updates main universe multiverse
deb http://security.ubuntu.com/ubuntu ${CODENAME}-security main universe multiverse
EOF
chmod 0644 "$root/etc/apt/sources.list"
chown root:root "$root/etc/apt/sources.list" 2>/dev/null || true
```
Add `# shellcheck disable=SC2154` above the block if `CODENAME` triggers an
unassigned-variable warning (it is exported by default.nix).

- [ ] **Step 4: Delete the now-unused static asset**

```bash
git rm build/stages/misc-os/assets/sources.list
```

- [ ] **Step 5: Pass `codename` from stages/default.nix to misc-os**

In `build/stages/default.nix`, change the function head from:
```nix
{
  callPackage,
  infrastructure ? "openstack",
}:
```
to:
```nix
{
  callPackage,
  infrastructure ? "openstack",
  release ? "noble",
}:
```
Add inside the `let` block:
```nix
  releaseDesc = import ../ubuntu/release.nix { inherit release; };
```
Change the misc-os import line from:
```nix
  (import ./misc-os { })
```
to:
```nix
  (import ./misc-os { codename = releaseDesc.codename; })
```

- [ ] **Step 6: Verify treefmt + evaluation**

```bash
nix fmt 2>/dev/null || treefmt
nix eval --raw '.#noble-rootfs.drvPath'
```
Expected: formatter clean; drvPath resolves.

- [ ] **Step 7: Commit**

```bash
git add build/rootfs/apply-stages.nix build/stages/default.nix build/stages/misc-os
git commit -m "refactor: template SPDX + sources.list from release codename/osVersion"
```

---

### Task 8: Phase A byte-level gate

**Files:** none (verification only)

- [ ] **Step 1: Rebuild the rootfs layers and compare hashes to baseline**

```bash
cd /home/ruben/workspace/bosh-nix-linux-stemcell-builder
for out in noble-stemcell-rootfs noble-stemcell-aws-rootfs; do
  p=$(nix build ".#${out}" --rebuild --no-link --print-out-paths)
  sha256sum "$p"/rootfs-staged.tar.gz
done
```
Expected: both sha256 values IDENTICAL to the Task 1 baseline lines for
`rootfs-staged.tar.gz`.

- [ ] **Step 2: If any hash differs, STOP and diff**

Use the repro devshell:
```bash
nix develop .#repro -c diffoscope <baseline-path> <new-path>
```
Do not proceed until hashes match. A mismatch means a supposedly byte-preserving
edit changed output — most likely the sources.list generation or an SPDX string.

- [ ] **Step 3: Commit a note recording the green gate**

```bash
git commit --allow-empty -m "test: Phase A rootfs determinism gate PASS (byte-identical to baseline)"
```

---

## Phase B — Infrastructure Descriptor

### Task 9: Create the infrastructure descriptors

**Files:**
- Create: `build/infra/openstack.nix`
- Create: `build/infra/aws.nix`

The YAML fragment fields carry load-bearing indentation transcribed VERBATIM
from `build/stemcells/package.nix` (lines 37-55). Do not reflow them.

- [ ] **Step 1: Write `build/infra/openstack.nix`**

```nix
# OpenStack/KVM infrastructure descriptor. Pure data. YAML fragments are
# transcribed verbatim from the previous package.nix conditionals; their
# indentation is load-bearing (see package.nix INDENTATION CONTRACT comments).
{
  infrastructure = "openstack";
  hypervisor = "kvm";
  diskFormat = "qcow2";
  diskFilename = "root.qcow2";
  nameSuffix = "";

  # IaaS-specific stage directory names, imported by stages/default.nix.
  infraStageNames = [ "openstack-agent-settings" ];

  # package.nix manifest fragments (byte-identical to prior conditionals).
  stemcellFormatsYaml = "  - openstack-qcow2\n  - openstack-raw";
  diskFormatValue = "qcow2";
  extraCloudPropsYaml = "auto_disk_config: true";
}
```

- [ ] **Step 2: Write `build/infra/aws.nix`**

```nix
# AWS infrastructure descriptor. Pure data. YAML fragments transcribed verbatim
# from the previous package.nix conditionals (indentation is load-bearing).
{
  infrastructure = "aws";
  hypervisor = "xen";
  diskFormat = "raw";
  diskFilename = "root.img";
  nameSuffix = "-aws";

  infraStageNames = [
    "aws-agent-settings"
    "udev-aws-rules"
  ];

  stemcellFormatsYaml = "  - aws-raw";
  diskFormatValue = "raw";
  extraCloudPropsYaml = "root_device_name: /dev/sda1\n  boot_mode: uefi-preferred";
}
```

- [ ] **Step 3: Verify both evaluate**

```bash
nix eval --json --expr '{ os = import ./build/infra/openstack.nix; aws = import ./build/infra/aws.nix; }'
```
Expected: JSON with both descriptors; `aws.hypervisor == "xen"`, `os.diskFormat == "qcow2"`.

- [ ] **Step 4: Commit**

```bash
git add build/infra/openstack.nix build/infra/aws.nix
git commit -m "feat: add openstack + aws infrastructure descriptors (pure data)"
```

---

### Task 10: Create the infrastructure selector

**Files:**
- Create: `build/infra/default.nix`

- [ ] **Step 1: Write the selector**

```nix
# Infrastructure selector. Returns the pure-data descriptor for the requested
# IaaS. Defaults to openstack so every existing call site is unchanged.
{ infrastructure ? "openstack" }:
let
  registry = {
    openstack = import ./openstack.nix;
    aws = import ./aws.nix;
  };
in
if registry ? ${infrastructure} then
  registry.${infrastructure}
else
  throw "build/infra/default.nix: unknown infrastructure '${infrastructure}' (known: ${builtins.concatStringsSep ", " (builtins.attrNames registry)})";
```

- [ ] **Step 2: Verify default + error path**

```bash
nix eval --raw --expr '(import ./build/infra { }).hypervisor'
```
Expected: `kvm`

```bash
nix eval --expr '(import ./build/infra { infrastructure = "gcp"; })' 2>&1 | grep -q "unknown infrastructure 'gcp'" && echo OK
```
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add build/infra/default.nix
git commit -m "feat: add infrastructure selector defaulting to openstack"
```

---

### Task 11: Drive stage selection from the infra descriptor

**Files:**
- Modify: `build/stages/default.nix`

- [ ] **Step 1: Replace the hardcoded infra branch with descriptor-driven name mapping**

Replace the `infraStages` binding (lines 15-24) with a lookup from the descriptor.
The descriptor owns WHICH stages; this file owns HOW to import them (locality).

```nix
  infra = import ../infra { inherit infrastructure; };

  # Map infra descriptor stage names to their imported stage dirs. Keeping the
  # import table here preserves stage-dir locality while selection stays data.
  infraStageTable = {
    openstack-agent-settings = import ./openstack-agent-settings { };
    aws-agent-settings = import ./aws-agent-settings { };
    udev-aws-rules = import ./udev-aws-rules { };
  };
  infraStages = map (n: infraStageTable.${n}) infra.infraStageNames;
```

Remove the old `if infrastructure == "openstack" then ... else if ... throw ...`
block. The trailing `++ infraStages` and the rest of the list stay unchanged.

- [ ] **Step 2: Verify stage lists match for both infrastructures**

```bash
nix eval --json --impure --expr 'map (s: s.name) ((import <nixpkgs> {}).callPackage ./build/stages { infrastructure = "aws"; })'
```
Expected: array ending with `"aws-agent-settings"` and `"udev-aws-rules"`.

```bash
nix eval --json --impure --expr 'map (s: s.name) ((import <nixpkgs> {}).callPackage ./build/stages { })'
```
Expected: array ending with `"openstack-agent-settings"` (no udev-aws-rules).

- [ ] **Step 3: Commit**

```bash
git add build/stages/default.nix
git commit -m "refactor: select infra stages from infrastructure descriptor"
```

---

### Task 12: Drive package.nix from the descriptors

**Files:**
- Modify: `build/stemcells/package.nix`

- [ ] **Step 1: Replace scalar args + inline conditionals with descriptor lookups**

Change the inner function argument set (lines 13-21) from:
```nix
{
  bootableDisk,
  metadata,
  version ? "0.0.1-nix",
  os ? "ubuntu",
  osVersion ? "noble",
  infrastructure ? "openstack",
  hypervisor ? "kvm",
}:
```
to:
```nix
{
  bootableDisk,
  metadata,
  version ? "0.0.1-nix",
  os ? "ubuntu",
  release ? "noble",
  infrastructure ? "openstack",
}:
```

At the top of the following `let` block add:
```nix
  releaseDesc = import ../ubuntu/release.nix { inherit release; };
  infra = import ../infra { inherit infrastructure; };
  osVersion = releaseDesc.osVersion;
  hypervisor = infra.hypervisor;
```

Replace the three fragment bindings (lines 37-55) with descriptor reads:
```nix
  stemcellFormatsYaml = infra.stemcellFormatsYaml;
  diskFormatValue = infra.diskFormatValue;
  extraCloudPropsYaml = infra.extraCloudPropsYaml;
```

Leave `stemcellFilename` and the entire `buildCommand` heredoc unchanged — they
already reference `${osVersion}`, `${hypervisor}`, `${infrastructure}`,
`${stemcellFormatsYaml}`, `${diskFormatValue}`, `${extraCloudPropsYaml}`.

- [ ] **Step 2: Verify evaluation still resolves for both infra**

```bash
nix eval --raw '.#openstack-kvm.drvPath'
nix eval --raw '.#aws.drvPath'
```
Expected: both resolve to `/nix/store/...-stemcell-packaging.drv` (byte gate at Task 15).

- [ ] **Step 3: Commit**

```bash
git add build/stemcells/package.nix
git commit -m "refactor: drive package.nix manifest from release + infra descriptors"
```

---

### Task 13: Thread `release` through the stemcell rootfs/disk files

**Files:**
- Modify: `build/stemcells/openstack-kvm-rootfs.nix`
- Modify: `build/stemcells/aws-rootfs.nix`
- Modify: `build/stemcells/openstack-kvm-disk.nix`
- Modify: `build/stemcells/aws-disk.nix`

- [ ] **Step 1: Add `release` to the openstack rootfs file**

Replace `build/stemcells/openstack-kvm-rootfs.nix` tail:
```nix
{
  callPackage,
  release ? "noble",
}:
let
  desc = import ../ubuntu/release.nix { inherit release; };
  osImage = callPackage ../rootfs/os-image.nix { inherit release; };
  mkBootableRootfs = callPackage ./bootable-rootfs.nix { };
in
mkBootableRootfs {
  inherit osImage;
  name = "${desc.release}-stemcell-rootfs";
}
```

- [ ] **Step 2: Add `release` to the aws rootfs file**

Replace `build/stemcells/aws-rootfs.nix` tail:
```nix
{
  callPackage,
  release ? "noble",
}:
let
  desc = import ../ubuntu/release.nix { inherit release; };
  osImage = callPackage ../rootfs/os-image.nix {
    infrastructure = "aws";
    inherit release;
  };
  mkBootableRootfs = callPackage ./bootable-rootfs.nix { };
in
mkBootableRootfs {
  inherit osImage;
  name = "${desc.release}-stemcell-aws-rootfs";
}
```

- [ ] **Step 3: Add `release` to both disk files, deriving name + diskFormat from descriptors**

Replace `build/stemcells/openstack-kvm-disk.nix` tail:
```nix
{
  callPackage,
  release ? "noble",
}:
let
  desc = import ../ubuntu/release.nix { inherit release; };
  infra = import ../infra { infrastructure = "openstack"; };
  mkBootableDisk = callPackage ./bootable-disk.nix { };
  rootfsTree = callPackage ./openstack-kvm-rootfs.nix { inherit release; };
in
mkBootableDisk {
  inherit rootfsTree;
  name = "${desc.release}-stemcell${infra.nameSuffix}";
  diskFormat = infra.diskFormat;
}
```

Replace `build/stemcells/aws-disk.nix` tail:
```nix
{
  callPackage,
  release ? "noble",
}:
let
  desc = import ../ubuntu/release.nix { inherit release; };
  infra = import ../infra { infrastructure = "aws"; };
  mkBootableDisk = callPackage ./bootable-disk.nix { };
  rootfsTree = callPackage ./aws-rootfs.nix { inherit release; };
in
mkBootableDisk {
  inherit rootfsTree;
  name = "${desc.release}-stemcell${infra.nameSuffix}";
  diskFormat = infra.diskFormat;
}
```

Note: `openstack-kvm-disk.nix` previously omitted `diskFormat` (relying on the
`"qcow2"` default in `bootable-disk.nix`). Passing `infra.diskFormat = "qcow2"`
explicitly is byte-identical.

- [ ] **Step 4: Verify names resolve unchanged**

```bash
nix eval --raw '.#noble-stemcell-disk.name'
nix eval --raw '.#noble-stemcell-aws-disk.name'
```
Expected: `noble-stemcell` and `noble-stemcell-aws` respectively.

- [ ] **Step 5: Commit**

```bash
git add build/stemcells/openstack-kvm-rootfs.nix build/stemcells/aws-rootfs.nix build/stemcells/openstack-kvm-disk.nix build/stemcells/aws-disk.nix
git commit -m "refactor: thread release through stemcell rootfs + disk files"
```

---

### Task 14: Thread `release` through the packaged stemcell files

**Files:**
- Modify: `build/stemcells/openstack-kvm.nix`
- Modify: `build/stemcells/aws.nix`

- [ ] **Step 1: Update openstack-kvm.nix to pass release + infrastructure**

Replace `build/stemcells/openstack-kvm.nix` tail:
```nix
{
  callPackage,
  release ? "noble",
}:
let
  bootableDiskDerivation = callPackage ./openstack-kvm-disk.nix { inherit release; };
  bootableDisk = "${bootableDiskDerivation}/root.qcow2";
  metadata = callPackage ../rootfs/os-image.nix { inherit release; };
  mkStemcell = callPackage ./package.nix { };
in
mkStemcell {
  inherit bootableDisk metadata release;
  version = "0.0.5-nix";
  os = "ubuntu";
  infrastructure = "openstack";
}
```

- [ ] **Step 2: Update aws.nix to pass release + infrastructure**

Replace `build/stemcells/aws.nix` tail:
```nix
{
  callPackage,
  release ? "noble",
}:
let
  bootableDiskDerivation = callPackage ./aws-disk.nix { inherit release; };
  bootableDisk = "${bootableDiskDerivation}/root.img";
  metadata = callPackage ../rootfs/os-image.nix {
    infrastructure = "aws";
    inherit release;
  };
  mkStemcell = callPackage ./package.nix { };
in
mkStemcell {
  inherit bootableDisk metadata release;
  version = "0.0.5-nix";
  os = "ubuntu";
  infrastructure = "aws";
}
```

- [ ] **Step 3: Verify the stemcell filenames are unchanged**

```bash
nix build '.#openstack-kvm' --no-link --print-out-paths | xargs -I{} sh -c 'ls {}'
```
Expected: `bosh-stemcell-0.0.5-nix-openstack-kvm-ubuntu-noble.tgz`

```bash
nix build '.#aws' --no-link --print-out-paths | xargs -I{} sh -c 'ls {}'
```
Expected: `bosh-stemcell-0.0.5-nix-aws-xen-ubuntu-noble.tgz`

- [ ] **Step 4: Commit**

```bash
git add build/stemcells/openstack-kvm.nix build/stemcells/aws.nix
git commit -m "refactor: thread release through packaged stemcell files"
```

---

## Phase C — Full Verification Gate

### Task 15: End-to-end byte + format gate

**Files:** none (verification only)

- [ ] **Step 1: treefmt clean**

```bash
nix fmt 2>/dev/null || treefmt
git diff --exit-code && echo "FORMAT CLEAN"
```
Expected: `FORMAT CLEAN` (formatter made no changes).

- [ ] **Step 2: Rebuild all four cells with --rebuild and compare to baseline**

```bash
cd /home/ruben/workspace/bosh-nix-linux-stemcell-builder
{
  for out in noble-stemcell-rootfs noble-stemcell-aws-rootfs; do
    p=$(nix build ".#${out}" --rebuild --no-link --print-out-paths)
    sha256sum "$p"/rootfs-staged.tar.gz
  done
  for out in noble-stemcell-disk noble-stemcell-aws-disk; do
    p=$(nix build ".#${out}" --rebuild --no-link --print-out-paths)
    sha256sum "$p"/root.*
  done
  for out in openstack-kvm aws; do
    p=$(nix build ".#${out}" --no-link --print-out-paths)
    sha256sum "$p"/*.tgz
  done
} > /tmp/after-hashes.txt
```

- [ ] **Step 3: Diff against baseline**

```bash
# Compare only the sha256 columns present in both files.
grep -oE '^[0-9a-f]{64}' docs/plans/baseline-hashes.txt | sort > /tmp/base.sums
grep -oE '^[0-9a-f]{64}' /tmp/after-hashes.txt | sort > /tmp/after.sums
diff /tmp/base.sums /tmp/after.sums && echo "ALL BYTE-IDENTICAL"
```
Expected: `ALL BYTE-IDENTICAL`. Any difference is a refactor regression — bisect
by commit and diffoscope the offending artifact before proceeding.

- [ ] **Step 4: Run the flake checks**

```bash
nix flake check 2>&1 | tail -20
```
Expected: all `*-determinism-*` checks build successfully.

- [ ] **Step 5: Final commit recording the green gate**

```bash
git commit --allow-empty -m "test: descriptor refactor complete — all Noble artifacts byte-identical to baseline"
```

---

## Self-Review Notes

- **Spec coverage:** This plan implements the "Axis 1 / Axis 2 descriptor" and
  "threading the parameters" sections of the design spec for Noble only. The
  flake product loop and Resolute addition are deliberately deferred to Plan 2
  (documented in the spec's Open Tasks). `features` toggles are introduced as
  descriptor DATA here but not yet consumed — their consumers (runit /
  pamLastlog2 stage rework) land in Plan 2 where Resolute flips them.
- **Byte preservation:** Every code move is a verbatim transcription; the two
  gates (Task 8, Task 15) enforce bit-identity against the Task 1 baseline.
- **Naming:** `noble-stemcell`, `noble-stemcell-aws`, disks, rootfs, `openstack-kvm`,
  `aws` outputs are preserved because `flake.nix` is untouched and all defaults
  resolve to noble/openstack.
