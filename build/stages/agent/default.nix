# agent stage: reproduces the upstream `bosh_go_agent` + `bosh_monit` stages
# using the source-built agent and monit. The static content lives in ./assets;
# the two source-built store paths are passed to apply.sh as env vars.
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
# ($root is the rootfs tree).
{ bosh-agent, monit }:
{
  name = "agent";
  script = ''
    export STAGE_DIR="${./assets}"
    export BOSH_AGENT="${bosh-agent}"
    export MONIT="${monit}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
