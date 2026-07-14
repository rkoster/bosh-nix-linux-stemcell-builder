# sysctl-limits-env stage: fragment externalized to sysctl-limits-env.sh (byte-identical to the previous
# inline string). Applied by rootfs/apply-stages.nix inside the shared fakeroot
# session with $root bound and the ambient PATH.
{ }:
import ../lib/mkStage.nix {
  name = "sysctl-limits-env";
  src = ./sysctl-limits-env.sh;
}
