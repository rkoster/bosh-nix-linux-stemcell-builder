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
let
  # Extract the CLI name from pname by removing "bosh-" prefix if present
  cliName = if lib.hasPrefix "bosh-" pname
    then lib.removePrefix "bosh-" pname
    else pname;
in
buildGoModule {
  inherit pname version vendorHash subPackages;
  src = fetchFromGitHub { inherit owner repo rev hash; };
  env.CGO_ENABLED = "0";
  doCheck = false;
  ldflags =
    lib.optionals (ldflagsVersionVar != null)
      [ "-s" "-w" "-X" "${ldflagsVersionVar}=${version}" ];
  postInstall = lib.optionalString (subPackages != [ "." ])
    ''
      # When subPackages is used, the binary is named after the last component of the package path.
      # Rename it to the CLI name (pname with "bosh-" prefix removed) for consistency.
      for bin in $out/bin/*; do
        [ -f "$bin" ] && mv "$bin" "$out/bin/${cliName}"
      done
    '';
  meta = {
    description = "BOSH blobstore CLI: ${pname}";
    homepage = "https://github.com/${owner}/${repo}";
  };
}

