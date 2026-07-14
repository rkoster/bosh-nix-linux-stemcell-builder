{ lib, buildGoModule, fetchFromGitHub }:
buildGoModule rec {
  pname = "bosh-agent";
  version = "2.861.0";

  src = fetchFromGitHub {
    owner = "cloudfoundry";
    repo = "bosh-agent";
    rev = "v${version}";
    hash = "sha256-fUImNmrYOKDXUpdN/n4ctZYZBBlKc8PmgNejFYE0qR4=";
  };

  vendorHash = null;   # repo has vendored dependencies

  env.CGO_ENABLED = "0";
  doCheck = false;

  # Upstream embeds the version via ldflags in bin/build. Replicates the build
  # script which uses: -ldflags="-X 'main.VersionLabel=...'" and builds "./main"
  ldflags = [ "-s" "-w" "-X" "main.VersionLabel=${version}" ];

  # bosh-agent's main package is in the "./main" subdir
  subPackages = [ "main" ];

  meta = {
    description = "BOSH agent (built from source)";
    homepage = "https://github.com/cloudfoundry/bosh-agent";
  };
}
