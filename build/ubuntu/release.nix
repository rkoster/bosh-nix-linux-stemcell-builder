# Release selector. Returns the pure-data descriptor for the requested release.
# Defaults to noble so every existing call site is unchanged.
{
  release ? "noble",
}:
let
  registry = {
    noble = import ./releases/noble.nix;
    # resolute added in a later plan
  };
in
if registry ? ${release} then
  registry.${release}
else
  throw "build/ubuntu/release.nix: unknown release '${release}' (known: ${builtins.concatStringsSep ", " (builtins.attrNames registry)})"
