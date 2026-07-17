{
  callPackage,
  infrastructure ? "openstack",
  release ? "noble",
}:
let
  releaseDesc = import ../ubuntu/release.nix { inherit release; };
  # Source-built components that need store-path interpolation
  bosh-agent = callPackage ../pkgs/bosh-agent.nix { };
  monit = callPackage ../pkgs/monit.nix { };
  blob = callPackage ../pkgs/blobstore-clis.nix { };

  # IaaS-specific stages. Generic stages are shared across all infrastructures.
  # NOTE: upstream's `system_aws_modules` is a verified no-op, so it is
  # deliberately omitted here.
  # (verified against upstream bosh-linux-stemcell-builder; see docs/superpowers/plans/2026-07-16-aws-stemcell-target.md and the AWS design spec.)
  infra = import ../infra { inherit infrastructure; };

  # Map infra descriptor stage names to their imported stage dirs. Keeping the
  # import table here preserves stage-dir locality while selection stays data.
  infraStageTable = {
    openstack-agent-settings = import ./openstack-agent-settings { };
    aws-agent-settings = import ./aws-agent-settings { };
    udev-aws-rules = import ./udev-aws-rules { };
  };
  infraStages = map (n: infraStageTable.${n}) infra.infraStageNames;
in
[
  # Pure stages: import individual stage directories (each resolves to its own default.nix)
  (import ./users { inherit release; })
  (import ./ssh { })
  (import ./sysctl-limits-env { })
  (import ./sudoers-pam { pamLastlog2 = releaseDesc.features.pamLastlog2; })
  (import ./rsyslog { })
  (import ./audit { })
  (import ./misc-os { codename = releaseDesc.codename; })
  (import ./systemd-services { })

  # Interpolated stages (embed store paths)
  (import ./agent { inherit bosh-agent monit; })
  (import ./blobstore-clis {
    inherit (blob)
      davcli
      s3cli
      gcscli
      azureStorageCli
      ;
  })
]
++ infraStages
