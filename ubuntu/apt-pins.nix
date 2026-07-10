# Pinned Ubuntu Noble APT coordinates + Packages.xz indices for
# makeImageFromDebDist. Folds the former noble-source.nix and noble-distro.nix.
#
# snapshot.ubuntu.com was unreachable (503) at build time, so we pin the live
# archive (accepted by the Serverspec oracle). Trade-off: NOT point-in-time
# reproducible — the index hashes float with the live archive.
{ fetchurl }:
let
  urlPrefix = "http://archive.ubuntu.com/ubuntu";
  codename = "noble";
  indexUrl = component:
    "${urlPrefix}/dists/${codename}/${component}/binary-amd64/Packages.xz";
  fetchIndex = component: sha256:
    fetchurl { url = indexUrl component; inherit sha256; };
in
{
  name = "ubuntu-24.04-noble-amd64";
  fullName = "Ubuntu 24.04 Noble (amd64)";
  inherit urlPrefix;

  # main/universe/multiverse indices (order matters: essential.nix scans head=main).
  packagesLists = [
    (fetchIndex "main" "0l94v46rh8q3m8maim1xq2qkagwrjkalcrilrdww599i22g1jsia")
    (fetchIndex "universe" "16jr0mj275yzaii4khfh07hryf451k80hs6jl748qhwi3gx5g45s")
    (fetchIndex "multiverse" "1sjh2wzbwvrxz098l6625igxb0lcdpkm4v9azhmvfjl6w07ld040")
  ];
}
