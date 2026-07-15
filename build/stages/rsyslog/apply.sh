#!/bin/bash
set -eu

# Install and configure rsyslog
cp "$STAGE_DIR"/rsyslog.conf /etc/rsyslog.conf
cp "$STAGE_DIR"/50-default.conf /etc/rsyslog.d/50-default.conf
cp "$STAGE_DIR"/90-bosh-agent.conf /etc/rsyslog.d/90-bosh-agent.conf
cp "$STAGE_DIR"/rsyslog /etc/logrotate.d/rsyslog
cp "$STAGE_DIR"/wait_for_var_log_to_be_mounted /usr/local/bin/
chmod +x /usr/local/bin/wait_for_var_log_to_be_mounted

# Setup systemd service overrides
mkdir -p /etc/systemd/system/rsyslog.service.d
cp "$STAGE_DIR"/rsyslog-service-override.conf /etc/systemd/system/rsyslog.service.d/00-override.conf
mkdir -p /etc/systemd/system/systemd-journald.service.d
cp "$STAGE_DIR"/journald-override.conf /etc/systemd/system/systemd-journald.service.d/00-override.conf
