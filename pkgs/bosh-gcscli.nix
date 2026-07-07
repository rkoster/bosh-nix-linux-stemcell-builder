{ lib, callPackage }:
callPackage ../lib/mk-blobstore-cli.nix { } {
  pname = "bosh-gcscli";
  version = "0.0.393";
  repo = "bosh-gcscli";
  hash = "sha256-LwsfF7OAweJBjzvilC5dpkWAnC3dAKgINlDk7Jf//pU=";
  vendorHash = null;  # bosh-gcscli vendors its Go dependencies
  ldflagsVersionVar = null;
}
