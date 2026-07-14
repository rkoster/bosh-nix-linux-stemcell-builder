# Turn a pure stage definition into the { name; script; } record that
# rootfs/apply-stages.nix consumes. `script = builtins.readFile src` is
# byte-identical to the previous inline `script = ''…''` string, so the
# assembled fakeroot buildCommand — and thus the os-image output — is unchanged.
#
# Only pure stages (no Nix store-path interpolation) use this. Stages that
# must embed store paths (agent, blobstore-clis, debug-ssh-keys) stay inline and
# return { name; script; } directly.
{ name, src }:
{
  inherit name;
  script = builtins.readFile src;
}
