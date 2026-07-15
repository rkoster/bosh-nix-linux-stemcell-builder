# blobstore-clis stage: install the four source-built CLIs into /var/vcap/bosh/bin
# Receives store-built CLI packages as arguments
{
  davcli,
  s3cli,
  gcscli,
  azureStorageCli,
}:
{
  name = "blobstore-clis";
  script = ''
    export STAGE_DIR="${./blobstore-clis}"
    export DAVCLI_BIN="${davcli}/bin/davcli"
    export S3CLI_BIN="${s3cli}/bin/bosh-s3cli"
    export GCSCLI_BIN="${gcscli}/bin/bosh-gcscli"
    export AZURE_STORAGE_CLI_BIN="${azureStorageCli}/bin/bosh-azure-storage-cli"
    bash -euxo pipefail "${./blobstore-clis/apply.sh}"
  '';
}
