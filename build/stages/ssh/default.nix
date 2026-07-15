# ssh stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "ssh";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
