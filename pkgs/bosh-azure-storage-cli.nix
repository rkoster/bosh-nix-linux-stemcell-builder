{ lib, callPackage }:
callPackage ../lib/mk-blobstore-cli.nix { } {
  pname = "bosh-azure-storage-cli";
  version = "0.0.242";
  repo = "bosh-azure-storage-cli";
  hash = "sha256-bAk9dwj5NppeoAOT+LVews/SV7GiWgJobVzQdAzSCmM=";
  vendorHash = null;
  ldflagsVersionVar = null;
}
