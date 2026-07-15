# misc-os stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "misc-os";
  script = ''
    export STAGE_DIR="${./misc-os}"
    bash -euxo pipefail "${./misc-os/apply.sh}"
  '';
}
