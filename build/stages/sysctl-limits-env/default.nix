# sysctl-limits-env stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "sysctl-limits-env";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
