{ lib, callPackage }:
callPackage ../lib/mk-blobstore-cli.nix { } {
  pname = "bosh-s3cli";
  version = "0.0.413";
  repo = "bosh-s3cli";
  hash = "sha256-sNaByQS5bwd5kSqAYCB/Xq2brDbhfXidHXqoK8V3ahU=";
  vendorHash = null;  # bosh-s3cli vendors its Go dependencies
  ldflagsVersionVar = "main.version";  # embeds 0.0.413 into the binary via ldflags
}
