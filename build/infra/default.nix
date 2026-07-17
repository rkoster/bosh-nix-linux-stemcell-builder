# Infrastructure selector. Returns the pure-data descriptor for the requested
# IaaS. Defaults to openstack so every existing call site is unchanged.
{
  infrastructure ? "openstack",
}:
let
  registry = {
    openstack = import ./openstack.nix;
    aws = import ./aws.nix;
  };
in
if registry ? ${infrastructure} then
  registry.${infrastructure}
else
  throw "build/infra/default.nix: unknown infrastructure '${infrastructure}' (known: ${builtins.concatStringsSep ", " (builtins.attrNames registry)})"
