#!/bin/bash
set -eu

# $root is exported by build/rootfs/apply-stages.nix (the rootfs tree target).
# shellcheck disable=SC2154

# Configure the audit daemon inside the rootfs tree ("$root").

# Create /etc/audit/rules.d directory if it doesn't exist
mkdir -p "$root/etc/audit/rules.d"

# Comprehensive audit rules (asset). This is the output of
# write_shared_audit_rules + record_use_of_privileged_binaries.
cp "$STAGE_DIR"/audit.rules "$root/etc/audit/rules.d/audit.rules"
chmod 640 "$root/etc/audit/rules.d/audit.rules"

# Also copy to /etc/audit/audit.rules for legacy auditd (0640)
cp "$root/etc/audit/rules.d/audit.rules" "$root/etc/audit/audit.rules"
chmod 640 "$root/etc/audit/audit.rules"

# Override default audit variables in auditd.conf
sed -i 's/^disk_error_action = .*$/disk_error_action = SYSLOG/g' "$root/etc/audit/auditd.conf"
sed -i 's/^disk_full_action = .*$/disk_full_action = SYSLOG/g' "$root/etc/audit/auditd.conf"
sed -i 's/^admin_space_left_action = .*$/admin_space_left_action = SYSLOG/g' "$root/etc/audit/auditd.conf"
sed -i 's/^space_left_action = .*$/space_left_action = SYSLOG/g' "$root/etc/audit/auditd.conf"
sed -i 's/^num_logs = .*$/num_logs = 5/g' "$root/etc/audit/auditd.conf"
sed -i 's/^max_log_file = .*$/max_log_file = 6/g' "$root/etc/audit/auditd.conf"
sed -i 's/^max_log_file_action = .*$/max_log_file_action = ROTATE/g' "$root/etc/audit/auditd.conf"
sed -i 's/^log_group = .*$/log_group = root/g' "$root/etc/audit/auditd.conf"
sed -i 's/^space_left = .*$/space_left = 75/g' "$root/etc/audit/auditd.conf"
sed -i 's/^admin_space_left = .*$/admin_space_left = 50/g' "$root/etc/audit/auditd.conf"
sed -i 's/^active = .*$/active = yes/g' "$root/etc/audit/plugins.d/syslog.conf"

# Disable auditd service (remove any systemd enable symlink)
rm -f "$root/etc/systemd/system/multi-user.target.wants/auditd.service"

# Set auditd.service ExecStartPost to load rules via augenrules (asset)
mkdir -p "$root/etc/systemd/system/auditd.service.d"
cp "$STAGE_DIR"/00-override.conf "$root/etc/systemd/system/auditd.service.d/00-override.conf"

# Create /var/log/audit directory with proper ownership (root:root) and mode (0750)
mkdir -p "$root/var/log/audit"
chmod 750 "$root/var/log/audit"
chown root:root "$root/var/log/audit" 2>/dev/null || true

# Logging/auditing startup script (asset)
mkdir -p "$root/var/vcap/bosh/bin"
cp "$STAGE_DIR"/bosh-start-logging-and-auditing "$root/var/vcap/bosh/bin/bosh-start-logging-and-auditing"
chmod 755 "$root/var/vcap/bosh/bin/bosh-start-logging-and-auditing"

# /etc/profile.d script to load audit rules on boot (asset)
mkdir -p "$root/etc/profile.d"
cp "$STAGE_DIR"/auditctl.sh "$root/etc/profile.d/auditctl.sh"
chmod 755 "$root/etc/profile.d/auditctl.sh"
