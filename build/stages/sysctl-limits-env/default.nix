# sysctl-limits-env stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "sysctl-limits-env";
  script = ''
    export STAGE_DIR="${./sysctl-limits-env}"
    bash -euxo pipefail "${./sysctl-limits-env/apply.sh}"
  '';
}
