# ssh stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "ssh";
  script = ''
    export STAGE_DIR="${./ssh}"
    bash -euxo pipefail "${./ssh/apply.sh}"
  '';
}
