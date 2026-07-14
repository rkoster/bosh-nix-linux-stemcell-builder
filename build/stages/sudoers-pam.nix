# sudoers-pam stage: fragment externalized to sudoers-pam.sh (byte-identical to the previous
# inline string). Applied by rootfs/apply-stages.nix inside the shared fakeroot
# session with $root bound and the ambient PATH.
{ }:
import ../lib/mkStage.nix {
  name = "sudoers-pam";
  src = ./sudoers-pam.sh;
}
