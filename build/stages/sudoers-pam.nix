# sudoers-pam stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "sudoers-pam";
  script = ''
    export STAGE_DIR="${./sudoers-pam}"
    bash -euxo pipefail "${./sudoers-pam/apply.sh}"
  '';
}
