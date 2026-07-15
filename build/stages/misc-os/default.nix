# misc-os stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "misc-os";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
