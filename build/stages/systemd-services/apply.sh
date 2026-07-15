#!/bin/bash
set -eu

# Install systemd service files
mkdir -p /etc/systemd/system
cp "$STAGE_DIR"/monit.service /etc/systemd/system/monit.service

# Configure systemd
mkdir -p /etc/systemd/system.conf.d
cp "$STAGE_DIR"/prevent_mount_locking.conf /etc/systemd/system.conf.d/prevent_mount_locking.conf
mkdir -p /etc/systemd/system/systemd-resolved.service.d
cp "$STAGE_DIR"/add-container-listener-address.conf /etc/systemd/system/systemd-resolved.service.d/add-container-listener-address.conf

# Create systemd-resolved listener address service
cp "$STAGE_DIR"/create-systemd-resolved-listener-address.service /etc/systemd/system/create-systemd-resolved-listener-address.service

# Configure sysstat
mkdir -p /etc/default
cp "$STAGE_DIR"/sysstat /etc/default/sysstat

# Setup firstboot service
cp "$STAGE_DIR"/firstboot.service /etc/systemd/system/firstboot.service
cp "$STAGE_DIR"/firstboot.sh /usr/local/bin/
chmod +x /usr/local/bin/firstboot.sh
