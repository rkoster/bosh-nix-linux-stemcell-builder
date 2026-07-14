# Collapse blobstore CLI packages: davcli, s3cli, gcscli, azureStorageCli
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

let
  # Shared wrapper for the four BOSH blobstore CLIs
  mkCli =
    {
      pname,
      version,
      owner ? "cloudfoundry",
      repo,
      rev ? "v${version}",
      hash,
      vendorHash,
      subPackages ? [ "." ],
      ldflagsVersionVar ? null,
    }:
    let
      # Extract the CLI name from pname by removing "bosh-" prefix if present
      cliName = if lib.hasPrefix "bosh-" pname then lib.removePrefix "bosh-" pname else pname;
    in
    buildGoModule {
      inherit
        pname
        version
        vendorHash
        subPackages
        ;
      src = fetchFromGitHub {
        inherit
          owner
          repo
          rev
          hash
          ;
      };
      env.CGO_ENABLED = "0";
      doCheck = false;
      ldflags = lib.optionals (ldflagsVersionVar != null) [
        "-s"
        "-w"
        "-X"
        "${ldflagsVersionVar}=${version}"
      ];
      postInstall = lib.optionalString (subPackages != [ "." ]) ''
        # When subPackages is used, the binary is named after the last component of the package path.
        # Rename it to the CLI name (pname with "bosh-" prefix removed) for consistency.
        for bin in $out/bin/*; do
          [ -f "$bin" ] && mv "$bin" "$out/bin/${cliName}"
        done
      '';
      meta = {
        description = "BOSH blobstore CLI: ${pname}";
        homepage = "https://github.com/${owner}/${repo}";
      };
    };
in
{
  davcli = mkCli {
    pname = "bosh-davcli";
    version = "0.0.486";
    repo = "bosh-davcli";
    hash = "sha256-rCAdyF97WeTvCPoJiiKvmNgCtddAi/30xbaVCrHaHD0=";
    vendorHash = null;
    subPackages = [ "./main" ];
    ldflagsVersionVar = null;
  };

  s3cli = mkCli {
    pname = "bosh-s3cli";
    version = "0.0.413";
    repo = "bosh-s3cli";
    hash = "sha256-sNaByQS5bwd5kSqAYCB/Xq2brDbhfXidHXqoK8V3ahU=";
    vendorHash = null;
    ldflagsVersionVar = "main.version";
  };

  gcscli = mkCli {
    pname = "bosh-gcscli";
    version = "0.0.393";
    repo = "bosh-gcscli";
    hash = "sha256-LwsfF7OAweJBjzvilC5dpkWAnC3dAKgINlDk7Jf//pU=";
    vendorHash = null;
    ldflagsVersionVar = null;
  };

  azureStorageCli = mkCli {
    pname = "bosh-azure-storage-cli";
    version = "0.0.242";
    repo = "bosh-azure-storage-cli";
    hash = "sha256-bAk9dwj5NppeoAOT+LVews/SV7GiWgJobVzQdAzSCmM=";
    vendorHash = null;
    ldflagsVersionVar = null;
  };
}
