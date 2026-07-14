# Pinned Ubuntu Noble APT coordinates + Packages.xz indices for
# makeImageFromDebDist. Pinned to a fixed snapshot.ubuntu.com timestamp for
# durable, point-in-time reproducibility: superseded .debs stay fetchable
# and the Packages index does not float.
# Spec-compliant (ubuntu_spec.rb:35-37 accepts archive/snapshot).
{ fetchurl }:
let
  urlPrefix = "https://snapshot.ubuntu.com/ubuntu/20260101T000000Z";
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

  # main/universe/multiverse indices. Pinned to snapshot.ubuntu.com/20260101T000000Z.
  packagesLists = [
    (fetchIndex "main" "0l94v46rh8q3m8maim1xq2qkagwrjkalcrilrdww599i22g1jsia")
    (fetchIndex "universe" "16jr0mj275yzaii4khfh07hryf451k80hs6jl748qhwi3gx5g45s")
    (fetchIndex "multiverse" "1sjh2wzbwvrxz098l6625igxb0lcdpkm4v9azhmvfjl6w07ld040")
  ];
}
