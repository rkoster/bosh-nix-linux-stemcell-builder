# debug-ssh-root-login overlay: fragment externalized to debug-ssh-root-login.sh (byte-identical to the previous
# inline string). Applied by rootfs/apply-overlays.nix inside the shared fakeroot
# session with $root bound and the ambient PATH.
{ }:
import ../mkOverlay.nix {
  name = "debug-ssh-root-login";
  src = ./debug-ssh-root-login.sh;
}
