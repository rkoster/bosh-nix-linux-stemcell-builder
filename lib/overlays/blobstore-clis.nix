# Reproduces the upstream `blobstore_clis` stage: install the four source-built
# CLIs into /var/vcap/bosh/bin as bosh-blobstore-<type>.
{ davcli, s3cli, gcscli, azureStorageCli }:
{
  name = "blobstore-clis";
  script = ''
    mkdir -p "$root/var/vcap/bosh/bin"

    install -m 0755 ${davcli}/bin/davcli                        "$root/var/vcap/bosh/bin/bosh-blobstore-dav"
    install -m 0755 ${s3cli}/bin/bosh-s3cli                     "$root/var/vcap/bosh/bin/bosh-blobstore-s3"
    install -m 0755 ${gcscli}/bin/bosh-gcscli                   "$root/var/vcap/bosh/bin/bosh-blobstore-gcs"
    install -m 0755 ${azureStorageCli}/bin/bosh-azure-storage-cli "$root/var/vcap/bosh/bin/bosh-blobstore-azure-storage"
  '';
}
