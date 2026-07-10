# Phase-1 OS image: fold every config overlay onto the noble-rootfs closure.
# Overlays are added task-by-task; the list order mirrors ubuntu_os_stages where it matters
# (users before anything asserting group membership; ssh after base packages).
{ callPackage, lib, writeText }:
let
  applyOverlays = callPackage ../lib/mk-apply-overlays.nix { };
  base = callPackage ./noble-rootfs.nix { };

  bosh-agent      = callPackage ../pkgs/bosh-agent.nix { };
  monit           = callPackage ../pkgs/monit.nix { };
  davcli          = callPackage ../pkgs/bosh-davcli.nix { };
  s3cli           = callPackage ../pkgs/bosh-s3cli.nix { };
  gcscli          = callPackage ../pkgs/bosh-gcscli.nix { };
  azureStorageCli = callPackage ../pkgs/bosh-azure-storage-cli.nix { };

  # DEBUG ONLY (disabled): emergency root-SSH overlays for diagnosing bosh-agent
  # startup crashes. They are intentionally NOT in the `overlays` list below:
  #   - debug-ssh-root-login.nix rewrites sshd_config with `AllowUsers root vcap`,
  #     which blocks the agent's ephemeral `bosh_*` login users -> `bosh ssh` fails.
  #   - debug-ssh-keys.nix consumes `builtins.readFile <key>`, which forces the
  #     whole build to `--impure`.
  # Re-enable ONLY for local emergency debugging by adding them back to `overlays`
  # and binding `debugSshPubKey = builtins.readFile /path/to/key.pub`.
  # See docs/superpowers/specs/2026-07-08-m5-monit-getopt-ssh-findings.md (Finding 2).

   overlays = [
      (import ../lib/overlays/users.nix { })
      (import ../lib/overlays/ssh.nix { })
      (import ../lib/overlays/sysctl-limits-env.nix { })
     (import ../lib/overlays/sudoers-pam.nix { })
     (import ../lib/overlays/rsyslog.nix { })
     (import ../lib/overlays/audit.nix { })
     (import ../lib/overlays/misc-os.nix { })
     (import ../lib/overlays/systemd-services.nix { })
     (import ../lib/overlays/agent.nix { inherit bosh-agent monit; })
     (import ../lib/overlays/blobstore-clis.nix {
       inherit davcli s3cli gcscli azureStorageCli;
     })
     (import ../lib/overlays/openstack-agent-settings.nix { })
   ];

   final = applyOverlays { inherit base overlays; };
in
final
