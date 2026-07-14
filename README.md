# bosh-nix-linux-stemcell-builder

A Nix-based builder for [BOSH](https://bosh.io) Linux stemcells, and the
feasibility study that produced it.

This repository converts the classic
[`cloudfoundry/bosh-linux-stemcell-builder`](https://github.com/cloudfoundry/bosh-linux-stemcell-builder)
— a privileged Docker container driven by Ruby/Rake that assembles an Ubuntu
rootfs with imperative `debootstrap`/`apt` shell stages — into a **reproducible,
content-addressed Nix build**, following Linus Heckemann's approach in
[*Building Ubuntu images in Nix*](https://linus.schreibt.jetzt/posts/ubuntu-images.html).

## Status: feasible, validated end-to-end

The POC builds a full `bosh-openstack-kvm-ubuntu-noble` stemcell entirely in Nix
and it has been validated against a real BOSH director:

- **Builds a bootable stemcell** (`nix build .#noble-stemcell`) — Ubuntu Noble
  24.04 rootfs assembled from pinned `.deb` fixed-output derivations via
  `vmTools.makeImageFromDebDist`, plus kernel, initramfs, GRUB (UEFI/OVMF), the
  BOSH agent, `monit`, and OpenStack/KVM agent settings, packaged as a qcow2
  stemcell tarball.
- **Boots on a BOSH director** — uploaded to an Incus/LXD director (`lxd_cpi`);
  the agent boots, configures networking, and reaches the director.
- **Passes a real deployment** — the upstream
  [`zookeeper`](https://github.com/cppforlife/zookeeper-release) release deploys
  on the Nix stemcell: 3 nodes compile python-2.7 / openjdk-8 / golang /
  zookeeper from source and run, and the **`smoke-tests` errand succeeds**
  (full `zk-latencies` suite green).
- **Matches the upstream oracle** — all **366** `os_image` Serverspec examples
  from `bosh-stemcell/spec/os_image/ubuntu_spec.rb` pass against the Nix-built
  rootfs (see `docs/specs/2026-07-08-m6-oracle-all-green-findings.md`).

## Quickstart

Requires Nix with flakes and a Linux builder (`runInLinuxVM` needs KVM).

```bash
# Build the full OpenStack/KVM Ubuntu Noble stemcell tarball
nix build .#noble-stemcell -L

# Build just the OS image rootfs
nix build .#os-image -L

# Deploy + validate against a BOSH director (source your own bosh.env first)
source ./bosh.env
./scripts/deploy-stemcell.sh --build --cleanup
```

Other flake outputs: `noble-rootfs`, `noble-bootable`, `noble-stemcell-disk`,
`noble-closure`, `hello-vm`, and the vendored blobstore CLIs / agent / `monit`
under `.#` (one package per file in `examples/` and `pkgs/`).

## Repository layout

| Path | Role |
|------|------|
| `flake.nix` | Flake entry point. Pins `nixpkgs` (`nixos-26.05`); one package per file in `build/examples/` and `build/pkgs/`. |
| `build/examples/` | Buildable image derivations: `os-image.nix`, `noble-stemcell.nix`, `noble-bootable.nix`, `noble-stemcell-disk.nix`, etc. |
| `build/lib/` | Build library: distro/source pinning (`noble-source.nix`, `noble-distro.nix`), package sets (`base-`, `boot-`, `essential-`, `image-`, `noble-packages.nix`), and the assembly helpers (`mk-rootfs-tarball.nix`, `mk-bootable-disk.nix`, `mk-stemcell.nix`, `mk-apply-overlays.nix`). |
| `build/lib/overlays/` | Post-unpack filesystem overlays that reproduce the upstream shell stages (ssh, sudoers/pam, audit, rsyslog, sysctl, systemd services, users, agent, OpenStack agent settings, blobstore CLIs). |
| `build/pkgs/` | Source-built components: the BOSH `agent`, blobstore CLIs (`s3cli`, `gcscli`, `davcli`, `azure-storage-cli`), and `monit` 5.2.5 (built from the vendored tarball). |
| `scripts/` | `deploy-stemcell.sh` (end-to-end director validation), `apt-resolve-noble.sh`, QEMU/OVMF boot smoke tests. |
| `manifests/`, `*.yml` | Validation manifests: `zookeeper.yml` (e2e deployment), `nix-stemcell-poc.yml` (jobless boot), `upstream-jobless-poc.yml` (upstream baseline). |
| `docs/specs/`, `docs/plans/` | Dated feasibility findings and milestone plans (the research trail M0–M6). |

## Selected engineering findings

The interesting parts of proving the article's claims against BOSH's requirements:

- **Dependency resolution.** The article's primitive Perl resolver is not faithful
  enough for the stemcell package set. This POC pins the Ubuntu APT `Packages`
  indices and resolves against them deterministically in Nix, plus a
  **debootstrap-style essential seed** (`lib/essential-packages.nix`) that parses
  the pinned `main` `Packages.xz` and selects every `Priority: required` /
  `Essential: yes` package — otherwise base tools like `hostname` are silently
  missing from the rootfs.

- **usrmerge.** Upstream nixpkgs `makeImageFromDebDist` extracts `.deb`s with raw
  `dpkg-deb`, which corrupts usr-merged Noble. Fixed locally in
  `lib/fill-disk-usrmerge.nix`.

- **`monit` + musl `getopt`.** The BOSH agent invokes `monit stop -g vcap`
  (action before options). `monit` built static against **musl** uses a
  `getopt()` that does not permute `argv`, so `-g vcap` was dropped and the stop
  failed with exit 1. Fixed with a `getopt_long` patch in `pkgs/monit.nix`
  (`docs/specs/2026-07-08-m5-monit-getopt-ssh-findings.md`).

- **Reproducing hardening/oracle behaviour.** Closing the last oracle failures
  required faithfully reproducing subtle upstream stage behaviour: dual-format
  audit rules (two spec checkers with incompatible field orders), `rsyslog` log
  ownership/modes, a normalized `/etc/shadow` with a 5-digit date field (the Nix
  sandbox clock is frozen at an early epoch), and avoiding a `find -perm /000`
  footgun that corrupts `shadow`/`gshadow` modes. See the M6 findings doc.

- **Build toolchain parity.** Compiling releases on the stemcell (e.g. zookeeper)
  needs the upstream compile stages reproduced: `zlib1g-dev` + `build-essential`
  in `lib/noble-packages.nix`, or source builds fail with missing `zlib.h`.

Full details and the decision history are in `docs/specs/` and `docs/plans/`.

## Known limitations / next steps

- **Scope:** `ubuntu-noble`, OpenStack/KVM, qcow2, `x86_64` only. Other IaaS
  targets, disk formats, FIPS, and `arm64` are out of scope for the POC.
- **Reproducibility:** mutable-filesystem image builds are not yet verified
  bit-for-bit reproducible; a rebuild-and-diff check is pending.
- **Security-update currency:** packages are pinned to point-in-time APT indices;
  a refresh/pinning workflow is still needed.
- **Tests:** the original rspec spec-parity oracle harness has been removed from
  this standalone repo; parity tests are to be rewritten in Go.

## References

- Article: [*Building Ubuntu images in Nix*](https://linus.schreibt.jetzt/posts/ubuntu-images.html) — Linus Heckemann
- Upstream builder: [`cloudfoundry/bosh-linux-stemcell-builder`](https://github.com/cloudfoundry/bosh-linux-stemcell-builder)
- [BOSH stemcell documentation](https://bosh.io/docs/stemcell/)
