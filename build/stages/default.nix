# Ordered stage list applied by rootfs/apply-stages.nix. Order mirrors the
# upstream ubuntu_os_stages where it matters (users before group-membership
# asserts; ssh after base packages; agent + blobstore CLIs late; the
# IaaS-specific agent-settings last).
#
# Interpolating stages (agent, blobstore-clis) receive their source-built
# store paths here; the debug-* stages are intentionally omitted (emergency
# use only — see 2026-07-08 findings).
{ callPackage }:
let
  bosh-agent = callPackage ../pkgs/bosh-agent.nix { };
  monit = callPackage ../pkgs/monit.nix { };
  blob = callPackage ../pkgs/blobstore-clis.nix { };
in
[
  (import ./users.nix { })
  (import ./ssh.nix { })
  (import ./sysctl-limits-env.nix { })
  (import ./sudoers-pam.nix { })
  (import ./rsyslog.nix { })
  (import ./audit.nix { })
  (import ./misc-os.nix { })
  (import ./systemd-services.nix { })
  (import ./agent.nix { inherit bosh-agent monit; })
  (import ./blobstore-clis.nix {
    inherit (blob)
      davcli
      s3cli
      gcscli
      azureStorageCli
      ;
  })
  (import ./openstack-agent-settings.nix { })
]
