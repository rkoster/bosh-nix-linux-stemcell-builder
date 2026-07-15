#!/bin/bash
set -eu

# Reproduces the upstream `blobstore_clis` stage: install the four source-built
# CLIs into /var/vcap/bosh/bin as bosh-blobstore-<type>.
#
# $root is exported by build/rootfs/apply-stages.nix (the rootfs tree target).
# DAVCLI/S3CLI/GCSCLI/AZURE_STORAGE_CLI are the source-built CLI store paths,
# exported by this stage's default.nix.
# shellcheck disable=SC2154

mkdir -p "$root/var/vcap/bosh/bin"

install -m 0755 "$DAVCLI/bin/davcli" "$root/var/vcap/bosh/bin/bosh-blobstore-dav"
install -m 0755 "$S3CLI/bin/bosh-s3cli" "$root/var/vcap/bosh/bin/bosh-blobstore-s3"
install -m 0755 "$GCSCLI/bin/bosh-gcscli" "$root/var/vcap/bosh/bin/bosh-blobstore-gcs"
install -m 0755 "$AZURE_STORAGE_CLI/bin/bosh-azure-storage-cli" "$root/var/vcap/bosh/bin/bosh-blobstore-azure-storage"
