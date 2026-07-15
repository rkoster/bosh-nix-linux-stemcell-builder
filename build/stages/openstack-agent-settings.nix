# openstack-agent-settings stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "openstack-agent-settings";
  script = ''
    export STAGE_DIR="${./openstack-agent-settings}"
    bash -euxo pipefail "${./openstack-agent-settings/apply.sh}"
  '';
}
