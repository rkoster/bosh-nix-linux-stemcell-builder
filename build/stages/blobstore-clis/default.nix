# blobstore-clis stage: install the four source-built CLIs into
# /var/vcap/bosh/bin as bosh-blobstore-<type>. The source-built CLI store paths
# are passed to apply.sh as env vars. Applied by rootfs/apply-stages.nix inside
# the shared fakeroot session ($root is the rootfs tree).
{
  davcli,
  s3cli,
  gcscli,
  azureStorageCli,
}:
{
  name = "blobstore-clis";
  script = ''
    export DAVCLI="${davcli}"
    export S3CLI="${s3cli}"
    export GCSCLI="${gcscli}"
    export AZURE_STORAGE_CLI="${azureStorageCli}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
