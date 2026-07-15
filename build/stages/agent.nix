# agent stage: install bosh-agent, monit, and related configuration
# Receives store-built bosh-agent and monit binaries as arguments
{ bosh-agent, monit }:
{
  name = "agent";
  script = ''
    export STAGE_DIR="${./agent}"
    export BOSH_AGENT_BIN="${bosh-agent}/bin/main"
    export MONIT_BIN="${monit}/bin/monit"
    bash -euxo pipefail "${./agent/apply.sh}"
  '';
}
