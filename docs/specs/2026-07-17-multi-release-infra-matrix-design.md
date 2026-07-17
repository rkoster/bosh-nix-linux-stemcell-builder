# Multi-Release / Multi-Infrastructure Build Matrix (Noble + Resolute)

Date: 2026-07-17
Status: Approved design, pending implementation

## Summary

Refactor the Nix stemcell builder from a single hardcoded release (Ubuntu Noble)
into a **data-driven build matrix** over two orthogonal axes:

- **Release axis** — `noble`, `resolute` (Jammy considered and dropped, see below)
- **Infrastructure axis** — `openstack`, `aws`

The build becomes the cartesian product `release × infrastructure`, yielding four
stemcell cells (each with rootfs + disk + packaged `.tgz` layers). Both axes are
expressed as **pure-data descriptor modules**; adding a release or an
infrastructure is a matter of authoring a descriptor, not editing build logic.

Noble's existing flake outputs and byte-for-byte artifacts are preserved as a
regression anchor.

## Motivation and Why Resolute (not Jammy)

The original request was to add Jammy (22.04) targets. Investigation of the
reference `bosh-linux-stemcell-builder` `ubuntu-jammy` and `ubuntu-resolute`
branches led to targeting **Resolute (26.04 LTS)** instead:

1. **Determinism comes from snapshot pinning, not the release.** This builder
   pins `snapshot.ubuntu.com` at a fixed timestamp and builds hermetically under
   Nix. Any *released* Ubuntu pinned to a snapshot rebuilds byte-identically.
   EOL does **not** break a pinned-snapshot build — the snapshot retains the
   point-in-time `.deb`s. So "Jammy EOL soon" is a security-support concern, not
   a reproducibility one.

2. **Hermeticity — no PPA (decisive).** Jammy's reference requires
   `ppa:adiscon/v8-stable` for rsyslog v8. PPAs are **not** served by
   `snapshot.ubuntu.com`, so a fully deterministic Jammy build would require
   vendoring/pinning PPA debs (extra work; they can disappear). The Resolute
   branch explicitly removed the Adiscon/Universe PPA dependency — all packages
   come from the main archive snapshot. This is a genuine hermeticity win.

3. **Architectural proximity to the proven Noble path.** Resolute shares Noble's
   post-t64 package names (`libaio1t64`, `libpam-pwquality`) and usrmerge
   behavior already handled by `fill-disk-usrmerge.nix`. Jammy is pre-t64
   (`libaio1`, `libpam-cracklib`) and diverges more, requiring more conditional
   logic.

4. **Resolves the existing `NOBLE_TODO`.** Resolute ships `libpam-lastlog2` as a
   real package, clearing the pam_lastlog2 workaround in `sudoers-pam`.

5. **Lifecycle.** Jammy standard support ends ~2027; Resolute 26.04 LTS runs to
   ~2036 — better ROI for a new target.

Tradeoffs accepted: Resolute removed `runit` (RFC #1498), requiring rework of
stages that reference `runit`/`chpst`; and Resolute is newer / less
production-tested than Jammy.

## Architecture

### Axis 1 — Release descriptor

New: `build/ubuntu/releases/noble.nix`, `build/ubuntu/releases/resolute.nix`.
Each returns a pure-data attrset:

```nix
{
  release       = "resolute";
  codename      = "resolute";
  osVersion     = "resolute";
  version       = "26.04";
  fullName      = "Ubuntu 26.04 Resolute (amd64)";

  # PER-RELEASE snapshot pin. Noble keeps 20260101T000000Z; Resolute pins its
  # own snapshot >= 26.04 GA date (verified to exist on snapshot.ubuntu.com).
  snapshot      = "<YYYYMMDDTHHMMSSZ>";

  # sha256 of each Packages.xz at this release's snapshot.
  packagesLists = { main = "<sha256>"; universe = "<sha256>"; multiverse = "<sha256>"; };

  # Authoritative per-release BOSH package set (from the reference branch).
  boshPackages  = [ ... ];

  # Behavioral toggles consumed by stages.
  features = {
    runit       = true;            # noble = true, resolute = false
    pamLastlog2 = "hack" | "package" | null;  # noble = "hack", resolute = "package"
  };
}
```

New selector: `build/ubuntu/release.nix` takes `release ? "noble"`, returns the
descriptor, throws a clear error on an unknown release.

### Axis 2 — Infrastructure descriptor

New: `build/infra/openstack.nix`, `build/infra/aws.nix`. Each returns:

```nix
{
  infrastructure  = "aws";                 # openstack -> "openstack"
  hypervisor      = "xen";                 # openstack -> "kvm"
  diskFormat      = "raw";                 # openstack -> "qcow2"
  diskFilename    = "root.img";            # openstack -> "root.qcow2"
  stemcellFormats = [ "aws-raw" ];         # openstack -> [ "openstack-qcow2" "openstack-raw" ]
  extraCloudProps = { root_device_name = "/dev/sda1"; boot_mode = "uefi-preferred"; };
                                            # openstack -> { auto_disk_config = true; }
  infraStages     = [ ./aws-agent-settings ./udev-aws-rules ];
                                            # openstack -> [ ./openstack-agent-settings ]
}
```

New selector: `build/infra/default.nix` takes `infrastructure ? "openstack"`,
throws on unknown.

This is a low-risk refactor because the code is already partly unified:
- `stemcells/bootable-disk.nix` (`mkBootableDisk`) already accepts `diskFormat`.
- `stages/default.nix` already selects `infraStages` by branch.
- `stemcells/package.nix` already branches on hypervisor / diskFormat /
  stemcellFormats / extraCloudProps.

The refactor replaces `if infrastructure == "aws"` conditionals with descriptor
field lookups; no new logic is introduced.

### Threading the parameters

The `callPackage` chain gains a threaded `release` (and, where relevant,
`infrastructure`) argument:

- `build/ubuntu/apt-pins.nix` — build snapshot URLs + index hashes from the
  release descriptor (drop hardcoded `codename`/`name`/hashes).
- `build/ubuntu/deb-sets.nix` — take `release`; use `descriptor.boshPackages`.
  `base` / `bootEssentials` remain shared unless a delta forces an override.
- `build/ubuntu/essential.nix` — already index-derived; receives the release's
  pinned `aptPins`.
- `build/rootfs/rootfs.nix`, `build/rootfs/os-image.nix` — pass `release` down.
- `build/stages/misc-os` — `sources.list` codename templated from the descriptor
  (currently a static `noble` asset).
- `build/stages/agent`, `build/stages/blobstore-clis` — gate runit/chpst usage on
  `features.runit`.
- `build/stages/sudoers-pam` — select pam_lastlog2 behavior on
  `features.pamLastlog2`.
- `build/rootfs/apply-stages.nix` — SPDX `documentNamespace` / `name` templated
  from `osVersion`.
- `build/stemcells/*.nix` — parameterized by `release` + `infrastructure`,
  defaulting so Noble/openstack and Noble/aws outputs are unchanged.

### Flake product

`flake.nix` gains a helper that iterates `releases × infrastructures` and emits:

- `packages`: per-cell rootfs, disk, and packaged stemcell outputs, plus the
  shared source-built components (`bosh-agent`, `monit`, blobstore CLIs).
- `checks`: per-cell rootfs-determinism and disk-determinism checks.

Naming:
- Noble keeps its **exact current output names** (`noble-stemcell`,
  `noble-stemcell-aws`, `noble-stemcell-disk`, `noble-stemcell-aws-disk`,
  `noble-stemcell-rootfs`, `noble-stemcell-aws-rootfs`, `openstack-kvm`, `aws`).
- Resolute adds parallel `resolute-*` outputs.

## Resolute Package / Stage Deltas (from `ubuntu-resolute` branch)

- rsyslog from archive only: `rsyslog rsyslog-gnutls rsyslog-relp` (no Adiscon
  PPA, no `rsyslog-mmjsonparse` / `rsyslog-mmnormalize` / `rsyslog-openssl`).
- Shares Noble t64 names: `libaio1t64`, `libpam-pwquality`.
- `libxml2-16` (versioned) instead of Noble's `libxml2`.
- `libpam-lastlog2` present as a real package (`features.pamLastlog2 = "package"`).
- `runit` removed (RFC #1498) — `features.runit = false`; rework agent /
  blobstore stages away from runit/chpst toward BPM/setpriv equivalents.
- Netplan purged; `systemd-networkd-resolvconf-update` units enabled;
  `iw mg wireless-regdb` and `postfix whoopsie apport` purged.
- Trimmed dev tooling absent vs Noble (e.g. `module-assistant`, `scsitools`,
  `traceroute`, `bison`, `zip`) — captured precisely in `boshPackages`.

## Verification

Agent-executable:
1. `nix build` all four Resolute cells (openstack/aws × rootfs/disk) and their
   packaged `.tgz`.
2. `nix build` Noble cells and confirm **byte-for-byte unchanged** (regression).
3. `treefmt` clean (nixfmt / shfmt / shellcheck).
4. Determinism `--rebuild` byte-identical for both rootfs and disk layers, Noble
   and Resolute (`build/checks/disk-determinism.nix`).
5. Boot-validate the Resolute disk in QEMU/Incus (per the Noble Phase 4 boot
   test).

Operator-run (documented, not agent-executable):
6. Full BOSH director deploy using the Resolute stemcell.

## Open Implementation Tasks / Risks

1. **Resolute snapshot selection** — pick a `snapshot.ubuntu.com` timestamp at or
   after 26.04 GA (~April 2026), verify Resolute's `dists/resolute/*` indices
   exist there, and prefetch the three `Packages.xz` sha256 hashes. (Snapshot is
   per-release data, so Noble is unaffected.)
2. **runit removal rework** — highest-risk item. Identify every stage/service
   depending on runit/chpst and provide a Resolute-appropriate replacement.
3. **Stage-delta reconciliation** — confirm the existing Nix stages already cover
   (or add Resolute-conditional handling for) netplan purge, resolvconf-update
   units, and any AppArmor dhclient handling.
4. **usrmerge / t64 confirmation** — verify `fill-disk-usrmerge.nix`'s Noble
   assumptions hold for Resolute (expected: yes, same generation).

## Non-Goals

- Jammy support (explicitly dropped).
- Architectures other than `x86_64` / amd64.
- Infrastructures beyond openstack and aws (the descriptor pattern leaves the
  door open, but none are in scope here).
