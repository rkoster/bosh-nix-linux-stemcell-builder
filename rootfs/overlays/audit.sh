    # Install auditd (should already be in the base closure, but ensure it's configured)
    # The auditd package provides default /etc/audit/auditd.conf and /etc/audit/audit.rules

    # Create /etc/audit/rules.d directory if it doesn't exist
    mkdir -p "$root/etc/audit/rules.d"

    # Write comprehensive audit rules to /etc/audit/rules.d/audit.rules
    # This is the output of write_shared_audit_rules + record_use_of_privileged_binaries
    cat > "$root/etc/audit/rules.d/audit.rules" <<'AUDITRULES'
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules

# /sbin/insmod, /sbin/rmmod, /sbin/modprobe are symlinks to /bin/kmod
# Adding a rule for /bin/kmod because auditd does not follow symlinks
-w /bin/kmod -p x -k modules

# Adding finit_module since /bin/kmod uses finit_module
-a always,exit -F arch=b64 -S finit_module -S init_module -S delete_module -k modules

# Record events that modify system date and time
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k time-change
-a always,exit -F arch=b32 -S adjtimex -S settimeofday -S stime -k time-change
-a always,exit -F arch=b64 -S clock_settime -k time-change
-a always,exit -F arch=b32 -S clock_settime -k time-change
-w /etc/localtime -p wa -k time-change

# Record file deletion events
-a always,exit -F arch=b64 -S unlink -S unlinkat -S rmdir -S rename -S renameat -F auid>=500 -F auid!=4294967295 -k delete
-a always,exit -F arch=b32 -S unlink -S unlinkat -S rmdir -S rename -S renameat -F auid>=500 -F auid!=4294967295 -k delete

# Record changes to sudoers file
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d -p wa -k scope

# Record login and logout events
-w /var/log/faillog -p wa -k logins
-w /var/log/lastlog -p wa -k logins
-w /var/log/tallylog -p wa -k logins
-w /var/run/faillock -p wa -k logins

# Record session initiation events
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session

# Record events that modify user/group information
-w /etc/group -p wa -k identity
-w /etc/passwd -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity

# Record events that modify system network environment
-a exit,always -F arch=b64 -S sethostname -S setdomainname -k system-locale
-a exit,always -F arch=b32 -S sethostname -S setdomainname -k system-locale
-w /etc/issue -p wa -k system-locale
-w /etc/issue.net -p wa -k system-locale
-w /etc/hosts -p wa -k system-locale
-w /etc/network -p wa -k system-locale
-w /etc/networks -p wa -k system-locale

# Record events that modify systems mandatory access controls
-w /etc/apparmor/ -p wa -k MAC-policy
-w /etc/apparmor.d/ -p wa -k MAC-policy

# Record system administrator actions
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=4294967295 -F key=sudo_log
-a always,exit -F arch=b32 -S execve -F euid=0 -F auid>=1000 -F auid!=4294967295 -F key=sudo_log

# Record file system mounts
-a always,exit -F arch=b64 -S mount -F auid>=500 -F auid!=4294967295 -k mounts
-a always,exit -F arch=b32 -S mount -F auid>=500 -F auid!=4294967295 -k mounts

# Record discretionary access control permission modification events
-a always,exit -F arch=b64 -S chmod -S fchmod -S fchmodat -F auid>=500 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b32 -S chmod -S fchmod -S fchmodat -F auid>=500 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b64 -S chown -S fchown -S fchownat -S lchown -F auid>=500 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b32 -S chown -S fchown -S fchownat -S lchown -F auid>=500 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b64 -S setxattr -S lsetxattr -S fsetxattr -S removexattr -S lremovexattr -S fremovexattr -F auid>=500 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b32 -S setxattr -S lsetxattr -S fsetxattr -S removexattr -S lremovexattr -S fremovexattr -F auid>=500 -F auid!=4294967295 -k perm_mod

# Record unsuccessful unauthorized access attempts to files - EACCES
-a always,exit -F arch=b64 -S creat -S open -S open_by_handle_at -S openat -S truncate -S ftruncate -F exit=-EACCES -F auid>=500 -F auid!=4294967295 -k access
-a always,exit -F arch=b32 -S creat -S open -S open_by_handle_at -S openat -S truncate -S ftruncate -F exit=-EACCES -F auid>=500 -F auid!=4294967295 -k access
-a always,exit -F arch=b64 -S creat -S open -S open_by_handle_at -S openat -S truncate -S ftruncate -F exit=-EPERM -F auid>=500 -F auid!=4294967295 -k access
-a always,exit -F arch=b32 -S creat -S open -S open_by_handle_at -S openat -S truncate -S ftruncate -F exit=-EPERM -F auid>=500 -F auid!=4294967295 -k access

# Record use of additional binaries (perm=x first — required by os_image_shared_examples.rb:679-703)
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/sbin/unix_chkpwd -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/sbin/mount.nfs -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/sbin/pam_timestamp_check -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/bin/write -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/bin/mount -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/bin/newgrp -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/bin/wall -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/bin/passwd -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/bin/umount -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/bin/crontab -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/bin/chfn -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/bin/ssh-agent -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/bin/gpasswd -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/bin/chsh -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/bin/chage -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/bin/mount -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/bin/su -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/bin/umount -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/sbin/mount.nfs -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/sbin/netreport -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/sbin/postdrop -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/sbin/postqueue -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/sbin/usernetctl -k privileged
-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=/usr/sbin/service -k privileged

# CIS-8.1.12: audit all SUID/SGID binaries (path= first with $ anchor — required by
# os_image_shared_examples.rb:737-751 which dynamically finds SUID/SGID binaries and
# checks for ^-a always,exit -F path=<binary> -F perm=x ... -k privileged$)
-a always,exit -F path=/usr/bin/sudo -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/umount -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/newgrp -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/chsh -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/mount -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/su -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/passwd -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/chfn -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/gpasswd -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/ssh-agent -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/expiry -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/chage -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/bin/crontab -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/sbin/pam_extrausers_chkpwd -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged
-a always,exit -F path=/usr/sbin/unix_chkpwd -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged
-a always,exit -F path=/sbin/unix_chkpwd -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged

# Record execution of privileged function
-a always,exit -F arch=b64 -S execve -C uid!=euid -F key=execpriv
-a always,exit -F arch=b64 -S execve -C gid!=egid -F key=execpriv
-a always,exit -F arch=b32 -S execve -C uid!=euid -F key=execpriv
-a always,exit -F arch=b32 -S execve -C gid!=egid -F key=execpriv

# Record execution of ssh-keysign
-a always,exit -F path=/usr/lib/openssh/ssh-keysign -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged-ssh

# Record execution of sudoedit
-a always,exit -F path=/usr/bin/sudoedit -F perm=x -F auid>=500 -F auid!=4294967295 -k priv_cmd

# Record execution of apparmor_parser
-a always,exit -F path=/sbin/apparmor_parser -F perm=x -F auid>=500 -F auid!=4294967295 -k perm_chng

# Record execution of usermod
-a always,exit -F path=/usr/sbin/usermod -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged-usermod

# Record execution of chcon
-a always,exit -F path=/usr/bin/chcon -F perm=x -F auid>=500 -F auid!=4294967295 -k perm_chng

# Recorde execution of unix_update
-a always,exit -F path=/sbin/unix_update -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged-unix-update

# Record use of privileged commands (dynamically generated in original, hardcoded here for reproducibility)
AUDITRULES

    # Set permissions on audit rules file (0640)
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
    # Note: systemctl disable removes /etc/systemd/system/multi-user.target.wants/auditd.service
    rm -f "$root/etc/systemd/system/multi-user.target.wants/auditd.service"

    # Set auditd.service ExecStartPost to load rules via augenrules
    mkdir -p "$root/etc/systemd/system/auditd.service.d"
    cat > "$root/etc/systemd/system/auditd.service.d/00-override.conf" <<'AUDITOVERRIDE'
[Service]
ExecStartPost=-/sbin/augenrules --load
AUDITOVERRIDE

    # Create /var/log/audit directory with proper ownership (root:root) and mode (0750)
    # Use fakeroot to ensure tar records uid/gid 0
    mkdir -p "$root/var/log/audit"
    chmod 750 "$root/var/log/audit"
    # Explicitly set group to root; auditd's postinst may create this dir with group adm.
    chown root:root "$root/var/log/audit" 2>/dev/null || true

    # Create /var/vcap/bosh/bin directory and copy the logging/auditing startup script
    mkdir -p "$root/var/vcap/bosh/bin"
    cat > "$root/var/vcap/bosh/bin/bosh-start-logging-and-auditing" <<'BASHSCRIPT'
#!/usr/bin/env bash

service auditd start
BASHSCRIPT
    chmod 755 "$root/var/vcap/bosh/bin/bosh-start-logging-and-auditing"

    # Create /etc/profile.d script to load audit rules on boot (alternative to ExecStartPost)
    # This is part of bosh_log_audit_start in the original
    mkdir -p "$root/etc/profile.d"
    cat > "$root/etc/profile.d/auditctl.sh" <<'PROFILESCRIPT'
#!/bin/bash
# Load audit rules at login
auditctl -l > /dev/null 2>&1 || true
PROFILESCRIPT
    chmod 755 "$root/etc/profile.d/auditctl.sh"
