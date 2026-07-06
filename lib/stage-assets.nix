# The upstream builder's stage asset tree, exposed as a Nix store path so overlays can
# reuse asset files verbatim (convert-in-place). Path is relative to the repo root.
{ lib }:
# NOTE: this pulls the builder subtree into the store. It is large; if closure size becomes
# a problem, replace with a filterSource limited to the assets actually referenced.
../../bosh-linux-stemcell-builder/stemcell_builder/stages
