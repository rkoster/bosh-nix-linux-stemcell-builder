#!/bin/bash
set -eu

# Install bosh-agent
mkdir -p /var/vcap/bosh_agent
cp "$STAGE_DIR"/monitrc /var/vcap/bosh_agent/
cp "$STAGE_DIR"/bosh-agent-rc /var/vcap/bosh_agent/
cp "$STAGE_DIR"/restart_networking /var/vcap/bosh_agent/
chmod +x /var/vcap/bosh_agent/restart_networking

# Setup alerts configuration
mkdir -p /var/vcap/monit
cp "$STAGE_DIR"/alerts.monitrc /var/vcap/monit/
cp "$STAGE_DIR"/bosh-agent.service /etc/systemd/system/

# Install helper scripts
cp "$STAGE_DIR"/sync-time /usr/local/bin/
chmod +x /usr/local/bin/sync-time

# Link binaries into system PATH (environment variables provided by stages.nix)
ln -sf "$BOSH_AGENT_BIN" /var/vcap/bosh_agent/main
ln -sf "$MONIT_BIN" /var/vcap/bosh_agent/monit
