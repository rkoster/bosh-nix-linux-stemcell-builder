# M3 — Source-Built BOSH Agent & Blobstore CLIs (Design)

**Date:** 2026-07-07
**Status:** APPROVED
**Phase:** M3 (real stemcell — agent + IaaS settings)
**Scope:** Build the BOSH agent and all four blobstore CLIs from source as inline
Nix packages in the POC, install them with full scaffolding, and wire the
OpenStack agent settings. FIPS hardening is out of scope (see finding below).

---

## 1. Goal & Motivation

The upstream `bosh_go_agent` and `blobstore_clis` stages install **pre-compiled
binaries** fetched over the network (S3 via a `meta4` metalink for the agent;
direct S3 URLs for the CLIs). This design replaces those network-dependent,
opaque-binary installs with **reproducible, content-addressed builds from
source** using Nix `buildGoModule`, consistent with the article-faithful Nix
approach the POC is validating.

Building from source:

- Removes trust in pre-built artifacts and the `meta4` download tooling.
- Makes the agent/CLI provenance auditable and reproducible.
- Proves the Nix approach generalizes to the BOSH agent — the single most
  important binary in a stemcell.

---

## 2. Scope (Confirmed Decisions)

| Decision | Choice |
|----------|--------|
| Blobstore CLIs | **All four**: dav, s3, gcs, azure-storage (full spec fidelity) |
| Version pinning | **Pin to upstream versions** (reproducible, matches oracle expectations) |
| Agent overlay | **Binary + full scaffolding** (systemd unit, rc, monit, restart_networking, agent.json, hardlink, log symlinks, cron/at hardening) |
| IaaS settings | **Include OpenStack agent settings** (our target IaaS) |
| Package location | **`poc/pkgs/`** (not `poc/lib/pkgs/`) |
| Packaging approach | **Approach C** — first-class flake outputs, consumed by overlays |
| FIPS | **Out of scope** — none applies to non-FIPS noble (see §7) |

### Pinned versions

| Component | Version | Source repo |
|-----------|---------|-------------|
| bosh-agent | 2.861.0 | `cloudfoundry/bosh-agent` |
| bosh-davcli | 0.0.486 | `cloudfoundry/bosh-davcli` |
| bosh-s3cli | 0.0.413 | `cloudfoundry/bosh-s3cli` |
| bosh-gcscli | 0.0.393 | `cloudfoundry/bosh-gcscli` |
| bosh-azure-storage-cli | 0.0.242 | `cloudfoundry/bosh-azure-storage-cli` |

---

## 3. Package Derivations (`poc/pkgs/`)

Five source-built Go packages, each a `buildGoModule` derivation via
`fetchFromGitHub`, exposed as flake outputs so each is independently buildable
(`nix build .#bosh-agent`, `.#bosh-s3cli`, …).

| File | Package | Repo (pinned tag) | Output binary |
|------|---------|-------------------|---------------|
| `pkgs/bosh-agent.nix` | `bosh-agent` | `cloudfoundry/bosh-agent` @ `v2.861.0` | `bin/bosh-agent` |
| `pkgs/blobstore-cli.nix` | *builder fn* | — | parameterized |
| `pkgs/bosh-davcli.nix` | `bosh-davcli` | `cloudfoundry/bosh-davcli` @ `v0.0.486` | `bin/davcli` |
| `pkgs/bosh-s3cli.nix` | `bosh-s3cli` | `cloudfoundry/bosh-s3cli` @ `v0.0.413` | `bin/s3cli` |
| `pkgs/bosh-gcscli.nix` | `bosh-gcscli` | `cloudfoundry/bosh-gcscli` @ `v0.0.393` | `bin/bosh-gcscli` |
| `pkgs/bosh-azure-storage-cli.nix` | `bosh-azure-storage-cli` | `cloudfoundry/bosh-azure-storage-cli` @ `v0.0.242` | `bin/azure-storage-cli` |

**`blobstore-cli.nix`** is a shared builder function
(`{ pname, version, owner, rev, hash, vendorHash, subPackages ? null }`) so the
four CLIs are ~5 lines each, reusing one `buildGoModule` wrapper — the DRY
payoff of Approach C.

**Build details (per package):**

- **`vendorHash`** — computed during implementation (build → hash-mismatch →
  fill in). If a repo vendors its dependencies (`vendor/` dir present), use
  `vendorHash = null`.
- **`bosh-agent` version embedding** — upstream's `bin/build` injects the
  version via `-ldflags "-X main.version=…"`. Replicate the ldflags so the
  binary reports `2.861.0` for spec fidelity (and set git sha where the code
  expects it).
- **`CGO_ENABLED = 0`** — static binaries, matching upstream release artifacts
  and avoiding glibc coupling inside the stemcell chroot.
- **`doCheck = false`** initially — upstream tests need network/fixtures; can be
  revisited later.

---

## 4. Install Overlays (`poc/lib/overlays/`)

Three new overlays consuming the `poc/pkgs/` derivations, following the existing
`{ name, script }` contract (`cp` store outputs into `$root`).

### `overlays/blobstore-clis.nix` (reproduces `blobstore_clis`)

- Takes the four CLI derivations as args.
- Installs each to `/var/vcap/bosh/bin/bosh-blobstore-<type>` (mode 0755):
  - `davcli` → `bosh-blobstore-dav`
  - `s3cli` → `bosh-blobstore-s3`
  - `bosh-gcscli` → `bosh-blobstore-gcs`
  - `azure-storage-cli` → `bosh-blobstore-azure-storage`

### `overlays/agent.nix` (reproduces `bosh_go_agent` full scaffolding)

- `cp ${bosh-agent}/bin/bosh-agent` → `/var/vcap/bosh/bin/bosh-agent` (0755)
- Hardlink → `/var/vcap/bosh/etc/bosh-enable-monit-access`
- Inlined byte-faithful assets from the stage `assets/`:
  `bosh-agent.service` → `/lib/systemd/system/`, `bosh-agent-rc`,
  `alerts.monitrc` → `/var/vcap/monit/`
- Generated: `restart_networking` script, `agent.json` = `{}`,
  `micro_bosh/data/cache` dir, `/var/vcap/bosh/log/current` →
  `/var/log/bosh-agent.log` symlink
- Enable `bosh-agent.service` via declarative `multi-user.target.wants` symlink
  (matches the pattern in `systemd-services.nix`)
- Cron/at hardening: `cron.allow`/`at.allow` = `vcap`, remove `*.deny`,
  `/var/lock` perms/ownership, `alerts.monitrc` 0600 root:root

### `overlays/openstack-agent-settings.nix` (reproduces `bosh_openstack_agent_settings`)

- Copies the openstack `agent.json` (inlined from that stage's
  `assets/agent.json`) → `/var/vcap/bosh/agent.json`, overwriting the `{}`
  placeholder.

### Dropped: metalink / `meta4`

Because we build from source, the `meta4` download tool and the entire metalink
fetch path are **dropped entirely** — a clean simplification.

### Overlay order

Appended after `systemd-services`:

```
… → agent → blobstore-clis → openstack-agent-settings
```

`openstack-agent-settings` goes last so its `agent.json` overwrites the agent
overlay's `{}` placeholder.

---

## 5. Flake Wiring (`poc/flake.nix`)

Currently `packages` auto-maps only `examples/*.nix`. Merge in the `pkgs/*.nix`
derivations so both are exposed:

```nix
packages =
  (lib.mapAttrs' examplesFn (builtins.readDir ./examples))
  // (lib.mapAttrs' pkgsFn (builtins.readDir ./pkgs));
```

Result: `nix build .#bosh-agent`, `.#bosh-s3cli`, etc. build independently (fast
`vendorHash` iteration), while `.#os-image` consumes them via the overlays.
`os-image.nix` gains three `callPackage` lines for the new overlays, passing the
package derivations in.

**Note on naming:** `poc/pkgs/` as a *directory* (referenced as the path
`./pkgs`) does not collide with the `pkgs` nixpkgs *variable* in
`perSystem = { pkgs, ... }` — Nix distinguishes paths from identifiers. The only
rule: do not `let pkgs = …` shadow it.

---

## 6. Validation Strategy

- **Per-package (primary proof):** `nix build .#bosh-agent && ./result/bin/bosh-agent --version` → expect `2.861.0`; equivalent smoke check for each CLI.
- **Overlay-level:** extract the os-image tarball; assert `/var/vcap/bosh/bin/bosh-agent` + four `bosh-blobstore-*` present, executable, and the systemd unit / scaffolding files exist.
- **Oracle caveat:** the OS_IMAGE Serverspec suite the POC has been running does **not** test the agent/blobstore — those are exercised by the *stemcell* phase specs, not `os_image`. This work is therefore verified by package smoke-tests + tarball assertions, not the existing oracle.
- **Disk reality:** the full `.#os-image` VM build is currently disk-constrained. The `buildGoModule` packages are small and independent, so they remain verifiable even when the full image build is not.

---

## 7. FIPS Finding (No Code)

FIPS hardening is **entirely conditional** on the `fips` OS variant:

- `stemcell_builder/lib/prelude_fips.bash` does `exit 0` when
  `stemcell_operating_system_variant != "fips"`.
- `bosh-stemcell/lib/bosh/stemcell/stage_collection.rb` only adds
  `system_fips_kernel` and `base_fips_apt` when `operating_system.variant == "fips"`.

Therefore the non-FIPS `ubuntu-noble` stemcell (our target) receives **zero**
FIPS hardening. Per the scope constraint ("only apply FIPS hardening applied to
all stemcells"), there is **nothing to implement**. Recorded here as an explicit
finding.

---

## 8. Deliverables

- 6 files in `poc/pkgs/` (5 packages + 1 shared builder function)
- 3 overlays in `poc/lib/overlays/` (agent, blobstore-clis, openstack-agent-settings)
- `poc/flake.nix` edit (expose `pkgs/` as flake outputs)
- `poc/examples/os-image.nix` edit (append 3 overlays)
- This design doc

---

## 9. Risks & Open Items

| Risk | Mitigation |
|------|------------|
| `vendorHash` unknown until first build | Standard Nix loop: build, read expected hash from mismatch error, fill in. Independent flake outputs make this fast. |
| Repo vendors deps (`vendor/` dir) | Use `vendorHash = null` for those repos. |
| Agent version string not embedded correctly | Replicate upstream `bin/build` ldflags; verify with `--version`. |
| Go module path / `subPackages` differences per repo | Inspect each repo's `go.mod` + `main` package during implementation; `subPackages` parameter on the shared builder handles it. |
| Full image build blocked by disk | Package-level smoke tests + tarball assertions provide verification independent of the full VM build. |
