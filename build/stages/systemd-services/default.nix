# systemd-services stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "systemd-services";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
