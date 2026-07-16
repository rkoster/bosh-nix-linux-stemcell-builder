# AWS Stemcell Target — Design

Date: 2026-07-16
Status: Approved (pending written-spec review)
Scope: Add a second stemcell build target for AWS (`aws-raw`, heavy) alongside the existing OpenStack/KVM target, by porting the AWS-specific stages and disk/packaging from the upstream `bosh-linux-stemcell-builder`.

## Goal

Produce a self-contained BOSH `aws-raw` stemcell tarball from this project's pure-Nix pipeline, reusing all generic OS build stages and diverging only where AWS genuinely requires it. The OpenStack target must continue to build byte-identically.

## Non-goals

- Light / AMI-referencing stemcell (needs S3 upload + AWS `RegisterImage`; not an offline pure build).
- FIPS variant (separate OS-variant axis; needs Ubuntu Pro entitlement + authenticated apt repos; conflicts with the current pinned public-snapshot closure). Design is FIPS-*ready* but FIPS is not built here.
- arm64 (x86_64 only).
- Any AWS API interaction.

## Background: what is AWS-specific upstream

From `bosh-linux-stemcell-builder`:

- **Infrastructure definition** (`bosh-stemcell/lib/bosh/stemcell/infrastructure.rb:113`): AWS is
  `name=aws`, `hypervisor=xen`, `default_disk_size=5120`, `disk_formats=["raw"]`,
  `stemcell_formats=["aws-raw"]`, and `additional_cloud_properties = { root_device_name: "/dev/sda1", boot_mode: "uefi-preferred" }`.
- **Stage ordering** (`bosh-stemcell/lib/bosh/stemcell/stage_collection.rb:147` `aws_stages`) vs `openstack_stages` (`:94`). Deltas only:
  - `system_aws_modules` (a verified no-op today) replaces `system_openstack_clock` + `system_openstack_modules`.
  - `bosh_aws_agent_settings` replaces `bosh_openstack_agent_settings`.
  - `udev_aws_rules` — new, no OpenStack equivalent.
  - Generic stages (`system_network`, `system_parameters`, `bosh_clean`, `bosh_harden`, `bosh_clean_ssh`, `image_create_efi`, `image_install_grub`, `sbom_create`) are shared.
- **AWS agent settings** (`stemcell_builder/stages/bosh_aws_agent_settings/assets/agent.json`): NVMe/EBS platform config + single HTTP IMDS source (IMDSv2 via `TokenPath`).
- **udev AWS rules** (`stemcell_builder/stages/udev_aws_rules/`): `70-ec2-nvme-devices.rules` + `/sbin/nvme-id` helper (calls `nvme id-ctrl -V`; needs `nvme-cli`).
- **FIPS** (`stage_collection.rb:18`) is an OS-variant axis orthogonal to infrastructure; the AWS stages are byte-identical under FIPS. The only infra×FIPS intersection is the optional `linux-<infra>-fips` kernel (`UBUNTU_FIPS_USE_IAAS_KERNEL`).

## Approach: parameterize the pipeline by `infrastructure` (Approach A)

Thread a single `infrastructure` argument (default `"openstack"`) through the derivation chain. Generic stays shared; only selection points branch. Backward-compatible: OpenStack outputs keep their names and hashes via defaults.

### 1. Infrastructure parameterization

- `build/stages/default.nix`: add `infrastructure ? "openstack"`. Generic stage list unchanged. Trailing infra slot:
  - `openstack` → `openstack-agent-settings`
  - `aws` → `aws-agent-settings` **and** `udev-aws-rules`
  - `system_aws_modules` deliberately omitted (verified upstream no-op); add a one-line comment noting this.
- `build/rootfs/os-image.nix`, `apply-stages.nix`: accept and forward `infrastructure` to the stage selection.

The base deb closure is infrastructure-agnostic (no IaaS-specific apt packages — upstream AWS adds none, and `nvme-cli` is already in the shared base via upstream's generic `base_ubuntu_packages`). So `build/rootfs/rootfs.nix` and `build/ubuntu/deb-sets.nix` are **not** parameterized: the base rootfs is built once and shared/cached across both targets; only the stage-apply layer diverges.

### 2. New AWS stages (under `build/stages/`)

Mirror the existing `openstack-agent-settings` structure (`default.nix` + `apply.sh` + `assets/`).

**`aws-agent-settings/`** — ports `bosh_aws_agent_settings`:
- `assets/agent.json`:
  - `Platform.Linux`: `PartitionerType=parted`, `DevicePathResolutionType=virtio`,
    `CreatePartitionIfNoEphemeralDisk=true`, `ServiceManager=systemd`,
    `DiskIDTransformPattern="^vol-(.+)$"`,
    `DiskIDTransformReplacement="nvme-Amazon_Elastic_Block_Store_vol${1}"`,
    `InstanceStorageDevicePattern="/dev/nvme*n1"`,
    `InstanceStorageManagedVolumePattern="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_*"`.
  - `Infrastructure.Settings.Sources`: single `Type=HTTP` source at `http://169.254.169.254` with
    `UserDataPath=/latest/user-data`, `InstanceIDPath=/latest/meta-data/instance-id`,
    `SSHKeysPath=/latest/meta-data/public-keys/0/openssh-key`, `TokenPath=/latest/api/token` (IMDSv2);
    `UseRegistry=true`.
- `apply.sh` writes it to `/var/vcap/bosh/agent.json` (same target the OpenStack stage uses).

**`udev-aws-rules/`** — ports `udev_aws_rules`:
- `assets/70-ec2-nvme-devices.rules` → `/etc/udev/rules.d/70-ec2-nvme-devices.rules`.
- `assets/nvme-id` → `/sbin/nvme-id`, mode `0755` (resolves EBS volume name via `nvme id-ctrl -V`).
- The `nvme` binary it invokes comes from `nvme-cli`, already in the shared base set (see §1).

### 3. Disk image + packaging

**Disk (`build/stemcells/bootable-disk.{nix,sh}`):** add a `diskFormat` parameter (`"qcow2"` default | `"raw"`).
- Only change in `bootable-disk.sh` is the final conversion + output filename:
  `qemu-img convert -f raw -O "$diskFormat" /dev/vda "$out/root.$ext"` (`ext` = `qcow2` or `img`).
- Shared and unchanged: MBR partitioning, dual BIOS + UEFI grub, deterministic partition UUIDs, initramfs. This already satisfies AWS `boot_mode=uefi-preferred`.
- New `build/stemcells/aws-disk.nix`: `mkBootableDisk { osImage = <aws os-image>; diskFormat = "raw"; name = "noble-stemcell-aws"; }`.

**Packaging (`build/stemcells/package.nix`):** branch three fields on `infrastructure`; OpenStack remains the default branch (unchanged output):
- `stemcell_formats`: `aws` → `["aws-raw"]`; `openstack` → `["openstack-qcow2","openstack-raw"]`.
- `disk_format`: `aws` → `raw`; `openstack` → `qcow2`.
- `cloud_properties`: `aws` adds `root_device_name: /dev/sda1` and `boot_mode: uefi-preferred`, and omits `auto_disk_config`; `openstack` keeps `auto_disk_config: true`.
- The inner `image` member wraps the raw `root.img` for AWS (the disk is already tarred as `root.img`; feed it the raw disk).

**New `build/stemcells/aws.nix` wrapper:** `infrastructure="aws"`, `hypervisor="xen"`, `diskFormat="raw"`, pulling the AWS os-image + aws-disk. `hypervisor` reuses the existing `package.nix` parameter (already `hypervisor ? "kvm"`); it is identity-only (filename + manifest `name`), matching upstream's `aws-xen` convention.
- Output: `bosh-stemcell-0.0.5-nix-aws-xen-ubuntu-noble.tgz`.

### 4. Flake outputs (`flake.nix`)

Add alongside existing OpenStack outputs (existing names unchanged via defaults):
- `os-image-aws` — AWS-parameterized os-image.
- `noble-stemcell-aws-disk` — raw bootable disk.
- `aws` / `noble-stemcell-aws` — the packaged `aws-raw` stemcell.

## Future axis: `variant` (FIPS)

Keep `infrastructure` selection independent of the kernel/apt layer so a future `variant` axis (e.g. `fips`) composes: FIPS would branch only kernel/apt (`system_fips_kernel` + `base_fips_apt`) and optionally select `linux-aws-fips`. The AWS stages defined here need no change under FIPS.

## Verification plan

1. `nix build .#aws` succeeds; `.tgz` contains exactly the 6 members; `stemcell.MF` shows
   `name: bosh-aws-xen-ubuntu-noble`, `stemcell_formats: [aws-raw]`, `disk_format: raw`, AWS `cloud_properties`.
2. `image` member unpacks to a raw `root.img` (`qemu-img info` reports `raw`).
3. Rootfs contains AWS `agent.json`, `70-ec2-nvme-devices.rules`, `/sbin/nvme-id` (0755), and the `nvme` binary.
4. Regression: `nix build .#openstack-kvm` tarball hash byte-identical to the pre-change build.
5. Determinism: double-build `.#aws --rebuild`; all members byte-identical (epoch-zero timestamps).

## Files touched

New:
- `build/stages/aws-agent-settings/{default.nix,apply.sh,assets/agent.json}`
- `build/stages/udev-aws-rules/{default.nix,apply.sh,assets/70-ec2-nvme-devices.rules,assets/nvme-id}`
- `build/stemcells/aws.nix`, `build/stemcells/aws-disk.nix`

Modified (backward-compatible):
- `build/stages/default.nix` (infrastructure selection)
- `build/rootfs/os-image.nix`, `build/rootfs/apply-stages.nix` (thread `infrastructure` to stage selection)
- `build/stemcells/bootable-disk.nix`, `build/stemcells/bootable-disk.sh` (`diskFormat` param)
- `build/stemcells/package.nix` (branch `stemcell_formats` / `disk_format` / `cloud_properties`)
- `flake.nix` (AWS outputs)
