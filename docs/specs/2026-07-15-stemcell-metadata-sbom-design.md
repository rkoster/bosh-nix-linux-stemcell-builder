# Deterministic Stemcell Metadata & SBOM Generation

Date: 2026-07-15
Status: Design (approved for planning)

## Problem

Four of the six BOSH stemcell members are currently emitted as empty stubs by
`build/stemcells/package.nix`:

- `packages.txt` — `touch` (empty) — `package.nix:90`
- `dev_tools_file_list.txt` — `touch` (empty) — `package.nix:91`
- `sbom.spdx.json` — `echo '{}'` — `package.nix:94`
- `sbom.cdx.json` — `echo '{}'` — `package.nix:95`

(The fifth/sixth members, `image` and `stemcell.MF`, already carry real content.)

The BOSH director only checks for member *presence*, not content, so builds
succeed — but these files should carry real, audit-grade content. This design
makes them real, generated **deterministically** and — as far as practical —
via **pure Nix** (no VM, no privileged mounts).

## How upstream produces these files

From `cloudfoundry/bosh-linux-stemcell-builder`:

- **`packages.txt`** — `stemcell_builder/stages/bosh_package_list/apply.sh:10-13`:
  runs `dpkg -l` inside the chroot and copies the output.
- **`dev_tools_file_list.txt`** — `stemcell_builder/stages/dev_tools_config/apply.sh`
  + `assets/generate_dev_tools_file_list.sh`: for a **hardcoded** list of build-tool
  packages (gcc, build-essential, clang, cmake, …), runs `dpkg-query -L` to
  enumerate their installed files, filtering out directories and symlinks, then
  `sort | uniq`. The director uses this to strip compilers off non-compilation VMs.
- **`sbom.spdx.json` / `sbom.cdx.json`** — `stemcell_builder/stages/sbom_create/apply.sh:36`:
  mounts the disk image partition and runs `syft <mnt> -o spdx-json -o cyclonedx-json`.

These upstream steps are inherently non-deterministic (live `dpkg -l` ordering,
syft timestamps/UUIDs) and require a chroot / privileged loopback mount.

## Key facts about this repository

This repo builds a **genuine Ubuntu 24.04 Noble** userland from a **pinned deb
closure** resolved purely in Nix:

- The resolved `.deb` set is produced by `vmTools.debClosureGenerator` and exposed
  as the `expr` passthru — `build/rootfs/fill-disk-usrmerge.nix:189-211`.
- The Ubuntu snapshot is pinned — `build/ubuntu/apt-pins.nix:8`.
- The final installed package set is assembled in `build/ubuntu/deb-sets.nix:154-156`.

**Critical for this design:** the *complete final rootfs* is materialized as a
plain directory tree — purely, with **no VM** — inside the `fakeroot` session of
`build/rootfs/apply-stages.nix:62-67`. At that point `$root` contains:

- the **real** dpkg admindir at `$root/var/lib/dpkg` (status db + `info/*.list` +
  `info/*.md5sums`), from the deb-closure base rootfs; and
- **all** stage overlays, including the source-built binaries: bosh-agent, monit,
  and the blobstore CLIs (davcli, s3cli, gcscli, azureStorageCli) — see
  `build/stages/default.nix:4-30`.

Because the real dpkg db and the source-built binaries are both present in this
pure fakeroot tree, we get **on-disk fidelity with zero VM changes**.

## Design

Generate all four files from the final rootfs tree (`$root`) **inside the existing
`apply-stages.nix` fakeroot session**, where the ~3 GB tree already exists — no
second extraction. Emit them to `$out` alongside `rootfs.tar.gz`, then thread them
through the disk/stemcell pipeline into `build/stemcells/package.nix`, replacing
the stubs.

### File generation

1. **`packages.txt`**
   `dpkg-query --admindir="$root/var/lib/dpkg" -l > packages.txt`
   Produces the exact `dpkg -l` column layout (`ii  name  version  arch  description`),
   matching upstream. Deterministic: dpkg-query emits packages in a stable order,
   and the admindir content is reproducible from the pinned closure.

2. **`dev_tools_file_list.txt`**
   Port upstream's hardcoded dev-tool package list (from
   `generate_dev_tools_file_list.sh`) into the repo. For each package **that is
   actually installed** (intersect with the dpkg status db), run
   `dpkg-query --admindir="$root/var/lib/dpkg" -L <pkg>`, filter out directories and
   symlinks (as upstream does via `file`), then `sort | uniq`. If none of the
   dev-tool packages are present (likely, since this is a minimal stemcell), the
   file is legitimately empty — matching upstream semantics.

3. **`sbom.spdx.json` / `sbom.cdx.json`**
   `syft dir:"$root" -o spdx-json=sbom.spdx.json -o cyclonedx-json=sbom.cdx.json`.
   A single scan of the whole rootfs covers **both** the Ubuntu `.deb` packages
   (dpkg cataloger reading `var/lib/dpkg`) and the **source-built** components
   (Go-binary cataloger reading embedded module info from bosh-agent and the
   blobstore CLIs).

   **Determinism:** syft embeds non-deterministic fields by default. We pin them:
   - Export `SOURCE_DATE_EPOCH` (already the repo convention: `1700000000`).
   - Post-process both JSON outputs with `jq` to force fixed, derived values for:
     - SPDX: `.documentNamespace`, `.creationInfo.created`
     - CycloneDX: `.serialNumber`, `.metadata.timestamp`
   - syft's own version string is pinned by the nixpkgs pin, so it is stable
     across rebuilds.

   **Known limitation:** monit is a C binary and may not be auto-cataloged by
   syft. Optional enhancement: inject monit as an explicit SBOM component (name +
   version from `build/pkgs/monit.nix`) during post-processing. Deferred unless
   full coverage is required.

### Plumbing

- Add `syft`, `dpkg`, `jq` (and `file`/`coreutils` as needed) to
  `apply-stages.nix` `nativeBuildInputs`.
- After the stage scripts run and before the final repack, generate the four files
  from `$root` and copy them into `$out` (e.g. `$out/metadata/`), alongside
  `$out/rootfs.tar.gz`.
- Thread these four files through the existing pipeline
  (`os-image.nix` → `bootable-disk` → `openstack-kvm-disk.nix` →
  `openstack-kvm.nix`) so they reach `build/stemcells/package.nix` as inputs.
- In `package.nix`, replace the four stub-creation lines (`package.nix:90-95`)
  with `cp` of the generated files. The 6-member presence check
  (`package.nix:99-115`) and deterministic tar assembly (`package.nix:122-131`)
  are unchanged.

## Determinism guarantees

- No VM, no chroot, no privileged loopback mount — all generation runs in the
  existing pure fakeroot derivation.
- Inputs are fully pinned (Ubuntu snapshot, nixpkgs, source-built component revs),
  so the dpkg db and source binaries are reproducible.
- `dpkg-query` output ordering is stable; SBOM non-deterministic fields are pinned
  via `SOURCE_DATE_EPOCH` + `jq` normalization.
- Target: byte-identical `packages.txt`, `dev_tools_file_list.txt`,
  `sbom.spdx.json`, `sbom.cdx.json` across rebuilds from the same inputs.

## Validation

- Build twice; assert the four files are byte-identical between builds.
- `packages.txt`: assert non-empty, well-formed `dpkg -l` header + rows; spot-check
  a known package (e.g. `systemd`, `dpkg`).
- `dev_tools_file_list.txt`: assert it matches the intersect logic (empty if no
  dev tools installed; otherwise sorted/unique absolute file paths).
- SBOMs: `jq empty` (valid JSON); assert deb packages present; assert at least one
  source-built component (e.g. bosh-agent) present; assert pinned
  timestamp/namespace/serial fields.
- End-to-end: rebuild the stemcell tarball and confirm all 6 members present and
  the tarball is deterministic.

## Non-goals

- Matching upstream's SBOM **byte-for-byte** (different tool invocation path).
- License/copyright extraction beyond what syft's catalogers provide by default.
- Changing the `fill-disk` VM (`fill-disk-usrmerge.nix`) — not required.

## Out-of-scope follow-ups

- Update `docs/ARCHITECTURE.md` (currently attributes these files to
  `build/stages/misc-os/apply.sh`, which is stale).
- Optional explicit monit SBOM component injection.
