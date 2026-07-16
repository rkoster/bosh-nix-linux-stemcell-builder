# udev-aws-rules stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "udev-aws-rules";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
