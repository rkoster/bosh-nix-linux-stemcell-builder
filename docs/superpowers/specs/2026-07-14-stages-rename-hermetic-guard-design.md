# Design: Rename overlays → stages, relocate to build/stages/, add a hermetic-execution guard

## Problem

`build/rootfs/overlays/` holds the ordered set of rootfs configuration steps
(SSH, sudoers, audit, systemd units, users, etc.) applied onto the base Noble
rootfs. Two issues:

1. **Naming collision.** "Overlay" already has a specific, different meaning
   in Nix (a nixpkgs overlay is a function that overrides a package set). Using
   the same word for "an ordered rootfs configuration step" is confusing. The
   upstream tooling this POC replaces already called the equivalent concept
   **stages** (`ubuntu_os_stages`), a term this repo's own comments already
   reference (`build/rootfs/overlays/default.nix:1`).
2. **Directory nesting implies a false scope.** Living under `build/rootfs/`
   suggests these steps are rootfs-specific, but conceptually they're a
   sibling build concern to `pkgs/`, `ubuntu/`, `stemcells/` — they deserve to
   be a top-level `build/` directory, not a subdirectory of `rootfs/`.
3. **The hermetic guarantee is implicit, not enforced.** The stage-application
   step (and the earlier VM-based deb-install step) are already
   network-isolated *in practice*, but only because the ambient `nix.conf` has
   `sandbox = true` (the Linux default). Nothing in the repo's own build
   definitions verifies this. If a build ever runs with a relaxed sandbox
   (`--option sandbox false`, or a misconfigured CI runner), it would silently
   succeed with real network access available — no warning, no failure. The
   abstraction should prove its own hermeticity rather than depend entirely on
   external configuration.

## Investigation Findings

- `build/rootfs/apply-overlays.nix` is a plain `stdenv.mkDerivation` running
  `fakeroot bash` — **not** a VM. It is the mechanism this design renames and
  relocates.
- A separate, earlier mechanism — `build/rootfs/fill-disk-usrmerge.nix`,
  invoked via `rootfs.nix` → `tarball.nix` — uses `vmTools.runInLinuxVM` to
  install `.deb` packages (dpkg + postinst scripts) into the base rootfs
  *before* any stages run. `os-image.nix` treats that VM-built tarball as an
  opaque `base` input.
- Empirically verified on this machine (`sandbox = true`): a plain
  non-fixed-output derivation that attempts a raw TCP connect
  (`/dev/tcp/1.1.1.1/443`) fails immediately with "Network is unreachable" —
  Nix's build sandbox unshares the network namespace, so even though the VM
  step's QEMU invocation doesn't pass an explicit `-nic none` (nixpkgs'
  `vmTools.runInLinuxVM` adds no network device args at all), the *host* QEMU
  process itself has no route out, so any guest-side NIC has nowhere to send
  packets. Both mechanisms are hermetic today, contingent entirely on
  `sandbox = true`.

## Goal

1. Move `build/rootfs/overlays/` → `build/stages/`.
2. Rename the "overlay" concept to "stage" throughout: directory, file names,
   internal variable/parameter names, comments, and documentation.
3. Add a self-verifying network-namespace guard to both the stage-application
   step and the VM-based deb-install step, so a build fails loudly if network
   is ever reachable, instead of silently depending on ambient `nix.conf`.

## Scope

### 1. Rename & relocation

| Current | New |
|---|---|
| `build/rootfs/overlays/` | `build/stages/` |
| `build/rootfs/overlays/default.nix` | `build/stages/default.nix` |
| `build/rootfs/apply-overlays.nix` | `build/rootfs/apply-stages.nix` (stays under `rootfs/` — it's rootfs-assembly glue that *consumes* stages, not a stage definition itself) |
| `build/lib/mkOverlay.nix` | `build/lib/mkStage.nix` |

Individual stage definition files that don't have "overlay" in their name
(`ssh.nix`, `audit.nix`, `audit.sh`, `users.nix`, `sudoers-pam.nix`,
`sysctl-limits-env.nix`, `systemd-services.nix`, `misc-os.nix`/`.sh`,
`openstack-agent-settings.nix`/`.sh`, `rsyslog.nix`/`.sh`, `agent.nix`,
`blobstore-clis.nix`, `debug-ssh-keys.nix`, `debug-ssh-root-login.nix`/`.sh`)
are moved but **not renamed**.

All moves use `git mv` to preserve history.

**Identifier renames** inside the moved/adjacent files:
- `overlays` (the list) → `stages`
- `ov` (single list item in `apply-overlays.nix`'s `map`) → `st`
- `runOverlays` → `runStages`
- `applyOverlays` (in `os-image.nix`) → `applyStages`
- Comments referencing "overlay(s)" throughout `build/rootfs/os-image.nix`,
  `build/rootfs/apply-stages.nix`, `build/stages/default.nix`, and the
  per-stage files' header comments ("Applied by rootfs/apply-overlays.nix
  inside the shared fakeroot...") updated to the new path/terminology.

**`flake.nix`:** `treefmt.settings.formatter.shfmt.excludes` changes from
`"build/rootfs/overlays/*.sh"` to `"build/stages/*.sh"`.

**`docs/ARCHITECTURE.md`, `README.md`:** path and terminology references
updated. `docs/specs/*`, `docs/plans/*`, and existing
`docs/superpowers/specs/*` / `docs/superpowers/plans/*` dated documents are
**left untouched** (same precedent as the prior
`move-nix-sources-into-build-dir` design) — they describe the repo as it
existed at specific points in time.

### 2. Hermetic guard

New shared snippet: `build/lib/hermetic-guard.sh`

```sh
# Hermetic guard: prove no network is reachable before any stage/package
# script runs. This does NOT rely on nix.conf's `sandbox = true` alone —
# if the sandbox is misconfigured (e.g. built with `--option sandbox false`),
# this turns that into a hard, loud build failure instead of a silent leak.
if timeout 3 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null; then
  echo "HERMETIC VIOLATION: network is reachable inside this build." >&2
  echo "Refusing to continue - stemcell artifacts must come only from Nix-tracked inputs." >&2
  exit 1
fi
```

- Raw IP (`1.1.1.1:443`), not a hostname: the sandbox has no
  `/etc/resolv.conf`, so a hostname-based probe would conflate "no DNS" with
  "no network." A raw-IP connect attempt gives an unambiguous signal.
- `timeout 3` bounds worst-case added build time; in practice the connect
  fails synchronously with `ENETUNREACH` inside the sandbox, so this adds no
  measurable delay to normal builds.
- Read via `builtins.readFile` (same pattern `mkStage.nix`/`mkOverlay.nix`
  already uses) and inlined into two build scripts, so there is one canonical
  copy of the probe logic.

**Injection points:**

1. `build/rootfs/apply-stages.nix` — prepended inside the `fakeroot bash`
   heredoc, before `runStages` executes. Covers the stage-application
   mechanism itself (the primary scope of this design).
2. `build/rootfs/tarball.nix`'s `createRootFS` override — prepended before
   `mkfs.ext4`/dpkg-install begins. This is the right injection point rather
   than editing `fill-disk-usrmerge.nix` directly, because that file is
   explicitly documented as "a verbatim mirror of upstream `fillDiskWithDebs`
   ... keep in sync when bumping nixpkgs"; `createRootFS` is already a local
   override point, so adding the guard there introduces no new upstream
   drift. Covers the VM-based deb-install step.

**Failure semantics:** any successful connection is an immediate hard build
failure with a clear `HERMETIC VIOLATION` message — never a warning, never a
skip.

## Verification

1. **No regression:** `nix build .#os-image`, `.#noble-stemcell` still
   succeed; `scripts/byte-check-osimage.sh` / `byte-check-stemcell.sh` still
   report byte-identical output (the guard runs before any file mutation and
   adds no non-determinism).
2. **Prove the guard is load-bearing:** one-time manual smoke test —
   `nix build .#os-image --option sandbox false` must now **fail** with the
   `HERMETIC VIOLATION` message, instead of silently succeeding. This is the
   evidence the check does something real, not decoration. (`--option sandbox
   false` requires the invoking user to be a `trusted-user` in the Nix daemon
   config; if unavailable, fall back to a standalone `nix-build` of a minimal
   derivation containing just the guard snippet with sandboxing disabled, to
   demonstrate the same failure mode in isolation.)
3. **`nix flake check`** — validates the flake still evaluates after the
   rename/relocation (treefmt config, import chains).
4. **Doc consistency:** no stale `overlay`/`rootfs/overlays` references remain
   in `ARCHITECTURE.md`/`README.md` (excluding historical dated docs, which
   are out of scope by precedent).

## Out of Scope

- Any change to the *content* or *ordering* of individual stages
  (ssh/sudoers/audit/etc.) — this is a structural/mechanical + guard-hardening
  change only.
- Static linting of stage scripts for network-tool invocations (curl, wget,
  etc.) — considered and explicitly not chosen; the runtime
  network-namespace probe is the authoritative guarantee, and a static scan
  would be redundant belt-and-suspenders not requested here.
- Changing the debClosureGenerator / fetchurl-based package-fetching layer —
  already hermetic via fixed-output derivations with sha256 verification;
  untouched by this design.
