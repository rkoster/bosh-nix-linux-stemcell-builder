# The upstream builder's stage asset tree, exposed as a Nix store path so overlays can
# reuse asset files verbatim (convert-in-place). Path is relative to the repo root.
# Uses builtins.path to import the submodule tree explicitly.
{ lib }:
builtins.path {
  path = ../../bosh-linux-stemcell-builder/stemcell_builder/stages;
  name = "stemcell-builder-stages";
}
