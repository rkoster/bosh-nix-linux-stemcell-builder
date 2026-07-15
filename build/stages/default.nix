{ callPackage }:
let
  # Source-built components that need store-path interpolation
  bosh-agent = callPackage ../pkgs/bosh-agent.nix { };
  monit = callPackage ../pkgs/monit.nix { };
  blob = callPackage ../pkgs/blobstore-clis.nix { };
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
  (import ./openstack-agent-settings { })
]
