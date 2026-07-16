# Deterministic Bootable Disk Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the BOSH stemcell disk images (`openstack-kvm` qcow2 and `aws` raw) bit-for-bit reproducible on the same machine (`nix build … --rebuild` identical) without changing their functional boot behavior.

**Architecture:** Split today's single `runInLinuxVM` disk build into two derivations with a deterministic staging tree as the boundary. Phase A (`bootable-rootfs`, still in a VM chroot) emits a byte-deterministic root tree plus generated grub/initramfs files. Phase B (`bootable-disk`) assembles the disk offline — `sfdisk` with a fixed MBR id, `mkfs.ext4 -d` (populate without mounting), `mkfs.vfat`+`mcopy`, `grub-bios-setup`, then `qemu-img convert` — eliminating the ext4 block-allocator and wall-clock non-determinism that dominates today.

**Tech Stack:** Nix (flake-parts), `vmTools.runInLinuxVM`, `e2fsprogs` (`mkfs.ext4 -d`), `libfaketime`, `fakeroot`, `mtools` (`mcopy`), `dosfstools`, `util-linux` (`sfdisk`), `grub2` (`grub-mkimage`/`grub-bios-setup`), `qemu` (`qemu-img`), bash.

**Reference spec:** `docs/superpowers/specs/2026-07-16-deterministic-disk-image-design.md` (root-cause table RC1–RC7, NixOS model, risks).

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `build/stemcells/bootable-rootfs.nix` | Phase A derivation: run VM chroot, emit deterministic **canonical tarball** `$out/rootfs-staged.tar.gz` (whole root incl `/boot/grub`) + `$out/esp/` (EFI files). | Create |
| `build/stemcells/bootable-rootfs.sh` | Phase A builder script: extract os-image, chroot to generate initramfs/grub files, canonicalize, wipe volatile state, pin mtimes, emit canonical tar (`--numeric-owner --xattrs --acls --sort=name --mtime=@0`). Extracted from today's `bootable-disk.sh`. | Create |
| `build/stemcells/bootable-disk.nix` | Phase B derivation: offline disk assembly. Now takes a `rootfsTree` (Phase A output) instead of raw `osImage`. Keeps `diskFormat`/`diskOutput` contract. | Rewrite |
| `build/stemcells/bootable-disk.sh` | Phase B builder script: sfdisk fixed id, `mkfs.ext4 -d`, `mkfs.vfat`+`mcopy`, assemble, `grub-bios-setup`, `qemu-img convert`. | Rewrite |
| `build/stemcells/openstack-kvm-disk.nix` | Wire os-image → `bootable-rootfs` → `bootable-disk` (qcow2). | Modify |
| `build/stemcells/aws-disk.nix` | Same wiring for AWS (raw). | Modify |
| `build/lib/mkVmImage.nix` | VM helper. Unchanged, reused by Phase A (and possibly Phase B — decided by Spike 3). | Read only |
| `flake.nix` | Add determinism regression `checks`. | Modify |
| `build/checks/disk-determinism.nix` | Regression guard derivation: build a disk twice under `--rebuild` semantics and assert byte-identity. | Create |

**Decomposition rationale:** the risky BIOS-grub step is isolated in Phase B, a small script that is cheap to iterate and `--rebuild`-check. The staging tree is a clean, inspectable, timestamp-pinned interface both targets share, so one fix covers openstack and aws.

---

## Phase 0 — De-risking spikes (resolve before implementation)

These three unknowns determine Phase B's exact shape. Each spike is a concrete experiment with a decision gate. Record outcomes in the plan's "Spike results" note (added inline) before starting Phase 2.

### Spike results (executed 2026-07-16) — RESOLVED, with design refinement

**Spike 0.1 (executed):**
- `libfaketime`, `fakeroot`, `mtools` all resolve in the pinned nixpkgs.
- `mkfs.ext4 -d` under `faketime` is **byte-deterministic** across two runs (fakeroot: `b4cc179…` twice; real-root: `05bd818…` twice). RC2/RC3/RC6 fix validated.
- **`fakeroot` masks `security.capability` xattrs** (empty `ea_list`); **real root preserves them**. So `fakeroot` is the wrong tool.
- **The real `os-image` rootfs carries NO capabilities/xattrs**, but has **209 files with non-root ownership** and **18 setuid/setgid files** (`/etc/shadow-` root:shadow, `crontab` setgid crontab, `ssh-keysign` setuid, `unix_chkpwd`, etc.).

**Critical design refinement (supersedes the File Structure + Phase A/B tasks below):**
1. **The Nix store normalizes all files to `root:root`, `mtime=1`, and forbids device nodes.** Passing the Phase A rootfs as an *unpacked store tree* would destroy the 209 non-root ownerships → security regression. Therefore **the Phase A → Phase B boundary is a canonical tarball**, mirroring the existing `os-image` `rootfs.tar.gz` pattern — NOT an unpacked `$out/root` tree.
   - Phase A output: `$out/rootfs-staged.tar.gz` (whole root incl `/boot/grub`, built with `--numeric-owner --xattrs --acls`, sorted, `--mtime=@0`) + `$out/esp/` (EFI files; store-safe, all root-owned).
   - Phase B: extract the tar to a scratch dir **as root**, then `mkfs.ext4 -d scratch`.
2. **Phase B runs in `runInLinuxVM` as real root** (Task 2.1b path). Drop `fakeroot`; keep `faketime` (for superblock times). This also gives loopback for `grub-bios-setup` → **Spike 0.3 resolved: VM + real root.**
3. **Spike 0.2 (grub file-gen) folded into Phase 1:** Phase A already runs the chroot as root in a VM exactly like today, so today's `grub-install` EFI generation is reused as-is; only the BIOS device-write is deferred to Phase B's `grub-bios-setup`. Exact BIOS file-gen flag confirmed during Task 1.2.

**Tasks 0.2 and 0.3 below are therefore NOT executed standalone** — their decisions are recorded above. Task 2.1a is dropped; use Task 2.1b. Where tasks below say `$out/root` (unpacked), read `$out/rootfs-staged.tar.gz` (extract-as-root then `mkfs.ext4 -d`); where they list `fakeroot`, remove it.

### Task 0.1: Confirm tooling + `mkfs.ext4 -d` ACL/xattr preservation

**Files:** none (scratch experiment in `/tmp/opencode`).

The current build extracts the rootfs with `tar --acls --xattrs`. Phase B replaces mount+tar with `mkfs.ext4 -d <dir>`. We must prove `mkfs.ext4 -d` preserves extended attributes (capabilities, apparmor) and works with `fakeroot` for ownership.

- [ ] **Step 1: Confirm the packages resolve in the pinned nixpkgs**

Run:
```bash
cd /home/ruben/workspace/bosh-nix-linux-stemcell-builder
nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.x86_64-linux.libfaketime.outPath'
nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.x86_64-linux.fakeroot.outPath'
nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.x86_64-linux.mtools.outPath'
```
Expected: three store paths print with no eval error. If any fails, note the correct attribute name (e.g. `libfaketimeHook`) for use in `nativeBuildInputs`.

- [ ] **Step 2: Prove `mkfs.ext4 -d` preserves xattrs and is deterministic**

Run:
```bash
cd /tmp/opencode && rm -rf detspike && mkdir -p detspike/tree/etc && cd detspike
echo hi > tree/etc/file
# set a security xattr similar to file capabilities
setcap cap_net_bind_service+ep tree/etc/file 2>/dev/null || sudo setcap cap_net_bind_service+ep tree/etc/file
nix shell nixpkgs#e2fsprogs nixpkgs#libfaketime nixpkgs#fakeroot -c bash -c '
  for i in 1 2; do
    faketime -f "1970-01-01 00:00:01" fakeroot mkfs.ext4 -q -F -L root \
      -U 44444444-4444-4444-4444-444444444444 \
      -E hash_seed=44444444-4444-4444-4444-444444444444,root_owner=0:0 \
      -d tree -O ^dir_index img$i.raw 40M
  done
  sha256sum img1.raw img2.raw
  debugfs -R "ea_list /etc/file" img1.raw'
```
Expected:
- The two `sha256sum` values are **identical** (proves RC2/RC3/RC6 fixed for a toy tree).
- `ea_list` shows `security.capability` (proves xattr preservation). If missing, note that `mke2fs` needs `-o` or a newer version, or that a `tar`-into-`mkfs` path is required — record this; it changes Task 2.3.

- [ ] **Step 3: Record decision**

Write a one-line "Spike 0.1 result" note into this plan file under this task: whether `mkfs.ext4 -d` is byte-deterministic and xattr-preserving. Commit the note.

```bash
git add docs/superpowers/plans/2026-07-16-deterministic-disk-image.md
git commit -m "spike: confirm mkfs.ext4 -d determinism and xattr preservation"
```

### Task 0.2: Grub file-only generation (no device write)

**Files:** none (scratch, reuse an existing built rootfs tree).

Today grub artifacts are produced by `grub-install … /dev/vda`, which writes to the device. Phase A must instead emit the grub `i386-pc` modules + `core.img` and the EFI `grubx64.efi` as **files** in the staging tree, with no device write. Determine the invocation.

- [ ] **Step 1: Extract a rootfs tree to inspect available grub tooling**

Run:
```bash
cd /tmp/opencode && rm -rf grubspike && mkdir grubspike && cd grubspike
tar -tf /nix/store/*noble-stemcell/rootfs.tar.gz 2>/dev/null | grep -m1 'usr/bin/grub-mkimage' || \
  nix build -o osimg 'path:/home/ruben/workspace/bosh-nix-linux-stemcell-builder#packages.x86_64-linux.noble-stemcell-disk' --dry-run
```
Expected: confirm `grub-mkimage`, `grub-bios-setup`, and the `i386-pc`/`x86_64-efi` module dirs (`/usr/lib/grub/`) exist in the noble rootfs.

- [ ] **Step 2: Decide the file-gen mechanism**

Primary approach (chroot, but suppress the device write):
```bash
# BIOS: generate modules + core.img into /boot/grub without touching the MBR
grub-install --target=i386-pc --boot-directory=/boot \
  --grub-setup=/bin/true --no-floppy /dev/vda
# EFI: generate grubx64.efi + modules into a staging ESP dir (removable layout)
grub-install --target=x86_64-efi --efi-directory=/staging-esp \
  --boot-directory=/boot --removable --no-nvram --no-floppy
```
Fallback if `--grub-setup=/bin/true` still writes or errors: use `grub-mkimage` directly to build `core.img` from a fixed module list, and copy `/usr/lib/grub/i386-pc/*.{mod,img,lst}` into `/boot/grub/i386-pc/` manually.

Run whichever inside the existing chroot (reuse Phase A once Task 1.x exists) and verify `/boot/grub/i386-pc/core.img` + `staging-esp/EFI/BOOT/BOOTX64.EFI` are produced and the MBR of a throwaway image is untouched.
Expected: both artifacts exist; MBR boot code region is zero/unmodified.

- [ ] **Step 3: Record decision** — note the chosen invocation (primary vs fallback) inline in this plan and commit.

### Task 0.3: `grub-bios-setup` offline vs loopback (Phase B execution context)

**Files:** none (scratch, uses the assembled raw image from a manual dry run).

This is the highest-risk item (NixOS calls BIOS/MBR "best effort"). Determine whether `grub-bios-setup` can embed `core.img` into an assembled **plain image file**, or whether it needs a loop device (which forces Phase B to also run in `runInLinuxVM`).

- [ ] **Step 1: Build a throwaway assembled raw image** by hand from the staging tree (sfdisk fixed id + mkfs.ext4 -d root + mkfs.vfat ESP dd'd to offsets) into `/tmp/opencode/disk.raw`.

- [ ] **Step 2: Attempt offline bios-setup on the plain file**

Run:
```bash
nix shell nixpkgs#grub2 -c grub-bios-setup \
  --directory=/tmp/opencode/grubspike/boot/grub/i386-pc \
  --device-map=/dev/null /tmp/opencode/disk.raw
```
Expected outcomes:
- **Success on the plain file** → Phase B can be a pure (non-VM) derivation. Preferred.
- **Requires a device** → run `grub-bios-setup` against a `losetup -Pf` loop device; if that needs privileges unavailable in the Nix sandbox, Phase B must run inside `runInLinuxVM` (like Phase A). Still deterministic (fixed inputs); only the derivation type changes.

- [ ] **Step 3: Record decision** — note "Phase B = pure builder" or "Phase B = runInLinuxVM" inline in this plan and commit. **This decision selects between Task 2.1a and Task 2.1b below.**

---

## Phase 1 — Phase A: deterministic staging tree (`bootable-rootfs`)

Extract today's rootfs+chroot logic into a standalone derivation whose output is a byte-deterministic tree. Behavior is preserved; the only new work is emitting grub/EFI as files, wiping volatile state, and pinning mtimes.

### Task 1.1: Create the Phase A builder script skeleton

**Files:**
- Create: `build/stemcells/bootable-rootfs.sh`
- Reference: `build/stemcells/bootable-disk.sh` (lines 46–127 = extract+chroot logic to move)

- [ ] **Step 1: Write `bootable-rootfs.sh`** — VM builder that produces a staging tree in `$out`, reusing the current extract+udev+chroot flow but with **no partitioning, no mkfs, no mount of a target fs, no qemu-img**.

```bash
# shellcheck shell=bash
# Phase A: emit a byte-deterministic root tree + generated grub/initramfs files.
# Embedded into a runInLinuxVM builder via replaceVars (bootable-rootfs.nix).
# shellcheck disable=SC2154
set -exuo pipefail
export SOURCE_DATE_EPOCH=0

stage=/build/stage
mkdir -p "$stage" /staging-esp

# Extract os-image rootfs (already deterministic) into the staging tree.
@gnutar@/bin/tar -xf @osImage@/rootfs.tar.gz --acls --xattrs -C "$stage"

# Bind mounts + udev so grub/initramfs tooling works inside the chroot.
mkdir -p "$stage"/{proc,sys,dev}
@util-linux@/bin/mount -t proc proc "$stage/proc"
@util-linux@/bin/mount -t sysfs sysfs "$stage/sys"
@util-linux@/bin/mount --bind /dev "$stage/dev"
@systemdMinimal@/lib/systemd/systemd-udevd &
@systemdMinimal@/bin/udevadm trigger
@systemdMinimal@/bin/udevadm settle

# /etc/fstab (label-based, unchanged from today's behavior).
cat >"$stage/etc/fstab" <<FSTAB
LABEL=root / ext4 defaults 0 1
LABEL=ESP /boot/efi vfat defaults 0 2
FSTAB
```

- [ ] **Step 2: Commit the skeleton**

```bash
git add build/stemcells/bootable-rootfs.sh
git commit -m "feat: add Phase A bootable-rootfs script skeleton"
```

### Task 1.2: Move the chroot (initramfs + grub cfg + fixed-UUID boot trick) into Phase A

**Files:**
- Modify: `build/stemcells/bootable-rootfs.sh`

- [ ] **Step 1: Append the chroot block**, preserving the load-bearing pieces from `bootable-disk.sh:66-127`: deterministic initramfs re-pack (RC5), the `/etc/default/grub` cmdline, the `/dev/disk/by-uuid/<uuid>` symlink trick so `update-grub` emits `root=UUID=…`, and `update-grub`. Replace `grub-install … /dev/vda` device writes with the **file-only** generation chosen in Task 0.2.

```bash
chroot "$stage" /bin/bash -exuo pipefail <<'CHROOT'
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export SOURCE_DATE_EPOCH=0

# Deterministic initramfs (RC5): create if missing, then re-pack each initrd
# with sorted names, pinned mtimes, and gzip -n.
if [ ! -f /boot/initrd.img ]; then update-initramfs -k all -c; fi
for img in /boot/initrd.img-*; do
  [ -e "$img" ] || continue
  tmpd=$(mktemp -d)
  if head -c 2 "$img" | od -An -tx1 | grep -q '1f 8b'; then
    ( cd "$tmpd" && zcat "$img" | cpio -idm --quiet ) || true
  else
    ( cd "$tmpd" && cpio -idm --quiet < "$img" ) || true
  fi
  find "$tmpd" -mindepth 1 -exec touch --no-dereference -d "@$SOURCE_DATE_EPOCH" {} +
  ( cd "$tmpd" && find . -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z \
      | cpio -o -H newc --quiet -0 --owner=0:0 | gzip -n -9 > "$img" )
  rm -rf "$tmpd"
done

cat > /etc/default/grub <<EOF
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX="vconsole.keymap=us net.ifnames=0 biosdevname=0 crashkernel=auto selinux=0 plymouth.enable=0 console=ttyS0,115200n8 earlyprintk=ttyS0 rootdelay=300 audit=1 cgroup_enable=memory swapaccount=1 apparmor=1 security=apparmor"
GRUB_CMDLINE_LINUX_DEFAULT=""
EOF

mkdir -p /boot/grub /staging-esp
# Fixed root UUID so grub.cfg is UUID-based (matches mkfs.ext4 -U in Phase B).
mkdir -p /dev/disk/by-uuid
ln -sf /dev/sda2 /dev/disk/by-uuid/44444444-4444-4444-4444-444444444444

# --- File-only grub generation (from Task 0.2 decision) ---
# BIOS: modules + core.img into /boot/grub, WITHOUT writing any MBR.
grub-install --target=i386-pc --boot-directory=/boot \
  --grub-setup=/bin/true --no-floppy /dev/sda
# EFI: grubx64.efi + modules into the staging ESP (removable layout).
grub-install --target=x86_64-efi --efi-directory=/staging-esp \
  --boot-directory=/boot --removable --no-nvram --no-floppy

update-grub

find /boot/grub \( -name '*.mod' -o -name 'grub.cfg' -o -name 'core.img' \) \
  -exec touch -d "@$SOURCE_DATE_EPOCH" {} +
CHROOT
```

Note: the `by-uuid` symlink now targets `/dev/sda2` (Incus presents the disk as `/dev/sda`); the target need not exist in the VM — only its presence at `grub-mkconfig` time matters. If Task 0.2 selected the `grub-mkimage` fallback, substitute that block here verbatim from the Spike 0.2 note.

- [ ] **Step 2: Commit**

```bash
git add build/stemcells/bootable-rootfs.sh
git commit -m "feat: generate initramfs and grub files in Phase A chroot"
```

### Task 1.3: Canonicalize the staging tree (RC7 + mtime pin) and emit `$out`

**Files:**
- Modify: `build/stemcells/bootable-rootfs.sh`

- [ ] **Step 1: After the chroot, unmount, wipe volatile state, pin mtimes, and copy the tree + ESP + grub-bios modules into `$out`.**

```bash
# Unmount chroot binds (reverse order).
@util-linux@/bin/umount "$stage/dev" 2>/dev/null || true
@util-linux@/bin/umount "$stage/sys" 2>/dev/null || true
@util-linux@/bin/umount "$stage/proc" 2>/dev/null || true

# RC7: remove leaked runtime state so nothing wall-clock/PARTUUID-derived remains.
rm -rf "$stage"/run/* "$stage"/tmp/* \
       "$stage"/var/cache/ldconfig/* \
       "$stage"/var/lib/systemd/random-seed 2>/dev/null || true

# Pin every remaining mtime (RC5/RC7 belt-and-braces) to SOURCE_DATE_EPOCH.
find "$stage" -exec touch --no-dereference -d "@$SOURCE_DATE_EPOCH" {} +
find /staging-esp -exec touch --no-dereference -d "@$SOURCE_DATE_EPOCH" {} +

# Emit the deterministic interface consumed by Phase B.
# Root tree MUST travel as a canonical tarball: the Nix store would otherwise
# normalize the 209 non-root ownerships + setuid/setgid bits to root:root.
mkdir -p "$out/esp"
( cd "$stage" && @gnutar@/bin/tar \
    --numeric-owner --xattrs --acls --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
    -czf "$out/rootfs-staged.tar.gz" . )
# ESP contents are all root-owned regular files → store-safe as a plain dir.
cp -a /staging-esp/. "$out/esp/"
```

- [ ] **Step 2: Commit**

```bash
git add build/stemcells/bootable-rootfs.sh
git commit -m "feat: canonicalize and emit Phase A staging tree"
```

### Task 1.4: Create the Phase A derivation and build it

**Files:**
- Create: `build/stemcells/bootable-rootfs.nix`

- [ ] **Step 1: Write `bootable-rootfs.nix`** modeled on today's `bootable-disk.nix` (uses `mkVmImage`), but its output is the staging tree.

```nix
# Phase A: deterministic staging tree (rootfs + generated grub/EFI files).
# Runs in a Linux VM (runInLinuxVM) because the chroot must run noble's
# update-initramfs / update-grub / grub tooling. Output: $out/root, $out/esp.
{
  util-linux,
  dosfstools,
  e2fsprogs,
  gnutar,
  systemdMinimal,
  replaceVars,
  callPackage,
}:
let
  mkVmImage = callPackage ../lib/mkVmImage.nix { };
in
{
  osImage,
  name ? "noble-stemcell-rootfs",
  size ? 2560,
}:
mkVmImage {
  inherit name size;
  buildCommand = builtins.readFile (
    replaceVars ./bootable-rootfs.sh {
      inherit util-linux dosfstools e2fsprogs gnutar systemdMinimal;
      osImage = "${osImage}";
    }
  );
  nativeBuildInputs = [ systemdMinimal util-linux dosfstools e2fsprogs gnutar ];
}
```

- [ ] **Step 2: Temporarily expose it and build to verify the tree is produced.** Add a scratch flake output or build via expression:

Run:
```bash
cd /home/ruben/workspace/bosh-nix-linux-stemcell-builder
nix build --impure --expr '
  let f = builtins.getFlake (toString ./.); p = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
      os = p.callPackage ./build/rootfs/os-image.nix { };
      a  = p.callPackage ./build/stemcells/bootable-rootfs.nix { };
  in a { osImage = os; }' -o result-rootfs
ls result-rootfs/root/boot/grub/i386-pc/core.img result-rootfs/esp/EFI/BOOT/BOOTX64.EFI
```
Expected: both files exist; `result-rootfs/root/boot/grub/grub.cfg` contains `root=UUID=44444444-…`.

- [ ] **Step 3: Verify Phase A is itself reproducible**

Run: `nix build --impure --expr '…same as above…' -o result-rootfs --rebuild`
Expected: EXIT 0 (no "output differs"). If it differs, diff the two trees to find a missed volatile file and extend the Task 1.3 wipe list before proceeding.

- [ ] **Step 4: Commit**

```bash
git add build/stemcells/bootable-rootfs.nix
git commit -m "feat: add Phase A bootable-rootfs derivation"
```

---

## Phase 2 — Phase B: offline deterministic disk assembly (`bootable-disk`)

Rewrite `bootable-disk` to consume the Phase A tree and assemble the disk offline. Use the derivation type selected in Task 0.3.

### Task 2.1a: Rewrite `bootable-disk.nix` inputs (pure builder — if Spike 0.3 = plain file works)

**Files:**
- Rewrite: `build/stemcells/bootable-disk.nix`

- [ ] **Step 1: Replace the `mkVmImage` wrapper with a plain `stdenv.mkDerivation`** taking `rootfsTree` (Phase A output) and keeping `diskFormat`/`diskOutput`.

```nix
# Phase B: offline deterministic disk assembly from the Phase A staging tree.
# Output: $out/root.<ext> (qcow2 for openstack, img for raw).
{
  stdenv,
  util-linux,
  dosfstools,
  e2fsprogs,
  libfaketime,
  fakeroot,
  mtools,
  grub2,
  qemu,
  replaceVars,
}:
{
  rootfsTree,
  name ? "noble-stemcell",
  size ? 2560,
  diskFormat ? "qcow2",
}:
let
  diskExt = if diskFormat == "qcow2" then "qcow2" else "img";
in
stdenv.mkDerivation {
  inherit name;
  dontUnpack = true;
  nativeBuildInputs = [ util-linux dosfstools e2fsprogs libfaketime fakeroot mtools grub2 qemu ];
  buildCommand = builtins.readFile (
    replaceVars ./bootable-disk.sh {
      inherit util-linux dosfstools e2fsprogs libfaketime fakeroot mtools grub2 qemu;
      rootfsTree = "${rootfsTree}";
      sizeMib = toString size;
      inherit diskFormat;
      diskOutput = "root.${diskExt}";
    }
  );
}
```

- [ ] **Step 2: Commit** — `git add build/stemcells/bootable-disk.nix && git commit -m "feat: Phase B pure builder derivation inputs"`

### Task 2.1b: Rewrite `bootable-disk.nix` inputs (VM builder — if Spike 0.3 = loopback needed)

**Files:**
- Rewrite: `build/stemcells/bootable-disk.nix`

- [ ] **Step 1: Keep `mkVmImage`** (VM runs as root: preserves ownership/setuid/xattrs during `mkfs.ext4 -d`, and gives loopback for `grub-bios-setup`). Take `rootfsTree` instead of `osImage`, and add `libfaketime mtools grub2` to inputs (NO `fakeroot` — it masks xattrs; real root is used instead). Swap the `osImage` replaceVar for `rootfsTree = "${rootfsTree}"` and add `sizeMib = toString size`. `mkfs.ext4 -O ^dir_index` and the fixed UUID/hash_seed match today's build.

- [ ] **Step 2: Commit** — `git commit -m "feat: Phase B VM builder derivation inputs"`

> **Per Spike results: execute Task 2.1b (NOT 2.1a).** Task 2.1a is dropped.

### Task 2.2: Partition table with fixed MBR id (RC1)

**Files:**
- Rewrite: `build/stemcells/bootable-disk.sh`

- [ ] **Step 1: Start the offline assembly script**: create a fixed-size raw whole-disk file and write the MBR table with a **constant `label-id`** (fixes RC1 → stable PARTUUID). Layout matches today (ESP p1 sectors 2048–100351 type ef bootable; root p2 from 100352).

```bash
# shellcheck shell=bash
# Phase B: offline deterministic disk assembly. shellcheck disable=SC2154
set -exuo pipefail
export SOURCE_DATE_EPOCH=0

work=$(mktemp -d)
raw="$work/disk.raw"
esp="$work/esp.raw"
root="$work/root.raw"

# Fixed-size whole disk (constant, not content-derived → cannot drift).
@util-linux@/bin/truncate -s $((@sizeMib@ * 1024 * 1024)) "$raw"

# RC1: fixed MBR disk signature via constant label-id.
@util-linux@/bin/sfdisk "$raw" <<EOF
label: dos
label-id: 0x44444444
unit: sectors

start=2048, size=98304, type=ef, bootable
start=100352, type=83
EOF
```

- [ ] **Step 2: Commit** — `git add build/stemcells/bootable-disk.sh && git commit -m "feat: Phase B partition table with fixed MBR id"`

### Task 2.3: Populate ext4 root offline with `mkfs.ext4 -d` (RC2/RC3/RC6)

**Files:**
- Modify: `build/stemcells/bootable-disk.sh`

- [ ] **Step 1: Compute the root partition byte length, extract the staged rootfs tarball as root, then create the root fs image by populating from that tree with `faketime`** — no mount, deterministic block layout, fixed superblock times. Real root (VM) preserves the 209 non-root ownerships + setuid/setgid; no `fakeroot` (it masks xattrs).

```bash
# Extract the canonical rootfs tarball (as root, preserving ownership/xattrs).
scratch="$work/rootfs"
mkdir -p "$scratch"
@gnutar@/bin/tar --numeric-owner --xattrs --acls \
  -xzf @rootfsTree@/rootfs-staged.tar.gz -C "$scratch"

# Root partition = disk end - 100352 sectors, in bytes (multiple of 512).
root_start=100352
disk_sectors=$(( @sizeMib@ * 1024 * 1024 / 512 ))
root_bytes=$(( (disk_sectors - root_start) * 512 ))

@libfaketime@/bin/faketime -f "1970-01-01 00:00:01" \
  @e2fsprogs@/bin/mkfs.ext4 -q -F -L root \
    -U 44444444-4444-4444-4444-444444444444 \
    -E hash_seed=44444444-4444-4444-4444-444444444444,root_owner=0:0 \
    -O ^dir_index \
    -d "$scratch" "$root" "$((root_bytes / 1024))k"
```

- [ ] **Step 2: Commit** — `git commit -am "feat: populate ext4 root offline with mkfs.ext4 -d"`

### Task 2.4: Build ESP vfat offline with `mkfs.vfat` + `mcopy` (RC4)

**Files:**
- Modify: `build/stemcells/bootable-disk.sh`

- [ ] **Step 1: Create the ESP image (98304 sectors) with fixed volume id and copy the staged EFI tree via `mcopy` honoring `SOURCE_DATE_EPOCH`.**

```bash
@util-linux@/bin/truncate -s $((98304 * 512)) "$esp"
@dosfstools@/bin/mkfs.vfat -F32 -n ESP -i 44444444 "$esp"
# mtools honors SOURCE_DATE_EPOCH for directory-entry timestamps (RC4).
( cd @rootfsTree@/esp && @mtools@/bin/mcopy -i "$esp" -s -Q ./* :: )
```

- [ ] **Step 2: Commit** — `git commit -am "feat: build ESP vfat offline with mcopy"`

### Task 2.5: Assemble partitions and embed BIOS grub (`grub-bios-setup`)

**Files:**
- Modify: `build/stemcells/bootable-disk.sh`

- [ ] **Step 1: `dd` the two partition images into the whole-disk file at their sector offsets, then embed `core.img` with `grub-bios-setup`.**

```bash
@util-linux@/bin/dd if="$esp"  of="$raw" bs=512 seek=2048   conv=notrunc
@util-linux@/bin/dd if="$root" of="$raw" bs=512 seek=100352 conv=notrunc

# Embed core.img into the MBR gap (highest-risk step). Phase B runs in a VM
# as root, so grub-bios-setup can use the assembled file (or a loop device).
@grub2@/bin/grub-bios-setup \
  --directory="$scratch/boot/grub/i386-pc" \
  --device-map=/dev/null "$raw"
```

If `grub-bios-setup` refuses the plain file, wrap it with `losetup -Pf --show "$raw"` and run against the loop device, then `losetup -d` (the VM builder is root, so loopback is available).

- [ ] **Step 2: Commit** — `git commit -am "feat: assemble partitions and embed BIOS grub"`

### Task 2.6: Convert to output format and finish

**Files:**
- Modify: `build/stemcells/bootable-disk.sh`

- [ ] **Step 1: Convert and verify** (preserves the existing `$out/root.<ext>` contract).

```bash
mkdir -p "$out"
@qemu@/bin/qemu-img convert -f raw -O @diskFormat@ "$raw" "$out/@diskOutput@"
@qemu@/bin/qemu-img info "$out/@diskOutput@"
rm -rf "$work"
```

- [ ] **Step 2: Commit** — `git commit -am "feat: convert Phase B output to target format"`

### Task 2.7: Wire the target derivations through Phase A → Phase B

**Files:**
- Modify: `build/stemcells/openstack-kvm-disk.nix`
- Modify: `build/stemcells/aws-disk.nix`

- [ ] **Step 1: Update `openstack-kvm-disk.nix`** to build the staging tree then the disk.

```nix
{ callPackage }:
let
  osImage = callPackage ../rootfs/os-image.nix { };
  mkBootableRootfs = callPackage ./bootable-rootfs.nix { };
  mkBootableDisk = callPackage ./bootable-disk.nix { };
  rootfsTree = mkBootableRootfs { inherit osImage; };
in
mkBootableDisk {
  inherit rootfsTree;
  name = "noble-stemcell";
}
```

- [ ] **Step 2: Update `aws-disk.nix`** the same way (raw + aws os-image).

```nix
{ callPackage }:
let
  osImage = callPackage ../rootfs/os-image.nix { infrastructure = "aws"; };
  mkBootableRootfs = callPackage ./bootable-rootfs.nix { };
  mkBootableDisk = callPackage ./bootable-disk.nix { };
  rootfsTree = mkBootableRootfs { inherit osImage; name = "noble-stemcell-aws-rootfs"; };
in
mkBootableDisk {
  inherit rootfsTree;
  name = "noble-stemcell-aws";
  diskFormat = "raw";
}
```

- [ ] **Step 3: Build both disks**

Run:
```bash
nix build .#noble-stemcell-disk .#noble-stemcell-aws-disk
ls result*/root.qcow2 result*/root.img 2>/dev/null || ls -R result*
```
Expected: both images build successfully.

- [ ] **Step 4: Commit** — `git commit -am "feat: wire openstack and aws targets through Phase A/B"`

### Task 2.8: Verify same-machine byte reproducibility (the core goal)

**Files:** none.

- [ ] **Step 1: `--rebuild` both disks**

Run:
```bash
nix build .#noble-stemcell-disk --rebuild
nix build .#noble-stemcell-aws-disk --rebuild
```
Expected: both EXIT 0 with no "output differs". If either differs, mount/convert both outputs and byte-diff by partition region (as in the spec investigation) to find the unfixed RC; do NOT proceed until identical.

- [ ] **Step 2: Also verify the full stemcell tarballs are reproducible**

Run: `nix build .#noble-stemcell --rebuild && nix build .#aws --rebuild`
Expected: both EXIT 0.

---

## Phase 3 — Determinism regression guard

Nix caches by derivation hash, so two plain evals reuse one output. The guard must force an actual rebuild-and-compare.

### Task 3.1: Add a determinism check derivation

**Files:**
- Create: `build/checks/disk-determinism.nix`

- [ ] **Step 1: Write a check that records the disk image sha256 into `$out`**, so two independent builds of the *disk* can be compared, and pair it with an assertion. Simplest robust form: a derivation that depends on the disk, computes `sha256sum root.<ext>`, and writes it; determinism is then enforced by CI running `nix build <check> --rebuild`.

```nix
# Determinism guard: emits the disk image sha256 so `nix build … --rebuild`
# (or a double-build compare in CI) fails loudly on any byte drift.
{ runCommand, disk, diskFile }:
runCommand "disk-determinism-${disk.name}" { } ''
  sha256sum ${disk}/${diskFile} | cut -d' ' -f1 > "$out"
''
```

- [ ] **Step 2: Commit** — `git add build/checks/disk-determinism.nix && git commit -m "feat: add disk determinism guard derivation"`

### Task 3.2: Expose checks in the flake

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1: Add `checks.<system>.disk-determinism-openstack` and `…-aws`** in the flake-parts `perSystem`, referencing the guard.

```nix
checks = {
  disk-determinism-openstack = pkgs.callPackage ./build/checks/disk-determinism.nix {
    disk = config.packages.noble-stemcell-disk;
    diskFile = "root.qcow2";
  };
  disk-determinism-aws = pkgs.callPackage ./build/checks/disk-determinism.nix {
    disk = config.packages.noble-stemcell-aws-disk;
    diskFile = "root.img";
  };
};
```
(Adjust `config.packages`/`self'.packages` reference to match how packages are named in this flake's `perSystem`.)

- [ ] **Step 2: Prove the guard exercises a real rebuild**

Run:
```bash
nix build .#checks.x86_64-linux.disk-determinism-openstack
nix build .#checks.x86_64-linux.disk-determinism-openstack --rebuild
nix build .#checks.x86_64-linux.disk-determinism-aws --rebuild
```
Expected: all EXIT 0. A regression (non-deterministic disk) makes the underlying disk `--rebuild` fail, failing the check.

- [ ] **Step 3: `nix fmt` then commit**

```bash
nix fmt
git commit -am "feat: expose disk determinism checks in flake"
```

---

## Phase 4 — Functional boot validation (Incus lab)

Prove the offline-assembled OpenStack image still boots and the BIOS-grub change didn't break boot.

### Task 4.1: Deploy and verify on the Incus-CPI director

**Files:** none (uses `scripts/deploy-stemcell.sh`).

- [ ] **Step 1: Source the director creds and run the end-to-end deploy** (builds `.#noble-stemcell`, uploads, deploys `nix-stemcell-poc`, asserts running + SSH + kernel/OS, then cleans up).

Run:
```bash
cd /home/ruben/workspace/bosh-nix-linux-stemcell-builder
source ./bosh.env
./scripts/deploy-stemcell.sh --build --cleanup
```
Expected: script exits 0; instance reaches `running`; SSH succeeds; `uname`/os-release checks pass. If boot fails with an ALERT about the root device or grub rescue, the BIOS-grub/`by-uuid` path regressed — return to Task 1.2 / Task 2.5.

- [ ] **Step 2: Record the validation outcome** in the plan (pass + stemcell sha) and stop for review before any cleanup of Phase 0 scratch notes.

> AWS raw-image boot is **not** covered by the Incus lab (out of scope for this automated gate); AWS determinism is covered by Task 2.8, and AWS functional boot remains a separate manual step.

---

## Success criteria (from spec)

1. `nix build .#noble-stemcell-disk --rebuild` — bit-identical (Task 2.8).
2. `nix build .#noble-stemcell-aws-disk --rebuild` — bit-identical (Task 2.8).
3. `./scripts/deploy-stemcell.sh --build --cleanup` — OpenStack stemcell boots on the Incus lab (Task 4.1).
4. Determinism regression guard present and passing (Phase 3).

---

## Self-review notes

- **Spec RC coverage:** RC1 → Task 2.2; RC2/RC3/RC6 → Task 2.3; RC4 → Task 2.4; RC5 → Task 1.2; RC7 → Task 1.3. All seven mapped.
- **Spec risks:** grub file-gen → Task 0.2/1.2; grub-bios-setup offline-vs-loop → Task 0.3 gating Task 2.1a/2.1b/2.5; tool availability + `mkfs.ext4 -d` xattrs → Task 0.1; boot-trick preserved → Task 1.2; regression guard mechanism → Phase 3.
- **Interface consistency:** Phase A output contract `$out/root` + `$out/esp` (+ `root/boot/grub/i386-pc/core.img`) is produced in Task 1.3 and consumed by Tasks 2.3/2.4/2.5. Phase B replaceVars (`rootfsTree`, `sizeMib`, `diskFormat`, `diskOutput`) defined in Task 2.1 and used in Tasks 2.2–2.6. Fixed constants (`0x44444444` MBR id, `44444444-4444-4444-4444-444444444444` ext4 UUID/hash_seed, `44444444` vfat id) consistent across Phase A `by-uuid` symlink and Phase B mkfs calls.
- **Spike-dependent branches** are the only conditional steps and each carries a concrete primary command plus a recorded fallback — no bare placeholders.
