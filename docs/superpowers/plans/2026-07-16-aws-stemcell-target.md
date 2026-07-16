# AWS Stemcell Target Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second BOSH stemcell build target for AWS (`aws-raw`, heavy) alongside the existing OpenStack/KVM target, by porting the AWS-specific stages and disk/packaging from upstream `bosh-linux-stemcell-builder`, while keeping the OpenStack output byte-identical.

**Architecture:** Approach A — thread a single `infrastructure` argument (default `"openstack"`) through `os-image.nix` → `stages/default.nix` to select IaaS-specific stages. The base deb closure stays shared/cached (no infra-specific packages). Disk format and stemcell manifest fields branch on infrastructure. New thin Nix wrappers + flake outputs expose the AWS target.

**Tech Stack:** Nix flakes (nixpkgs `nixos-26.05`), `vmTools.runInLinuxVM`, bash stage scripts, `qemu-img`, `syft`, `jq`.

**Reference spec:** `docs/superpowers/specs/2026-07-16-aws-stemcell-target-design.md`

**Conventions in this repo (important for the worker):**
- There is **no unit-test framework**. "Tests" here are Nix evaluation checks (`nix eval`, `nix build --dry-run`) and, at the end, a real build + tarball inspection + byte-hash comparison.
- Full builds are **expensive** (Linux VM + ~3 GB rootfs + syft) and need free disk. Prefer cheap `nix eval` / `--dry-run` gates per task; do the single full build only in the final task.
- The repo enforces `nix fmt` (nixfmt + shfmt + shellcheck). Run it before every commit.
- Reproducible-build timestamps are epoch-zero (`SOURCE_DATE_EPOCH=0`).

---

## File Structure

New files:
- `build/stages/aws-agent-settings/default.nix` — stage descriptor (name + script)
- `build/stages/aws-agent-settings/apply.sh` — copies agent.json into rootfs
- `build/stages/aws-agent-settings/assets/agent.json` — AWS agent settings
- `build/stages/udev-aws-rules/default.nix` — stage descriptor
- `build/stages/udev-aws-rules/apply.sh` — installs NVMe udev rule + nvme-id helper
- `build/stages/udev-aws-rules/assets/70-ec2-nvme-devices.rules` — EBS NVMe udev rules
- `build/stages/udev-aws-rules/assets/nvme-id` — EBS volume-name resolver
- `build/stemcells/aws-disk.nix` — raw bootable disk wrapper (aws os-image)
- `build/stemcells/aws.nix` — packages the aws-raw stemcell tarball

Modified files (backward-compatible):
- `build/stemcells/bootable-disk.nix` — add `diskFormat` param
- `build/stemcells/bootable-disk.sh` — parameterize final convert/output (`@diskFormat@`, `@diskOutput@`)
- `build/stages/default.nix` — add `infrastructure ? "openstack"`, select infra stages
- `build/rootfs/os-image.nix` — add `infrastructure ? "openstack"`, forward to stages
- `build/stemcells/package.nix` — branch `stemcell_formats` / `disk_format` / trailing cloud_properties on `infrastructure`
- `flake.nix` — add AWS outputs

---

## Task 1: Parameterize the bootable disk output format

**Files:**
- Modify: `build/stemcells/bootable-disk.nix`
- Modify: `build/stemcells/bootable-disk.sh:136-141`

The disk builder currently always emits `root.qcow2`. Add a `diskFormat` param (`"qcow2"` default | `"raw"`) so AWS can emit a raw `root.img`. OpenStack keeps the default, and the substituted script must render **identically** to today for OpenStack.

- [ ] **Step 1: Add `diskFormat` param and derived output name in `bootable-disk.nix`**

Replace the argument block and `replaceVars` call. Current (lines 24-45):

```nix
{
  osImage,
  name ? "noble-stemcell",
  size ? 2560,
}:

mkVmImage {
  inherit name size;

  buildCommand = builtins.readFile (
    replaceVars ./bootable-disk.sh {
      inherit
        util-linux
        dosfstools
        e2fsprogs
        qemu
        gnutar
        systemdMinimal
        ;
      osImage = "${osImage}";
    }
  );
```

New:

```nix
{
  osImage,
  name ? "noble-stemcell",
  size ? 2560,
  diskFormat ? "qcow2",
}:
let
  diskExt = if diskFormat == "qcow2" then "qcow2" else "img";
in
mkVmImage {
  inherit name size;

  buildCommand = builtins.readFile (
    replaceVars ./bootable-disk.sh {
      inherit
        util-linux
        dosfstools
        e2fsprogs
        qemu
        gnutar
        systemdMinimal
        ;
      osImage = "${osImage}";
      diskFormat = diskFormat;
      diskOutput = "root.${diskExt}";
    }
  );
```

- [ ] **Step 2: Parameterize the conversion in `bootable-disk.sh`**

Replace lines 136-141:

```bash
# Convert raw disk image to qcow2
mkdir -p "$out"
@qemu@/bin/qemu-img convert -f raw -O qcow2 /dev/vda "$out/root.qcow2"

# Verify qcow2
@qemu@/bin/qemu-img info "$out/root.qcow2"
```

with:

```bash
# Convert raw disk image to the requested output format
mkdir -p "$out"
@qemu@/bin/qemu-img convert -f raw -O @diskFormat@ /dev/vda "$out/@diskOutput@"

# Verify output image
@qemu@/bin/qemu-img info "$out/@diskOutput@"
```

- [ ] **Step 3: Format**

Run: `nix fmt`
Expected: `0 changed` (or only these two files reformatted with no semantic change).

- [ ] **Step 4: Evaluate the existing OpenStack disk still wires up**

Run: `nix eval .#noble-stemcell-disk.drvPath`
Expected: prints a `/nix/store/...-noble-stemcell.drv` path with no evaluation error.

- [ ] **Step 5: Commit**

```bash
git add build/stemcells/bootable-disk.nix build/stemcells/bootable-disk.sh
git commit -m "feat: parameterize bootable disk output format (qcow2|raw)"
```

---

## Task 2: Create the `aws-agent-settings` stage

**Files:**
- Create: `build/stages/aws-agent-settings/default.nix`
- Create: `build/stages/aws-agent-settings/apply.sh`
- Create: `build/stages/aws-agent-settings/assets/agent.json`

Mirror the existing `openstack-agent-settings` stage structure exactly; only the `agent.json` content differs.

- [ ] **Step 1: Write `build/stages/aws-agent-settings/assets/agent.json`**

```json
{
  "Platform": {
    "Linux": {
      "PartitionerType": "parted",
      "DevicePathResolutionType": "virtio",
      "CreatePartitionIfNoEphemeralDisk": true,
      "ServiceManager": "systemd",
      "DiskIDTransformPattern": "^vol-(.+)$",
      "DiskIDTransformReplacement": "nvme-Amazon_Elastic_Block_Store_vol${1}",
      "InstanceStorageDevicePattern": "/dev/nvme*n1",
      "InstanceStorageManagedVolumePattern": "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_*"
    }
  },
  "Infrastructure": {
    "Settings": {
      "Sources": [
        {
          "Type": "HTTP",
          "URI": "http://169.254.169.254",
          "UserDataPath": "/latest/user-data",
          "InstanceIDPath": "/latest/meta-data/instance-id",
          "SSHKeysPath": "/latest/meta-data/public-keys/0/openssh-key",
          "TokenPath": "/latest/api/token"
        }
      ],
      "UseRegistry": true
    }
  }
}
```

- [ ] **Step 2: Write `build/stages/aws-agent-settings/apply.sh`**

```bash
#!/bin/bash
set -eu

# $root is exported by build/rootfs/apply-stages.nix (the rootfs tree target).
# shellcheck disable=SC2154

# Configure AWS agent settings. The agent config lives at
# /var/vcap/bosh/agent.json inside the rootfs tree ("$root").
mkdir -p "$root/var/vcap/bosh"
cp "$STAGE_DIR"/agent.json "$root/var/vcap/bosh/agent.json"
```

- [ ] **Step 3: Write `build/stages/aws-agent-settings/default.nix`**

```nix
# aws-agent-settings stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "aws-agent-settings";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
```

- [ ] **Step 4: Format and validate**

Run: `nix fmt && nix-instantiate --eval --expr 'import ./build/stages/aws-agent-settings { }'`
Expected: `nix fmt` clean; the eval prints an attrset with `name = "aws-agent-settings"` and a `script`.

- [ ] **Step 5: Commit**

```bash
git add build/stages/aws-agent-settings
git commit -m "feat: add aws-agent-settings stage"
```

---

## Task 3: Create the `udev-aws-rules` stage

**Files:**
- Create: `build/stages/udev-aws-rules/default.nix`
- Create: `build/stages/udev-aws-rules/apply.sh`
- Create: `build/stages/udev-aws-rules/assets/70-ec2-nvme-devices.rules`
- Create: `build/stages/udev-aws-rules/assets/nvme-id`

Ports upstream `udev_aws_rules`. Installs the EBS NVMe udev rule and the `nvme-id` helper (mode 0755). The `nvme` binary it calls at runtime is `nvme-cli`, already in the shared base package set.

- [ ] **Step 1: Write `build/stages/udev-aws-rules/assets/70-ec2-nvme-devices.rules`**

```
KERNEL=="nvme[0-9]*n[0-9]*", ENV{DEVTYPE}=="disk", ATTRS{model}=="Amazon Elastic Block Store", PROGRAM="/sbin/nvme-id /dev/%k", SYMLINK+="%c"
KERNEL=="nvme[0-9]*n[0-9]*p[0-9]*", PROGRAM="/sbin/nvme-id /dev/%k", SYMLINK+="%c"
```

- [ ] **Step 2: Write `build/stages/udev-aws-rules/assets/nvme-id`**

```bash
#!/bin/bash

device_name="$(echo -n "$1" | cut -d 'p' -f1)"
partition_number="$(echo -n "$1" | sed -E "s#${device_name}p?##")"
resolved_device_name=$(/usr/sbin/nvme id-ctrl -V "$1" | sed -n -E '/0000:/s/.*"([^.]+).*".*/\1/p')
echo "${resolved_device_name}${partition_number}"
```

- [ ] **Step 3: Write `build/stages/udev-aws-rules/apply.sh`**

```bash
#!/bin/bash
set -eu

# $root is exported by build/rootfs/apply-stages.nix (the rootfs tree target).
# shellcheck disable=SC2154

# Install the EC2/EBS NVMe udev rule and the nvme-id helper it invokes.
mkdir -p "$root/etc/udev/rules.d" "$root/sbin"
cp "$STAGE_DIR"/70-ec2-nvme-devices.rules "$root/etc/udev/rules.d/70-ec2-nvme-devices.rules"
cp "$STAGE_DIR"/nvme-id "$root/sbin/nvme-id"
chmod 0755 "$root/sbin/nvme-id"
```

- [ ] **Step 4: Write `build/stages/udev-aws-rules/default.nix`**

```nix
# udev-aws-rules stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "udev-aws-rules";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
```

- [ ] **Step 5: Format and validate**

Run: `nix fmt && nix-instantiate --eval --expr 'import ./build/stages/udev-aws-rules { }'`
Expected: `nix fmt` clean; eval prints an attrset with `name = "udev-aws-rules"`.

- [ ] **Step 6: Commit**

```bash
git add build/stages/udev-aws-rules
git commit -m "feat: add udev-aws-rules stage (EBS NVMe device naming)"
```

---

## Task 4: Select infrastructure stages in the stage list and os-image

**Files:**
- Modify: `build/stages/default.nix`
- Modify: `build/rootfs/os-image.nix`

Make the trailing IaaS stage(s) selectable by an `infrastructure` argument. OpenStack default preserves the exact current stage list.

- [ ] **Step 1: Parameterize `build/stages/default.nix`**

Replace the whole file with:

```nix
{
  callPackage,
  infrastructure ? "openstack",
}:
let
  # Source-built components that need store-path interpolation
  bosh-agent = callPackage ../pkgs/bosh-agent.nix { };
  monit = callPackage ../pkgs/monit.nix { };
  blob = callPackage ../pkgs/blobstore-clis.nix { };

  # IaaS-specific stages. Generic stages are shared across all infrastructures.
  # NOTE: upstream's `system_aws_modules` is a verified no-op, so it is
  # deliberately omitted here.
  infraStages =
    if infrastructure == "openstack" then
      [ (import ./openstack-agent-settings { }) ]
    else if infrastructure == "aws" then
      [
        (import ./aws-agent-settings { })
        (import ./udev-aws-rules { })
      ]
    else
      throw "stages/default.nix: unsupported infrastructure '${infrastructure}'";
in
[
  # Pure stages: import individual stage directories (each resolves to its own default.nix)
  (import ./users { })
  (import ./ssh { })
  (import ./sysctl-limits-env { })
  (import ./sudoers-pam { })
  (import ./rsyslog { })
  (import ./audit { })
  (import ./misc-os { })
  (import ./systemd-services { })

  # Interpolated stages (embed store paths)
  (import ./agent { inherit bosh-agent monit; })
  (import ./blobstore-clis {
    inherit (blob)
      davcli
      s3cli
      gcscli
      azureStorageCli
      ;
  })
]
++ infraStages
```

- [ ] **Step 2: Thread `infrastructure` through `build/rootfs/os-image.nix`**

Replace the whole file with:

```nix
# PHASE 1 entry point: fold the config stages onto the base rootfs.
# Flake output `os-image`. `infrastructure` selects the IaaS-specific stages;
# the base deb closure is infrastructure-agnostic and shared/cached.
{
  callPackage,
  infrastructure ? "openstack",
}:
let
  applyStages = callPackage ./apply-stages.nix { };
  base = callPackage ./rootfs.nix { };
  stages = callPackage ../stages { inherit infrastructure; };
in
applyStages { inherit base stages; }
```

- [ ] **Step 3: Format**

Run: `nix fmt`
Expected: clean.

- [ ] **Step 4: Verify OpenStack stage list is unchanged and AWS evaluates**

Run:
```bash
nix eval --raw --expr 'builtins.concatStringsSep "," (map (s: s.name) (import ./build/stages { callPackage = (import <nixpkgs> {}).callPackage; }))' 2>/dev/null \
  || nix eval --impure --raw --expr 'let p = import ./build/stages; in builtins.concatStringsSep "," (map (s: s.name) (p { callPackage = (import <nixpkgs> {}).callPackage; }))'
```
Expected (default = openstack): ends with `...,agent,blobstore-clis,openstack-agent-settings`.

Then AWS:
```bash
nix eval --impure --raw --expr 'let p = import ./build/stages; in builtins.concatStringsSep "," (map (s: s.name) (p { callPackage = (import <nixpkgs> {}).callPackage; infrastructure = "aws"; }))'
```
Expected: ends with `...,agent,blobstore-clis,aws-agent-settings,udev-aws-rules`.

- [ ] **Step 5: Verify the default os-image derivation is still valid**

Run: `nix eval .#os-image.drvPath`
Expected: prints a `.drv` path, no error.

- [ ] **Step 6: Commit**

```bash
git add build/stages/default.nix build/rootfs/os-image.nix
git commit -m "feat: select IaaS stages via infrastructure arg"
```

---

## Task 5: Branch stemcell manifest fields on infrastructure

**Files:**
- Modify: `build/stemcells/package.nix`

Branch `stemcell_formats`, `disk_format`, and the trailing cloud_properties on `infrastructure`. OpenStack renders exactly as today; AWS renders `aws-raw` / `raw` / `root_device_name` + `boot_mode`.

- [ ] **Step 1: Add derived values in the `let` block**

In `build/stemcells/package.nix`, the current `let` block (lines 23-27) is:

```nix
let
  # Compute stemcell archive filename per upstream convention:
  # bosh-stemcell-VERSION-INFRASTRUCTURE-HYPERVISOR-OS-OSVERSION.tgz
  stemcellFilename = "bosh-stemcell-${version}-${infrastructure}-${hypervisor}-${os}-${osVersion}.tgz";
in
```

Replace it with:

```nix
let
  # Compute stemcell archive filename per upstream convention:
  # bosh-stemcell-VERSION-INFRASTRUCTURE-HYPERVISOR-OS-OSVERSION.tgz
  stemcellFilename = "bosh-stemcell-${version}-${infrastructure}-${hypervisor}-${os}-${osVersion}.tgz";

  # Infrastructure-specific manifest fields (mirrors upstream
  # bosh/stemcell/infrastructure.rb + stemcell_packager.rb).
  stemcellFormatsYaml =
    if infrastructure == "aws" then
      "  - aws-raw"
    else
      "  - openstack-qcow2\n  - openstack-raw";

  diskFormatValue = if infrastructure == "aws" then "raw" else "qcow2";

  # Trailing cloud_properties entries appended after `architecture`
  # (upstream additional_cloud_properties).
  extraCloudPropsYaml =
    if infrastructure == "aws" then
      "  root_device_name: /dev/sda1\n      boot_mode: uefi-preferred"
    else
      "  auto_disk_config: true";
in
```

Note on indentation: `extraCloudPropsYaml` is substituted after `      ` (6 spaces) already present in the heredoc line, so the first entry gets 6 spaces + the literal 2 spaces above = 8, and the continuation line embeds its own 6-space indent. See Step 2 for the exact heredoc.

- [ ] **Step 2: Use the derived values in the heredoc**

The current heredoc (lines 64-86) contains these lines:

```
    stemcell_formats:
      - openstack-qcow2
      - openstack-raw
    cloud_properties:
      name: bosh-${infrastructure}-${hypervisor}-${os}-${osVersion}
      version: ${version}
      infrastructure: ${infrastructure}
      hypervisor: ${hypervisor}
      disk: 5120
      disk_format: qcow2
      container_format: bare
      os_type: linux
      os_distro: ${os}
      architecture: x86_64
      auto_disk_config: true
    EOF
```

Replace those lines with:

```
    stemcell_formats:
    ${stemcellFormatsYaml}
    cloud_properties:
      name: bosh-${infrastructure}-${hypervisor}-${os}-${osVersion}
      version: ${version}
      infrastructure: ${infrastructure}
      hypervisor: ${hypervisor}
      disk: 5120
      disk_format: ${diskFormatValue}
      container_format: bare
      os_type: linux
      os_distro: ${os}
      architecture: x86_64
      ${extraCloudPropsYaml}
    EOF
```

(The `stemcellFormatsYaml` value already includes the `  - ` list-item indentation; the `    ` before `${stemcellFormatsYaml}` provides the 4-space YAML nesting so items render at 6 spaces, matching today's output.)

- [ ] **Step 3: Format**

Run: `nix fmt`
Expected: clean.

- [ ] **Step 4: Render-check the OpenStack manifest is unchanged**

Because manifest correctness depends on exact YAML indentation, verify by evaluating the buildCommand string for the OpenStack case and grepping the relevant block. Run:

```bash
nix eval --raw .#openstack-kvm.drvPath
```
Expected: prints a `.drv` path (proves evaluation succeeds). The byte-identical guarantee for OpenStack is verified for real in Task 8.

- [ ] **Step 5: Commit**

```bash
git add build/stemcells/package.nix
git commit -m "feat: branch stemcell manifest fields on infrastructure"
```

---

## Task 6: Add AWS disk and stemcell wrappers

**Files:**
- Create: `build/stemcells/aws-disk.nix`
- Create: `build/stemcells/aws.nix`

Mirror `openstack-kvm-disk.nix` and `openstack-kvm.nix`, but with the AWS os-image, raw disk format, and AWS identity.

- [ ] **Step 1: Write `build/stemcells/aws-disk.nix`**

```nix
# AWS: raw bootable MBR disk from the phase-1 AWS os-image.
# Flake output `noble-stemcell-aws-disk`. Output: $out/root.img
{ callPackage }:
let
  osImage = callPackage ../rootfs/os-image.nix { infrastructure = "aws"; };
  mkBootableDisk = callPackage ./bootable-disk.nix { };
in
mkBootableDisk {
  inherit osImage;
  name = "noble-stemcell-aws";
  diskFormat = "raw";
}
```

- [ ] **Step 2: Write `build/stemcells/aws.nix`**

```nix
# AWS: package the raw disk into a BOSH aws-raw stemcell .tgz.
# Flake outputs `aws` / `noble-stemcell-aws`.
# Output: $out/bosh-stemcell-<version>-aws-xen-ubuntu-noble.tgz
{ callPackage }:
let
  bootableDiskDerivation = callPackage ./aws-disk.nix { };
  bootableDisk = "${bootableDiskDerivation}/root.img";
  # Same memoized AWS os-image derivation used inside aws-disk.nix; provides the
  # generated stemcell metadata members under ${metadata}/metadata/.
  metadata = callPackage ../rootfs/os-image.nix { infrastructure = "aws"; };
  mkStemcell = callPackage ./package.nix { };
in
mkStemcell {
  inherit bootableDisk metadata;
  version = "0.0.5-nix";
  os = "ubuntu";
  osVersion = "noble";
  infrastructure = "aws";
  hypervisor = "xen";
}
```

- [ ] **Step 3: Format**

Run: `nix fmt`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add build/stemcells/aws-disk.nix build/stemcells/aws.nix
git commit -m "feat: add AWS disk and stemcell packaging wrappers"
```

---

## Task 7: Wire AWS flake outputs

**Files:**
- Modify: `flake.nix`

Add AWS package outputs alongside the OpenStack ones. Existing outputs are untouched.

- [ ] **Step 1: Add the AWS derivations to the `let` block**

In `flake.nix`, the current `let` (lines 34-37) is:

```nix
            let
              blobstoreClis = pkgs.callPackage ./build/pkgs/blobstore-clis.nix { };
              openstack-kvm = pkgs.callPackage ./build/stemcells/openstack-kvm.nix { };
            in
```

Replace with:

```nix
            let
              blobstoreClis = pkgs.callPackage ./build/pkgs/blobstore-clis.nix { };
              openstack-kvm = pkgs.callPackage ./build/stemcells/openstack-kvm.nix { };
              aws = pkgs.callPackage ./build/stemcells/aws.nix { };
            in
```

- [ ] **Step 2: Add the AWS outputs to the `packages` attrset**

After the OpenStack block (current lines 43-46):

```nix
              # PHASE 2 (OpenStack/KVM)
              noble-stemcell-disk = pkgs.callPackage ./build/stemcells/openstack-kvm-disk.nix { };
              noble-stemcell = openstack-kvm;
              openstack-kvm = openstack-kvm;
```

insert:

```nix
              # PHASE 2 (AWS / xen, aws-raw heavy stemcell)
              os-image-aws = pkgs.callPackage ./build/rootfs/os-image.nix { infrastructure = "aws"; };
              noble-stemcell-aws-disk = pkgs.callPackage ./build/stemcells/aws-disk.nix { };
              noble-stemcell-aws = aws;
              aws = aws;
```

- [ ] **Step 3: Format**

Run: `nix fmt`
Expected: clean.

- [ ] **Step 4: Evaluate all outputs**

Run: `nix flake check` (evaluation only; may be slow but does not build the VM images) or, if `nix flake check` attempts builds, use:
```bash
for o in os-image os-image-aws openstack-kvm aws noble-stemcell-aws-disk; do nix eval .#$o.drvPath; done
```
Expected: each prints a `.drv` path with no evaluation error.

- [ ] **Step 5: Commit**

```bash
git add flake.nix
git commit -m "feat: expose AWS stemcell flake outputs"
```

---

## Task 8: Build, verify, and regression-check

**Files:** none (verification only)

Full builds are expensive and need disk. Ensure free space first (the store may need GC: `nix-collect-garbage -d`).

- [ ] **Step 1: Build the AWS stemcell**

Run: `nix build .#aws -L`
Expected: succeeds; `result/bosh-stemcell-0.0.5-nix-aws-xen-ubuntu-noble.tgz` exists.

- [ ] **Step 2: Verify the 6 members and manifest fields**

Run:
```bash
tar -tzf result/bosh-stemcell-0.0.5-nix-aws-xen-ubuntu-noble.tgz
mkdir -p /tmp/aws-inspect && tar -xzf result/bosh-stemcell-0.0.5-nix-aws-xen-ubuntu-noble.tgz -C /tmp/aws-inspect stemcell.MF
cat /tmp/aws-inspect/stemcell.MF
```
Expected: exactly `stemcell.MF packages.txt dev_tools_file_list.txt image sbom.spdx.json sbom.cdx.json`. Manifest shows:
- `name: bosh-aws-xen-ubuntu-noble`
- `stemcell_formats:` with a single `- aws-raw`
- `disk_format: raw`
- `cloud_properties` includes `root_device_name: /dev/sda1` and `boot_mode: uefi-preferred`, and NO `auto_disk_config`.

- [ ] **Step 3: Verify the image member is a raw disk**

Run:
```bash
tar -xzf result/bosh-stemcell-0.0.5-nix-aws-xen-ubuntu-noble.tgz -C /tmp/aws-inspect image
tar -xzf /tmp/aws-inspect/image -C /tmp/aws-inspect root.img
qemu-img info /tmp/aws-inspect/root.img
```
Expected: `file format: raw`.

- [ ] **Step 4: Verify AWS-specific rootfs contents landed**

Run:
```bash
nix build .#os-image-aws -o result-aws-osimage -L
mkdir -p /tmp/aws-root && tar -xzf result-aws-osimage/rootfs.tar.gz -C /tmp/aws-root ./var/vcap/bosh/agent.json ./etc/udev/rules.d/70-ec2-nvme-devices.rules ./sbin/nvme-id ./usr/sbin/nvme 2>/dev/null
grep -q 'Amazon_Elastic_Block_Store' /tmp/aws-root/var/vcap/bosh/agent.json && echo AGENT_OK
test -f /tmp/aws-root/etc/udev/rules.d/70-ec2-nvme-devices.rules && echo RULES_OK
test -x /tmp/aws-root/sbin/nvme-id && echo NVMEID_OK
test -f /tmp/aws-root/usr/sbin/nvme && echo NVMECLI_OK
```
Expected: `AGENT_OK`, `RULES_OK`, `NVMEID_OK`, `NVMECLI_OK` all print.

- [ ] **Step 5: Determinism — rebuild AWS and compare hashes**

Run:
```bash
sha256sum result/bosh-stemcell-0.0.5-nix-aws-xen-ubuntu-noble.tgz
nix build .#aws --rebuild -L
sha256sum result/bosh-stemcell-0.0.5-nix-aws-xen-ubuntu-noble.tgz
```
Expected: identical sha256 across the two builds.

- [ ] **Step 6: Regression — OpenStack stemcell byte-identical**

Capture the current OpenStack tarball hash, rebuild after the changes, and compare. Run:
```bash
nix build .#openstack-kvm -o result-os -L
sha256sum result-os/bosh-stemcell-0.0.5-nix-openstack-kvm-ubuntu-noble.tgz
```
Expected: matches the hash from the last OpenStack build on `main` before this branch (the OpenStack code paths render identical substituted scripts/manifests). If it differs, diff the extracted `stemcell.MF` and the `image` to locate the unintended change and fix before proceeding.

- [ ] **Step 7: Final format check and (optional) squash-free push**

Run: `nix fmt -- --fail-on-change`
Expected: `0 changed`. The feature is complete.

---

## Self-Review Notes (author)

- **Spec coverage:** §1 → Task 4; §2 (aws-agent-settings) → Task 2; §2 (udev-aws-rules) → Task 3; §3 disk → Task 1 + Task 6; §3 packaging → Task 5; §4 flake outputs → Task 7; verification plan → Task 8. FIPS is explicitly out of scope (no task). Base deb closure intentionally not parameterized (no task) — matches the simplified design.
- **No new packages:** `nvme-cli` already in base; confirmed no rootfs/deb-sets changes needed.
- **Type/name consistency:** `diskFormat` param name and `root.img` output are consistent across Task 1, Task 6, and Task 8. `infrastructure` values `"openstack"`/`"aws"` consistent across Tasks 4-7. Stage names `aws-agent-settings` / `udev-aws-rules` consistent between Task 2/3 (definition) and Task 4 (selection).
