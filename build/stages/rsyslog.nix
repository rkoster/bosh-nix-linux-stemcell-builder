# rsyslog stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "rsyslog";
  script = ''
    export STAGE_DIR="${./rsyslog}"
    bash -euxo pipefail "${./rsyslog/apply.sh}"
  '';
}
