# misc-os stage: fragment externalized to misc-os.sh (byte-identical to the previous
# inline string). Applied by rootfs/apply-stages.nix inside the shared fakeroot
# session with $root bound and the ambient PATH.
{ }:
import ../lib/mkStage.nix {
  name = "misc-os";
  src = ./misc-os.sh;
}
