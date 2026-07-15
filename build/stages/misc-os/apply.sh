#!/bin/bash
set -eu

# Setup periodic cron jobs
cp "$STAGE_DIR"/02periodic /etc/apt/apt.conf.d/02periodic

# Configure package sources
cp "$STAGE_DIR"/sources.list /etc/apt/sources.list
