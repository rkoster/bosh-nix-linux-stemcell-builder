#!/bin/bash
set -eu

# Install and configure audit daemon
cp "$STAGE_DIR"/audit.rules /etc/audit/rules.d/bosh.rules
cp "$STAGE_DIR"/00-override.conf /etc/systemd/system/auditd.service.d/00-override.conf
cp "$STAGE_DIR"/bosh-start-logging-and-auditing /usr/local/bin/
chmod +x /usr/local/bin/bosh-start-logging-and-auditing
cp "$STAGE_DIR"/auditctl.sh /usr/local/bin/
chmod +x /usr/local/bin/auditctl.sh

# Setup service override directory
mkdir -p /etc/systemd/system/auditd.service.d
