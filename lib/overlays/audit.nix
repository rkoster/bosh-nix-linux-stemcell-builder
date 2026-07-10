# audit overlay: fragment externalized to audit.sh (byte-identical to the previous
# inline string). Applied by rootfs/apply-overlays.nix inside the shared fakeroot
# session with $root bound and the ambient PATH.
{ }:
import ../mkOverlay.nix {
  name = "audit";
  src = ./audit.sh;
}
