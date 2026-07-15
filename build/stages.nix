{ callPackage }:
let
  # Source-built components that need store-path interpolation
  bosh-agent = callPackage ./pkgs/bosh-agent.nix { };
  monit = callPackage ./pkgs/monit.nix { };
  blob = callPackage ./pkgs/blobstore-clis.nix { };
in
[
  # Pure stages: import individual .nix files (matches old stages/default.nix pattern)
  (import ./stages/users.nix { })
  (import ./stages/ssh.nix { })
  (import ./stages/sysctl-limits-env.nix { })
  (import ./stages/sudoers-pam.nix { })
  (import ./stages/rsyslog.nix { })
  (import ./stages/audit.nix { })
  (import ./stages/misc-os.nix { })
  (import ./stages/systemd-services.nix { })

  # Interpolated stages (embed store paths)
  (import ./stages/agent.nix { inherit bosh-agent monit; })
  (import ./stages/blobstore-clis.nix {
    inherit (blob)
      davcli
      s3cli
      gcscli
      azureStorageCli
      ;
  })
  (import ./stages/openstack-agent-settings.nix { })
]
