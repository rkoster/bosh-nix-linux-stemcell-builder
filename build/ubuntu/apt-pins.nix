# Pinned Ubuntu APT coordinates + Packages.xz indices for makeImageFromDebDist.
# Coordinates (codename, snapshot, index hashes, names) now come from the
# per-release descriptor via release.nix; defaults to noble so the pinned
# snapshot and indices are byte-identical to before.
{
  fetchurl,
  release ? "noble",
}:
let
  desc = import ./release.nix { inherit release; };
  urlPrefix = "https://snapshot.ubuntu.com/ubuntu/${desc.snapshot}";
  indexUrl = component: "${urlPrefix}/dists/${desc.codename}/${component}/binary-amd64/Packages.xz";
  fetchIndex =
    component: sha256:
    fetchurl {
      url = indexUrl component;
      inherit sha256;
    };
in
{
  inherit (desc) name fullName;
  inherit urlPrefix;

  packagesLists = [
    (fetchIndex "main" desc.packagesListHashes.main)
    (fetchIndex "universe" desc.packagesListHashes.universe)
    (fetchIndex "multiverse" desc.packagesListHashes.multiverse)
  ];
}
