{ lib, callPackage }:
callPackage ../lib/mk-blobstore-cli.nix { } {
  pname = "bosh-davcli";
  version = "0.0.486";
  repo = "bosh-davcli";
  hash = "sha256-rCAdyF97WeTvCPoJiiKvmNgCtddAi/30xbaVCrHaHD0=";
  vendorHash = null;
  subPackages = [ "./main" ];
  ldflagsVersionVar = null;  # davcli hardcodes version string
}
