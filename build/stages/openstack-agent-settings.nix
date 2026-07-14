# openstack-agent-settings stage: fragment externalized to openstack-agent-settings.sh (byte-identical to the previous
# inline string). Applied by rootfs/apply-stages.nix inside the shared fakeroot
# session with $root bound and the ambient PATH.
{ }:
import ../lib/mkStage.nix {
  name = "openstack-agent-settings";
  src = ./openstack-agent-settings.sh;
}
