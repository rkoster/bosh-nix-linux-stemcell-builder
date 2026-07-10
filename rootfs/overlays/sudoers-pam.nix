# sudoers-pam overlay: fragment externalized to sudoers-pam.sh (byte-identical to the previous
# inline string). Applied by rootfs/apply-overlays.nix inside the shared fakeroot
# session with $root bound and the ambient PATH.
{ }:
import ../../lib/mkOverlay.nix {
  name = "sudoers-pam";
  src = ./sudoers-pam.sh;
}
