# Nix-Native Refactor: Directory Structure, Externalized Bash & Idiomatic Nix

- **Date:** 2026-07-10
- **Status:** Design for review
- **Repo:** `bosh-nix-linux-stemcell-builder` (standalone)
- **Scope:** Structural/readability refactor only — no change to build behavior or outputs
- **Approach:** A — externalize bash to real files + adopt upstream Nix helpers + restructure by build phase + collapse thin files

---

## 1. Purpose

The POC works end-to-end but reads poorly for humans:

- Bash is embedded in `.nix` strings (no syntax highlighting, no shellcheck) across
  ~20 files — the biggest offenders being the overlay fragments (`rsyslog` 252 lines,
  `users` 243, `audit` 226) and the VM build derivations (`mk-bootable-disk`,
  `fill-disk-usrmerge`).
- Everything lives in a flat `lib/` with a nested `overlays/`, so the build pipeline
  is not visible from the tree.
- Nix's expressiveness leaves many `.nix` files thin (the four blobstore-CLI wrappers
  are ~9 lines each; several package-set and target files are 12–48 lines), inflating
  the file count.
- Inline `${pkg}/bin/tool` interpolation and hand-rolled `stdenv.mkDerivation`
  + `buildCommand` patterns are used where upstream helpers exist.

**Goal:** make the codebase feel Nix-native and readable — highlighted/lintable shell,
a directory layout that narrates the build, fewer/denser `.nix` files, and idiomatic
upstream helpers — **without changing what gets built.**

## 2. Constraints & Acceptance Bar

- **Byte-identical `rootfs.tar.gz`.** The `os-image` derivation output (the pure-Nix
  fakeroot rootfs) must be byte-for-byte identical before and after the refactor. This
  is the primary regression guard.
  - The qcow2 disk and stemcell `.tgz` run inside `runInLinuxVM` and were never
    byte-reproducible (filesystem timestamps, UUIDs), so those layers are held to a
    weaker bar: they must still **build successfully**.
- **No output-name changes.** Existing flake outputs keep working
  (`noble-stemcell`, `os-image`, `noble-stemcell-disk`, `noble-rootfs`,
  `noble-bootable`, `noble-closure`, `hello-vm`, and the `pkgs`). New, clearer aliases
  may be added (e.g. `openstack-kvm`), but old names remain.
- **No behavior change.** Same debs, same overlay effects, same store paths for
  source-built components.

## 3. Target Directory Structure

Organized by BOSH's own two-phase build (OS image → stemcell). Two top-level build
dirs; the tree narrates the pipeline.

```
flake.nix                  # explicit outputs; wires the phases together
lib/                       # extracted local helpers
  mkOverlay.nix            #   { name; deps; src } → overlay fragment
  mkVmImage.nix            #   runInLinuxVM + createEmptyImage wrapper
ubuntu/                    # deb selection ("what Ubuntu packages go in")
  apt-pins.nix             #   pinned APT indices / hashes (was noble-source)
  deb-sets.nix             #   base/boot/bosh/image lists (folds base/boot/noble/image)
  essential.nix            #   Packages.xz parse for required/essential seed
pkgs/                      # source-built Nix components
  bosh-agent.nix
  monit.nix  monit-5.2.5.tar.gz
  blobstore-clis.nix       #   collapses mk-blobstore-cli + 4 wrappers → 1 attrset
rootfs/                    # PHASE 1 — the OS image
  fill-disk-usrmerge.nix
  tarball.nix              #   was mk-rootfs-tarball
  apply-overlays.nix       #   was mk-apply-overlays (fakeroot driver)
  os-image.nix             #   composed OS-image build target
  overlays/
    <name>.nix             #   metadata only: mkOverlay { name; deps; src=./<name>.sh }
    <name>.sh              #   highlighted, lintable shell fragment
    assets/                #   heredoc payloads as real files (securetty, banners, …)
    default.nix            #   the ordered overlay list (was inline in os-image)
stemcells/                 # PHASE 2 — per-IaaS stemcells (consumer-facing targets)
  bootable-disk.nix  bootable-disk.sh   # internal step: rootfs → bootable qcow2
  package.nix              #   was mk-stemcell (qcow2 + MF → .tgz)
  openstack-kvm.nix        #   build target — future: aws-xen.nix, gcp-kvm.nix, …
examples/                  # genuine demos / diagnostics
  noble-bootable.nix  noble-closure.nix  hello-vm.nix
scripts/                   # writeShellApplication-backed dev scripts
```

**Rationale**

- `rootfs/` (phase 1) and `stemcells/` (phase 2) are the only build-phase dirs and are
  clearly distinct — a filesystem vs a packaged bootable stemcell. This replaces the
  earlier confusing `rootfs/ · disk/ · images/` trio.
- `stemcells/` is where a consumer looks to answer "what can I build?" and "how do I
  add an IaaS?" — each IaaS is one file. The bootable-disk and packaging builders are
  internal steps of phase 2 and live here rather than in a separate `disk/` dir.
- `ubuntu/` (deb selection) no longer collides with `pkgs/` (source-built components).
- `examples/` now contains only real demos/diagnostics, so the name is honest.

**File-count reduction:** ~39 → ~22 `.nix` files. Notable collapses:
- `ubuntu/`: `noble-source` + `base-packages` + `boot-packages` + `noble-packages` +
  `image-packages` → `apt-pins.nix` + `deb-sets.nix` (essential kept separate for its
  real parsing logic).
- `pkgs/`: `mk-blobstore-cli` + 4 CLI wrappers → `blobstore-clis.nix`.
- `rootfs/`: the inline overlay list in `os-image.nix` → `overlays/default.nix`.

## 4. Bash Externalization (byte-identical-critical)

**Overlays.** Each `overlays/<name>.nix` becomes metadata only:

```nix
mkOverlay {
  name = "ssh";
  deps = [ gnused coreutils ];        # informs PATH; defaults to the ambient set
  src  = ./ssh.sh;
}
```

`mkOverlay` sets `script = builtins.readFile src` (behaviorally identical to today's
inline string). The `apply-overlays.nix` driver concatenates the fragments in the same
order, in the same single `fakeroot` session, under the same `set -euxo pipefail`
subshell wrapper. Because the executed commands are unchanged, the rootfs bytes are
unchanged.

**Heredoc payloads** (securetty, `/etc/issue` + `/etc/issue.net` banners, empty
`/etc/motd`, `motd-news`, sshd cipher/MAC lines, the ssh firstboot drop-in, grub
defaults, fstab) move to `overlays/assets/` (or `stemcells/assets/`) as real files and
are emitted via the same `cat >` / `printf` calls. **Exact bytes — including trailing
newlines — must be preserved**; this is the single highest-risk area for the
byte-identical guarantee and is verified per-overlay.

**VM build scripts** (`stemcells/bootable-disk.sh`) are not byte-constrained. They
become real `.sh` files with `@placeholder@` markers substituted at build time via
`replaceVars` (so store paths like `@util-linux@` are injected, keeping the `.sh`
highlightable and shellcheck-able).

## 5. Upstream Helpers — Where Each Applies

| Helper | Replaces | Where | Byte-safe? |
|--------|----------|-------|------------|
| `lib.getExe` / `getExe'` | inline `${pkg}/bin/tool` | `stemcells/` VM builds | n/a (VM layer) |
| `runCommand` / `runCommandLocal` | `stdenv.mkDerivation` + `buildCommand` | pure transforms | only if output verified byte-identical; else keep `mkDerivation` |
| `writeShellApplication` | hand-written scripts | `scripts/*` dev tools (shellcheck + `runtimeInputs`) | n/a |
| `writeText` | heredoc-built config in Nix | small in-Nix assets | preserve bytes |
| `replaceVars` (`substituteAll` successor) | inline store-path interpolation in shell | `bootable-disk.sh` | n/a (VM layer) |

Rule: in the **rootfs phase**, prefer the smallest change that preserves bytes
(externalize + `readFile`), and only swap `mkDerivation`→`runCommand` when a build
confirms identical output. In the **stemcell phase**, adopt helpers freely.

## 6. Local `lib/`

- `lib/mkOverlay.nix` — `{ name; deps ? …; src }` → `{ name; script; }`. Removes the
  repeated `{ }: { name = …; script = ''…''; }` boilerplate across ~13 overlays.
- `lib/mkVmImage.nix` — thin wrapper over `vmTools.runInLinuxVM` +
  `vmTools.createEmptyImage`, shared by `stemcells/bootable-disk.nix` and reusable by
  `examples/noble-bootable.nix` (removes duplicated VM boilerplate).

## 7. flake.nix & Tooling

- Replace the `mapDir ./examples // mapDir ./pkgs` auto-discovery with **explicit
  outputs** wired to the new dirs. Keep all existing output names; add `openstack-kvm`
  as the clear alias for the noble stemcell.
- Add **`treefmt`** (nixfmt + shfmt + shellcheck) as the flake `formatter` and a flake
  `check`, so `nix fmt` and `nix flake check` enforce style and lint going forward.
  Shellcheck runs over the externalized `.sh` files; overlay fragments are checked in
  "sourced fragment" mode (they share `$root`/PATH from the driver).

## 8. Verification Strategy

1. **Baseline snapshot.** Before any change, build the current `os-image` and record
   its store path + `rootfs.tar.gz` hash. (Use the `path:` fetcher: the local
   virtiofs + libgit2 quirk breaks the `git+file` fetcher — see the standalone-repo
   notes. `git archive HEAD | tar -x` into a scratch dir, then `nix build path:.#os-image`.)
2. **Per-stage check.** After each refactor stage that touches rootfs code, rebuild
   `os-image` and assert the `rootfs.tar.gz` is byte-identical (`cmp` + store-path
   equality). Any diff halts that stage for root-cause (systematic-debugging).
3. **Lint/format.** `nix fmt --check` and `nix flake check` green.
4. **Full build.** `nix build .#noble-stemcell` (== `.#openstack-kvm`) succeeds.
5. **Optional.** Re-deploy smoke on the Incus director — not required by the
   acceptance bar, but available as a final confidence signal.

## 9. Sequencing (for the plan)

Ordered to keep the tree buildable and the byte-identical check meaningful at every
step:

1. Add `lib/mkOverlay.nix` + `lib/mkVmImage.nix` (no behavior change).
2. Externalize overlays to `.sh` + `assets/`, one at a time, byte-checking after each.
3. Restructure dirs (`ubuntu/`, `rootfs/`, `stemcells/`, `examples/`) + collapse thin
   files; update `flake.nix` to explicit outputs. Byte-check `os-image`.
4. Adopt upstream helpers in the stemcell phase (`getExe`, `replaceVars`,
   externalize `bootable-disk.sh`). Build-check.
5. Add `treefmt` formatter + flake `check`; run `nix fmt`; fix lint.
6. Final full build + update README/docs to reflect the new layout.

## 10. Out of Scope / YAGNI

- No multi-IaaS implementation now — only the `stemcells/` seam that makes it a
  one-file addition later.
- No change to the deb pin set, agent/monit versions, or overlay effects.
- No Go test rewrite (tracked separately).
- `mkDerivation`→`runCommand` swaps are opportunistic, not mandatory; skipped wherever
  they would risk the byte-identical rootfs.
