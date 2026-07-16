#!/bin/bash
set -eu

# $root is exported by build/rootfs/apply-stages.nix (the rootfs tree target).
# shellcheck disable=SC2154

# Install the EC2/EBS NVMe udev rule and the nvme-id helper it invokes.
mkdir -p "$root/etc/udev/rules.d" "$root/sbin"
cp "$STAGE_DIR"/70-ec2-nvme-devices.rules "$root/etc/udev/rules.d/70-ec2-nvme-devices.rules"
cp "$STAGE_DIR"/nvme-id "$root/sbin/nvme-id"
chmod 0755 "$root/sbin/nvme-id"
