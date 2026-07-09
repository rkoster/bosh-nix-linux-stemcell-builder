# Nix Stemcell POC — Milestones M0–M1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a pinned Nix toolchain (M0) and build an Ubuntu **Noble** root filesystem via the article's `vmTools.makeImageFromDebDist` that **boots to a login prompt under QEMU/OVMF** (M1) — proving the two riskiest claims (privileged image builds in the Nix sandbox, and Debian dependency-resolution fidelity for the real BOSH noble package set) before any stage-porting or packaging work.

**Architecture:** A self-contained POC under `poc/` uses a flake pinned to the exact `lheckemann/nixpkgs#foreign-distros` + `flake-parts` revisions from `lheckemann/nixbuntu-samples`. `poc/lib/` holds the Noble APT-distribution coordinates (not predefined in the fork — only trusty→jammy exist), the authoritative BOSH noble package list transcribed from the upstream `base_ubuntu_packages` stage, and a **shared package-set assembler** consumed by both the resolver-fidelity gate and the bootable image (so the set they resolve/install can never drift). `poc/examples/` holds three derivations: an M0 `runInLinuxVM` smoke test, an M1 resolver-closure gate, and the M1 `makeImageFromDebDist` bootable image. `poc/scripts/` holds an apt-reference resolver and a headless QEMU/OVMF boot-assertion script. Incus/director boot is deliberately deferred to M3 (it is `lxd_cpi`'s native job); M1's boot gate is QEMU/OVMF only.

**Tech Stack:** Nix (flakes), `flake-parts`, `lheckemann/nixpkgs#foreign-distros` `vmTools` (`runInLinuxVM`, `makeImageFromDebDist`, `debClosureGenerator`), QEMU + OVMF (UEFI), `devbox` for host CLI tooling. Target: `x86_64-linux`, KVM present.

---

## Assumptions & Grounded Facts (verified 2026-07-06)

- Host: NixOS, **Nix 2.34.7**, `/dev/kvm` present (`crw-rw-rw-`), `x86_64`.
- Builder repo is now on branch **`ubuntu-noble`** (HEAD `7170566ab`, 2026-07-04). All stage references below are that branch.
- The pinned fork exposes `vmTools.debDistros.{trusty,xenial,bionic,ubuntu2004x86_64,ubuntu2204x86_64,...}` but **no noble/2404 entry** — we must supply Noble coordinates ourselves. `vmTools.debDistros.ubuntu2204x86_64.packages` is accessible and equals the fork's `commonDebPackages ++ ["diffutils" "libc-bin"]`; we reuse it as the common base.
- `makeImageFromDebDist` signature (fork `pkgs/build-support/vm/default.nix`): `{ name, fullName, size?4096, urlPrefix, packagesLists?[packagesList], packages, extraPackages?[], postInstall?"", extraDebs?[], createRootFS?defaultCreateRootFS, QEMU_OPTS?"", memSize?512 }`. Its build output is a directory containing **`disk-image.qcow2`** (created via `qemu-img create -f qcow2`; `createRootFS` partitions `/dev/vda`). `fillDiskWithDebs` installs `.deb`s with `dpkg --install --force-all ... || true` (install-script failures are logged, not fatal).
- `runInLinuxVM` sets `requiredSystemFeatures = [ "kvm" ]`.
- **Package-source availability (verified):** `http://archive.ubuntu.com/ubuntu/dists/noble/main/binary-amd64/Packages.xz` → `206 Partial Content`, valid `.xz`. `snapshot.ubuntu.com/` landing → `200`, but archive paths `https://snapshot.ubuntu.com/ubuntu/<ts>/...` returned a hard **`503 Service Unavailable`** from the research sandbox for every path (including `Release`). This may be sandbox-egress-specific or transient, so M0 Task 0.5 **re-verifies host-side** and picks the pin; the Serverspec oracle (`bosh-stemcell/spec/os_image/ubuntu_spec.rb:35-37`) accepts **both** `archive.ubuntu.com` and `snapshot.ubuntu.com`, so falling back to `archive.ubuntu.com` is spec-compliant.
- Flake pins (verbatim from the sample `flake.lock`): `nixpkgs` (lheckemann/foreign-distros) `5a4f40797c98c8eb33d2e86b8eb78624a36b83ea`; `flake-parts` `8c9fa2545007b49a5db5f650ae91f227672c3877`; `nixpkgs-lib` `0cbe9f69c234a7700596e943bfae7ef27a31b735`.

---

## File Structure

- `poc/flake.nix` — flake: pinned inputs, per-system `packages` (auto-mapped from `examples/`), and a `devShells.default` exporting `OVMF_FD`, `qemu`, `xz`.
- `poc/flake.lock` — committed lock, **verbatim** from `lheckemann/nixbuntu-samples` (guarantees identical eval).
- `poc/examples/hello-vm.nix` — M0 gate: a `runInLinuxVM` derivation that does a privileged loopback `mkfs.ext4`+mount; proves KVM + VM sandbox + privileged ops.
- `poc/examples/noble-closure.nix` — M1 resolver-fidelity gate: exposes only the `debClosureGenerator` output (the resolved `.deb` fetch-closure) for inspection/diff against apt, without building an image.
- `poc/examples/noble-bootable.nix` — M1: `makeImageFromDebDist` Noble image (EFI/GPT, removable GRUB, serial console), including the real BOSH noble package set.
- `poc/lib/noble-distro.nix` — Noble APT coordinates: `name`, `fullName`, `urlPrefix`, `packagesLists` (main/universe/multiverse `Packages.xz`), and `basePackages` (reused jammy common base).
- `poc/lib/noble-packages.nix` — the authoritative BOSH noble deb list (verbatim transcription of `base_ubuntu_packages/apply.sh`).
- `poc/lib/boot-packages.nix` — pure data: the boot/runtime essentials to add on top of the base and the build-only base packages to drop; read by both the assembler and the apt-reference script.
- `poc/lib/image-packages.nix` — the shared assembler (filtered jammy base ++ boot essentials ++ BOSH set), imported by BOTH `noble-closure.nix` and `noble-bootable.nix` so the resolver gate validates exactly the image's package set.
- `poc/scripts/apt-resolve-noble.sh` — computes apt's resolved install set for the same top-level packages (in a throwaway `ubuntu:noble` container) as the resolver-fidelity reference.
- `poc/scripts/boot-qemu.sh` — headless QEMU/OVMF boot with serial capture; asserts a `login:` prompt.
- `poc/.gitignore` — ignores `result*` symlinks and scratch.
- `devbox.json` (repo root) — host CLI tools (`git`, `qemu`, `xz`, `jq`); full pinned build toolchain comes from `nix develop ./poc`.
- `docs/superpowers/specs/2026-07-06-nix-based-stemcell-feasibility-design.md` — updated with M0/M1 findings (Tasks 0.5, 1.4, 1.8).

The root `.gitignore` already protects `bosh.env`, `result`, `*.qcow2`. The nested `bosh-linux-stemcell-builder/` repo remains untracked by the outer repo.

---

## M0 — Toolchain & Scaffolding

### Task 0.1: POC flake scaffold with pinned inputs

**Files:**
- Create: `poc/flake.nix`
- Create: `poc/flake.lock`
- Create: `poc/.gitignore`

- [ ] **Step 1: Write `poc/flake.nix`**

```nix
{
  description = "Nix POC: Ubuntu Noble BOSH stemcell (milestones M0-M1)";

  # Inputs match lheckemann/nixbuntu-samples exactly; poc/flake.lock pins the
  # revisions verbatim so evaluation is reproducible without ref resolution.
  inputs = {
    nixpkgs.url = "github:lheckemann/nixpkgs/foreign-distros";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } ({ lib, ... }: {
    systems = [ "x86_64-linux" ];
    perSystem = { pkgs, ... }: {
      # One package per file in ./examples (mirrors the samples repo layout).
      packages = lib.mapAttrs' (name: _type: {
        name = lib.replaceStrings [ ".nix" ] [ "" ] name;
        value = pkgs.callPackage ./examples/${name} { };
      }) (builtins.readDir ./examples);

      devShells.default = pkgs.mkShell {
        # nix-prefetch-url ships with Nix itself, so no extra package needed.
        packages = with pkgs; [ qemu OVMF xz ];
        shellHook = ''
          export OVMF_FD="${pkgs.OVMF.fd}/FV/OVMF.fd"
          echo "POC devshell: OVMF_FD=$OVMF_FD"
        '';
      };
    };
  });
}
```

- [ ] **Step 2: Write `poc/flake.lock` (verbatim pin)**

```json
{
  "nodes": {
    "flake-parts": {
      "inputs": {
        "nixpkgs-lib": "nixpkgs-lib"
      },
      "locked": {
        "lastModified": 1698882062,
        "narHash": "sha256-HkhafUayIqxXyHH1X8d9RDl1M2CkFgZLjKD3MzabiEo=",
        "owner": "hercules-ci",
        "repo": "flake-parts",
        "rev": "8c9fa2545007b49a5db5f650ae91f227672c3877",
        "type": "github"
      },
      "original": {
        "owner": "hercules-ci",
        "repo": "flake-parts",
        "type": "github"
      }
    },
    "nixpkgs": {
      "locked": {
        "lastModified": 1698575171,
        "narHash": "sha256-Qbxmi5UzUx6jSpeLVbACpFCUcx8KJlV7rB6fPte5Zos=",
        "owner": "lheckemann",
        "repo": "nixpkgs",
        "rev": "5a4f40797c98c8eb33d2e86b8eb78624a36b83ea",
        "type": "github"
      },
      "original": {
        "owner": "lheckemann",
        "ref": "foreign-distros",
        "repo": "nixpkgs",
        "type": "github"
      }
    },
    "nixpkgs-lib": {
      "locked": {
        "dir": "lib",
        "lastModified": 1698611440,
        "narHash": "sha256-jPjHjrerhYDy3q9+s5EAsuhyhuknNfowY6yt6pjn9pc=",
        "owner": "NixOS",
        "repo": "nixpkgs",
        "rev": "0cbe9f69c234a7700596e943bfae7ef27a31b735",
        "type": "github"
      },
      "original": {
        "dir": "lib",
        "owner": "NixOS",
        "ref": "nixos-unstable",
        "repo": "nixpkgs",
        "type": "github"
      }
    },
    "root": {
      "inputs": {
        "flake-parts": "flake-parts",
        "nixpkgs": "nixpkgs"
      }
    }
  },
  "root": "root",
  "version": 7
}
```

- [ ] **Step 3: Write `poc/.gitignore`**

```gitignore
result
result-*
*.qcow2
*.log
```

- [ ] **Step 4: Verify the flake evaluates against the pinned revs**

Run: `nix --extra-experimental-features 'nix-command flakes' flake metadata ./poc`
Expected: output shows `Resolved URL` and locked nodes with
`nixpkgs` rev `5a4f40797c98c8eb33d2e86b8eb78624a36b83ea` and
`flake-parts` rev `8c9fa2545007b49a5db5f650ae91f227672c3877` (no network re-locking, since `flake.lock` is present).

- [ ] **Step 5: Commit**

```bash
git add poc/flake.nix poc/flake.lock poc/.gitignore
git commit -m "poc(m0): pin Nix flake to nixbuntu-samples foreign-distros revisions"
```

---

### Task 0.2: M0 boot gate — trivial `runInLinuxVM` derivation

**Files:**
- Create: `poc/examples/hello-vm.nix`

- [ ] **Step 1: Write `poc/examples/hello-vm.nix`**

```nix
# M0 gate: proves the Nix sandbox can run a build inside a Linux VM (runInLinuxVM)
# with KVM, and perform privileged filesystem operations (loopback + mkfs + mount).
{ vmTools, runCommand, e2fsprogs, util-linux }:

vmTools.runInLinuxVM (runCommand "hello-vm"
  { nativeBuildInputs = [ e2fsprogs util-linux ]; }
  ''
    echo "=== inside the build VM ==="
    uname -a

    # Privileged op #1: create a loopback ext4 filesystem and mount it.
    truncate -s 32M /tmp/disk.img
    mkfs.ext4 -F -q /tmp/disk.img
    mkdir -p /tmp/mnt
    mount -o loop /tmp/disk.img /tmp/mnt
    echo "privileged mount works" > /tmp/mnt/proof.txt
    cat /tmp/mnt/proof.txt
    umount /tmp/mnt

    mkdir -p $out
    uname -a > $out/uname.txt
    cp /tmp/disk.img $out/disk.img
  '')
```

- [ ] **Step 2: Build it (this is the M0 exit gate)**

Run: `nix --extra-experimental-features 'nix-command flakes' build ./poc#hello-vm -L`
Expected: build log shows `inside the build VM`, a Linux `uname -a`, and `privileged mount works`; build succeeds and `./result/uname.txt` exists.

- [ ] **Step 3: Confirm the artifact**

Run: `cat ./result/uname.txt`
Expected: a Linux kernel string (the VM's kernel), confirming the derivation ran inside the VM.

- [ ] **Step 4: Commit**

```bash
git add poc/examples/hello-vm.nix
git commit -m "poc(m0): add runInLinuxVM smoke test (KVM + privileged mount gate)"
```

**If Step 2 fails** with `a 'kvm' feature is required` or similar: the Nix daemon lacks the `kvm` system feature. Fix by adding `system-features = kvm nixos-test benchmark big-parallel` to `/etc/nix/nix.conf` (NixOS: `nix.settings.system-features`) and `sudo systemctl restart nix-daemon`, then re-run. Record the resolution in the M0 findings.

---

### Task 0.3: Wire `devbox.json` host tooling

**Files:**
- Modify: `devbox.json` (currently a bare scaffold with empty `packages`)

- [ ] **Step 1: Read the current `devbox.json`**

Run: `cat devbox.json`
Expected: a minimal scaffold (empty or near-empty `packages` array).

- [ ] **Step 2: Write `devbox.json`**

```json
{
  "$schema": "https://raw.githubusercontent.com/jetify-com/devbox/0.17.2/.schema/devbox.schema.json",
  "packages": [
    "git@latest",
    "qemu@latest",
    "xz@latest",
    "jq@latest"
  ],
  "shell": {
    "init_hook": [
      "echo 'devbox: host CLI ready. For the pinned build toolchain run: nix develop ./poc'"
    ],
    "scripts": {
      "boot": [
        "nix develop ./poc --command bash poc/scripts/boot-qemu.sh"
      ]
    }
  }
}
```

- [ ] **Step 3: Validate devbox resolves the environment**

Run: `devbox install`
Expected: devbox resolves and installs `git`, `qemu`, `xz`, `jq` without error.

- [ ] **Step 4: Commit**

```bash
git add devbox.json
git commit -m "poc(m0): wire devbox host CLI tooling (git, qemu, xz, jq)"
```

---

### Task 0.4: Capture the authoritative Noble package set

**Files:**
- Create: `poc/lib/noble-packages.nix`
- Reference: `bosh-linux-stemcell-builder/stemcell_builder/stages/base_ubuntu_packages/apply.sh` (branch `ubuntu-noble`)

- [ ] **Step 1: Re-read the source of truth to confirm it is unchanged**

Run: `sed -n '9,37p' bosh-linux-stemcell-builder/stemcell_builder/stages/base_ubuntu_packages/apply.sh`
Expected: the `debs=` list containing `libaio1t64`, `libpam-pwquality`, `nftables`, and the stock `rsyslog rsyslog-gnutls rsyslog-openssl rsyslog-relp` install (adiscon PPA commented out). If the list differs from Step 2, update Step 2 to match before continuing.

- [ ] **Step 2: Write `poc/lib/noble-packages.nix`**

```nix
# Authoritative BOSH package set for ubuntu-noble.
# Transcribed verbatim from:
#   bosh-linux-stemcell-builder/stemcell_builder/stages/base_ubuntu_packages/apply.sh
# on branch ubuntu-noble (HEAD 7170566ab).
# Note Noble's 64-bit time_t (t64) ABI transition and PAM change:
#   jammy libaio1        -> noble libaio1t64
#   jammy libpam-cracklib -> noble libpam-pwquality
# Duplicate "rng-tools" from the shell list is de-duplicated here.
[
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
  # rsyslog set (stock noble; adiscon v8-stable PPA has no noble build yet)
  "rsyslog" "rsyslog-gnutls" "rsyslog-openssl" "rsyslog-relp"
]
```

- [ ] **Step 3: Verify the list is a valid Nix expression of strings**

Run: `nix --extra-experimental-features 'nix-command' eval --impure --expr 'builtins.length (import ./poc/lib/noble-packages.nix)'`
Expected: `61`

- [ ] **Step 4: Commit**

```bash
git add poc/lib/noble-packages.nix
git commit -m "poc(m0): capture authoritative ubuntu-noble BOSH package set"
```

---

### Task 0.5: Choose the package source (snapshot vs archive) and record it

**Files:**
- Create: `poc/lib/noble-source.nix`
- Modify: `docs/superpowers/specs/2026-07-06-nix-based-stemcell-feasibility-design.md` (§5.4)

- [ ] **Step 1: Probe `snapshot.ubuntu.com` from the host for a Noble index**

Run:
```bash
TS=20250602T000000Z
for c in main universe multiverse; do
  echo -n "$c: "; curl -fsSL -o /dev/null -w '%{http_code}\n' \
    "https://snapshot.ubuntu.com/ubuntu/$TS/dists/noble/$c/binary-amd64/Packages.xz" || echo FAIL
done
```
Expected: three `200` lines if `snapshot.ubuntu.com` is usable from the host. If any is `503`/`FAIL`, proceed with the archive fallback in Step 2b.

- [ ] **Step 2a: (If snapshot works) Write `poc/lib/noble-source.nix` pinned to the snapshot**

```nix
# Package source for the Noble POC build.
# Snapshot pin confirmed reachable from the host (M0 Task 0.5).
# suites/components mirror base_apt/apply.sh: noble{,-updates,-security} main universe multiverse.
{
  urlPrefix = "https://snapshot.ubuntu.com/ubuntu/20250602T000000Z";
  codename = "noble";
  components = [ "main" "universe" "multiverse" ];
}
```

- [ ] **Step 2b: (If snapshot 503s) Write `poc/lib/noble-source.nix` with the archive fallback**

```nix
# Package source for the Noble POC build.
# snapshot.ubuntu.com was unreachable from the host (503) at build time, so we
# fall back to the live archive. This is spec-compliant: the Serverspec oracle
# (bosh-stemcell/spec/os_image/ubuntu_spec.rb:35-37) accepts archive.ubuntu.com.
# Trade-off: NOT point-in-time reproducible; hashes float with the live index.
# Revisit for M2 once a stable snapshot timestamp is confirmed.
{
  urlPrefix = "http://archive.ubuntu.com/ubuntu";
  codename = "noble";
  components = [ "main" "universe" "multiverse" ];
}
```

- [ ] **Step 3: Update the spec §5.4 with the decision**

In `docs/superpowers/specs/2026-07-06-nix-based-stemcell-feasibility-design.md`, replace the parenthetical action note at the end of §5.4 (the sentence beginning `*(Action: confirm`) with the resolved finding. Use whichever branch applies:

```markdown
**M0 result (2026-07-06):** `snapshot.ubuntu.com` archive paths returned `503`
for every Noble index request from both the research sandbox and the host, while
`archive.ubuntu.com/dists/noble/*/binary-amd64/Packages.xz` served valid `.xz`
indices. The POC therefore pins against `archive.ubuntu.com` for M1 (spec-compliant
per `ubuntu_spec.rb:35-37`), trading point-in-time reproducibility for availability.
Re-pinning to a confirmed `snapshot.ubuntu.com/<timestamp>` index is deferred to M2.
```

(If snapshot worked instead, record that `snapshot.ubuntu.com/<timestamp>` serves stable Noble indices usable as Nix fixed-output inputs, and that the POC pins to it.)

- [ ] **Step 4: Commit**

```bash
git add poc/lib/noble-source.nix docs/superpowers/specs/2026-07-06-nix-based-stemcell-feasibility-design.md
git commit -m "poc(m0): choose Noble package source and record snapshot-vs-archive finding"
```

**M0 exit criteria:** `nix build ./poc#hello-vm` succeeds (privileged VM build works); the Noble package set and package source are captured as Nix expressions; the snapshot/archive decision is recorded in the spec.

---

## M1 — Bootable Noble rootfs (the core risk)

### Task 1.1: Define the Noble APT distribution coordinates

**Files:**
- Create: `poc/lib/noble-distro.nix`

- [ ] **Step 1: Write `poc/lib/noble-distro.nix` with placeholder hashes**

`lib.fakeHash` is intentional here: Nix reports the correct hash on first build, which Task 1.2 pastes back. This is the standard fixed-output workflow, not a stub.

```nix
# Noble APT distribution coordinates for makeImageFromDebDist.
# The fork's vmTools.debDistros has no 2404/noble entry, so we supply our own.
# basePackages reuses jammy's common base (== commonDebPackages ++ diffutils libc-bin),
# which is the closest predefined analogue in the fork.
{ lib, fetchurl, vmTools }:

let
  src = import ./noble-source.nix;
  indexUrl = component:
    "${src.urlPrefix}/dists/${src.codename}/${component}/binary-amd64/Packages.xz";
  fetchIndex = component: sha256:
    fetchurl { url = indexUrl component; inherit sha256; };
in
{
  name = "ubuntu-24.04-noble-amd64";
  fullName = "Ubuntu 24.04 Noble (amd64)";
  urlPrefix = src.urlPrefix;

  # main/universe/multiverse indices. Hashes filled in Task 1.2.
  packagesLists = [
    (fetchIndex "main" lib.fakeHash)
    (fetchIndex "universe" lib.fakeHash)
    (fetchIndex "multiverse" lib.fakeHash)
  ];

  basePackages = vmTools.debDistros.ubuntu2204x86_64.packages;
}
```

- [ ] **Step 2: Confirm the file parses (hashes not yet needed)**

Run: `nix-instantiate --parse ./poc/lib/noble-distro.nix >/dev/null && echo "parse ok"`
Expected: `parse ok`. (`fakeHash` only fails at *build* time, not parse/eval, so a green parse here confirms the syntax is valid.)

- [ ] **Step 3: Commit**

```bash
git add poc/lib/noble-distro.nix
git commit -m "poc(m1): define Noble APT distribution coordinates (fakeHash placeholders)"
```

---

### Task 1.2: Resolve the real `Packages.xz` hashes

**Files:**
- Modify: `poc/lib/noble-distro.nix:packagesLists`

- [ ] **Step 1: Prefetch the three index hashes**

Run (reads `urlPrefix`/`codename` from `poc/lib/noble-source.nix`):
```bash
URLPREFIX=$(nix eval --impure --raw --expr '(import ./poc/lib/noble-source.nix).urlPrefix')
CODENAME=$(nix eval --impure --raw --expr '(import ./poc/lib/noble-source.nix).codename')
for c in main universe multiverse; do
  echo -n "$c "
  nix-prefetch-url "$URLPREFIX/dists/$CODENAME/$c/binary-amd64/Packages.xz"
done
```
Expected: three lines, each `<component> <base32-sha256>` — for example
`main 0abc...`, `universe 1def...`, `multiverse 2ghi...`. Record all three.

- [ ] **Step 2: Paste the hashes into `poc/lib/noble-distro.nix`**

Replace the `packagesLists` block, substituting each `lib.fakeHash` with the matching base32 hash from Step 1 (fetchurl accepts base32 `sha256` directly, as the fork's existing Ubuntu entries do):

```nix
  packagesLists = [
    (fetchIndex "main" "PASTE_MAIN_HASH_FROM_STEP_1")
    (fetchIndex "universe" "PASTE_UNIVERSE_HASH_FROM_STEP_1")
    (fetchIndex "multiverse" "PASTE_MULTIVERSE_HASH_FROM_STEP_1")
  ];
```

- [ ] **Step 3: Confirm the prefetch is deterministic**

Run: `nix-prefetch-url "$(nix eval --impure --raw --expr '(import ./poc/lib/noble-source.nix).urlPrefix')/dists/noble/main/binary-amd64/Packages.xz"`
Expected: the **same** base32 hash you pasted for `main` in Step 2 (proves the index is stable enough to pin). Full validation that all three pinned hashes fetch correctly happens when `nix build ./poc#noble-closure` runs in Task 1.4 Step 2.

- [ ] **Step 4: Commit**

```bash
git add poc/lib/noble-distro.nix
git commit -m "poc(m1): pin real Noble Packages.xz index hashes"
```

---

### Task 1.3: Assemble the shared image package set

**Files:**
- Create: `poc/lib/boot-packages.nix`
- Create: `poc/lib/image-packages.nix`

Both the resolver-fidelity gate (Task 1.4) and the bootable image (Task 1.5) must
install the **same** package set, or the gate is meaningless. This task extracts
that set into one assembler so the two derivations can never drift, and keeps the
raw lists as pure data the apt-reference script can read too.

- [ ] **Step 1: Write `poc/lib/boot-packages.nix` (pure data, no args)**

```nix
# Boot/runtime essentials to add on top of the distro base, and the build-only
# base packages to drop. Kept as pure data (no function args) so BOTH the Nix
# assembler (image-packages.nix) and the apt-reference script (apt-resolve-noble.sh)
# read the identical lists — no drift.
{
  # Build-only tooling in jammy's common base that a bootable image doesn't need.
  dropFromBase = [ "g++" "make" "dpkg-dev" "pkg-config" "sysvinit" ];

  # Minimal packages required to boot, plus a few runtime essentials.
  bootEssentials = [
    "systemd"               # init system
    "init-system-helpers"   # provides update-rc.d used by udev hooks
    "systemd-sysv"          # provides /sbin/init
    "linux-image-generic"   # kernel
    "initramfs-tools"       # initramfs generation
    "e2fsprogs"             # initramfs fsck
    "grub-efi"              # boot loader
    "apt"                   # package manager (for later in-image work)
    "ncurses-base"          # terminfo
    "dbus"                  # networkctl / logind
  ];
}
```

- [ ] **Step 2: Write `poc/lib/image-packages.nix` (the shared assembler)**

```nix
# Single source of truth for the full top-level package set installed into the
# Noble image. Imported by BOTH noble-closure.nix (resolver-fidelity gate) and
# noble-bootable.nix (the image), so the gate validates EXACTLY what ships.
# Returns a plain list of package-name strings (what makeImageFromDebDist and
# debClosureGenerator expect for `packages`).
{ lib, callPackage }:

let
  noble = callPackage ./noble-distro.nix { };
  bosh = import ./noble-packages.nix;
  boot = import ./boot-packages.nix;
in
lib.filter (p: !lib.elem p boot.dropFromBase) noble.basePackages
++ boot.bootEssentials
++ bosh
```

Note: evaluating this list forces only `noble.basePackages` (plain strings from
`vmTools.debDistros.ubuntu2204x86_64.packages`) — never `noble.packagesLists` —
so it evaluates cleanly even while Task 1.1's `fakeHash` placeholders are still in
place. The real index hashes (Task 1.2) are only forced when a closure/image builds.

- [ ] **Step 3: Verify both files parse/evaluate**

Run:
```bash
nix-instantiate --parse ./poc/lib/image-packages.nix >/dev/null && echo "assembler parse ok"
nix --extra-experimental-features 'nix-command' eval --impure \
  --expr 'builtins.length (import ./poc/lib/boot-packages.nix).bootEssentials'
```
Expected: `assembler parse ok`, then `10` (the boot-essentials count). The full
assembled list is exercised when `nix build ./poc#noble-closure` runs in Task 1.4.

- [ ] **Step 4: Commit**

```bash
git add poc/lib/boot-packages.nix poc/lib/image-packages.nix
git commit -m "poc(m1): add shared image package assembler (single source for gate + image)"
```

---

### Task 1.4: Resolver-fidelity gate — build the closure and compare to apt

**Files:**
- Create: `poc/examples/noble-closure.nix`
- Create: `poc/scripts/apt-resolve-noble.sh`

This task isolates the single highest feasibility risk (does the fork's primitive Perl resolver produce a working closure for the real noble set?) **before** spending build time on a full image.

- [ ] **Step 1: Write `poc/examples/noble-closure.nix`**

```nix
# Exposes ONLY the debClosureGenerator output (the generated fetchurl-closure .nix)
# for the Noble package set, so we can inspect what the resolver selected without
# building a full disk image. `packages` comes from the shared assembler
# (../lib/image-packages.nix), so this gate resolves EXACTLY the set that
# noble-bootable.nix installs — the two cannot drift.
{ vmTools, callPackage }:

let
  noble = callPackage ../lib/noble-distro.nix { };
  packages = callPackage ../lib/image-packages.nix { };
in
# debClosureGenerator returns a derivation that builds "<name>.nix": a Nix
# expression listing every .deb (with fetchurl) in the resolved closure.
(vmTools.debClosureGenerator {
  name = "ubuntu-24.04-noble-amd64";
  inherit (noble) packagesLists urlPrefix;
  inherit packages;
})
```

- [ ] **Step 2: Build the closure expression**

Run: `nix --extra-experimental-features 'nix-command flakes' build ./poc#noble-closure -L -o result-closure`
Expected: succeeds, producing `result-closure` — a `.nix` file of `fetchurl` entries. If the Perl resolver errors (e.g. `no such package`), capture the failing package name; that is a resolver-fidelity finding to record in Step 5.

- [ ] **Step 3: Count and list the resolved closure**

Run: `grep -c 'url = ' result-closure; grep -oE '[^/"]+\.deb' result-closure | sed 's:_.*::' | sort -u > /tmp/nix-closure.txt; wc -l /tmp/nix-closure.txt`
Expected: a package count (typically several hundred) and a sorted, de-duplicated list of package names at `/tmp/nix-closure.txt` (the `.deb` URLs are `pool/...` paths, so we take the filename and strip `_version_arch.deb`).

- [ ] **Step 4: Write `poc/scripts/apt-resolve-noble.sh` (apt reference closure)**

```bash
#!/usr/bin/env bash
# Computes apt's resolved install set for the same top-level packages, inside a
# throwaway noble container, to compare against the Nix resolver's closure.
set -euo pipefail

PKGS="$(nix eval --impure --raw --expr '
  builtins.concatStringsSep " " (import ./poc/lib/noble-packages.nix)
')"
# Read the SAME boot-essentials list the Nix image uses, so the comparison feeds
# apt exactly the top-level packages the assembler adds on top of the base.
BOOT="$(nix eval --impure --raw --expr '
  builtins.concatStringsSep " " (import ./poc/lib/boot-packages.nix).bootEssentials
')"

docker run --rm ubuntu:noble bash -c "
  set -e
  apt-get update -qq
  apt-get install -y --no-install-recommends --print-uris $PKGS $BOOT \
    | grep -oP \"'[^']+\\.deb'\" | sed \"s:.*/::;s:_.*::\" | sort -u
" > /tmp/apt-closure.txt
wc -l /tmp/apt-closure.txt
```

- [ ] **Step 5: Run the comparison and record findings**

Run:
```bash
bash poc/scripts/apt-resolve-noble.sh
comm -23 /tmp/apt-closure.txt /tmp/nix-closure.txt > /tmp/apt-only.txt
comm -13 /tmp/apt-closure.txt /tmp/nix-closure.txt > /tmp/nix-only.txt
echo "in apt but NOT nix:"; cat /tmp/apt-only.txt
echo "in nix but NOT apt:"; cat /tmp/nix-only.txt
```
Expected: two diff lists (both inputs are already sorted, de-duplicated bare package names). `apt-only` = packages the primitive resolver **missed** (the real risk — likely `Recommends`/alternatives/versioned deps). `nix-only` = the base system the Nix closure builds from scratch (the `ubuntu:noble` container already has it installed, so apt won't re-list it) plus any genuine over-resolution — so a large `nix-only` list is expected and not itself a problem. Record both lists and their significance in the spec (Task 1.8). **Decision rule:** if `apt-only.txt` is empty or contains only non-essential packages, the Nix resolver is sufficient for M1 → proceed to Task 1.5 as-is. If it contains boot- or agent-critical packages, add them explicitly to `poc/lib/boot-packages.nix:bootEssentials` (they get pulled as fixed-output fetches) and re-run Steps 2–5 until `apt-only.txt` has no critical gaps.

- [ ] **Step 6: Commit**

```bash
git add poc/examples/noble-closure.nix poc/scripts/apt-resolve-noble.sh
git commit -m "poc(m1): add resolver-fidelity gate (nix closure vs apt reference)"
```

---

### Task 1.5: Define the bootable Noble image derivation

**Files:**
- Create: `poc/examples/noble-bootable.nix`

- [ ] **Step 1: Write `poc/examples/noble-bootable.nix`**

Adapted from `nixbuntu-samples/examples/3-creature-comforts.nix` with three deliberate divergences: (a) Noble coordinates instead of `ubuntu2004x86_64`; (b) the full package set comes from the shared assembler (`../lib/image-packages.nix`) — identical to what the Task 1.4 resolver gate validated, so this build genuinely exercises resolver fidelity for the real BOSH noble set; (c) `grub-install --removable` writes `/EFI/BOOT/BOOTX64.EFI` so a fresh OVMF (no persisted NVRAM entry) boots headlessly.

```nix
{ vmTools, udev, gptfdisk, util-linux, dosfstools, e2fsprogs, callPackage }:

let
  noble = callPackage ../lib/noble-distro.nix { };
in
vmTools.makeImageFromDebDist {
  inherit (noble) name fullName urlPrefix packagesLists;

  # Full package set from the shared assembler — identical to the set the Task 1.4
  # resolver gate validated (filtered jammy base ++ boot essentials ++ BOSH set).
  packages = callPackage ../lib/image-packages.nix { };

  size = 8192;

  createRootFS = ''
    disk=/dev/vda
    ${gptfdisk}/bin/sgdisk $disk \
      -n1:0:+100M -t1:ef00 -c1:esp \
      -n2:0:0 -t2:8300 -c2:root

    ${util-linux}/bin/partx -u "$disk"
    ${dosfstools}/bin/mkfs.vfat -F32 -n ESP "$disk"1
    part="$disk"2
    ${e2fsprogs}/bin/mkfs.ext4 "$part" -L root
    mkdir /mnt
    ${util-linux}/bin/mount -t ext4 "$part" /mnt
    mkdir -p /mnt/{proc,dev,sys,boot/efi}
    ${util-linux}/bin/mount -t vfat "$disk"1 /mnt/boot/efi
    touch /mnt/.debug
  '';

  postInstall = ''
    ${udev}/lib/systemd/systemd-udevd &
    ${udev}/bin/udevadm trigger
    ${udev}/bin/udevadm settle

    ${util-linux}/bin/mount -t sysfs sysfs /mnt/sys

    chroot /mnt /bin/bash -exuo pipefail <<CHROOT
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin

    echo LABEL=root / ext4 defaults > /etc/fstab

    update-initramfs -k all -c

    # Serial console so headless QEMU boot is observable and assertable.
    cat >> /etc/default/grub <<EOF
    GRUB_TIMEOUT=5
    GRUB_CMDLINE_LINUX="console=ttyS0"
    GRUB_CMDLINE_LINUX_DEFAULT=""
    EOF
    sed -i '/TIMEOUT_HIDDEN/d' /etc/default/grub
    update-grub
    # --removable writes /EFI/BOOT/BOOTX64.EFI, which OVMF always tries even
    # without a persisted NVRAM boot entry (required for fresh headless boots).
    grub-install --target x86_64-efi --removable

    echo root:root | chpasswd
    CHROOT
    ${util-linux}/bin/umount /mnt/boot/efi
    ${util-linux}/bin/umount /mnt/sys
  '';
}
```

- [ ] **Step 2: Confirm the attribute is discoverable and hashes are pinned**

Run: `nix-instantiate ./poc -A packages.x86_64-linux.noble-bootable 2>&1 | grep -i 'hash mismatch' && echo "HASH BAD — redo Task 1.2" || echo "instantiation ok"`
Expected: `instantiation ok` (this also completes Task 1.2 Step 3's deferred check).

- [ ] **Step 3: Commit**

```bash
git add poc/examples/noble-bootable.nix
git commit -m "poc(m1): add bootable Noble makeImageFromDebDist derivation"
```

---

### Task 1.6: Build the Noble disk image

**Files:** none (build only)

- [ ] **Step 1: Build the image**

Run: `nix --extra-experimental-features 'nix-command flakes' build ./poc#noble-bootable -L`
Expected: a long VM build log (unpacking + installing hundreds of `.deb`s, `update-initramfs`, `grub-install`), ending in success with `./result/disk-image.qcow2` present. Per-`.deb` dpkg failures are logged but non-fatal (`--force-all ... || true`); note any that look boot-critical.

- [ ] **Step 2: Confirm the artifact exists and is a qcow2**

Run: `ls -lh ./result/disk-image.qcow2 && qemu-img info ./result/disk-image.qcow2`
Expected: file exists; `qemu-img info` reports `file format: qcow2` and virtual size `8.0 GiB`.

**If the build fails** during install of a specific package, record it (resolver/ABI finding — e.g. a `t64` mismatch), and either add the missing dependency to the shared list (`poc/lib/boot-packages.nix:bootEssentials`) or exclude the offending optional package (drop it from `poc/lib/noble-packages.nix`), then re-run. This iteration is the substance of M1.

---

### Task 1.7: Boot the image under QEMU/OVMF and assert a login prompt

**Files:**
- Create: `poc/scripts/boot-qemu.sh`

- [ ] **Step 1: Write `poc/scripts/boot-qemu.sh`**

```bash
#!/usr/bin/env bash
# Headless QEMU/OVMF boot of the Noble image; asserts a getty "login:" prompt on
# the serial console. Requires OVMF_FD (exported by `nix develop ./poc`).
set -euo pipefail

IMG="${1:-result/disk-image.qcow2}"
: "${OVMF_FD:?set OVMF_FD — run inside 'nix develop ./poc'}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp --no-preserve=mode "$IMG" "$WORK/disk.qcow2"
LOG="$WORK/boot.log"

echo "Booting $IMG (timeout 240s, log: $LOG) ..."
timeout 240 qemu-system-x86_64 \
  -enable-kvm -m 2048 -smp 2 -machine q35 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_FD" \
  -drive file="$WORK/disk.qcow2",if=virtio,format=qcow2 \
  -nographic -serial mon:stdio -display none -net none \
  2>&1 | tee "$LOG" || true

echo "--- checking serial log for a login prompt ---"
if grep -Eq 'login:' "$LOG"; then
  echo "BOOT OK: reached login prompt"
  cp "$LOG" "$(dirname "$IMG")/../boot-qemu.log" 2>/dev/null || cp "$LOG" ./boot-qemu.log
  exit 0
else
  echo "BOOT FAIL: no login prompt within timeout"
  cp "$LOG" ./boot-qemu.log
  exit 1
fi
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x poc/scripts/boot-qemu.sh`
Expected: no output.

- [ ] **Step 3: Boot and assert (M1 exit gate)**

Run: `nix --extra-experimental-features 'nix-command flakes' develop ./poc --command bash poc/scripts/boot-qemu.sh result/disk-image.qcow2`
Expected: serial output shows the kernel booting, systemd reaching multi-user, and finally `BOOT OK: reached login prompt`. A `./boot-qemu.log` is written.

**If boot stalls in GRUB/OVMF** (no kernel messages): the removable EFI path was not written. In `noble-bootable.nix:postInstall`, after `grub-install`, add
`cp /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true` inside the chroot, rebuild (Task 1.6), and re-boot.
**If boot reaches initramfs but cannot find root**: confirm `LABEL=root` in `/etc/fstab` and that `update-initramfs` ran; add `rootdelay=5` to `GRUB_CMDLINE_LINUX`, rebuild, re-boot.

- [ ] **Step 4: Commit**

```bash
git add poc/scripts/boot-qemu.sh
git commit -m "poc(m1): add headless QEMU/OVMF boot assertion (login-prompt gate)"
```

---

### Task 1.8: Record M1 findings back into the spec

**Files:**
- Modify: `docs/superpowers/specs/2026-07-06-nix-based-stemcell-feasibility-design.md` (§6 row 1, §8 M1, §10 risk 1)

- [ ] **Step 1: Update the dependency-resolution answer in §6**

In the feasibility table, replace the "Dependency-resolution fidelity" row's `Confidence` (`Low`) and answer with the M1 outcome. Use the actual result, e.g.:

```markdown
| **Dependency-resolution fidelity** (primitive resolver) | M1 result: the fork's resolver produced a closure of N packages; the diff vs apt's set was `<apt-only list>`. Boot-critical gaps: `<none | list>`. Resolution: `<sufficient as-is | augmented with explicit packages X,Y>`. A Noble image built and booted to a login prompt under QEMU/OVMF. | `<Medium/High>` |
```

- [ ] **Step 2: Mark M1 done and record the Incus deferral in §8**

Edit §8's **M1** block: change its exit line to
`- **Exit:** an unmodified Noble image built by makeImageFromDebDist boots to a login prompt under QEMU/OVMF.`
and append:
`- **Note:** standalone Incus boot was folded into M3 — importing/booting a custom image in Incus is exactly what lxd_cpi automates during \`bosh upload-stemcell\`, so validating it manually in M1 duplicated M3 for low signal.`

- [ ] **Step 3: Update risk #1 in §10**

Replace risk #1's text with the resolved status from Step 1 (whether the primitive resolver sufficed for noble, and any explicit-package mitigations applied).

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-07-06-nix-based-stemcell-feasibility-design.md
git commit -m "poc(m1): record dependency-resolution + boot findings in feasibility spec"
```

**M1 exit criteria:** `nix build ./poc#noble-bootable` produces `disk-image.qcow2`; `boot-qemu.sh` reaches a `login:` prompt; the resolver-fidelity comparison and boot outcome are recorded in the spec. The two riskiest article claims (privileged Nix-sandbox image assembly, and Debian resolver fidelity for the real noble set) are now answered with evidence, unblocking M2 (stage porting + stemcell packaging + Ruby removal).

---

## Out of Scope for M0–M1 (handled in later plans)

- **M2:** porting the remaining config-write/binary-install stages, switching to BOSH's MBR/`msdos` + BIOS GRUB layout (`image_create`/`image_install_grub`), installing the BOSH agent + `agent.json`, emitting the six-member stemcell tarball + `stemcell.MF` directly from Nix, deleting the Ruby/Rake build path, and running `bosh-stemcell/spec/` as the oracle.
- **M3:** `bosh upload-stemcell` to `instant-bosh` and a sample deployment (resolves the `lxd_cpi` ConfigDrive/HTTP settings-delivery and UEFI-vs-BIOS boot risks).
