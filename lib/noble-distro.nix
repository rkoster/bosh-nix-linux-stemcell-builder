# Noble APT distribution coordinates for makeImageFromDebDist.
# The fork's vmTools.debDistros has no 2404/noble entry, so we supply our own.
# basePackages reuses jammy's common base (== commonDebPackages ++ diffutils libc-bin),
# which is the closest predefined analogue in the fork.
{ lib, fetchurl, vmTools }:

let
  src = import ./noble-source.nix;
  indexUrl = component:
    "${src.urlPrefix}/dists/${src.codename}/${component}/binary-amd64/Packages.xz";
  fetchIndex = component: sha256:
    fetchurl { url = indexUrl component; inherit sha256; };
in
{
  name = "ubuntu-24.04-noble-amd64";
  fullName = "Ubuntu 24.04 Noble (amd64)";
  urlPrefix = src.urlPrefix;

  # main/universe/multiverse indices. Hashes filled in Task 1.2.
  packagesLists = [
    (fetchIndex "main" lib.fakeHash)
    (fetchIndex "universe" lib.fakeHash)
    (fetchIndex "multiverse" lib.fakeHash)
  ];

  basePackages = vmTools.debDistros.ubuntu2204x86_64.packages;
}
