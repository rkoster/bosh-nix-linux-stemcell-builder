#!/bin/bash
set -eu

# Create user accounts and groups
cp "$STAGE_DIR"/group /etc/group
cp "$STAGE_DIR"/gshadow /etc/gshadow
cp "$STAGE_DIR"/passwd /etc/passwd
cp "$STAGE_DIR"/shadow /etc/shadow
cp "$STAGE_DIR"/00-bosh-ps1 /etc/profile.d/bosh-ps1

chmod 644 /etc/group
chmod 644 /etc/gshadow
chmod 600 /etc/shadow
chmod 600 /etc/passwd
