#!/bin/bash
set -eu

# Install the four source-built blobstore CLIs into /var/vcap/bosh/bin as
# bosh-blobstore-<type>.
mkdir -p /var/vcap/bosh/bin

install -m 0755 "$DAVCLI_BIN" /var/vcap/bosh/bin/bosh-blobstore-dav
install -m 0755 "$S3CLI_BIN" /var/vcap/bosh/bin/bosh-blobstore-s3
install -m 0755 "$GCSCLI_BIN" /var/vcap/bosh/bin/bosh-blobstore-gcs
install -m 0755 "$AZURE_STORAGE_CLI_BIN" /var/vcap/bosh/bin/bosh-blobstore-azure-storage
