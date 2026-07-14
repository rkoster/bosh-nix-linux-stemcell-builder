# debug-ssh-root-login stage: fragment externalized to debug-ssh-root-login.sh (byte-identical to the previous
# inline string). Applied by rootfs/apply-stages.nix inside the shared fakeroot
# session with $root bound and the ambient PATH.
{ }:
import ../lib/mkStage.nix {
  name = "debug-ssh-root-login";
  src = ./debug-ssh-root-login.sh;
}
