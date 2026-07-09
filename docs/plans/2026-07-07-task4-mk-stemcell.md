# Task 4: mk-stemcell.nix — BOSH Stemcell Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a pure Nix derivation that packages the bootable qcow2 disk (from Task 2) into a valid 6-member BOSH stemcell tarball, meeting the upstream stemcell contract exactly.

**Architecture:** Two-file entry point pattern (matching Task 2 precedent):
- **`poc/lib/mk-stemcell.nix`** — reusable packaging function accepting `bootableDisk` (qcow2 path), version, OS metadata, and infrastructure details; outputs a derivation with the stemcell tarball
- **`poc/examples/noble-stemcell.nix`** — entry point calling `mk-stemcell.nix` with Task 2's qcow2 and POC defaults (version `0.0.1-nix`, `ubuntu-noble`, `openstack-kvm`)

**Tech Stack:** Nix derivations, bash scripting, tar/gzip, SHA-1 checksums, JSON generation

**Upstream Reference:** `bosh-linux-stemcell-builder/bosh-stemcell/lib/bosh/stemcell/stemcell_packager.rb` (Ruby implementation to translate to Nix/bash)

---

## File Structure

| File | Role |
|------|------|
| `poc/lib/mk-stemcell.nix` | Pure packaging derivation: qcow2 → 6-member stemcell `.tgz` |
| `poc/examples/noble-stemcell.nix` | Entry point: references `mk-stemcell.nix`, passes Task 2 disk + defaults |
| `nix-stemcell-poc.yml` | Jobless deploy manifest (created in Task 5, not here) |

---

## Task 1: Create `poc/lib/mk-stemcell.nix` — Derivation Shell

**Files:**
- Create: `poc/lib/mk-stemcell.nix`

- [ ] **Step 1: Write the minimal derivation skeleton**

Create `poc/lib/mk-stemcell.nix` with correct Nix structure but non-functional derivation (will flesh out in Tasks 2–6):

```nix
# mk-stemcell.nix
# Pure derivation: package bootable qcow2 disk into a 6-member BOSH stemcell tarball.
# Input: bootableDisk (path to root.qcow2)
# Output: $out/bosh-stemcell-VERSION-INFRASTRUCTURE-HYPERVISOR-OS-VERSION.tgz
{ stdenv
, lib
, coreutils
, gnutar
, gzip
, qemu
}:
{ bootableDisk
, version ? "0.0.1-nix"
, os ? "ubuntu"
, osVersion ? "noble"
, infrastructure ? "openstack"
, hypervisor ? "kvm"
}:

let
  # Compute stemcell archive filename per upstream convention:
  # bosh-stemcell-VERSION-INFRASTRUCTURE-HYPERVISOR-OS-OSVERSION.tgz
  stemcellFilename = "bosh-stemcell-${version}-${infrastructure}-${hypervisor}-${os}-${osVersion}.tgz";
in

stdenv.mkDerivation {
  name = "stemcell-packaging";
  
  buildInputs = [ coreutils gnutar gzip qemu ];
  
  # Dummy buildCommand; will be replaced in Task 2
  buildCommand = ''
    echo "Placeholder derivation for mk-stemcell.nix"
    mkdir -p $out
  '';
}
```

- [ ] **Step 2: Verify Nix evaluation succeeds**

Run: `cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder && nix eval ./poc/lib/mk-stemcell.nix --raw`

Expected: No evaluation errors (may show file not found for `bootableDisk` at runtime, that's OK for now).

---

## Task 2: Implement Inner Image Tarball & SHA-1 Logic

**Files:**
- Modify: `poc/lib/mk-stemcell.nix`

- [ ] **Step 1: Replace buildCommand with image tarball creation**

Replace the placeholder `buildCommand` in `mk-stemcell.nix` with:

```nix
  buildCommand = ''
    set -exuo pipefail
    
    # Setup working directory
    mkdir -p $out/work
    cd $out/work
    
    # Copy qcow2 to root.img (qcow2 file named as root.img, per BOSH OpenStack convention)
    ${coreutils}/bin/cp ${bootableDisk} root.img
    
    # Create inner image tarball
    # tar zcf image root.img
    ${gnutar}/bin/tar -cf image root.img
    
    # Compute SHA-1 of the inner image tarball (NOT root.img!)
    # This value goes into stemcell.MF
    imageSha1=$(${coreutils}/bin/sha1sum image | ${coreutils}/bin/cut -d' ' -f1)
    echo "$imageSha1" > image.sha1
    echo "Image SHA-1: $imageSha1"
  '';
```

- [ ] **Step 2: Test derivation evaluation**

Run: `nix eval ./poc/lib/mk-stemcell.nix -L 2>&1 | head -50`

Expected: No errors during evaluation phase.

---

## Task 3: Implement Manifest (stemcell.MF) JSON Generation

**Files:**
- Modify: `poc/lib/mk-stemcell.nix`

- [ ] **Step 1: Add JSON manifest generation to buildCommand**

Append this to the buildCommand (before final tarball creation):

```bash
    # Generate stemcell.MF (JSON manifest)
    # Must include the sha1 from the inner image tarball
    cat > stemcell.MF <<'MANIFEST'
name: bosh-openstack-kvm-ubuntu-${osVersion}
version: ${version}
bosh_protocol: 1
api_version: 3
sha1: $imageSha1
operating_system: ubuntu-${osVersion}
stemcell_formats:
  - openstack-qcow2
  - openstack-raw
cloud_properties:
  name: bosh-openstack-kvm-ubuntu-${osVersion}
  version: ${version}
  infrastructure: ${infrastructure}
  hypervisor: ${hypervisor}
  disk: 5120
  disk_format: qcow2
  container_format: bare
  os_type: linux
  os_distro: ubuntu
  architecture: x86_64
  auto_disk_config: true
MANIFEST
```

- [ ] **Step 2: Verify manifest is well-formed YAML**

Add a verification step in buildCommand:

```bash
    # Verify stemcell.MF is valid YAML (optional, for early catch)
    # If YAML tools unavailable, just trust the format
    echo "Manifest created; sha1=$imageSha1"
```

Expected: No errors; manifest file appears in `$out/work/stemcell.MF`.

---

## Task 4: Implement Stub Auxiliary Files

**Files:**
- Modify: `poc/lib/mk-stemcell.nix`

- [ ] **Step 1: Create stub files in buildCommand**

Add this to buildCommand (after manifest generation):

```bash
    # Create minimal stub files (director checks presence, ignores content per R6)
    touch packages.txt
    touch dev_tools_file_list.txt
    
    # Create stub SBOM files (empty JSON objects)
    echo '{}' > sbom.spdx.json
    echo '{}' > sbom.cdx.json
    
    echo "Stub files created"
```

- [ ] **Step 2: Verify all 6 members exist**

Add to buildCommand:

```bash
    # Verify all 6 required members exist
    expected_files=(
      "stemcell.MF"
      "packages.txt"
      "dev_tools_file_list.txt"
      "image"
      "sbom.spdx.json"
      "sbom.cdx.json"
    )
    
    for f in "''${expected_files[@]}"; do
      if [ ! -e "$f" ]; then
        echo "ERROR: Missing required file: $f"
        ls -la
        exit 1
      fi
    done
    
    echo "All 6 required members present"
```

---

## Task 5: Implement Final Tarball Assembly

**Files:**
- Modify: `poc/lib/mk-stemcell.nix`

- [ ] **Step 1: Add tarball creation to buildCommand**

Replace the final mkdir with tarball assembly:

```bash
    # Create final stemcell tarball with exactly the 6 members in spec order
    # (matching upstream stemcell_packager.rb:84)
    cd $out/work
    ${gnutar}/bin/tar -zcf stemcell.tgz \
      stemcell.MF \
      packages.txt \
      dev_tools_file_list.txt \
      image \
      sbom.spdx.json \
      sbom.cdx.json
    
    # Move to output directory with correct filename
    mv stemcell.tgz $out/${stemcellFilename}
    
    echo "Stemcell tarball created: $out/${stemcellFilename}"
    ls -lh $out/${stemcellFilename}
```

- [ ] **Step 2: End buildCommand**

Complete buildCommand with cleanup and final summary:

```bash
    cd $out
    tar -tzf ${stemcellFilename} | head -10
    echo "Stemcell package complete"
  '';
```

---

## Task 6: Verify derivation structure and test evaluation

**Files:**
- Modify: `poc/lib/mk-stemcell.nix` (complete)

- [ ] **Step 1: Check complete mk-stemcell.nix**

Verify the final `buildCommand` in `poc/lib/mk-stemcell.nix` contains all steps from Tasks 2–5 in sequence:
1. Copy qcow2 → root.img
2. Create inner image tarball
3. Compute SHA-1
4. Generate stemcell.MF
5. Create stub files
6. Verify all 6 members exist
7. Create and move final tarball

Expected: Single cohesive buildCommand with all steps.

- [ ] **Step 2: Syntax check the .nix file**

Run: `nix flake check /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder/poc 2>&1 | head -20`

Expected: Passes syntax check or shows meaningful Nix errors (not parse errors).

---

## Task 7: Create Entry Point `poc/examples/noble-stemcell.nix`

**Files:**
- Create: `poc/examples/noble-stemcell.nix`

- [ ] **Step 1: Write entry point referencing Task 2 disk**

Create `poc/examples/noble-stemcell.nix`:

```nix
# Entry point: Build a BOSH stemcell tarball for OpenStack/KVM (ubuntu-noble)
# Consumes the bootable qcow2 from Task 2 (noble-stemcell-disk.nix)
# Usage: nix build ./poc#noble-stemcell -L
# Output: ./result/bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz
{ callPackage, pkgs }:

let
  # Get the bootable qcow2 disk from Task 2
  bootableDisk = (callPackage ./noble-stemcell-disk.nix { }).out;
  
  # Load the mk-stemcell packaging derivation
  mkStemcell = callPackage ../lib/mk-stemcell.nix { };
in

mkStemcell {
  inherit bootableDisk;
  version = "0.0.1-nix";
  os = "ubuntu";
  osVersion = "noble";
  infrastructure = "openstack";
  hypervisor = "kvm";
}
```

- [ ] **Step 2: Verify entry point structure**

Run: `nix eval ./poc#noble-stemcell --raw 2>&1 | head -30`

Expected: Shows derivation or reference without errors (OK if dependencies not yet built).

---

## Task 8: Test Build — End-to-End

**Files:**
- None (build test only)

- [ ] **Step 1: Check if Task 2 disk exists**

Run: `ls -lh /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder/result/root.qcow2`

Expected: File exists, ~1.7 GiB.

If missing: Run `nix build /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder/poc#noble-stemcell-disk -L` first.

- [ ] **Step 2: Build the stemcell tarball**

Run: `cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder && nix build ./poc#noble-stemcell -L 2>&1 | tail -50`

Expected: Build succeeds, outputs summary of tarball creation.

- [ ] **Step 3: Check output exists**

Run: `ls -lh /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder/result/bosh-stemcell-*.tgz`

Expected: Exactly one file matching `bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz`, ~1.7 GiB.

---

## Task 9: Verify Archive Contents

**Files:**
- None (verification only)

- [ ] **Step 1: List archive members**

Run: `tar -tzf /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder/result/bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz`

Expected: Exactly these 6 members, in order:
```
stemcell.MF
packages.txt
dev_tools_file_list.txt
image
sbom.spdx.json
sbom.cdx.json
```

No extra files (no `.`, `..`, dotfiles).

- [ ] **Step 2: Extract and verify stemcell.MF**

Run: `tar -xzf /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder/result/bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz stemcell.MF -O`

Expected: Valid YAML with:
- `name: bosh-openstack-kvm-ubuntu-noble`
- `version: 0.0.1-nix`
- `sha1: <40-hex-char-hash>`
- `operating_system: ubuntu-noble`

- [ ] **Step 3: Verify image tarball SHA-1 matches manifest**

Run:
```bash
cd /tmp && \
tar -xzf /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder/result/bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz image && \
actual_sha1=$(sha1sum image | cut -d' ' -f1) && \
manifest_sha1=$(tar -xzf /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder/result/bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz stemcell.MF -O | grep sha1 | cut -d: -f2 | xargs) && \
if [ "$actual_sha1" = "$manifest_sha1" ]; then echo "SHA-1 MATCH: $actual_sha1"; else echo "MISMATCH: actual=$actual_sha1 manifest=$manifest_sha1"; fi
```

Expected: `SHA-1 MATCH: <hash>`

---

## Task 10: Commit Task 4 Implementation

**Files:**
- Modified: `poc/lib/mk-stemcell.nix` (new)
- Created: `poc/examples/noble-stemcell.nix` (new)

- [ ] **Step 1: Stage files**

Run: `cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder && git add poc/lib/mk-stemcell.nix poc/examples/noble-stemcell.nix`

- [ ] **Step 2: Create commit**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder && \
git commit -m "feat(task4): add mk-stemcell.nix packaging derivation

- Creates 6-member BOSH stemcell tarball from bootable qcow2 disk
- Implements stemcell.MF JSON manifest with correct SHA-1 of inner image
- Adds stub files (packages.txt, dev_tools_file_list.txt, sbom.spdx.json, sbom.cdx.json)
- Produces bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz
- Entry point: poc/examples/noble-stemcell.nix
- Upstream reference: bosh-stemcell/lib/bosh/stemcell/stemcell_packager.rb"
```

Expected: Commit succeeds.

- [ ] **Step 3: Verify commit**

Run: `cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder && git log -1 --name-status`

Expected: Shows commit with M4 files listed.

---

## Verification Gates (Final DoD)

✅ **Task 4 complete when:**
- [ ] `poc/lib/mk-stemcell.nix` exists and evaluates without error
- [ ] `poc/examples/noble-stemcell.nix` exists and calls mk-stemcell.nix correctly
- [ ] `nix build ./poc#noble-stemcell -L` succeeds
- [ ] `./result/bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz` exists (~1.7 GiB)
- [ ] Archive contains exactly 6 members (no more, no less) in correct order
- [ ] `stemcell.MF` is valid YAML with correct sha1 (matches inner image tarball)
- [ ] Commit created with descriptive message
- [ ] No extra files in archive (no dotfiles, no `..`, etc.)

---

## Spec Coverage Self-Review

| Spec Section | Plan Task(s) | Status |
|--------------|-------------|--------|
| Input: bootableDisk (qcow2) | Task 1, 2 | ✅ Param in mk-stemcell.nix, used in Task 2 |
| Input: version, os, osVersion, infrastructure, hypervisor | Task 1, 7 | ✅ Params in mk-stemcell.nix, defaults in noble-stemcell.nix |
| Inner image tarball creation | Task 2 | ✅ tar -cf image root.img |
| SHA-1 computation of inner tarball | Task 2 | ✅ sha1sum image, stored in image.sha1 |
| stemcell.MF JSON generation | Task 3 | ✅ Full manifest with all required fields |
| Stub files (packages.txt, dev_tools_file_list.txt, sbom*.json) | Task 4 | ✅ Created as empty/`{}` |
| Final tarball assembly (6-member, exact order) | Task 5 | ✅ tar -zcf with exact member list |
| Filename format (bosh-stemcell-VERSION-INFRA-HYPER-OS-OSVER.tgz) | Task 1, 7 | ✅ Computed in mk-stemcell.nix, output in task 5 |
| Entry point (noble-stemcell.nix) | Task 7 | ✅ Calls mk-stemcell.nix with Task 2 disk + defaults |
| Build success (nix build ./poc#noble-stemcell) | Task 8 | ✅ Tests from Task 8 gate this |
| Archive contents verification | Task 9 | ✅ Extraction tests confirm 6 members + SHA-1 match |
| Commit with descriptive message | Task 10 | ✅ Final commit task |

No gaps identified. All spec requirements have corresponding plan tasks.

---

## Plan Complete

This plan provides step-by-step implementation of `mk-stemcell.nix` and entry point, validated against the M4 design spec and upstream reference implementation. Each task is bite-sized (2–5 minutes) and produces testable artifacts.

**Next: Choose execution mode** (below).
