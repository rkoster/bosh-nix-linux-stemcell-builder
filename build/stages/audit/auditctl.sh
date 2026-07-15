#!/bin/bash
# Load audit rules at login
auditctl -l > /dev/null 2>&1 || true
