{ stdenv, lib, fakeroot, coreutils, busybox, util-linux, gnugrep
, bosh-agent, bosh-stemcell-builder-cert, monit, davcli, s3cli, gcscli
, bosh-windows-stemcell-builder, azure-storage-cli
}:

# Helper function to create a stage (absorbed from build/lib/mkStage.nix + build/stages/default.nix)
let
  mkStage = { name, script }:
    let
      stageDir = ./stages + "/${name}";
    in
    stdenv.mkDerivation {
      inherit name;
      phases = [ "buildPhase" "installPhase" ];
      buildPhase = ''
        export STAGE_DIR="${stageDir}"
        export BOSH_AGENT_BIN="${bosh-agent}/bin/main"
        export MONIT_BIN="${monit}/bin/monit"
        export DAVCLI_BIN="${davcli}/bin/davcli"
        export S3CLI_BIN="${s3cli}/bin/s3cli"
        export GCSCLI_BIN="${gcscli}/bin/gcscli"
        export AZURE_STORAGE_CLI_BIN="${azure-storage-cli}/bin/blobcp"
        ${fakeroot}/bin/fakeroot -s ${fakeroot-state} ${script}
      '';
      installPhase = "mkdir -p $out; find ${builtins.getEnv "fakeroot-state"} -type f | xargs -I {} cp {} $out/";
    };

  # Stage definitions
  stages = [
    { name = "users"; }
    { name = "ssh"; }
    { name = "sysctl-limits-env"; }
    { name = "sudoers-pam"; }
    { name = "rsyslog"; }
    { name = "audit"; }
    { name = "misc-os"; }
    { name = "systemd-services"; }
    { name = "agent"; }
    { name = "blobstore-clis"; }
    { name = "openstack-agent-settings"; }
  ];

in
  # Return list of built stages
  map (stage: mkStage { inherit (stage) name; script = "${./stages}/${stage.name}/apply.sh"; }) stages
