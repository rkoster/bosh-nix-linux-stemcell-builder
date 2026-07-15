#!/bin/bash
set -eu

# Setup systemd firstboot-done marker for SSH
mkdir -p /etc/systemd/system-preset/
cp "$STAGE_DIR"/10-ssh-firstboot-done.conf /etc/systemd/system-preset/10-ssh-firstboot-done.conf

# Configure TTY access for SSH
cp "$STAGE_DIR"/securetty /etc/securetty
