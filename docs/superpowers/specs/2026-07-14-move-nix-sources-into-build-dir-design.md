# Design: Move Nix build sources into `build/`

## Problem

The repository's top level is cluttered with six directories that hold nothing
but Nix build source (`lib/`, `pkgs/`, `rootfs/`, `stemcells/`, `ubuntu/`,
`examples/`), mixed in alongside docs, scripts, deployment manifests, and the
flake entry point. This makes the top level noisy and leaves no obvious home
for specs/tests to live at the top level in the future.

## Goal

Consolidate the pure-Nix source directories one level down into a single
`build/` directory, decluttering the top level, without changing any buildable
flake output names or behavior.

## Scope

**Moves into `build/`:**

- `lib/` (mkVmImage.nix, mkOverlay.nix)
- `pkgs/` (bosh-agent.nix, blobstore-clis.nix, monit.nix, monit-5.2.5.tar.gz)
- `rootfs/` (os-image.nix, rootfs.nix, tarball.nix, apply-overlays.nix,
  fill-disk-usrmerge.nix, overlays/)
- `stemcells/` (bootable-disk.nix, bootable-disk.sh, openstack-kvm.nix,
  openstack-kvm-disk.nix, package.nix)
- `ubuntu/` (deb-sets.nix, apt-pins.nix, essential.nix)
- `examples/` (noble-bootable.nix, noble-closure.nix, hello-vm.nix)

Each directory is moved with `git mv` to preserve history.

**Stays at top level (out of scope):**

- `flake.nix` / `flake.lock` — must remain at the repo root; `nix build .#foo`
  resolves flake outputs relative to the flake root.
- `scripts/`, `manifests/`, `*.yml` manifests, `docs/`, `README.md`,
  `bosh.env`, `.gitignore`, `result-stemcell`.

Cross-references between the moved directories (e.g.
`rootfs/overlays/*.nix` → `../../lib/mkOverlay.nix`,
`stemcells/*.nix` → `../rootfs/os-image.nix`, `../lib/mkVmImage.nix`,
`examples/*.nix` → `../ubuntu/apt-pins.nix`) are unaffected: the directories
move together as siblings under `build/`, so their relative paths to each
other don't change.

## Changes

### 1. `flake.nix`

Update the `callPackage`/import paths under `packages = { ... }` to prefix
with `build/`:

| Current | New |
|---|---|
| `./pkgs/blobstore-clis.nix` | `./build/pkgs/blobstore-clis.nix` |
| `./stemcells/openstack-kvm.nix` | `./build/stemcells/openstack-kvm.nix` |
| `./rootfs/os-image.nix` | `./build/rootfs/os-image.nix` |
| `./rootfs/rootfs.nix` | `./build/rootfs/rootfs.nix` |
| `./stemcells/openstack-kvm-disk.nix` | `./build/stemcells/openstack-kvm-disk.nix` |
| `./examples/noble-bootable.nix` | `./build/examples/noble-bootable.nix` |
| `./examples/noble-closure.nix` | `./build/examples/noble-closure.nix` |
| `./examples/hello-vm.nix` | `./build/examples/hello-vm.nix` |
| `./pkgs/bosh-agent.nix` | `./build/pkgs/bosh-agent.nix` |
| `./pkgs/monit.nix` | `./build/pkgs/monit.nix` |

Also update the treefmt `shfmt.excludes` entry:

- `"rootfs/overlays/*.sh"` → `"build/rootfs/overlays/*.sh"`

Flake output attribute names (`os-image`, `noble-stemcell`,
`noble-stemcell-disk`, `noble-bootable`, `noble-closure`, `hello-vm`,
`bosh-agent`, `monit`, `bosh-davcli`, `bosh-s3cli`, `bosh-gcscli`,
`bosh-azure-storage-cli`) are unchanged.

### 2. `README.md`

Update the "Repository layout" table's path column to prefix the moved
directories with `build/` (e.g. `lib/` → `build/lib/`, `pkgs/` →
`build/pkgs/`). Table descriptions are left as-is — some already reference
filenames that don't match the current tree (pre-existing staleness), and
fixing that content is out of scope for this move.

### 3. `docs/ARCHITECTURE.md`

Update all path references (~61 occurrences) to add the `build/` prefix, e.g.
`rootfs/overlays/ssh.nix` → `build/rootfs/overlays/ssh.nix`, so the doc's
source cross-links keep resolving to real paths.

### 4. `docs/specs/*`, `docs/plans/*`

Left untouched. These are dated historical findings/plan documents describing
the repository as it existed at specific points in time; they are not living
references and should not be rewritten after the fact.

## Verification

1. `nix flake check` — validates the flake evaluates and treefmt config is
   consistent.
2. `nix build .#os-image --dry-run` — confirms the rootfs/ubuntu import chain
   resolves.
3. `nix build .#noble-stemcell --dry-run` — confirms the stemcells/rootfs/lib
   import chain resolves.

No functional/behavioral change is expected; this is a pure path
reorganization.
