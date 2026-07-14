# systemd-services stage: fragment externalized to systemd-services.sh (byte-identical to the previous
# inline string). Applied by rootfs/apply-stages.nix inside the shared fakeroot
# session with $root bound and the ambient PATH.
{ }:
import ../lib/mkStage.nix {
  name = "systemd-services";
  src = ./systemd-services.sh;
}
