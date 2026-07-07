# Phase-1 OS image: fold every config overlay onto the noble-rootfs closure.
# Overlays are added task-by-task; the list order mirrors ubuntu_os_stages where it matters
# (users before anything asserting group membership; ssh after base packages).
{ callPackage, lib }:
let
  stageAssets = callPackage ../lib/stage-assets.nix { };
  applyOverlay = callPackage ../lib/mk-overlay.nix { };
  base = callPackage ./noble-rootfs.nix { };

  bosh-agent      = callPackage ../pkgs/bosh-agent.nix { };
  davcli          = callPackage ../pkgs/bosh-davcli.nix { };
  s3cli           = callPackage ../pkgs/bosh-s3cli.nix { };
  gcscli          = callPackage ../pkgs/bosh-gcscli.nix { };
  azureStorageCli = callPackage ../pkgs/bosh-azure-storage-cli.nix { };

   overlays = [
     (import ../lib/overlays/users.nix { })
     (import ../lib/overlays/ssh.nix { inherit stageAssets; })
     (import ../lib/overlays/sysctl-limits-env.nix { inherit stageAssets; })
     (import ../lib/overlays/sudoers-pam.nix { inherit stageAssets; })
     (import ../lib/overlays/rsyslog.nix { inherit stageAssets; })
     (import ../lib/overlays/audit.nix { inherit stageAssets; })
     (import ../lib/overlays/misc-os.nix { inherit stageAssets; })
     (import ../lib/overlays/systemd-services.nix { inherit stageAssets; })
     (import ../lib/overlays/agent.nix { inherit bosh-agent; })
     (import ../lib/overlays/blobstore-clis.nix {
       inherit davcli s3cli gcscli azureStorageCli;
     })
     (import ../lib/overlays/openstack-agent-settings.nix { })
   ];

  final = lib.foldl (acc: ov: applyOverlay {
    base = acc; inherit (ov) name script;
  }) base overlays;
in
# Re-expose as os-image.tgz for the oracle harness.
final
