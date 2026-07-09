# Inline Fork Libs & Switch POC to Upstream nixpkgs

**Date:** 2026-07-06
**Status:** DONE — executed, all gates pass on `nixos-26.05` (commits `d7f81ed`, `9dd7b0e`, `675f4ac`)
**Scope:** POC toolchain only (`poc/`). No M2/M3 work. `ubuntu-noble` + OpenStack/KVM target unchanged.

## Problem

The POC's Nix flake pins its `nixpkgs` input to the **unmaintained** fork
`github:lheckemann/nixpkgs#foreign-distros`
(rev `5a4f40797c98c8eb33d2e86b8eb78624a36b83ea`). For a build system BOSH would
own, depending on one person's unmaintained nixpkgs fork is unacceptable. We must
(a) switch to an upstream nixpkgs release, and (b) make explicit which pieces the
BOSH team must actually maintain themselves.

## Key finding (why this is nearly free)

Upstream nixpkgs `nixos-26.05` (already realised on the build host at
`/nix/store/pl75sc81jyq5cz916j9bjwyx7c1w4qk3-source`) **still ships the entire
`vmTools` deb-image machinery the POC uses**, and it is equivalent to the fork:

| Piece POC consumes | Upstream `nixos-26.05` | Notes |
|---|---|---|
| `vmTools.runInLinuxVM` | present | equivalent |
| `vmTools.createEmptyImage` | present | equivalent |
| `vmTools.defaultCreateRootFS` | present | equivalent |
| `vmTools.debClosureGenerator` | present | adds a cosmetic `nixfmt` pass on the generated closure |
| `deb/deb-closure.pl` (the Perl resolver) | present | **byte-identical** to the fork's |
| `vmTools.fillDiskWithDebs` / `makeImageFromDebDist` | present | **still has the usrmerge raw-extract boot bug** — we keep our local fix |
| `vmTools.debDistros.ubuntu2204x86_64.packages` | present | only datum the POC used; upstream even adds `ubuntu2404x86_64` (Noble) |

Because the machinery is equivalent, the migration is a small, well-scoped change.

## Decisions

- **Inlining depth: Thin.** Rely on upstream `vmTools.{runInLinuxVM,
  createEmptyImage, debClosureGenerator, defaultCreateRootFS}`. Do **not** vendor
  the machinery into `poc/lib/`. This keeps the smallest POC-owned surface. The
  tradeoff — upstream's `vmTools` deb support is the same legacy code the fork
  branched from and is itself lightly maintained — is documented, not hidden.
- **nixpkgs pin: `nixos-26.05`** (stable release branch; the version already
  proven on the host). Not unstable (churn risk), not an opaque store rev.
- **Do not adopt upstream `debDistros.ubuntu2404x86_64`.** It pins
  `snapshot.ubuntu.com/20260101`, which we do not control. We keep our own Noble
  coordinates (`noble-source.nix` @ `archive.ubuntu.com` snapshot 503) so the pin
  is ours.

## Changes

1. **`poc/flake.nix`** — input `nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05"`.
   Remove the "matches lheckemann/nixbuntu-samples" comments.
2. **`poc/flake.lock`** — regenerate (`nix flake lock` / `nix flake update
   nixpkgs`) to pin `nixos-26.05`; keep `flake-parts` (version-independent).
3. **`poc/lib/base-packages.nix`** (new) — inline the base package list that was
   `vmTools.debDistros.ubuntu2204x86_64.packages`, i.e. the 27 strings
   `commonDebPackages ++ [ "diffutils" "libc-bin" ]`, with a header documenting
   provenance (transcribed from nixpkgs `vmTools` `commonDebPackages`).
4. **`poc/lib/noble-distro.nix`** — replace
   `basePackages = vmTools.debDistros.ubuntu2204x86_64.packages;` with
   `basePackages = import ./base-packages.nix;`; drop the now-unused `vmTools` arg.
5. **`poc/lib/fill-disk-usrmerge.nix`** — unchanged. Its
   `vmTools.{runInLinuxVM,createEmptyImage,debClosureGenerator,defaultCreateRootFS}`
   references now resolve against upstream (signatures verified equivalent).

## The maintenance surface this makes explicit

After the switch, the pieces BOSH must maintain itself (everything else comes from
upstream nixpkgs) are:

- `poc/lib/fill-disk-usrmerge.nix` — usrmerge-safe image assembly (upstream's is buggy).
- `poc/lib/base-packages.nix` — the vendored deb base list.
- `poc/lib/noble-{distro,source,packages}.nix`, `boot-packages.nix`,
  `image-packages.nix` — Noble APT coordinates, indices/hashes, and BOSH package set.

## Verification (all gates must pass, results unchanged from pre-switch)

1. `nix build ./poc#hello-vm` — M0 `runInLinuxVM` smoke test.
2. `nix build ./poc#noble-closure` — resolver gate; re-confirm the closure package
   **set** (429 pkgs, 0 critical gaps). The gate compares the package set, not file
   bytes, so upstream's `nixfmt` pass on the generated closure is cosmetic.
3. `nix build ./poc#noble-bootable` — EXIT 0.
4. `boot-qemu.sh <img>` — "BOOT OK: reached login prompt" (GRUB → kernel → login).

## Risks & mitigations

- **`runInLinuxVM` kernel/qemu wiring differs subtly on 26.05 → boot changes.**
  Mitigation: 26.05 is the tree already realised on the host; machinery verified
  equivalent to the fork. The QEMU/OVMF boot gate catches any regression.
- **flake-parts incompatible with 26.05 lib.** Mitigation: flake-parts is
  version-independent; pin kept. Eval failure would surface immediately.
- **`debClosureGenerator` nixfmt pass changes closure text.** Mitigation: gate
  compares package sets, not bytes. Benign.

## Out of scope

- Rewriting historical `docs/superpowers/{specs,plans}/…` docs that reference the
  fork — they record past state.
- Vendoring the vmTools machinery (rejected: Thin).
- M2 (real stemcell + Ruby removal) and M3 (director deploy).

## Execution

Subagent-driven, on `master`, commit per task:
1. Design doc (this file).
2. Add `poc/lib/base-packages.nix` + rewire `noble-distro.nix` (still on fork
   input — should build identically, proving the list swap is behaviour-neutral).
3. Switch `poc/flake.nix` to `nixos-26.05` + regenerate `poc/flake.lock`.
4. Verify all four gates; record results in this doc / feasibility spec.

## Outcome (executed 2026-07-06)

Done. `poc/flake.nix` now pins `github:NixOS/nixpkgs/nixos-26.05`
(rev `a50de1b`, 2026-07-04). The fork is no longer referenced by any live POC
file. All four gates pass:

| Gate | Result |
|---|---|
| `nix build ./poc#hello-vm` | EXIT 0 |
| `nix build ./poc#noble-closure` | EXIT 0 — **429 debs, unchanged** |
| `nix build ./poc#noble-bootable` | EXIT 0 |
| `boot-qemu.sh` | "BOOT OK: reached login prompt" |

The inlined base list was proven identical to the fork datum
(`nix eval`: `equal = true`, 27 pkgs), so the resolver closure is unchanged.

### Drift fixes required (2023 fork nixpkgs → 2026 nixos-26.05)

This is precisely the "what BOSH must maintain" surface the switch was meant to
expose. Three consequences of moving four nixpkgs years forward:

1. **structuredAttrs migration of vmTools.** Upstream now builds vmTools
   derivations with `structuredAttrs`, so list-valued attrs are bash arrays, not
   space-joined scalars. `fill-disk-usrmerge.nix` was rebased onto upstream's
   current `fillDiskWithDebs`: `debsFlat = lib.flatten debs` for the unpack loop,
   and — because structuredAttrs cannot export a *nested* list as a usable array
   — `debsGrouped = map (c: concatStringsSep " " c) debs` (a flat list of
   per-component strings) for the install loop. Without this the install loop ran
   zero times → no postinst scripts → no `/etc/passwd` → boot/login broken. The
   sole deviation from upstream remains the one-line usrmerge-safe extraction.
2. **`pkgs.udev` now aliases `systemd-minimal-libs`** (libs only; no
   `systemd-udevd`/`udevadm` binaries). `noble-bootable.nix` postInstall switched
   to `systemdMinimal`, the smallest package still shipping those binaries.
3. **`update-grub` ordering.** `grub-mkconfig` needs `/boot/grub` to pre-exist;
   the chroot runs `update-grub` before the `grub-install` that would create it.
   Added `mkdir -p /boot/grub`.

**Maintenance lesson:** upstream nixpkgs `vmTools` deb support still works but is
lightly maintained and drifts (structuredAttrs, `udev` alias). A BOSH conversion
must either pin nixpkgs and absorb these deltas on bump, or vendor the machinery
(the "Thick" option rejected here). The three fixes above took one session; a
nixpkgs bump could surface similar deltas and needs the boot gate to catch them.
