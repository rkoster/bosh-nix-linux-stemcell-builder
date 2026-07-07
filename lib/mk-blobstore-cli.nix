# Shared buildGoModule wrapper for the four BOSH blobstore CLIs.
# Each concrete package in ../pkgs supplies the repo coordinates + hashes.
{ lib, buildGoModule, fetchFromGitHub }:
{ pname
, version
, owner ? "cloudfoundry"
, repo
, rev ? "v${version}"
, hash            # fetchFromGitHub source hash
, vendorHash      # null if the repo vendors deps, else sha256-...
, subPackages ? [ "." ]
, ldflagsVersionVar ? null   # e.g. "main.version"; null = no version embed
}:
buildGoModule {
  inherit pname version vendorHash subPackages;
  src = fetchFromGitHub { inherit owner repo rev hash; };
  env.CGO_ENABLED = "0";
  doCheck = false;
  ldflags =
    lib.optionals (ldflagsVersionVar != null)
      [ "-s" "-w" "-X" "${ldflagsVersionVar}=${version}" ];
  meta = {
    description = "BOSH blobstore CLI: ${pname}";
    homepage = "https://github.com/${owner}/${repo}";
  };
}
