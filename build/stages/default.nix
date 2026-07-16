{
  callPackage,
  infrastructure ? "openstack",
}:
let
  # Source-built components that need store-path interpolation
  bosh-agent = callPackage ../pkgs/bosh-agent.nix { };
  monit = callPackage ../pkgs/monit.nix { };
  blob = callPackage ../pkgs/blobstore-clis.nix { };

  # IaaS-specific stages. Generic stages are shared across all infrastructures.
  # NOTE: upstream's `system_aws_modules` is a verified no-op, so it is
  # deliberately omitted here.
  # (verified against upstream bosh-linux-stemcell-builder; see docs/superpowers/plans/2026-07-16-aws-stemcell-target.md and the AWS design spec.)
  infraStages =
    if infrastructure == "openstack" then
      [ (import ./openstack-agent-settings { }) ]
    else if infrastructure == "aws" then
      [
        (import ./aws-agent-settings { })
        (import ./udev-aws-rules { })
      ]
    else
      throw "stages/default.nix: unsupported infrastructure '${infrastructure}'";
in
[
  # Pure stages: import individual stage directories (each resolves to its own default.nix)
  (import ./users { })
  (import ./ssh { })
  (import ./sysctl-limits-env { })
  (import ./sudoers-pam { })
  (import ./rsyslog { })
  (import ./audit { })
  (import ./misc-os { })
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
