# Faster Stemcell Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut Nix stemcell build wall-time by collapsing the 11-derivation overlay chain into a single `fakeroot` derivation and using parallel `pigz` compression, without changing the produced stemcell's behavior.

**Architecture:** The overlay chain (`os-image.nix` `foldl` over `mk-overlay.nix`) currently extracts+gzip-recompresses the full ~3 GB rootfs 11 times serially. Replace it with one derivation (`mk-apply-overlays.nix`) that extracts once, runs all overlay scripts in one continuous `fakeroot` session, and repacks once with `pigz -1`. Separately, switch the inner stemcell `image` gzip (`mk-stemcell.nix`) to `pigz -1`.

**Tech Stack:** Nix (nixpkgs `nixos-26.05`, `vmTools`), `fakeroot`, `tar`, `pigz`, bash.

**Design reference:** `docs/superpowers/specs/2026-07-08-faster-stemcell-build-design.md`

---

## File Structure

- **Create** `poc/lib/mk-apply-overlays.nix` — single-derivation overlay applier: takes `{ base, overlays }` (list of `{ name, script }`), returns a derivation producing `$out/rootfs.tar.gz`.
- **Modify** `poc/examples/os-image.nix` — replace the `foldl`/`mk-overlay` wiring with one `applyOverlays { inherit base overlays; }` call.
- **Modify** `poc/lib/mk-stemcell.nix` — inner `image` member built with `pigz -1`; add `pigz` to inputs.
- **Modify** `poc/lib/overlays/audit.nix` — update the code comment that references `mk-overlay.nix`.
- **Delete** `poc/lib/mk-overlay.nix` — retired once unreferenced.

Baseline timing is captured first (Task 1) so the speedup is measurable.

---

## Task 1: Capture baseline build time

**Files:** none (measurement only).

- [ ] **Step 1: Ensure a clean tree and free disk**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
git status --short
df -h / | tail -1
```
Expected: working tree shows only the already-modified files from prior work (`poc/lib/noble-packages.nix`, `poc/pkgs/monit.nix`, `poc/examples/os-image.nix`); root filesystem has >20 GB free. If <20 GB free, run `nix store gc` first.

- [ ] **Step 2: Time a full rebuild of the stemcell (baseline)**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
/usr/bin/time -v nix build ./poc#noble-stemcell --rebuild --out-link result-baseline 2>&1 | tail -20
```
Expected: build succeeds; note the "Elapsed (wall clock) time" line. Record it in the design doc's Validation section (append a line: `Baseline wall-time: <value>`).

- [ ] **Step 3: Record a content fingerprint of the current os-image (for later equivalence check)**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
nix build ./poc#os-image --out-link result-osimage-baseline
tar -tvzf result-osimage-baseline/rootfs.tar.gz | sort -k1,4 \
  | sha256sum > /tmp/osimage-baseline-listing.sha256
cat /tmp/osimage-baseline-listing.sha256
```
Expected: prints a sha256. This hashes the sorted `tar -tv` listing (paths + perms + owners + sizes), which must stay identical after the refactor. Keep the file.

- [ ] **Step 4: Commit nothing; clean up baseline links**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
rm -f result-baseline result-osimage-baseline
```
Expected: links removed (store paths remain cached).

---

## Task 2: Create the single-derivation overlay applier

**Files:**
- Create: `poc/lib/mk-apply-overlays.nix`

- [ ] **Step 1: Write `mk-apply-overlays.nix`**

Create `poc/lib/mk-apply-overlays.nix` with exactly:

```nix
# Pure-Nix (no VM, no chroot) rootfs transform that applies MANY overlays in a
# SINGLE fakeroot session: extract the base rootfs.tar.gz once, run every overlay
# script in order (each in an isolated subshell), then repack once.
#
# This replaces the previous per-overlay mk-overlay.nix folded 11x, which
# extracted + gzip-recompressed the full ~3 GB rootfs on every overlay. Here the
# expensive extract/repack happens exactly once.
#
# Ownership: the Nix store normalizes file ownership, but the BOSH rootfs needs
# real uid/gid 0 (and package-created users). A single continuous `fakeroot`
# session holds that ownership state end-to-end; the final `tar --numeric-owner`
# serializes it so it survives the store boundary (same guarantee mk-overlay.nix
# gave, without re-deriving it 11 times). See the auditd/sshd/sudo "not owned by
# root" failure mode this prevents.
#
# Compression: intermediate gzip is not load-bearing (tar -xf auto-detects), so
# the single final repack uses parallel `pigz -1`.
{ stdenv, fakeroot, gnutar, pigz, coreutils, gnused, gawk, gnugrep, findutils }:
{ base, overlays }:
let
  runOverlays = builtins.concatStringsSep "\n" (map (ov: ''
    echo "=== overlay: ${ov.name} ==="
    ( set -euxo pipefail
      ${ov.script}
    )
  '') overlays);
in
stdenv.mkDerivation {
  name = "os-image";
  nativeBuildInputs = [ fakeroot gnutar pigz coreutils gnused gawk gnugrep findutils ];
  buildCommand = ''
    fakeroot bash -euxo pipefail <<'IN_FAKEROOT'
    root="$PWD/root"
    mkdir -p "$root"
    tar -xzf ${base}/rootfs.tar.gz -C "$root"

    # --- overlay scripts run here in order; $root is the rootfs tree ---
    ${runOverlays}
    # ------------------------------------------------------------------

    # Ensure all files are readable for tar packing (fix any 0000 permissions)
    find "$root" -perm /000 -exec chmod u+r {} \; 2>/dev/null || true

    mkdir -p "$out"
    tar --numeric-owner --one-file-system -C "$root" -cf - . | pigz -1 > "$out/rootfs.tar.gz"
    IN_FAKEROOT
  '';
}
```

> The heredoc delimiter is **quoted** (`<<'IN_FAKEROOT'`), exactly as the original `mk-overlay.nix`. Nix still interpolates `${base}` and `${runOverlays}` (Nix `''` interpolation is independent of bash heredoc quoting), while the quoting prevents the *outer* build shell from expanding `$root`/`$out`/`$PWD` — those are expanded by the inner `fakeroot bash`. This is the proven pattern; do not switch to an unquoted heredoc.

- [ ] **Step 2: Commit the new file (not yet wired in)**

```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
git add poc/lib/mk-apply-overlays.nix
git commit -m "feat: add single-session overlay applier (mk-apply-overlays)"
```

---

## Task 3: Wire os-image.nix to the new applier

**Files:**
- Modify: `poc/examples/os-image.nix` (lines 7 and 44-46)

- [ ] **Step 1: Replace the applier import**

In `poc/examples/os-image.nix`, change line 7 from:
```nix
  applyOverlay = callPackage ../lib/mk-overlay.nix { };
```
to:
```nix
  applyOverlays = callPackage ../lib/mk-apply-overlays.nix { };
```

- [ ] **Step 2: Replace the foldl with a single call**

In `poc/examples/os-image.nix`, change the block at lines 44-46 from:
```nix
  final = lib.foldl (acc: ov: applyOverlay {
    base = acc; inherit (ov) name script;
  }) base overlays;
```
to:
```nix
  final = applyOverlays { inherit base overlays; };
```

> `lib` may now be unused in this file. Leave the `{ callPackage, lib, writeText }:` header as-is — an unused function argument is harmless in Nix and removing it risks breaking callers that pass it. (If a later cleanup pass wants it gone, that is a separate change.)

- [ ] **Step 3: Build the os-image and verify it succeeds**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
nix build ./poc#os-image --rebuild --out-link result-osimage-new 2>&1 | tail -15
```
Expected: build succeeds; `result-osimage-new/rootfs.tar.gz` exists.

- [ ] **Step 4: Verify rootfs content is byte-equivalent to baseline**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
tar -tvzf result-osimage-new/rootfs.tar.gz | sort -k1,4 \
  | sha256sum > /tmp/osimage-new-listing.sha256
diff /tmp/osimage-baseline-listing.sha256 /tmp/osimage-new-listing.sha256 \
  && echo "ROOTFS LISTING IDENTICAL" || echo "MISMATCH - investigate"
```
Expected: `ROOTFS LISTING IDENTICAL`. The sorted `tar -tv` listing (paths, perms, uid/gid, sizes) must match the Task 1 baseline — proving the collapse changed nothing about the produced tree, only how it was produced. If MISMATCH, inspect the diff of the two listings before proceeding.

- [ ] **Step 5: Commit**

```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
git add poc/examples/os-image.nix
git commit -m "perf: apply overlays in one fakeroot session instead of folding 11 derivations"
rm -f result-osimage-new
```

---

## Task 4: Parallel compression for the inner stemcell image

**Files:**
- Modify: `poc/lib/mk-stemcell.nix` (inputs line 5-11; buildInputs line 29; image line 42)

- [ ] **Step 1: Add `pigz` to the derivation inputs**

In `poc/lib/mk-stemcell.nix`, change the input attrset (lines 5-11) from:
```nix
{ stdenv
, lib
, coreutils
, gnutar
, gzip
, qemu
}:
```
to:
```nix
{ stdenv
, lib
, coreutils
, gnutar
, gzip
, pigz
, qemu
}:
```

- [ ] **Step 2: Add `pigz` to buildInputs**

In `poc/lib/mk-stemcell.nix`, change line 29 from:
```nix
  buildInputs = [ coreutils gnutar gzip qemu ];
```
to:
```nix
  buildInputs = [ coreutils gnutar gzip pigz qemu ];
```

- [ ] **Step 3: Build the inner `image` member with pigz**

In `poc/lib/mk-stemcell.nix`, change line 42 from:
```nix
    ${gnutar}/bin/tar -czf image root.img
```
to:
```nix
    ${gnutar}/bin/tar -cf - root.img | ${pigz}/bin/pigz -1 > image
```

> `pigz` emits standard gzip, so the CPI still sees a gzipped tar and the `sha1` computed over `image` in the next step is unaffected in format (its value changes only because compression level/impl differ — expected and fine; the manifest recomputes it).

- [ ] **Step 4: Build the full stemcell and verify success**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
nix build ./poc#noble-stemcell --out-link result-stemcell 2>&1 | tail -15
ls -lh result-stemcell/*.tgz
```
Expected: build succeeds; a `bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz` exists.

- [ ] **Step 5: Verify the inner image is a valid gzip tar**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
mkdir -p /tmp/sc-verify && tar -xf result-stemcell/*.tgz -C /tmp/sc-verify
file /tmp/sc-verify/image
tar -tzf /tmp/sc-verify/image
```
Expected: `file` reports gzip-compressed data; `tar -tzf` lists `root.img`. Confirms pigz output is CPI-compatible.

- [ ] **Step 6: Commit**

```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
git add poc/lib/mk-stemcell.nix
git commit -m "perf: compress inner stemcell image with parallel pigz"
rm -rf /tmp/sc-verify
```

---

## Task 5: Retire mk-overlay.nix and fix stale comment

**Files:**
- Modify: `poc/lib/overlays/audit.nix:187`
- Delete: `poc/lib/mk-overlay.nix`

- [ ] **Step 1: Confirm nothing else references mk-overlay.nix**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
grep -rn "mk-overlay" poc/ || echo "NO REMAINING CODE REFERENCES"
```
Expected: the only hit is the comment in `poc/lib/overlays/audit.nix:187`. If any `.nix` file still *imports* `mk-overlay.nix`, stop and fix that first.

- [ ] **Step 2: Update the stale comment in audit.nix**

In `poc/lib/overlays/audit.nix`, change the line at 187 from:
```
    # For the tarball to record uid/gid 0, we use fakeroot in mk-overlay.nix
```
to:
```
    # For the tarball to record uid/gid 0, we use fakeroot in mk-apply-overlays.nix
```

- [ ] **Step 3: Delete the retired file**

```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
git rm poc/lib/mk-overlay.nix
```

- [ ] **Step 4: Verify the stemcell still evaluates and builds**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
nix build ./poc#noble-stemcell --out-link result-stemcell 2>&1 | tail -8
```
Expected: build succeeds (cached from Task 4; deleting the unused file changes nothing).

- [ ] **Step 5: Commit**

```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
git add poc/lib/overlays/audit.nix
git commit -m "chore: retire mk-overlay.nix (superseded by mk-apply-overlays)"
```

---

## Task 6: Measure speedup and validate end-to-end

**Files:**
- Modify: `docs/superpowers/specs/2026-07-08-faster-stemcell-build-design.md` (append measured results)

- [ ] **Step 1: Time a full rebuild (after)**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
/usr/bin/time -v nix build ./poc#noble-stemcell --rebuild --out-link result-stemcell 2>&1 | tail -20
```
Expected: build succeeds; record "Elapsed (wall clock) time". Compare to the Task 1 baseline.

- [ ] **Step 2: Record before/after in the design doc**

Append to the "Validation" section of
`docs/superpowers/specs/2026-07-08-faster-stemcell-build-design.md`:
```markdown

### Measured results
- Baseline wall-time (before): <Task 1 value>
- After (collapse + pigz): <Step 1 value>
- Speedup: <ratio>
```
Fill in the real values.

- [ ] **Step 3: Run the oracle serverspec suite against the new os-image**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
nix build ./poc#os-image --out-link result-osimage
bash poc/oracle/run-os-image-specs.sh result-osimage/rootfs.tar.gz 2>&1 | tail -30
```
Expected: serverspec suite passes (same result as before the refactor). If the script needs the oracle devshell, run it via `nix develop ./poc#oracle -c bash poc/oracle/run-os-image-specs.sh result-osimage/rootfs.tar.gz`.

- [ ] **Step 4: End-to-end deploy on the director**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
source ./bosh.env
bosh -n -d nix-stemcell-poc delete-deployment --force
bosh -n delete-stemcell bosh-openstack-kvm-ubuntu-noble/0.0.1-nix
bosh -n upload-stemcell result-stemcell/bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz
bosh -n -d nix-stemcell-poc deploy nix-stemcell-poc.yml 2>&1 | tail -20
```
Expected: deploy completes the full update lifecycle (through post-start); `bosh vms` shows `started`.

- [ ] **Step 5: Confirm runtime behavior unchanged (ssh + sudo + monit)**

Run:
```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
source ./bosh.env
bosh -n -d nix-stemcell-poc ssh vm-instance/0 -c 'command -v sudo; sudo -n true && echo SUDO_OK; monit summary >/dev/null && echo MONIT_OK' 2>&1 | tail -10
```
Expected: `/usr/bin/sudo`, `SUDO_OK`, `MONIT_OK` — same as the M5 findings. Confirms the faster build produced a behaviorally identical stemcell.

- [ ] **Step 6: Commit the measured results**

```bash
cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder
git add docs/superpowers/specs/2026-07-08-faster-stemcell-build-design.md
git commit -m "docs: record measured stemcell build speedup"
rm -f result-stemcell result-osimage
```

---

## Self-Review Notes

- **Spec coverage:** Design §1 (collapse) → Tasks 2-3, 5; §2 (pigz on overlay repack) → Task 2 Step 1; §2 (pigz on inner image) → Task 4; Validation (baseline, after, oracle, deploy) → Tasks 1 and 6. All covered.
- **Type/name consistency:** `applyOverlays` (Task 3) matches the file/function created in Task 2; `mk-apply-overlays.nix` referenced consistently in Tasks 2, 3, 5.
- **Equivalence guard:** Task 1 Step 3 + Task 3 Step 4 fingerprint the rootfs listing so the refactor is proven content-neutral before touching compression or deploying.
