{ lib, callPackage }:
callPackage ../lib/mk-blobstore-cli.nix { } {
  pname = "bosh-gcscli";
  version = "0.0.393";
  repo = "bosh-gcscli";
  hash = lib.fakeHash;
  vendorHash = lib.fakeHash;
  ldflagsVersionVar = null;
}
