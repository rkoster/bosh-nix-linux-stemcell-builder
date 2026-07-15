#!/bin/bash
set -eu

# Configure sudoers
cp "$STAGE_DIR"/bosh_sudoers /etc/sudoers.d/bosh
chmod 440 /etc/sudoers.d/bosh

# Setup PAM limits
cp "$STAGE_DIR"/bosh_sudoers /etc/security/limits.d/bosh
chmod 644 /etc/security/limits.d/bosh
