# Turn a pure overlay definition into the { name; script; } record that
# rootfs/apply-overlays.nix consumes. `script = builtins.readFile src` is
# byte-identical to the previous inline `script = ''…''` string, so the
# assembled fakeroot buildCommand — and thus the os-image output — is unchanged.
#
# Only pure overlays (no Nix store-path interpolation) use this. Overlays that
# must embed store paths (agent, blobstore-clis, debug-ssh-keys) stay inline and
# return { name; script; } directly.
{ name, src }:
{
  inherit name;
  script = builtins.readFile src;
}
