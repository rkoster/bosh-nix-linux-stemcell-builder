#!/bin/bash
set -eu

# Configure OpenStack agent settings
mkdir -p /var/vcap/bosh/agent
cp "$STAGE_DIR"/agent.json /var/vcap/bosh/agent/agent.json
