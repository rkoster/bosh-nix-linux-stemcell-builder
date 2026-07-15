# Deterministic Stemcell Metadata & SBOM Generation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the four empty stub stemcell members (`packages.txt`, `dev_tools_file_list.txt`, `sbom.spdx.json`, `sbom.cdx.json`) with real, deterministically-generated content produced purely in Nix.

**Architecture:** Generate all four files inside the existing `fakeroot` session of `build/rootfs/apply-stages.nix`, where the complete final rootfs tree (`$root`) — real dpkg admindir plus all source-built binaries — already exists with no VM. Use `dpkg-query` for the two package files and `syft dir:$root` (normalized with `jq`) for the two SBOMs. Thread the generated files through `os-image` → `openstack-kvm.nix` → `package.nix`, replacing the stubs.

**Tech Stack:** Nix (nixos-26.05), fakeroot, dpkg / dpkg-query, syft 1.44.0, jq, bash.

**Design reference:** `docs/specs/2026-07-15-stemcell-metadata-sbom-design.md`

**Build-time note:** Building `os-image` and the stemcell is expensive (deb closure VM + ~3 GB rootfs extract/repack + syft scan). Each `nix build` in this plan may take many minutes. That is expected.

---

## File Structure

- **Modify** `build/rootfs/apply-stages.nix` — add `dpkg`, `syft`, `jq`, `file` inputs; generate the four metadata files from `$root` into `$out/metadata/`.
- **Create** `build/rootfs/dev-tools-packages.nix` — the hardcoded dev-tool package name list (ported from upstream `generate_dev_tools_file_list.sh`), imported by `apply-stages.nix`.
- **Modify** `build/stemcells/package.nix` — accept a `metadata` input; replace the four stub lines with `cp` from `${metadata}/metadata/`.
- **Modify** `build/stemcells/openstack-kvm.nix` — resolve the `os-image` derivation and pass it as `metadata` to `mkStemcell`.
- **Modify** `docs/ARCHITECTURE.md` — correct the stale attribution of these files.

---

## Task 1: Dev-tools package list module

**Files:**
- Create: `build/rootfs/dev-tools-packages.nix`

- [ ] **Step 1: Create the dev-tools package list**

Port the package array from upstream `stemcell_builder/stages/dev_tools_config/assets/generate_dev_tools_file_list.sh` (de-duplicated), as a plain Nix list of strings.

Create `build/rootfs/dev-tools-packages.nix`:

```nix
# Build/compiler-tool package names whose files the BOSH director may strip from
# non-compilation VMs. Ported verbatim (de-duplicated) from upstream
# stemcell_builder/stages/dev_tools_config/assets/generate_dev_tools_file_list.sh.
# apply-stages.nix intersects this with packages actually installed in the rootfs
# and emits their regular-file paths to dev_tools_file_list.txt.
[
  "binutils"
  "bison"
  "build-essential"
  "cmake"
  "cpp"
  "debhelper"
  "dkms"
  "dpkg-dev"
  "flex"
  "g++"
  "gcc"
  "gettext"
  "intltool-debian"
  "libmpc3"
  "make"
  "patch"
  "po-debconf"
  "cpp-5"
  "cpp-7"
  "cpp-8"
  "cpp-9"
  "cpp-10"
  "cpp-11"
  "g++-5"
  "g++-7"
  "gcc-5"
  "gcc-6"
  "gcc-7"
  "gcc-8"
  "gcc-10"
  "gcc-11"
  "gcc-5-base"
  "gcc-6-base"
  "gcc-7-base"
  "gcc-8-base"
  "gcc-9-base"
  "gcc-10-base"
  "gcc-11-base"
  "clang"
  "clang-14"
  "lib32gcc-s1"
  "lib32stdc++6"
  "libc6-i386"
  "libclang-common-14-dev"
  "libclang-cpp14"
  "libclang1-14"
  "libgc1"
  "libllvm14"
  "libobjc-11-dev"
  "libobjc4"
  "llvm-14-linker-tools"
]
```

- [ ] **Step 2: Verify the file evaluates**

Run: `nix eval --impure --expr 'builtins.length (import ./build/rootfs/dev-tools-packages.nix)'`
Expected: prints `50` (a positive integer; the list evaluates without error).

- [ ] **Step 3: Commit**

```bash
git add build/rootfs/dev-tools-packages.nix
git commit -m "feat: add dev-tools package list for stemcell metadata"
```

---

## Task 2: Generate packages.txt and dev_tools_file_list.txt in apply-stages

**Files:**
- Modify: `build/rootfs/apply-stages.nix`

- [ ] **Step 1: Add new inputs to the function signature**

In `build/rootfs/apply-stages.nix`, the first argument set (lines 18-28) lists build tools. Add `dpkg`, `file`, and import the dev-tools list. Change:

```nix
{
  stdenv,
  fakeroot,
  gnutar,
  pigz,
  coreutils,
  gnused,
  gawk,
  gnugrep,
  findutils,
}:
{ base, stages }:
```

to:

```nix
{
  stdenv,
  fakeroot,
  gnutar,
  pigz,
  coreutils,
  gnused,
  gawk,
  gnugrep,
  findutils,
  dpkg,
  file,
}:
{ base, stages }:
let
  devToolsPackages = import ./dev-tools-packages.nix;
  devToolsBashArray = builtins.concatStringsSep " " (
    map (p: "\"${p}\"") devToolsPackages
  );
in
```

Note: the existing `let ... in` block for `runStages` (lines 30-39) must be merged into this new `let`. Keep the existing `runStages` binding inside the same `let`.

- [ ] **Step 2: Add the two build tools to nativeBuildInputs**

In the `nativeBuildInputs` list (lines 42-51), add `dpkg` and `file`:

```nix
  nativeBuildInputs = [
    fakeroot
    gnutar
    pigz
    coreutils
    gnused
    gawk
    gnugrep
    findutils
    dpkg
    file
  ];
```

- [ ] **Step 3: Add metadata generation inside the fakeroot session**

In the `buildCommand`, immediately AFTER the final repack tar (after line 87, `... | pigz -1n > "$out/rootfs.tar.gz"`) and still BEFORE the `IN_FAKEROOT` terminator (line 88), insert:

```bash

    # --- stemcell metadata: packages.txt + dev_tools_file_list.txt ---------
    # Generated from the real dpkg admindir baked into $root by the deb-closure
    # base rootfs. Pure (no VM); dpkg-query only reads the text db.
    mkdir -p "$out/metadata"
    admindir="$root/var/lib/dpkg"

    # packages.txt: exact `dpkg -l` column format (upstream bosh_package_list).
    dpkg-query --admindir="$admindir" -l > "$out/metadata/packages.txt"

    # dev_tools_file_list.txt: for each dev-tool package that is actually
    # installed, list its regular files (excluding directories and symlinks),
    # sorted + unique. Mirrors upstream generate_dev_tools_file_list.sh.
    dev_tools_pkgs=( ${devToolsBashArray} )
    dev_tools_tmp="$(mktemp)"
    for pkg in "''${dev_tools_pkgs[@]}"; do
      if dpkg-query --admindir="$admindir" -W "$pkg" >/dev/null 2>&1; then
        dpkg-query --admindir="$admindir" -L "$pkg" 2>/dev/null || true
      fi
    done > "$dev_tools_tmp" || true

    : > "$out/metadata/dev_tools_file_list.txt"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      target="$root$p"
      # keep only regular files that are not symlinks (upstream filters dirs +
      # symlinks via `file`)
      if [ -f "$target" ] && [ ! -L "$target" ]; then
        printf '%s\n' "$p"
      fi
    done < "$dev_tools_tmp" | sort -u > "$out/metadata/dev_tools_file_list.txt"
```

- [ ] **Step 4: Build os-image and verify the two files**

Run:
```bash
nix build .#os-image -L
ls -l ./result/metadata/
head -5 ./result/metadata/packages.txt
```
Expected: `./result/metadata/packages.txt` exists and is non-empty; its first lines are the `dpkg -l` header (`Desired=...`, `| Status=...`, `+++-===`), followed by `ii  <pkg>  <version>  <arch>  <description>` rows. `dev_tools_file_list.txt` exists (may be empty if no dev-tool packages are installed — that is valid).

- [ ] **Step 5: Assert packages.txt contains a known package**

Run: `grep -E '^ii\s+dpkg\s' ./result/metadata/packages.txt`
Expected: one matching line for the `dpkg` package (non-empty output, exit 0).

- [ ] **Step 6: Commit**

```bash
git add build/rootfs/apply-stages.nix
git commit -m "feat: generate packages.txt and dev_tools_file_list.txt from rootfs dpkg db"
```

---

## Task 3: Generate normalized SBOMs with syft in apply-stages

**Files:**
- Modify: `build/rootfs/apply-stages.nix`

- [ ] **Step 1: Add syft and jq to inputs**

In the first argument set of `build/rootfs/apply-stages.nix`, add `syft` and `jq` alongside `dpkg` and `file`:

```nix
  dpkg,
  file,
  syft,
  jq,
}:
```

- [ ] **Step 2: Add syft and jq to nativeBuildInputs**

Append to the `nativeBuildInputs` list:

```nix
    dpkg
    file
    syft
    jq
```

- [ ] **Step 3: Add SBOM generation after the packages.txt/dev-tools block**

Immediately after the dev_tools_file_list.txt block added in Task 2 (still inside the fakeroot session, before `IN_FAKEROOT`), insert:

```bash

    # --- stemcell SBOMs: sbom.spdx.json + sbom.cdx.json --------------------
    # One syft scan of the whole rootfs tree covers BOTH the Ubuntu .deb
    # packages (dpkg cataloger) and the source-built Go binaries (bosh-agent,
    # blobstore CLIs). SOURCE_DATE_EPOCH is already exported above (1700000000).
    export HOME="$TMPDIR"
    export XDG_CACHE_HOME="$TMPDIR/syft-cache"
    export SYFT_CHECK_FOR_APP_UPDATE=false
    mkdir -p "$XDG_CACHE_HOME"

    syft scan "dir:$root" \
      -o "spdx-json=$out/metadata/sbom.spdx.json.raw" \
      -o "cyclonedx-json=$out/metadata/sbom.cdx.json.raw"

    # Normalize non-deterministic fields to fixed values derived from
    # SOURCE_DATE_EPOCH=1700000000 (== 2023-11-14T22:13:20Z). --sort-keys makes
    # object key ordering stable across syft runs.
    jq --sort-keys '
      .documentNamespace = "https://bosh.io/stemcell/ubuntu-noble" |
      .creationInfo.created = "2023-11-14T22:13:20Z" |
      .name = "bosh-stemcell-ubuntu-noble"
    ' "$out/metadata/sbom.spdx.json.raw" > "$out/metadata/sbom.spdx.json"

    jq --sort-keys '
      .serialNumber = "urn:uuid:00000000-0000-0000-0000-000000000000" |
      .metadata.timestamp = "2023-11-14T22:13:20Z"
    ' "$out/metadata/sbom.cdx.json.raw" > "$out/metadata/sbom.cdx.json"

    rm -f "$out/metadata/sbom.spdx.json.raw" "$out/metadata/sbom.cdx.json.raw"
```

- [ ] **Step 4: Build os-image and verify SBOMs are valid JSON**

Run:
```bash
nix build .#os-image -L
jq empty ./result/metadata/sbom.spdx.json && echo SPDX_OK
jq empty ./result/metadata/sbom.cdx.json && echo CDX_OK
```
Expected: `SPDX_OK` and `CDX_OK` both print (both files are valid JSON).

- [ ] **Step 5: Assert SBOM covers both a deb and a source-built component**

Run (SPDX package names):
```bash
jq -r '.packages[].name' ./result/metadata/sbom.spdx.json | grep -E '^(dpkg|systemd)$'
jq -r '.packages[].name' ./result/metadata/sbom.spdx.json | grep -i 'bosh-agent'
```
Expected: the first `grep` matches a core deb package (e.g. `dpkg` or `systemd`). The second matches the source-built `bosh-agent` Go binary (non-empty; confirms the Go cataloger picked it up). If `bosh-agent` is absent, note it in findings — the Go binary may be located under `/var/vcap/bosh` and syft should still catalog it; investigate before proceeding.

- [ ] **Step 6: Assert normalized fields are pinned**

Run:
```bash
jq -r '.creationInfo.created, .documentNamespace' ./result/metadata/sbom.spdx.json
jq -r '.metadata.timestamp, .serialNumber' ./result/metadata/sbom.cdx.json
```
Expected: `2023-11-14T22:13:20Z` + `https://bosh.io/stemcell/ubuntu-noble` for SPDX; `2023-11-14T22:13:20Z` + `urn:uuid:00000000-0000-0000-0000-000000000000` for CycloneDX.

- [ ] **Step 7: Commit**

```bash
git add build/rootfs/apply-stages.nix
git commit -m "feat: generate deterministic SBOMs with syft in apply-stages"
```

---

## Task 4: Thread metadata into the stemcell package

**Files:**
- Modify: `build/stemcells/package.nix`
- Modify: `build/stemcells/openstack-kvm.nix`

- [ ] **Step 1: Add `metadata` input to package.nix**

In `build/stemcells/package.nix`, the second (curried) argument set is lines 13-20. Add `metadata`:

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

- [ ] **Step 2: Replace the four stub lines with copies from metadata**

In `build/stemcells/package.nix`, replace the stub block (lines 89-97):

```bash
        # Create minimal stub files (director checks presence, ignores content per R6)
        touch packages.txt
        touch dev_tools_file_list.txt
        
        # Create stub SBOM files (empty JSON objects)
        echo '{}' > sbom.spdx.json
        echo '{}' > sbom.cdx.json
        
        echo "Stub files created"
```

with:

```bash
        # Copy real metadata members generated from the rootfs (apply-stages.nix)
        ${coreutils}/bin/cp ${metadata}/metadata/packages.txt packages.txt
        ${coreutils}/bin/cp ${metadata}/metadata/dev_tools_file_list.txt dev_tools_file_list.txt
        ${coreutils}/bin/cp ${metadata}/metadata/sbom.spdx.json sbom.spdx.json
        ${coreutils}/bin/cp ${metadata}/metadata/sbom.cdx.json sbom.cdx.json
        
        echo "Metadata members copied"
```

Leave the presence check (lines 99-115) and tar assembly (lines 122-131) unchanged.

- [ ] **Step 3: Pass metadata from openstack-kvm.nix**

In `build/stemcells/openstack-kvm.nix`, update the `let` block (lines 5-8) to resolve the os-image derivation, and pass it into `mkStemcell`. Change:

```nix
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

to:

```nix
let
  bootableDiskDerivation = callPackage ./openstack-kvm-disk.nix { };
  bootableDisk = "${bootableDiskDerivation}/root.qcow2";
  # Same memoized derivation used inside openstack-kvm-disk.nix; provides the
  # generated stemcell metadata members under ${metadata}/metadata/.
  metadata = callPackage ../rootfs/os-image.nix { };
  mkStemcell = callPackage ./package.nix { };
in
mkStemcell {
  inherit bootableDisk metadata;
  version = "0.0.5-nix";
  os = "ubuntu";
  osVersion = "noble";
  infrastructure = "openstack";
  hypervisor = "kvm";
}
```

- [ ] **Step 4: Build the full stemcell**

Run: `nix build .#openstack-kvm -L`
Expected: build succeeds; `./result/` contains `bosh-stemcell-0.0.5-nix-openstack-kvm-ubuntu-noble.tgz`.

- [ ] **Step 5: Assert all 6 members present with real content**

Run:
```bash
mkdir -p /tmp/sc-verify && tar -xzf ./result/*.tgz -C /tmp/sc-verify
ls -l /tmp/sc-verify
test -s /tmp/sc-verify/packages.txt && echo PACKAGES_NONEMPTY
jq empty /tmp/sc-verify/sbom.spdx.json && jq empty /tmp/sc-verify/sbom.cdx.json && echo SBOMS_VALID
grep -E '^ii\s+dpkg\s' /tmp/sc-verify/packages.txt && echo PACKAGES_OK
```
Expected: all 6 members listed (`stemcell.MF`, `packages.txt`, `dev_tools_file_list.txt`, `image`, `sbom.spdx.json`, `sbom.cdx.json`); `PACKAGES_NONEMPTY`, `SBOMS_VALID`, and `PACKAGES_OK` all print.

- [ ] **Step 6: Commit**

```bash
git add build/stemcells/package.nix build/stemcells/openstack-kvm.nix
git commit -m "feat: package real metadata and SBOM members into the stemcell"
```

---

## Task 5: Determinism validation (double build)

**Files:** none (verification only)

- [ ] **Step 1: Build os-image, capture hashes**

Run:
```bash
nix build .#os-image -L --out-link /tmp/osimg-a
sha256sum /tmp/osimg-a/metadata/packages.txt \
          /tmp/osimg-a/metadata/dev_tools_file_list.txt \
          /tmp/osimg-a/metadata/sbom.spdx.json \
          /tmp/osimg-a/metadata/sbom.cdx.json | tee /tmp/meta-a.sha
```
Expected: four sha256 lines printed and saved.

- [ ] **Step 2: Force a rebuild and re-capture**

Run:
```bash
nix build .#os-image -L --rebuild --out-link /tmp/osimg-b
sha256sum /tmp/osimg-b/metadata/packages.txt \
          /tmp/osimg-b/metadata/dev_tools_file_list.txt \
          /tmp/osimg-b/metadata/sbom.spdx.json \
          /tmp/osimg-b/metadata/sbom.cdx.json | tee /tmp/meta-b.sha
```
Expected: four sha256 lines.

- [ ] **Step 3: Assert byte-identical across builds**

Run:
```bash
for f in packages.txt dev_tools_file_list.txt sbom.spdx.json sbom.cdx.json; do
  if cmp -s /tmp/osimg-a/metadata/$f /tmp/osimg-b/metadata/$f; then
    echo "DETERMINISTIC: $f"
  else
    echo "NON-DETERMINISTIC: $f"; diff <(jq --sort-keys . /tmp/osimg-a/metadata/$f 2>/dev/null || cat /tmp/osimg-a/metadata/$f) \
                                        <(jq --sort-keys . /tmp/osimg-b/metadata/$f 2>/dev/null || cat /tmp/osimg-b/metadata/$f) | head -40
  fi
done
```
Expected: `DETERMINISTIC:` for all four files. If any SBOM shows `NON-DETERMINISTIC`, inspect the diff for additional syft-embedded volatile fields (e.g. per-package `SPDXID` suffixes, `licenses` ordering) and extend the `jq` normalization in `apply-stages.nix` (Task 3, Step 3) to pin/sort them, then re-run this task.

- [ ] **Step 4: Commit (only if normalization changed)**

If Step 3 required jq changes:
```bash
git add build/rootfs/apply-stages.nix
git commit -m "fix: pin additional syft fields for deterministic SBOMs"
```
If no changes were needed, skip this step.

---

## Task 6: Correct stale documentation

**Files:**
- Modify: `docs/ARCHITECTURE.md`

- [ ] **Step 1: Locate the stale attribution**

Run: `grep -n 'packages.txt\|dev_tools\|sbom\|misc-os/apply.sh' docs/ARCHITECTURE.md`
Expected: line(s) around 455 (and 396-397, 521-524) attributing these files to `build/stages/misc-os/apply.sh`.

- [ ] **Step 2: Update the attribution**

Edit the relevant lines in `docs/ARCHITECTURE.md` to state that `packages.txt`, `dev_tools_file_list.txt`, `sbom.spdx.json`, and `sbom.cdx.json` are generated in `build/rootfs/apply-stages.nix` from the final rootfs (`dpkg-query` for the package files, `syft` for the SBOMs) and copied into the stemcell by `build/stemcells/package.nix`. Remove the claim that `build/stages/misc-os/apply.sh` produces them.

- [ ] **Step 3: Commit**

```bash
git add docs/ARCHITECTURE.md
git commit -m "docs: correct attribution of stemcell metadata generation"
```

---

## Self-Review Notes

- **Spec coverage:** packages.txt (Task 2), dev_tools_file_list.txt (Task 1+2), both SBOMs incl. deb + source-built coverage (Task 3), determinism via SOURCE_DATE_EPOCH + jq normalization (Task 3) and validated by double-build (Task 5), plumbing into package.nix (Task 4), docs follow-up (Task 6). monit-as-explicit-component was explicitly accepted as out-of-scope by the user.
- **Type/interface consistency:** `metadata` input name is consistent across `package.nix` (Task 4 Step 1) and `openstack-kvm.nix` (Task 4 Step 3); files land in `$out/metadata/` (Task 2/3) and are read from `${metadata}/metadata/` (Task 4 Step 2). The dev-tools list module path `./dev-tools-packages.nix` is consistent between Task 1 and Task 2 Step 1.
- **Risk flagged inline:** Task 3 Step 5 (bosh-agent cataloging) and Task 5 Step 3 (residual SBOM non-determinism) include explicit investigate-and-fix guidance rather than assuming success.
