# Deterministic Bootable Disk Image — Design

- Date: 2026-07-16
- Status: Approved (design)
- Scope: Make the heavy BOSH stemcell disk images (`openstack-kvm` qcow2 and `aws` raw) bit-for-bit reproducible on the same machine, without changing their functional behavior.
- Related: `docs/superpowers/specs/2026-07-16-aws-stemcell-target-design.md`, `docs/superpowers/plans/2026-07-16-aws-stemcell-target.md`

## Problem

The disk image produced by `build/stemcells/bootable-disk.{nix,sh}` is not reproducible: two builds with identical inputs produce different output bytes. This was found while attempting an OpenStack byte-identity regression test (the two builds' tarballs differed only in the `image` member).

`nix build .#noble-stemcell-disk --rebuild` reports *"output differs"* — confirming inherent non-determinism, independent of source changes.

## Root-cause investigation (evidence)

Two independent OpenStack disk builds were compared (`g8zx07…` vs `i15x0z8…`; executed commands proven byte-identical, so every difference is pure non-determinism). Converting both qcow2 → raw and bucketing differing bytes by partition region:

| Region | Differing bytes | Root cause |
|--------|----------------|-----------|
| MBR `0x1b8–0x1bb` | 4 | **RC1** — random MBR disk signature written by `sfdisk`. Propagates to PARTUUID and into `/run/blkid/blkid.tab`. |
| ext4 superblock | ~dozen | **RC2** — wall-clock `Last mount time` / `Last write time`; journal sequence differs. |
| ext4 data blocks | **~1.1 GB (99.99%)** | **RC3** — block-allocator non-determinism: identical files placed at different physical blocks by the live kernel ext4 allocator during `tar` extract into the mounted fs. |
| ESP (vfat) | 21 | **RC4** — FAT directory-entry timestamps for the grub EFI files copied by `grub-install`. |
| `initrd.img` | 6 (→2 after gzip) | **RC5** — cpio entry mtimes (`10:28` vs `10:30`, wall-clock build time). |
| ext4 journal | (within RC3 region) | **RC6** — non-deterministic journal transaction contents/sequence. |
| `/run/blkid/blkid.tab` | whole file | **RC7** — leaked runtime state (`TIME=`, `PARTUUID=`); PARTUUID derives from RC1. |

Key proofs:
- Of **36,271 files, only 2 differ in content** (`initrd.img`, `/run/blkid/blkid.tab`); every other file is byte-identical. So the 1.1 GB raw difference is overwhelmingly **block placement**, not content.
- `vmlinuz` (identical bytes) occupies blocks `33536-33791 + 49152-52540` in one image but contiguous `45056-48700` in the other — direct confirmation of RC3.
- The `initrd.img` cpio differs only in the 8-byte `mtime` fields of 3 header entries.

**Dominant cause: RC3 (ext4 block-allocator non-determinism).**

## How NixOS solves this (reference)

From nixpkgs `nixos/lib/make-ext4-fs.nix` and `nixos/lib/make-disk-image.nix`:

- **Core principle: never mount the target filesystem; never let the live kernel allocator touch it.** NixOS assembles a *staging directory*, then populates the image with an **offline** tool:
  - `faketime -f "1970-01-01 00:00:01" fakeroot mkfs.ext4 -L <label> -U <uuid> -d ./rootImage $img` (populate-at-creation, no mount), or
  - `cptofs` (an LKL / Linux-Kernel-Library userspace tool) to copy a staging root into an already-formatted image without mounting or a VM.
- An explicit `deterministic ? true` mode fixes GPT disk GUID, partition GUIDs/type IDs, and the ext4 filesystem UUID and "last time checked".
- `faketime` freezes the clock for `mkfs` (mke2fs writes wall-clock fields that don't all honor `SOURCE_DATE_EPOCH`); `fakeroot` gives deterministic ownership without real root.
- **Honest caveat, from their source:** *"BIOS/MBR support is 'best effort' at the moment. Boot partitions may not be deterministic."* NixOS sidesteps the hardest part by preferring GPT + fixed GUIDs + EFI. The BIOS boot code remains their acknowledged weak spot.

**Implication for us:** the ext4 fix (RC2/RC3/RC6) is a solved problem — copy the `faketime + fakeroot + mkfs.ext4 -d` pattern. We are better positioned than NixOS on RC1: we use MBR but control `sfdisk`, so we can pin a fixed `label-id`. The one genuinely hard piece — matching NixOS's own assessment — is the **BIOS grub `core.img` in the MBR gap**.

## Approach (chosen)

**Approach 1 — Offline assembly (NixOS model).** A chroot phase generates *files only* into a deterministic staging tree; the disk image is then assembled fully offline (no mount of the target fs).

Alternatives considered and rejected:
- **Approach 2 (hybrid re-layout):** run today's in-VM mount+chroot to produce the tree, then copy out and re-layout offline. More redundant work, keeps a live-fs step.
- **Approach 3 (LKL `cptofs`):** faithful to NixOS `make-disk-image`, but adds a `cptofs`/LKL dependency that `mkfs.ext4 -d` already makes unnecessary.
- **Post-hoc canonicalization only:** cannot fix RC3 (block placement can't be reordered after the fact). Rejected.

## Architecture

Two derivations with a **deterministic staging tree** as the boundary:

```
Phase A: bootable-rootfs  (Nix runInLinuxVM — chroot needed to run noble tooling)
  - tar-extract os-image rootfs into staging/
  - chroot: update-initramfs, update-grub, generate grub i386-pc modules+core.img
    and x86_64-efi grubx64.efi as FILES (no device writes)
  - canonicalize: fix initramfs mtimes, wipe volatile /run|/tmp|caches, pin all mtimes
  - output: deterministic staging tree (rootfs + /boot/grub + ESP/)
        │
        ▼  (staging tree = clean, timestamp-fixed; an input to Phase B)
Phase B: bootable-disk  (pure offline builder — no VM mount of target fs)
  - sfdisk with FIXED label-id                       (RC1)
  - faketime + fakeroot + mkfs.ext4 -d staging/ -U … (RC2, RC3, RC6)
  - mkfs.vfat -i <fixed> + mcopy ESP/ (SOURCE_DATE_EPOCH) (RC4)
  - assemble partitions into whole-disk raw at fixed offsets
  - grub-bios-setup: embed core.img into MBR gap
  - qemu-img convert -O <qcow2|raw> → output (existing diskFormat contract)
```

Rationale: never mounting the target fs removes RC2/RC3/RC6 at the source; the risky BIOS-grub step is isolated in a small, pure, easily `--rebuild`-checkable derivation; both targets already share `bootable-disk`, so one fix covers `openstack-kvm` (qcow2) and `aws` (raw).

### Phase A — deterministic staging tree

Runs in the VM because the chroot must execute noble's `update-initramfs` / `update-grub` / grub tooling. Its only responsibility is to emit a byte-deterministic tree.

1. Extract `os-image` rootfs into `staging/` (os-image is already deterministic).
2. Chroot (bind `/proc`,`/sys`,`/dev`, run udevd as today):
   - `update-initramfs -c`, then re-pack each initrd as today **plus** `touch -d @$SOURCE_DATE_EPOCH` the extracted cpio tree before repack — fixes **RC5**.
   - Preserve the existing load-bearing trick: manually create `/dev/disk/by-uuid/<root-uuid>` so `grub-mkconfig` emits `root=UUID=…` (required because Incus presents the disk as `/dev/sda`).
   - `update-grub` → `grub.cfg` (deterministic: root referenced by the fixed FS UUID `4444…`).
   - Generate grub artifacts as files without a device write:
     `grub-install --target=i386-pc --grub-setup=/bin/true …` (or `grub-mkimage` directly) → `/boot/grub/i386-pc/*` + `core.img`.
     `grub-install --target=x86_64-efi --removable --no-nvram …` into a staging `ESP/` dir → `grubx64.efi` + modules. (Exact flag mechanism finalized in the plan.)
3. Canonicalize:
   - Remove volatile state: `staging/run/*`, `staging/tmp/*`, `var/cache/ldconfig/*`, etc. — fixes **RC7**.
   - `find staging -exec touch --no-dereference -d @$SOURCE_DATE_EPOCH` to pin every remaining mtime.
4. Emit the tree in `$out` (directory, or canonical tar: sorted, `--mtime=@0 --owner=0 --group=0 --numeric-owner`).

### Phase B — offline deterministic assembly

Pure builder; no VM mount of the target fs; no privileged ops beyond `fakeroot` (and possibly a minimal loopback for `grub-bios-setup` — see risks).

1. `truncate` a raw image to a **fixed** size (constant, not content-derived, so it cannot drift).
2. `sfdisk` writes the partition table with a **fixed MBR disk signature** (`label: dos`, `label-id: <constant>`) — fixes **RC1** and stabilizes PARTUUID. Layout unchanged: ESP p1 `2048..100351` (type ef, bootable), root p2 `100352..`.
3. Root ext4, offline:
   `faketime -f "1970-01-01 00:00:01" fakeroot mkfs.ext4 -F -L root -U 44444444-4444-4444-4444-444444444444 -E hash_seed=44444444-4444-4444-4444-444444444444,root_owner=0:0 -d staging/ <p2-image>`
   — deterministic block layout (**RC3**), fixed superblock/inode times (**RC2**), deterministic journal (**RC6**), preserved ownership via `fakeroot`.
4. ESP vfat, offline: `mkfs.vfat -F32 -n ESP -i <fixed>`, then `mcopy` the staged `ESP/` in with `SOURCE_DATE_EPOCH` honored (mtools) — fixes **RC4**.
5. Assemble the two partition images into the whole-disk raw at their sector offsets.
6. `grub-bios-setup` embeds `core.img` (from staging `/boot/grub/i386-pc`) into the post-MBR gap, pointing at the fixed-UUID root; `boot.img` → MBR boot code. **Highest-risk step.**
7. `qemu-img convert -f raw -O @diskFormat@ … @diskOutput@` → existing output contract (qcow2 for openstack, raw for aws).

Tooling to confirm present in the closure: `libfaketime`, `fakeroot`, `e2fsprogs` (`mkfs.ext4 -d`), `mtools` (`mcopy`), `grub2` (`grub-bios-setup`), `dosfstools`, `util-linux` (`sfdisk`), `qemu`.

## Root-cause coverage

| RC | Fix | Phase |
|----|-----|-------|
| RC1 MBR signature | `sfdisk` fixed `label-id` | B |
| RC2 ext4 superblock times | `faketime` around `mkfs.ext4` | B |
| RC3 block placement | `mkfs.ext4 -d` (offline populate, no mount) | B |
| RC4 ESP vfat times | `mkfs.vfat -i` + `mcopy` with `SOURCE_DATE_EPOCH` | B |
| RC5 initramfs mtimes | `touch -d @0` before cpio re-pack | A |
| RC6 ext4 journal | deterministic journal via `mkfs -d`, no live writes | B |
| RC7 `/run` leak | wipe volatile dirs in staging | A |

## Regression guard

A determinism guard so this cannot silently regress:

- Add flake checks `checks.<system>.disk-determinism-openstack` and `…-aws`.
- Each must **actually re-exercise the build** (Nix caches by drv hash, so two evals reuse the same output). Candidate mechanisms, to be finalized in the plan:
  - a CI job running `nix build .#<disk> --rebuild` (Nix's own bit-identity check), and/or
  - a wrapper that builds the raw image, records its sha256 into `$out`, and asserts equality across two independent builds.
- The guard must fail loudly on any byte difference.

## Functional boot validation

**OpenStack/KVM (primary) — automated via the Incus lab:**
- Run `./scripts/deploy-stemcell.sh --build --cleanup` with `./bosh.env` sourced (Incus-CPI director; the Incus CPI consumes the OpenStack qcow2 stemcell).
- The script builds `.#noble-stemcell`, uploads, deploys a 1-instance `nix-stemcell-poc`, and asserts the VM reaches `running`, accepts BOSH agent/SSH, and reports correct kernel/OS.
- This is the gate that the offline assembly (esp. BIOS grub / `core.img`) did not break boot.

**AWS (raw) — deferred/manual:**
- The Incus lab does not exercise the AWS raw image; AWS boot correctness is a separate manual step (real AWS import), out of scope for this change's automated gate. AWS determinism is still verified byte-wise via `--rebuild`.

## Success criteria

1. `nix build .#noble-stemcell-disk --rebuild` — bit-identical on the same machine.
2. `nix build .#noble-stemcell-aws-disk --rebuild` — bit-identical on the same machine.
3. `./scripts/deploy-stemcell.sh --build --cleanup` — OpenStack stemcell boots on the Incus lab and passes SSH/kernel/OS checks.
4. Determinism regression guard present and passing.

## Risks and open questions

1. **BIOS grub determinism (highest risk).** `grub-bios-setup` + `core.img` in the MBR gap is the piece NixOS calls "best effort." Expected deterministic given fixed inputs/layout; may require iteration. Focus of verification.
2. **Where `grub-bios-setup` runs.** It may require a loop/block device rather than a plain image file. If so, that step may need a minimal loopback (possibly inside a VM). Determinism is unaffected (fixed inputs); the "Phase B = no VM at all" boundary may soften to "Phase B = offline fs population + minimal loopback for bios-setup." To be settled by a small spike.
3. **Boot correctness must be preserved.** Keep the `/dev/disk/by-uuid` trick so `grub.cfg` stays UUID-based; validated by the Incus deploy.
4. **Grub file-generation mechanism** (`grub-install --grub-setup=/bin/true` vs `grub-mkimage`) — finalize in the plan.
5. **Tool availability/versions** (`libfaketime`, `fakeroot`, `mtools`, e2fsprogs `-d`) — confirm in nixpkgs closure.

## Scope

**In scope:** deterministic, functionally-equivalent qcow2 (openstack) and raw (aws) disk images; the two-phase refactor; the regression guard; OpenStack boot validation via the Incus lab.

**Out of scope:** cross-machine reproducibility; automated AWS boot validation; FIPS; arm64; changes to partition layout, filesystem type, or boot behavior; light/AMI AWS builds.
