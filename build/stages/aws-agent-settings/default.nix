# aws-agent-settings stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "aws-agent-settings";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
