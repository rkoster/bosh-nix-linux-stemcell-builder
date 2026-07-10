# users overlay: fragment externalized to users.sh (byte-identical to the previous
# inline string). Applied by rootfs/apply-overlays.nix inside the shared fakeroot
# session with $root bound and the ambient PATH.
{ }:
import ../../lib/mkOverlay.nix {
  name = "users";
  src = ./users.sh;
}
