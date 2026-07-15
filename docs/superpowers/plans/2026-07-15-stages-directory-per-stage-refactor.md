# Stages Directory-Per-Stage Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `build/stages/*.nix` + flat `build/stages/*.sh` with a single `build/stages.nix` (all Nix boilerplate) plus one directory per stage (`build/stages/<name>/apply.sh` + extracted asset files, zero Nix syntax, zero heredocs), while producing a byte-identical `rootfs.tar.gz`.

**Architecture:** Every stage becomes `build/stages/<name>/apply.sh` (plain bash, no heredocs, no `${...}` Nix interpolation) plus any asset files it copies into place. `build/stages.nix` exports `STAGE_DIR` (the stage's own store path) and any stage-specific env vars (e.g. `BOSH_AGENT_BIN`) before concatenating `apply.sh`'s contents into the existing single-fakeroot-session script that `build/rootfs/apply-stages.nix` already assembles. The two "debug" stages (unused, dead code) are deleted outright.

**Tech Stack:** Nix (nixpkgs `nixos-26.05`), bash, fakeroot, existing `flake.nix` treefmt (nixfmt/shfmt/shellcheck).

**Reference:** `docs/superpowers/specs/2026-07-15-stages-directory-per-stage-refactor-design.md`

---

## Important notes for the implementer

- Every heredoc body in the current stage scripts uses a **quoted** delimiter (`<<'EOF'`, `<<'AUDITRULES'`, etc.), meaning no shell-side variable expansion ever happens inside them. Extracting them to static files via `sed -n 'X,Yp'` is therefore lossless and exact — do not retype file contents by hand.
- `agent.nix`'s heredocs are indented (they live inside a Nix `''...''` string). The `sed -n` line ranges given below extract the **exact bytes**, indentation included — do not "clean up" the extracted files' whitespace. Byte-for-byte fidelity of the final `rootfs.tar.gz` is a hard requirement.
- All `sed -n` extraction commands below reference the **original, not-yet-deleted** files. Do not delete any original `build/stages/*.nix`/`*.sh` file until Task 14 (after `build/stages.nix` exists and has been verified to build correctly).
- After each stage task, no `nix build` is possible yet (the old `build/stages/default.nix` is still what's wired into the actual build until Task 13). Verification for Tasks 2–12 is limited to diffing extracted content and shell syntax-checking `apply.sh` with `bash -n`. The real build verification happens in Tasks 13 and 17.
- `git mv`/`git rm` is used where the plan deletes original files, to preserve history where possible; new files are plain `git add`.

---

### Task 1: Capture baseline reproducibility + build output

**Files:** none (read-only verification step)

- [ ] **Step 1: Confirm working tree is clean**

Run: `git status --porcelain`
Expected: empty output (no uncommitted changes)

- [ ] **Step 2: Build os-image on the current (pre-refactor) code and capture its hash**

Run:
```bash
nix build .#os-image --print-out-paths --no-link > /tmp/opencode/baseline-os-image-out.txt
sha256sum "$(cat /tmp/opencode/baseline-os-image-out.txt)/rootfs.tar.gz" | tee /tmp/opencode/baseline-os-image.sha256
```
Expected: prints a store path and a sha256sum line. Save that hash — it is the baseline `rootfs.tar.gz` hash the final refactored build must reproduce exactly.

- [ ] **Step 3: No commit for this task** (read-only verification; nothing to commit)

---

### Task 2: `users` stage

**Files:**
- Create: `build/stages/users/apply.sh`
- Create: `build/stages/users/group`
- Create: `build/stages/users/gshadow`
- Create: `build/stages/users/passwd`
- Create: `build/stages/users/shadow`
- Create: `build/stages/users/00-bosh-ps1`

- [ ] **Step 1: Create the stage directory and extract heredoc bodies verbatim**

Run:
```bash
mkdir -p build/stages/users
sed -n '5,65p'   build/stages/users.sh > build/stages/users/group
sed -n '70,130p' build/stages/users.sh > build/stages/users/gshadow
sed -n '139,169p' build/stages/users.sh > build/stages/users/passwd
sed -n '176,206p' build/stages/users.sh > build/stages/users/shadow
sed -n '216,225p' build/stages/users.sh > build/stages/users/00-bosh-ps1
```

- [ ] **Step 2: Verify extraction line counts**

Run: `wc -l build/stages/users/{group,gshadow,passwd,shadow,00-bosh-ps1}`
Expected: `group`=61, `gshadow`=61, `passwd`=31, `shadow`=31, `00-bosh-ps1`=10 lines.

- [ ] **Step 3: Write `build/stages/users/apply.sh`**

```bash
# shellcheck shell=bash
# shellcheck disable=SC2148,SC2154,SC2016
# /etc/group -- exact bytes asserted by os_image/ubuntu_spec.rb (lines 413-477)
cp "$STAGE_DIR/group" "$root/etc/group"

# /etc/gshadow -- exact bytes asserted by os_image/ubuntu_spec.rb (lines 479-543)
cp "$STAGE_DIR/gshadow" "$root/etc/gshadow"

# /etc/passwd -- exact bytes asserted by os_image/ubuntu_spec.rb (allowed user accounts test).
# Written last (after all packages) to normalise uid/ordering differences introduced by
# apt installing packages in a different order than the classic debootstrap pipeline.
# systemd-timesync (uid 996) is added by the systemd-timesyncd package; polkitd (989),
# _runit-log (999), and syslog (102) UIDs differ from what apt assigns in our build.
cp "$STAGE_DIR/passwd" "$root/etc/passwd"

# /etc/shadow -- exact ordering and format asserted by ubuntu_spec.rb allowed user accounts test.
# Uses static date 19000 (5 digits, ~2022-01-01) because the Nix debootstrap environment
# sets a very old epoch date (3652 = 1980, only 4 digits) which fails the spec regex \d{5}.
# vcap needs password field non-empty (regex uses (.+)), min-age=1 (not 0).
cp "$STAGE_DIR/shadow" "$root/etc/shadow"
chmod 000 "$root/etc/shadow"
mkdir -p "$root/home/vcap"
chmod 700 "$root/home/vcap"
chown 1000:1000 "$root/home/vcap" 2>/dev/null || true

# Inline ps1 asset (from bosh_users/assets/ps1.sh; inlined for reproducibility)
mkdir -p "$root/etc/profile.d"
cp "$STAGE_DIR/00-bosh-ps1" "$root/etc/profile.d/00-bosh-ps1"

# Update bashrc + profile for root, vcap, and skel
for home in "$root/root" "$root/home/vcap" "$root/etc/skel"; do
  mkdir -p "$home"
  printf 'export PATH=/var/vcap/bosh/bin:$PATH\nsource /etc/profile.d/00-bosh-ps1\n' >> "$home/.bashrc"
done
grep -q '.bashrc' "$root/root/.profile" 2>/dev/null || \
  printf '\n. ~/.bashrc\n' >> "$root/root/.profile"
```

- [ ] **Step 4: Syntax-check**

Run: `bash -n build/stages/users/apply.sh`
Expected: no output (exit 0)

- [ ] **Step 5: Commit**

```bash
git add build/stages/users/
git commit -m "Add users/ stage directory (apply.sh + extracted assets)"
```

---

### Task 3: `ssh` stage

**Files:**
- Create: `build/stages/ssh/apply.sh`
- Create: `build/stages/ssh/10-ssh-firstboot-done.conf`
- Create: `build/stages/ssh/securetty`

- [ ] **Step 1: Create the stage directory and extract heredoc bodies**

Run:
```bash
mkdir -p build/stages/ssh
sed -n '31,32p' build/stages/ssh.sh > build/stages/ssh/10-ssh-firstboot-done.conf
sed -n '37,39p' build/stages/ssh.sh > build/stages/ssh/securetty
```

- [ ] **Step 2: Verify**

Run: `wc -l build/stages/ssh/{10-ssh-firstboot-done.conf,securetty}`
Expected: `10-ssh-firstboot-done.conf`=2, `securetty`=3 lines.

- [ ] **Step 3: Write `build/stages/ssh/apply.sh`**

```bash
# shellcheck shell=bash
# shellcheck disable=SC2148,SC2154,SC2016
cfg="$root/etc/ssh/sshd_config"
echo "" >> "$cfg"
for kv in \
  "UseDNS no" "PermitRootLogin no" "X11Forwarding no" "MaxAuthTries 3" \
  "PermitEmptyPasswords no" "Protocol 2" "HostbasedAuthentication no" \
  "Banner /etc/issue.net" "IgnoreRhosts yes" "ClientAliveInterval 180" \
  "LoginGraceTime 60" "Compression delayed" "PermitUserEnvironment no" \
  "ClientAliveCountMax 1" "PasswordAuthentication no" "PrintLastLog yes" \
  "AllowGroups bosh_sshers" "DenyUsers root"; do
  key=${kv%% *}
  sed -i "/^ *$key/d" "$cfg"
  echo "$kv" >> "$cfg"
done
sed -i "/^ *X11DisplayOffset/d" "$cfg"
# Ciphers + MACs (asserted verbatim by the os_image spec)
sed -i "/^ *Ciphers/d;/^ *MACs/d" "$cfg"
echo 'Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr' >> "$cfg"
echo 'MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com' >> "$cfg"
# host keys: drop DSA, ensure rsa/ecdsa/ed25519 uncommented
sed -i "/^[ #]*HostKey \/etc\/ssh\/ssh_host_dsa_key/d" "$cfg"
for t in rsa ecdsa ed25519; do
  sed -i "s|^[ #]*HostKey /etc/ssh/ssh_host_${t}_key|HostKey /etc/ssh/ssh_host_${t}_key|" "$cfg"
done
chmod 0600 "$cfg"

# firstboot drop-in (inlined asset from base_ssh/assets)
mkdir -p "$root/lib/systemd/system/ssh.service.d"
cp "$STAGE_DIR/10-ssh-firstboot-done.conf" "$root/lib/systemd/system/ssh.service.d/10-ssh-firstboot-done.conf"

# tty_config: securetty (inlined asset)
cp "$STAGE_DIR/securetty" "$root/etc/securetty"

# base_ssh: /etc/issue and /etc/issue.net BOSH warning banner (CIS-11.1)
# Both files must contain the unauthorized-use warning; sshd_config Banner
# directive points to /etc/issue.net.
BANNER_TEXT='Unauthorized use is strictly prohibited. All access and activity
is subject to logging and monitoring.'
printf '%s\n' "$BANNER_TEXT" > "$root/etc/issue"
chmod 0644 "$root/etc/issue"
chown root:root "$root/etc/issue" 2>/dev/null || true
printf '%s\n' "$BANNER_TEXT" > "$root/etc/issue.net"
chmod 0644 "$root/etc/issue.net"
chown root:root "$root/etc/issue.net" 2>/dev/null || true

# base_ssh: empty /etc/motd (CIS-11.1) and disable motd-news
: > "$root/etc/motd"
chmod 0644 "$root/etc/motd"
chown root:root "$root/etc/motd" 2>/dev/null || true
mkdir -p "$root/etc/default"
printf 'ENABLED=0\n' > "$root/etc/default/motd-news"
```

- [ ] **Step 4: Syntax-check**

Run: `bash -n build/stages/ssh/apply.sh`
Expected: no output (exit 0)

- [ ] **Step 5: Commit**

```bash
git add build/stages/ssh/
git commit -m "Add ssh/ stage directory (apply.sh + extracted assets)"
```

---

### Task 4: `sysctl-limits-env` stage

**Files:**
- Create: `build/stages/sysctl-limits-env/apply.sh`
- Create: `build/stages/sysctl-limits-env/60-bosh-sysctl.conf`
- Create: `build/stages/sysctl-limits-env/60-bosh-sysctl-neigh-fix.conf`

- [ ] **Step 1: Create the stage directory and extract heredoc bodies**

Run:
```bash
mkdir -p build/stages/sysctl-limits-env
sed -n '6,47p' build/stages/sysctl-limits-env.sh > build/stages/sysctl-limits-env/60-bosh-sysctl.conf
sed -n '53,57p' build/stages/sysctl-limits-env.sh > build/stages/sysctl-limits-env/60-bosh-sysctl-neigh-fix.conf
```

- [ ] **Step 2: Verify**

Run: `wc -l build/stages/sysctl-limits-env/{60-bosh-sysctl.conf,60-bosh-sysctl-neigh-fix.conf}`
Expected: `60-bosh-sysctl.conf`=42, `60-bosh-sysctl-neigh-fix.conf`=5 lines.

- [ ] **Step 3: Write `build/stages/sysctl-limits-env/apply.sh`**

```bash
# shellcheck shell=bash
# shellcheck disable=SC2148,SC2154,SC2016
# bosh_sysctl: install 60-bosh-sysctl.conf (inlined verbatim from upstream)
mkdir -p "$root/etc/sysctl.d"
cp "$STAGE_DIR/60-bosh-sysctl.conf" "$root/etc/sysctl.d/60-bosh-sysctl.conf"
chmod 0644 "$root/etc/sysctl.d/60-bosh-sysctl.conf"

# bosh_sysctl: install 60-bosh-sysctl-neigh-fix.conf (inlined verbatim from upstream)
cp "$STAGE_DIR/60-bosh-sysctl-neigh-fix.conf" "$root/etc/sysctl.d/60-bosh-sysctl-neigh-fix.conf"
chmod 0644 "$root/etc/sysctl.d/60-bosh-sysctl-neigh-fix.conf"

# bosh_limits
echo '*               hard    core            0' >> "$root/etc/security/limits.conf"

# bosh_environment
touch "$root/etc/environment"
sed -i '/^PATH/d' "$root/etc/environment"
echo 'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/var/vcap/bosh/bin"' >> "$root/etc/environment"
```

- [ ] **Step 4: Syntax-check**

Run: `bash -n build/stages/sysctl-limits-env/apply.sh`
Expected: no output (exit 0)

- [ ] **Step 5: Commit**

```bash
git add build/stages/sysctl-limits-env/
git commit -m "Add sysctl-limits-env/ stage directory (apply.sh + extracted assets)"
```

---

### Task 5: `sudoers-pam` stage

**Files:**
- Create: `build/stages/sudoers-pam/apply.sh`
- Create: `build/stages/sudoers-pam/bosh_sudoers`

- [ ] **Step 1: Create the stage directory and extract heredoc body**

Run:
```bash
mkdir -p build/stages/sudoers-pam
sed -n '10,10p' build/stages/sudoers-pam.sh > build/stages/sudoers-pam/bosh_sudoers
```

- [ ] **Step 2: Verify**

Run: `cat build/stages/sudoers-pam/bosh_sudoers`
Expected: exactly one line: `%bosh_sudoers ALL=(ALL) NOPASSWD: ALL`

- [ ] **Step 3: Write `build/stages/sudoers-pam/apply.sh`**

```bash
# shellcheck shell=bash
# shellcheck disable=SC2148,SC2154,SC2016
# bosh_sudoers: Append includedir to sudoers and create bosh_sudoers sudoers.d file
# Also add the rule directly to /etc/sudoers so that spec tests checking
# /etc/sudoers content (not just the included directory) find the rule.
echo '%bosh_sudoers ALL=(ALL) NOPASSWD: ALL' >> "$root/etc/sudoers"
echo '#includedir /etc/sudoers.d' >> "$root/etc/sudoers"
mkdir -p "$root/etc/sudoers.d"
cp "$STAGE_DIR/bosh_sudoers" "$root/etc/sudoers.d/bosh_sudoers"
chmod 0440 "$root/etc/sudoers.d/bosh_sudoers"

# restrict_su_command: Add pam_wheel.so use_uid to /etc/pam.d/su
echo 'auth required pam_wheel.so use_uid' >> "$root/etc/pam.d/su"

# password_policies: Strip nullok from all PAM files
find "$root/etc/pam.d" -type f -print0 | xargs -0 sed -i -r 's%\bnullok[^ ]*%%g'

# password_policies: Strip trailing whitespace from PAM files
for pam_file in common-account common-auth common-password login; do
  sed -i -e's/[[:space:]]*$//' "$root/etc/pam.d/$pam_file"
done

# password_policies: Modify PAM files using sed and helpers
# common-account: Add pam_faillock.so after pam_permit.so
sed -i '/pam_permit.so/a account\trequired\t\t\tpam_faillock.so' "$root/etc/pam.d/common-account"

# common-auth: Add pam_faillock.so lines (using multiple sed commands to handle tabs)
# Insert preauth line before pam_unix.so
sed -i '/\[success=1 default=ignore\].*pam_unix/i auth\trequired\t\t\tpam_faillock.so preauth silent deny=3 unlock_time=604800 fail_interval=900' "$root/etc/pam.d/common-auth"
# Append authfail and authsucc after pam_unix.so
sed -i '/\[success=1 default=ignore\].*pam_unix/a auth\t[default=die]\t\t\tpam_faillock.so authfail deny=3 unlock_time=604800 fail_interval=900\nauth    sufficient pam_faillock.so authsucc audit deny=3 unlock_time=604800 fail_interval=900' "$root/etc/pam.d/common-auth"

# common-password: Update pam_pwquality and pam_unix settings
sed -i 's/pam_pwquality.so retry=3$/pam_pwquality.so retry=3 minlen=14 dcredit=-1 ucredit=-1 ocredit=-1 lcredit=-1 difok=8/' "$root/etc/pam.d/common-password"
sed -i 's/pam_unix.so obscure use_authtok try_first_pass yescrypt/pam_unix.so obscure use_authtok try_first_pass sha512 remember=24 minlen=14 rounds=5000/' "$root/etc/pam.d/common-password"
# Add pam_lastlog2.so comment line
sed -i '/# end of pam-auth-update config/i #session\toptional\t\t\tpam_lastlog2.so showfailed #NOBLE_TODO: this will only work if util-linux =>2.40 which provide pam_lastlog2.so or if users will install it manually' "$root/etc/pam.d/common-password"

# login: Change pam_faildelay delay from 3000000 to 4000000
sed -i 's/delay=3000000/delay=4000000/' "$root/etc/pam.d/login"
```

- [ ] **Step 4: Syntax-check**

Run: `bash -n build/stages/sudoers-pam/apply.sh`
Expected: no output (exit 0)

- [ ] **Step 5: Commit**

```bash
git add build/stages/sudoers-pam/
git commit -m "Add sudoers-pam/ stage directory (apply.sh + extracted assets)"
```

---

### Task 6: `rsyslog` stage

**Files:**
- Create: `build/stages/rsyslog/apply.sh`
- Create: `build/stages/rsyslog/rsyslog.conf`
- Create: `build/stages/rsyslog/50-default.conf`
- Create: `build/stages/rsyslog/90-bosh-agent.conf`
- Create: `build/stages/rsyslog/rsyslog` (logrotate config)
- Create: `build/stages/rsyslog/wait_for_var_log_to_be_mounted`
- Create: `build/stages/rsyslog/rsyslog-service-override.conf`
- Create: `build/stages/rsyslog/journald-override.conf`

- [ ] **Step 1: Create the stage directory and extract heredoc bodies**

Run:
```bash
mkdir -p build/stages/rsyslog
sed -n '5,62p'   build/stages/rsyslog.sh > build/stages/rsyslog/rsyslog.conf
sed -n '74,145p' build/stages/rsyslog.sh > build/stages/rsyslog/50-default.conf
sed -n '150,152p' build/stages/rsyslog.sh > build/stages/rsyslog/90-bosh-agent.conf
sed -n '158,204p' build/stages/rsyslog.sh > build/stages/rsyslog/rsyslog
sed -n '210,215p' build/stages/rsyslog.sh > build/stages/rsyslog/wait_for_var_log_to_be_mounted
sed -n '234,235p' build/stages/rsyslog.sh > build/stages/rsyslog/rsyslog-service-override.conf
sed -n '241,242p' build/stages/rsyslog.sh > build/stages/rsyslog/journald-override.conf
```

- [ ] **Step 2: Verify**

Run: `wc -l build/stages/rsyslog/*`
Expected: `rsyslog.conf`=58, `50-default.conf`=72, `90-bosh-agent.conf`=3, `rsyslog`=47, `wait_for_var_log_to_be_mounted`=6, `rsyslog-service-override.conf`=2, `journald-override.conf`=2.

- [ ] **Step 3: Write `build/stages/rsyslog/apply.sh`**

```bash
# shellcheck shell=bash
# shellcheck disable=SC2148,SC2154,SC2016
# Create /etc/rsyslog.conf with the main rsyslog configuration
cp "$STAGE_DIR/rsyslog.conf" "$root/etc/rsyslog.conf"

# Clear any default rsyslog.d contents and create the directory
if [ -d "$root/etc/rsyslog.d" ]; then
  rm -rf "$root/etc/rsyslog.d"/*
else
  mkdir -p "$root/etc/rsyslog.d"
fi

# Create /etc/rsyslog.d/50-default.conf
cp "$STAGE_DIR/50-default.conf" "$root/etc/rsyslog.d/50-default.conf"

# Create /etc/rsyslog.d/90-bosh-agent.conf
cp "$STAGE_DIR/90-bosh-agent.conf" "$root/etc/rsyslog.d/90-bosh-agent.conf"

# Create /etc/logrotate.d/rsyslog
mkdir -p "$root/etc/logrotate.d"
cp "$STAGE_DIR/rsyslog" "$root/etc/logrotate.d/rsyslog"

# Create /usr/local/bin/wait_for_var_log_to_be_mounted with 755 permissions
mkdir -p "$root/usr/local/bin"
cp "$STAGE_DIR/wait_for_var_log_to_be_mounted" "$root/usr/local/bin/wait_for_var_log_to_be_mounted"
chmod 755 "$root/usr/local/bin/wait_for_var_log_to_be_mounted"

# Pre-create log files referenced by rsyslog.d/50-default.conf so that
# the os_image spec "secures rsyslog.conf-referenced files" test can stat
# them. rsyslog owns these files (uid/gid of syslog account).
# In the tarball, fakeroot records the syslog uid/gid (102:102 as per
# the group/passwd written by the users stage).
mkdir -p "$root/var/log"
for logfile in auth.log syslog cron.log daemon.log kern.log bosh-agent.log; do
  touch "$root/var/log/$logfile"
  chmod 0600 "$root/var/log/$logfile"
  chown 102:102 "$root/var/log/$logfile" 2>/dev/null || true
done

# Create rsyslog.service.d override
mkdir -p "$root/etc/systemd/system/rsyslog.service.d"
cp "$STAGE_DIR/rsyslog-service-override.conf" "$root/etc/systemd/system/rsyslog.service.d/00-override.conf"

# Create journald.conf.d override
mkdir -p "$root/etc/systemd/journald.conf.d"
cp "$STAGE_DIR/journald-override.conf" "$root/etc/systemd/journald.conf.d/00-override.conf"
```

- [ ] **Step 4: Syntax-check**

Run: `bash -n build/stages/rsyslog/apply.sh`
Expected: no output (exit 0)

- [ ] **Step 5: Commit**

```bash
git add build/stages/rsyslog/
git commit -m "Add rsyslog/ stage directory (apply.sh + extracted assets)"
```

---

### Task 7: `audit` stage

**Files:**
- Create: `build/stages/audit/apply.sh`
- Create: `build/stages/audit/audit.rules`
- Create: `build/stages/audit/00-override.conf`
- Create: `build/stages/audit/bosh-start-logging-and-auditing`
- Create: `build/stages/audit/auditctl.sh`

- [ ] **Step 1: Create the stage directory and extract heredoc bodies**

Run:
```bash
mkdir -p build/stages/audit
sed -n '12,161p' build/stages/audit.sh > build/stages/audit/audit.rules
sed -n '191,192p' build/stages/audit.sh > build/stages/audit/00-override.conf
sed -n '205,207p' build/stages/audit.sh > build/stages/audit/bosh-start-logging-and-auditing
sed -n '215,217p' build/stages/audit.sh > build/stages/audit/auditctl.sh
```

- [ ] **Step 2: Verify**

Run: `wc -l build/stages/audit/*`
Expected: `audit.rules`=150, `00-override.conf`=2, `bosh-start-logging-and-auditing`=3, `auditctl.sh`=3.

- [ ] **Step 3: Write `build/stages/audit/apply.sh`**

```bash
# shellcheck shell=bash
# shellcheck disable=SC2148,SC2154,SC2016
# Install auditd (should already be in the base closure, but ensure it's configured)
# The auditd package provides default /etc/audit/auditd.conf and /etc/audit/audit.rules

# Create /etc/audit/rules.d directory if it doesn't exist
mkdir -p "$root/etc/audit/rules.d"

# Write comprehensive audit rules to /etc/audit/rules.d/audit.rules
# This is the output of write_shared_audit_rules + record_use_of_privileged_binaries
cp "$STAGE_DIR/audit.rules" "$root/etc/audit/rules.d/audit.rules"

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
cp "$STAGE_DIR/00-override.conf" "$root/etc/systemd/system/auditd.service.d/00-override.conf"

# Create /var/log/audit directory with proper ownership (root:root) and mode (0750)
# Use fakeroot to ensure tar records uid/gid 0
mkdir -p "$root/var/log/audit"
chmod 750 "$root/var/log/audit"
# Explicitly set group to root; auditd's postinst may create this dir with group adm.
chown root:root "$root/var/log/audit" 2>/dev/null || true

# Create /var/vcap/bosh/bin directory and copy the logging/auditing startup script
mkdir -p "$root/var/vcap/bosh/bin"
cp "$STAGE_DIR/bosh-start-logging-and-auditing" "$root/var/vcap/bosh/bin/bosh-start-logging-and-auditing"
chmod 755 "$root/var/vcap/bosh/bin/bosh-start-logging-and-auditing"

# Create /etc/profile.d script to load audit rules on boot (alternative to ExecStartPost)
# This is part of bosh_log_audit_start in the original
mkdir -p "$root/etc/profile.d"
cp "$STAGE_DIR/auditctl.sh" "$root/etc/profile.d/auditctl.sh"
chmod 755 "$root/etc/profile.d/auditctl.sh"
```

- [ ] **Step 4: Syntax-check**

Run: `bash -n build/stages/audit/apply.sh`
Expected: no output (exit 0)

- [ ] **Step 5: Commit**

```bash
git add build/stages/audit/
git commit -m "Add audit/ stage directory (apply.sh + extracted assets)"
```

---

### Task 8: `misc-os` stage

**Files:**
- Create: `build/stages/misc-os/apply.sh`
- Create: `build/stages/misc-os/02periodic`
- Create: `build/stages/misc-os/sources.list`

- [ ] **Step 1: Create the stage directory and extract heredoc bodies**

Run:
```bash
mkdir -p build/stages/misc-os
sed -n '17,19p' build/stages/misc-os.sh > build/stages/misc-os/02periodic
sed -n '43,45p' build/stages/misc-os.sh > build/stages/misc-os/sources.list
```

- [ ] **Step 2: Verify**

Run: `wc -l build/stages/misc-os/{02periodic,sources.list}`
Expected: `02periodic`=3, `sources.list`=3.

- [ ] **Step 3: Write `build/stages/misc-os/apply.sh`**

```bash
# shellcheck shell=bash
# shellcheck disable=SC2148,SC2154,SC2016
# system_grub: menu.lst placeholder (grub2 pkg already installed in M1 closure).
mkdir -p "$root/boot/grub"
touch "$root/boot/grub/menu.lst"

# system_grub: gfxblacklist.txt (spec asserts file exists)
touch "$root/boot/grub/gfxblacklist.txt"

# vim_tiny
ln -sf /usr/bin/vim.tiny "$root/usr/bin/vim"

# cron_config: man-db removal + apt periodic disable
rm -f "$root/etc/cron.weekly/man-db" "$root/etc/cron.daily/man-db" "$root/etc/cron.daily/man-db.cron"
mkdir -p "$root/etc/apt/apt.conf.d"
cp "$STAGE_DIR/02periodic" "$root/etc/apt/apt.conf.d/02periodic"
# anacrontab RANDOM_DELAY (cron_config)
if [ -f "$root/etc/anacrontab" ]; then
  grep -v RANDOM_DELAY "$root/etc/anacrontab" > "$root/etc/anacrontab.new"
  sed -i -e '1 a RANDOM_DELAY=60' "$root/etc/anacrontab.new"
  mv "$root/etc/anacrontab.new" "$root/etc/anacrontab"
fi

# escape_ctrl_alt_del
mkdir -p "$root/etc/init"
echo 'exec /usr/bin/logger -p security.info "Control-Alt-Delete pressed"' \
  > "$root/etc/init/control-alt-delete.override"

# clean_machine_id
chmod 644 "$root/etc/machine-id" || true
echo "" > "$root/etc/machine-id"
rm -f "$root/var/lib/dbus/machine-id" || true

# base_apt: create /etc/apt/sources.list with the Ubuntu noble deb lines.
# Ubuntu 24.04 ships apt sources in /etc/apt/sources.list.d/ubuntu.sources
# (DEB822 format) but the os_image spec asserts the legacy /etc/apt/sources.list
# contains the three required deb entries.
cp "$STAGE_DIR/sources.list" "$root/etc/apt/sources.list"
chmod 0644 "$root/etc/apt/sources.list"
chown root:root "$root/etc/apt/sources.list" 2>/dev/null || true

# password_policies / login.defs: PASS_MIN_DAYS 1 (stig: V-38477)
if grep -q '^PASS_MIN_DAYS' "$root/etc/login.defs" 2>/dev/null; then
  sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS 1/' "$root/etc/login.defs"
else
  echo 'PASS_MIN_DAYS 1' >> "$root/etc/login.defs"
fi

# base_ubuntu_packages: remove ZFS kernel module directories.
# The spec asserts /lib/modules/*/kernel/zfs/ and /usr/src/linux-headers-*/zfs
# should NOT be directories.
find "$root/lib/modules" -maxdepth 4 -name "zfs" -type d -exec rm -rf {} \; 2>/dev/null || true
find "$root/usr/src" -maxdepth 3 -name "zfs" -type d -exec rm -rf {} \; 2>/dev/null || true
```

- [ ] **Step 4: Syntax-check**

Run: `bash -n build/stages/misc-os/apply.sh`
Expected: no output (exit 0)

- [ ] **Step 5: Commit**

```bash
git add build/stages/misc-os/
git commit -m "Add misc-os/ stage directory (apply.sh + extracted assets)"
```

---

### Task 9: `systemd-services` stage

**Files:**
- Create: `build/stages/systemd-services/apply.sh`
- Create: `build/stages/systemd-services/monit.service`
- Create: `build/stages/systemd-services/prevent_mount_locking.conf`
- Create: `build/stages/systemd-services/add-container-listener-address.conf`
- Create: `build/stages/systemd-services/create-systemd-resolved-listener-address.service`
- Create: `build/stages/systemd-services/sysstat`
- Create: `build/stages/systemd-services/firstboot.service`
- Create: `build/stages/systemd-services/firstboot.sh`

- [ ] **Step 1: Create the stage directory and extract heredoc bodies**

Run:
```bash
mkdir -p build/stages/systemd-services
sed -n '6,17p'  build/stages/systemd-services.sh > build/stages/systemd-services/monit.service
sed -n '30,31p' build/stages/systemd-services.sh > build/stages/systemd-services/prevent_mount_locking.conf
sed -n '40,41p' build/stages/systemd-services.sh > build/stages/systemd-services/add-container-listener-address.conf
sed -n '46,58p' build/stages/systemd-services.sh > build/stages/systemd-services/create-systemd-resolved-listener-address.service
sed -n '85,86p' build/stages/systemd-services.sh > build/stages/systemd-services/sysstat
sed -n '91,102p' build/stages/systemd-services.sh > build/stages/systemd-services/firstboot.service
sed -n '116,122p' build/stages/systemd-services.sh > build/stages/systemd-services/firstboot.sh
```

- [ ] **Step 2: Verify**

Run: `wc -l build/stages/systemd-services/*`
Expected: `monit.service`=12, `prevent_mount_locking.conf`=2, `add-container-listener-address.conf`=2, `create-systemd-resolved-listener-address.service`=13, `sysstat`=2, `firstboot.service`=12, `firstboot.sh`=7.

- [ ] **Step 3: Write `build/stages/systemd-services/apply.sh`**

```bash
# shellcheck shell=bash
# shellcheck disable=SC2148,SC2154,SC2016
# bosh_monit: monit.service + enable
mkdir -p "$root/lib/systemd/system"
cp "$STAGE_DIR/monit.service" "$root/lib/systemd/system/monit.service"

# bosh_monit: enable monit.service
# Create the want symlink in /etc/systemd/system/ (mirrors what `systemctl enable`
# produces; symlinks in /lib/systemd/system/ are considered "static" by systemctl
# is-enabled and are NOT reported as "enabled").
mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/monit.service "$root/etc/systemd/system/multi-user.target.wants/monit.service"

# bosh_ntp: chrony drop-in override (prevent mount locking)
mkdir -p "$root/etc/systemd/system/chronyd.service.d"
cp "$STAGE_DIR/prevent_mount_locking.conf" "$root/etc/systemd/system/chronyd.service.d/prevent_mount_locking.conf"

# bosh_systemd: RemoveIPC=no in logind.conf
echo 'RemoveIPC=no' >> "$root/etc/systemd/logind.conf"

# bosh_systemd_resolved: add-container-listener-address config
mkdir -p "$root/etc/systemd/resolved.conf.d"
cp "$STAGE_DIR/add-container-listener-address.conf" "$root/etc/systemd/resolved.conf.d/add-container-listener-address.conf"

# bosh_systemd_resolved: create-systemd-resolved-listener-address.service + enable
cp "$STAGE_DIR/create-systemd-resolved-listener-address.service" "$root/lib/systemd/system/create-systemd-resolved-listener-address.service"

# bosh_systemd_resolved: enable create-systemd-resolved-listener-address.service
mkdir -p "$root/lib/systemd/system/systemd-resolved.service.requires"
ln -sf /lib/systemd/system/create-systemd-resolved-listener-address.service \
  "$root/lib/systemd/system/systemd-resolved.service.requires/create-systemd-resolved-listener-address.service"

# base_ubuntu_packages: enable systemd-networkd (mirrors upstream
# `systemctl enable systemd-networkd`). Without this the agent-written
# /etc/systemd/network/10_eth0.network is never applied, so static-network
# validation fails with "no interface configured with that name (eth0)".
# Replicates the symlinks systemctl would create from the unit [Install]
# sections: WantedBy=multi-user.target, Also=systemd-networkd.socket
# (WantedBy=sockets.target), Alias=dbus-org.freedesktop.network1.service.
mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
mkdir -p "$root/etc/systemd/system/sockets.target.wants"
ln -sf /lib/systemd/system/systemd-networkd.service \
  "$root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
ln -sf /lib/systemd/system/systemd-networkd.socket \
  "$root/etc/systemd/system/sockets.target.wants/systemd-networkd.socket"
ln -sf /lib/systemd/system/systemd-networkd.service \
  "$root/etc/systemd/system/dbus-org.freedesktop.network1.service"

# bosh_sysstat: sysstat default config
mkdir -p "$root/etc/default"
cp "$STAGE_DIR/sysstat" "$root/etc/default/sysstat"

# base_ubuntu_firstboot: firstboot.service + enable
cp "$STAGE_DIR/firstboot.service" "$root/etc/systemd/system/firstboot.service"

# base_ubuntu_firstboot: enable firstboot.service
mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/firstboot.service \
  "$root/etc/systemd/system/multi-user.target.wants/firstboot.service"

# base_ubuntu_firstboot: firstboot.sh (assets/root/firstboot.sh, inlined).
# Regenerates per-VM SSH host keys (ssh-keygen -A) and reconfigures sysstat.
# WITHOUT this, firstboot.service ExecStart fails, /root/firstboot_done is
# never created, and ssh.service's ConditionPathExists=/root/firstboot_done
# never passes -> socket-triggered sshd is skipped -> SSH unusable.
cp "$STAGE_DIR/firstboot.sh" "$root/root/firstboot.sh"
chmod 0755 "$root/root/firstboot.sh"
chown 0:0 "$root/root/firstboot.sh"

# base_file_permission: gshadow and shadow (setuid binaries handled separately)
chmod 0000 "$root/etc/gshadow" || true
chown root:root "$root/etc/gshadow" 2>/dev/null || true

chmod 0000 "$root/etc/shadow" || true
chown root:root "$root/etc/shadow" 2>/dev/null || true
```

- [ ] **Step 4: Syntax-check**

Run: `bash -n build/stages/systemd-services/apply.sh`
Expected: no output (exit 0)

- [ ] **Step 5: Commit**

```bash
git add build/stages/systemd-services/
git commit -m "Add systemd-services/ stage directory (apply.sh + extracted assets)"
```

---

### Task 10: `agent` stage

**Files:**
- Create: `build/stages/agent/apply.sh`
- Create: `build/stages/agent/monitrc`
- Create: `build/stages/agent/bosh-agent-rc`
- Create: `build/stages/agent/restart_networking`
- Create: `build/stages/agent/alerts.monitrc`
- Create: `build/stages/agent/bosh-agent.service`
- Create: `build/stages/agent/sync-time`

- [ ] **Step 1: Create the stage directory and extract heredoc bodies verbatim (including indentation — these live inside a Nix string today, do not reformat)**

Run:
```bash
mkdir -p build/stages/agent
sed -n '31,38p'   build/stages/agent.nix > build/stages/agent/monitrc
sed -n '48,60p'   build/stages/agent.nix > build/stages/agent/bosh-agent-rc
sed -n '66,67p'   build/stages/agent.nix > build/stages/agent/restart_networking
sed -n '73,90p'   build/stages/agent.nix > build/stages/agent/alerts.monitrc
sed -n '106,125p' build/stages/agent.nix > build/stages/agent/bosh-agent.service
sed -n '154,156p' build/stages/agent.nix > build/stages/agent/sync-time
```

- [ ] **Step 2: Verify**

Run: `wc -l build/stages/agent/*`
Expected: `monitrc`=8, `bosh-agent-rc`=13, `restart_networking`=2, `alerts.monitrc`=18, `bosh-agent.service`=20, `sync-time`=3.

- [ ] **Step 3: Write `build/stages/agent/apply.sh`**

`$BOSH_AGENT_BIN` and `$MONIT_BIN` are exported by `build/stages.nix` (Task 13) — Nix store paths to the source-built binaries.

```bash
# shellcheck shell=bash
# shellcheck disable=SC2148,SC2154,SC2016
# Reproduces the upstream `bosh_go_agent` stage using the source-built agent:
# binary + systemd unit + rc + monit alerts + agent.json placeholder +
# log symlink + cron/at hardening.
mkdir -p "$root/var/vcap/bosh/bin" "$root/var/vcap/bosh/etc" \
         "$root/var/vcap/bosh/log" "$root/var/vcap/monit" \
         "$root/lib/systemd/system"

# agent binary + monit-access hardlink
install -m 0755 "$BOSH_AGENT_BIN" "$root/var/vcap/bosh/bin/bosh-agent"
ln -f "$root/var/vcap/bosh/bin/bosh-agent" \
      "$root/var/vcap/bosh/etc/bosh-enable-monit-access"
# `install` leaves the binary owned by the build user; under fakeroot only
# explicit chowns record uid 0, so force root ownership (real stemcell has
# /var/vcap/bosh/bin/bosh-agent as root:root). The hardlink shares the inode.
chown 0:0 "$root/var/vcap/bosh/bin/bosh-agent"

# monit 5.2.5 (static): the process supervisor the agent drives over its
# 127.0.0.1:2822 HTTP interface. Reproduces bosh_monit stage:
#   - install the binary to /var/vcap/bosh/bin/monit
#   - install monitrc (0700) to /var/vcap/bosh/etc/monitrc
#   - seed /var/vcap/monit/empty.monitrc so monit's `include` glob is
#     non-empty (monit refuses to start otherwise)
install -m 0755 "$MONIT_BIN" "$root/var/vcap/bosh/bin/monit"
chown 0:0 "$root/var/vcap/bosh/bin/monit"

cp "$STAGE_DIR/monitrc" "$root/var/vcap/bosh/etc/monitrc"
chmod 0700 "$root/var/vcap/bosh/etc/monitrc"
chown 0:0 "$root/var/vcap/bosh/etc/monitrc"

touch "$root/var/vcap/monit/empty.monitrc"
chown 0:0 "$root/var/vcap/monit/empty.monitrc"

# bosh-agent-rc
cp "$STAGE_DIR/bosh-agent-rc" "$root/var/vcap/bosh/bin/bosh-agent-rc"
chmod 0755 "$root/var/vcap/bosh/bin/bosh-agent-rc"

# restart_networking helper
cp "$STAGE_DIR/restart_networking" "$root/var/vcap/bosh/bin/restart_networking"
chmod 0755 "$root/var/vcap/bosh/bin/restart_networking"

# monit alerts
cp "$STAGE_DIR/alerts.monitrc" "$root/var/vcap/monit/alerts.monitrc"
chmod 0600 "$root/var/vcap/monit/alerts.monitrc"
chown root:root "$root/var/vcap/monit/alerts.monitrc" 2>/dev/null || true

# empty agent conf (overwritten by openstack-agent-settings stage)
echo '{}' > "$root/var/vcap/bosh/agent.json"

# platform name consumed by bosh-agent.service `-P $(cat .../operating_system)`
echo 'ubuntu' > "$root/var/vcap/bosh/etc/operating_system"

# cache dir used by agent/init/create-env
mkdir -p "$root/var/vcap/micro_bosh/data/cache"

# bosh-agent.service (byte-faithful copy of stage asset)
cp "$STAGE_DIR/bosh-agent.service" "$root/lib/systemd/system/bosh-agent.service"

# enable bosh-agent.service (declarative wants + Alias symlinks)
mkdir -p "$root/lib/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/bosh-agent.service \
  "$root/lib/systemd/system/multi-user.target.wants/bosh-agent.service"
ln -sf /lib/systemd/system/bosh-agent.service \
  "$root/lib/systemd/system/agent.service"

# agent log symlink target (log file created at runtime)
ln -sf /var/log/bosh-agent.log "$root/var/vcap/bosh/log/current"

# cron/at hardening (bosh_go_agent chroot block)
rm -f "$root/etc/cron.deny" "$root/etc/at.deny"
echo 'vcap' > "$root/etc/cron.allow"
echo 'vcap' > "$root/etc/at.allow"
chmod -f og-rwx "$root/etc/at.allow" "$root/etc/cron.allow" \
  "$root/etc/crontab" "$root/etc/cron.hourly" "$root/etc/cron.daily" \
  "$root/etc/cron.weekly" "$root/etc/cron.monthly" "$root/etc/cron.d" \
  2>/dev/null || true
chown -f root:root "$root/etc/at.allow" "$root/etc/cron.allow" \
  "$root/etc/crontab" "$root/etc/cron.hourly" "$root/etc/cron.daily" \
  "$root/etc/cron.weekly" "$root/etc/cron.monthly" "$root/etc/cron.d" \
  2>/dev/null || true

# bosh_ntp/chrony: sync-time script (stig: V-38620 V-38621)
# Checked by both "every OS image installed binaries" and "an os with chrony" specs.
cp "$STAGE_DIR/sync-time" "$root/var/vcap/bosh/bin/sync-time"
chmod 0755 "$root/var/vcap/bosh/bin/sync-time"
chown 0:0 "$root/var/vcap/bosh/bin/sync-time" 2>/dev/null || true
```

- [ ] **Step 4: Syntax-check**

Run: `bash -n build/stages/agent/apply.sh`
Expected: no output (exit 0)

- [ ] **Step 5: Commit**

```bash
git add build/stages/agent/
git commit -m "Add agent/ stage directory (apply.sh + extracted assets)"
```

---

### Task 11: `blobstore-clis` stage

**Files:**
- Create: `build/stages/blobstore-clis/apply.sh` (no assets — pure `install` from env-var paths)

- [ ] **Step 1: Create the stage directory**

Run: `mkdir -p build/stages/blobstore-clis`

- [ ] **Step 2: Write `build/stages/blobstore-clis/apply.sh`**

`$DAVCLI_BIN`, `$S3CLI_BIN`, `$GCSCLI_BIN`, `$AZURE_STORAGE_CLI_BIN` are exported by `build/stages.nix` (Task 13).

```bash
# shellcheck shell=bash
# shellcheck disable=SC2148,SC2154,SC2016
# Reproduces the upstream `blobstore_clis` stage: install the four source-built
# CLIs into /var/vcap/bosh/bin as bosh-blobstore-<type>.
mkdir -p "$root/var/vcap/bosh/bin"

install -m 0755 "$DAVCLI_BIN"            "$root/var/vcap/bosh/bin/bosh-blobstore-dav"
install -m 0755 "$S3CLI_BIN"             "$root/var/vcap/bosh/bin/bosh-blobstore-s3"
install -m 0755 "$GCSCLI_BIN"            "$root/var/vcap/bosh/bin/bosh-blobstore-gcs"
install -m 0755 "$AZURE_STORAGE_CLI_BIN" "$root/var/vcap/bosh/bin/bosh-blobstore-azure-storage"
```

- [ ] **Step 3: Syntax-check**

Run: `bash -n build/stages/blobstore-clis/apply.sh`
Expected: no output (exit 0)

- [ ] **Step 4: Commit**

```bash
git add build/stages/blobstore-clis/
git commit -m "Add blobstore-clis/ stage directory (apply.sh)"
```

---

### Task 12: `openstack-agent-settings` stage

**Files:**
- Create: `build/stages/openstack-agent-settings/apply.sh`
- Create: `build/stages/openstack-agent-settings/agent.json`

- [ ] **Step 1: Create the stage directory and extract heredoc body**

Run:
```bash
mkdir -p build/stages/openstack-agent-settings
sed -n '5,45p' build/stages/openstack-agent-settings.sh > build/stages/openstack-agent-settings/agent.json
```

- [ ] **Step 2: Verify**

Run: `wc -l build/stages/openstack-agent-settings/agent.json`
Expected: 41 lines.

- [ ] **Step 3: Write `build/stages/openstack-agent-settings/apply.sh`**

```bash
# shellcheck shell=bash
# shellcheck disable=SC2148,SC2154,SC2016
mkdir -p "$root/var/vcap/bosh"
cp "$STAGE_DIR/agent.json" "$root/var/vcap/bosh/agent.json"
```

- [ ] **Step 4: Syntax-check**

Run: `bash -n build/stages/openstack-agent-settings/apply.sh`
Expected: no output (exit 0)

- [ ] **Step 5: Commit**

```bash
git add build/stages/openstack-agent-settings/
git commit -m "Add openstack-agent-settings/ stage directory (apply.sh + extracted assets)"
```

---

### Task 13: Create `build/stages.nix` and wire it into `os-image.nix`

**Files:**
- Create: `build/stages.nix`
- Modify: `build/rootfs/os-image.nix`

- [ ] **Step 1: Write `build/stages.nix`**

```nix
# Ordered stage list + the generic stage-builder helper. Every stage is a
# directory under ./stages/<name>/ containing a plain apply.sh (and any
# extracted asset files it copies into place). Stages are pure file
# operations only -- no network access (enforced at runtime by
# lib/hermetic-guard.sh in apply-stages.nix).
{ callPackage, lib }:
let
  # env: attrset of SHELL_VAR_NAME -> nix expression coercible to a string
  # (typically a Nix store path built via `${pkg}/bin/foo`), exported before
  # apply.sh runs. STAGE_DIR is always exported (as a real Nix store path,
  # via `"${stageDir}"` interpolation, NOT `toString`, so it's copied into
  # the store and stays visible inside the build sandbox) so apply.sh can
  # reference its own sibling asset files.
  mkStage =
    { name, env ? { } }:
    let
      stageDir = ./stages + "/${name}";
    in
    {
      inherit name;
      script = ''
        export STAGE_DIR=${lib.escapeShellArg "${stageDir}"}
        ${lib.concatStrings (
          lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg (toString v)}\n") env
        )}
        ${builtins.readFile (stageDir + "/apply.sh")}
      '';
    };

  bosh-agent = callPackage ./pkgs/bosh-agent.nix { };
  monit = callPackage ./pkgs/monit.nix { };
  blob = callPackage ./pkgs/blobstore-clis.nix { };
in
[
  (mkStage { name = "users"; })
  (mkStage { name = "ssh"; })
  (mkStage { name = "sysctl-limits-env"; })
  (mkStage { name = "sudoers-pam"; })
  (mkStage { name = "rsyslog"; })
  (mkStage { name = "audit"; })
  (mkStage { name = "misc-os"; })
  (mkStage { name = "systemd-services"; })
  (mkStage {
    name = "agent";
    env = {
      BOSH_AGENT_BIN = "${bosh-agent}/bin/main";
      MONIT_BIN = "${monit}/bin/monit";
    };
  })
  (mkStage {
    name = "blobstore-clis";
    env = {
      DAVCLI_BIN = "${blob.davcli}/bin/davcli";
      S3CLI_BIN = "${blob.s3cli}/bin/bosh-s3cli";
      GCSCLI_BIN = "${blob.gcscli}/bin/bosh-gcscli";
      AZURE_STORAGE_CLI_BIN = "${blob.azureStorageCli}/bin/bosh-azure-storage-cli";
    };
  })
  (mkStage { name = "openstack-agent-settings"; })
]
```

- [ ] **Step 2: Update `build/rootfs/os-image.nix`**

Current content (`build/rootfs/os-image.nix`):
```nix
# PHASE 1 OS image: fold every config stage onto the noble rootfs closure.
# The ordered stage list lives in ../stages/default.nix.
{ callPackage }:
let
  applyStages = callPackage ./apply-stages.nix { };
  base = callPackage ./rootfs.nix { };
  stages = callPackage ../stages/default.nix { };
in
applyStages { inherit base stages; }
```

New content:
```nix
# PHASE 1 OS image: fold every config stage onto the noble rootfs closure.
# The ordered stage list lives in ../stages.nix.
{ callPackage }:
let
  applyStages = callPackage ./apply-stages.nix { };
  base = callPackage ./rootfs.nix { };
  stages = callPackage ../stages.nix { };
in
applyStages { inherit base stages; }
```

Use the Edit tool to change:
- The comment `# The ordered stage list lives in ../stages/default.nix.` → `# The ordered stage list lives in ../stages.nix.`
- `stages = callPackage ../stages/default.nix { };` → `stages = callPackage ../stages.nix { };`

- [ ] **Step 3: Build os-image with the new stages.nix (old stage files still present but no longer referenced)**

Run: `nix build .#os-image --print-out-paths --no-link`
Expected: succeeds, prints a `/nix/store/...` path. If it fails, read the error — it is almost always a missing/misnamed `apply.sh` or asset file from Tasks 2–12.

- [ ] **Step 4: Compare the new build's rootfs.tar.gz hash to the Task 1 baseline**

Run:
```bash
out="$(nix build .#os-image --print-out-paths --no-link)"
sha256sum "$out/rootfs.tar.gz"
diff <(sha256sum "$out/rootfs.tar.gz" | cut -d' ' -f1) <(cut -d' ' -f1 /tmp/opencode/baseline-os-image.sha256)
```
Expected: `diff` prints nothing (hashes match exactly). **If the hashes differ, do not proceed** — go back and find which stage's extraction introduced a difference (bisect by temporarily reverting `os-image.nix` to point at the old `../stages/default.nix` and rebuilding to reconfirm the baseline, then re-check each new stage directory's content against the `sed` ranges above).

- [ ] **Step 5: Commit**

```bash
git add build/stages.nix build/rootfs/os-image.nix
git commit -m "Wire build/stages.nix into os-image.nix"
```

---

### Task 14: Delete superseded files

**Files:**
- Delete: `build/stages/default.nix`
- Delete: `build/lib/mkStage.nix`
- Delete: `build/stages/{users,ssh,sysctl-limits-env,sudoers-pam,rsyslog,audit,misc-os,systemd-services}.nix` (8 files)
- Delete: `build/stages/{users,ssh,sysctl-limits-env,sudoers-pam,rsyslog,audit,misc-os,systemd-services}.sh` (8 files)
- Delete: `build/stages/agent.nix`
- Delete: `build/stages/blobstore-clis.nix`
- Delete: `build/stages/debug-ssh-keys.nix`
- Delete: `build/stages/debug-ssh-root-login.nix`
- Delete: `build/stages/debug-ssh-root-login.sh`

- [ ] **Step 1: Delete the superseded stage wrapper/flat files and the old helper/list**

Run:
```bash
git rm build/stages/default.nix
git rm build/lib/mkStage.nix
git rm build/stages/users.nix build/stages/users.sh
git rm build/stages/ssh.nix build/stages/ssh.sh
git rm build/stages/sysctl-limits-env.nix build/stages/sysctl-limits-env.sh
git rm build/stages/sudoers-pam.nix build/stages/sudoers-pam.sh
git rm build/stages/rsyslog.nix build/stages/rsyslog.sh
git rm build/stages/audit.nix build/stages/audit.sh
git rm build/stages/misc-os.nix build/stages/misc-os.sh
git rm build/stages/systemd-services.nix build/stages/systemd-services.sh
git rm build/stages/agent.nix
git rm build/stages/blobstore-clis.nix
git rm build/stages/debug-ssh-keys.nix
git rm build/stages/debug-ssh-root-login.nix build/stages/debug-ssh-root-login.sh
```

- [ ] **Step 2: Confirm no remaining references to the deleted files**

Run: `grep -rn "stages/default.nix\|lib/mkStage.nix\|debug-ssh" build/ flake.nix`
Expected: no matches (empty output).

- [ ] **Step 3: Rebuild and re-verify byte-identical output**

Run:
```bash
out="$(nix build .#os-image --print-out-paths --no-link)"
diff <(sha256sum "$out/rootfs.tar.gz" | cut -d' ' -f1) <(cut -d' ' -f1 /tmp/opencode/baseline-os-image.sha256)
```
Expected: no output (still matches baseline — confirms the deletions didn't break anything the build silently depended on).

- [ ] **Step 4: Commit**

```bash
git commit -m "Delete superseded stage files (old wrappers, flat scripts, mkStage.nix, debug stages)"
```

---

### Task 15: Update `flake.nix` shfmt excludes

**Files:**
- Modify: `flake.nix:29`

- [ ] **Step 1: Update the exclude glob**

Use the Edit tool on `flake.nix`:
- Old: `settings.formatter.shfmt.excludes = [ "build/stages/*.sh" ];`
- New: `settings.formatter.shfmt.excludes = [ "build/stages/*/apply.sh" ];`

- [ ] **Step 2: Validate the flake still evaluates**

Run: `nix flake check`
Expected: succeeds (no evaluation errors). Note: this may take a while if it also builds checks; that's fine.

- [ ] **Step 3: Run treefmt to confirm formatting/linting passes on the new files**

Run: `nix fmt`
Expected: exits 0; `git status` afterward shows no unexpected reformatting of unrelated files (some `apply.sh` files may get shfmt-reformatted for the first time — that's expected and fine, since these are now real standalone scripts).

- [ ] **Step 4: If treefmt reformatted any apply.sh files, re-verify byte-identical output (whitespace-only script changes must not affect the built rootfs)**

Run:
```bash
out="$(nix build .#os-image --print-out-paths --no-link)"
diff <(sha256sum "$out/rootfs.tar.gz" | cut -d' ' -f1) <(cut -d' ' -f1 /tmp/opencode/baseline-os-image.sha256)
```
Expected: no output (still matches baseline).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Update flake.nix shfmt excludes for per-stage apply.sh layout"
```

---

### Task 16: Update living docs (`ARCHITECTURE.md`, `README.md`)

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `README.md`

- [ ] **Step 1: Fix the Configuration Stages list in `docs/ARCHITECTURE.md`**

Use the Edit tool to replace the block at `docs/ARCHITECTURE.md` (currently lines 444–460):

Old:
```markdown
## Configuration Stages

After the base filesystem is assembled, 11 configuration stages are applied in a **single fakeroot session** (avoiding expensive re-extractions):

1. **SSH Configuration** — [`build/stages/ssh.nix`](../build/stages/ssh.nix) — server keys, sshd_config
2. **Sudoers Setup** — [`build/stages/sudoers-pam.sh`](../build/stages/sudoers-pam.sh) — vcap user with passwordless sudo
3. **Audit Daemon** — [`build/stages/audit.sh`](../build/stages/audit.sh) — auditd rules and logging
4. **Systemd Units** — [`build/stages/systemd-services.nix`](../build/stages/systemd-services.nix) — BOSH agent service, monitoring
5. **Hardening** — [`build/stages/sysctl-limits-env.nix`](../build/stages/sysctl-limits-env.nix) — sysctl, kernel parameters
6. **Package Lists** — [`build/stages/misc-os.sh`](../build/stages/misc-os.sh) — packages.txt, dev_tools_file_list.txt, SBOM
7. **Locale & Timezone** — [`build/stages/misc-os.sh`](../build/stages/misc-os.sh) — en_US.UTF-8, UTC
8. **Hostname & Network** — [`build/stages/misc-os.sh`](../build/stages/misc-os.sh) — dhclient, hostname resolution
9. **OpenStack Agent Settings** — [`build/stages/openstack-agent-settings.nix`](../build/stages/openstack-agent-settings.nix) — OpenStack-specific cloud-init
10. **User Accounts** — [`build/stages/users.nix`](../build/stages/users.nix) — root, vcap, bosh_ssh_* users
11. **Debug SSH** — [`build/stages/debug-ssh-root-login.nix`](../build/stages/debug-ssh-root-login.nix) — diagnostic SSH access

Orchestrated by: [`build/stages/default.nix`](../build/stages/default.nix) and [`build/rootfs/apply-stages.nix`](../build/rootfs/apply-stages.nix)
```

New:
```markdown
## Configuration Stages

After the base filesystem is assembled, 11 configuration stages are applied in a **single fakeroot session** (avoiding expensive re-extractions). Each stage is a directory under `build/stages/<name>/` containing a plain `apply.sh` (no Nix syntax, no heredocs) plus any static asset files it copies into place:

1. **User Accounts** — [`build/stages/users/`](../build/stages/users/) — /etc/group, /etc/passwd, /etc/shadow, /etc/gshadow, BOSH command prompt
2. **SSH Configuration** — [`build/stages/ssh/`](../build/stages/ssh/) — sshd_config hardening, host keys, login banner
3. **Kernel/Limits Hardening** — [`build/stages/sysctl-limits-env/`](../build/stages/sysctl-limits-env/) — sysctl, ulimits, /etc/environment PATH
4. **Sudoers + PAM** — [`build/stages/sudoers-pam/`](../build/stages/sudoers-pam/) — vcap passwordless sudo, PAM hardening
5. **Rsyslog** — [`build/stages/rsyslog/`](../build/stages/rsyslog/) — rsyslog.conf, logrotate, journald/rsyslog systemd overrides
6. **Audit Daemon** — [`build/stages/audit/`](../build/stages/audit/) — auditd rules and logging
7. **Misc OS Tweaks** — [`build/stages/misc-os/`](../build/stages/misc-os/) — grub placeholders, apt sources, cron/machine-id cleanup
8. **Systemd Units** — [`build/stages/systemd-services/`](../build/stages/systemd-services/) — monit.service, chrony/resolved overrides, firstboot
9. **BOSH Agent** — [`build/stages/agent/`](../build/stages/agent/) — agent + monit binaries, systemd unit, cron/at hardening
10. **Blobstore CLIs** — [`build/stages/blobstore-clis/`](../build/stages/blobstore-clis/) — davcli/s3cli/gcscli/azure-storage-cli
11. **OpenStack Agent Settings** — [`build/stages/openstack-agent-settings/`](../build/stages/openstack-agent-settings/) — OpenStack-specific agent.json

Orchestrated by: [`build/stages.nix`](../build/stages.nix) and [`build/rootfs/apply-stages.nix`](../build/rootfs/apply-stages.nix)
```

- [ ] **Step 2: Fix the repo file-tree section in `docs/ARCHITECTURE.md`**

Use the Edit tool to replace (currently around lines 599–625):

Old:
```markdown
│   │   └── apply-stages.nix           # Stage application (single fakeroot session)
│   ├── stages/
│   │   ├── default.nix                # Stage orchestration
│   │   ├── ssh.nix                    # SSH key generation and config
│   │   ├── sudoers-pam.sh             # Sudoers and PAM setup
│   │   ├── audit.sh                   # Audit daemon configuration
│   │   ├── systemd-services.nix       # Systemd unit definitions
│   │   ├── sysctl-limits-env.nix      # Kernel parameters and limits
│   │   ├── misc-os.sh                 # Packages.txt, SBOM, locale, network
│   │   ├── openstack-agent-settings.nix  # OpenStack cloud-init
│   │   ├── users.nix                  # User account creation
│   │   ├── debug-ssh-root-login.nix   # Debug SSH access
│   │   └── blobstore-clis.nix         # Blobstore tools (S3, Azure, etc.)
│   ├── stemcells/
```

New:
```markdown
│   │   └── apply-stages.nix           # Stage application (single fakeroot session)
│   ├── stages.nix                     # Ordered stage list + mkStage helper (all Nix boilerplate)
│   ├── stages/
│   │   ├── users/                     # apply.sh + /etc/{group,passwd,shadow,gshadow}, ps1
│   │   ├── ssh/                       # apply.sh + sshd firstboot drop-in, securetty
│   │   ├── sysctl-limits-env/         # apply.sh + sysctl.d configs
│   │   ├── sudoers-pam/               # apply.sh + bosh_sudoers
│   │   ├── rsyslog/                   # apply.sh + rsyslog.conf, logrotate, systemd overrides
│   │   ├── audit/                     # apply.sh + audit.rules, auditd overrides
│   │   ├── misc-os/                   # apply.sh + apt periodic/sources.list
│   │   ├── systemd-services/          # apply.sh + monit/chrony/resolved/firstboot units
│   │   ├── agent/                     # apply.sh + monitrc, bosh-agent-rc, bosh-agent.service
│   │   ├── blobstore-clis/            # apply.sh (no assets; env-var store paths only)
│   │   └── openstack-agent-settings/  # apply.sh + agent.json
│   ├── stemcells/
```

- [ ] **Step 3: Fix `mkStage.nix` reference in `docs/ARCHITECTURE.md`**

Use the Edit tool:
- Old: `│       ├── mkStage.nix                # Stage composition utilities`
- New: (delete this line entirely — `mkStage` now lives inside `build/stages.nix`, not `build/lib/`)

- [ ] **Step 4: Fix the two remaining table references in `docs/ARCHITECTURE.md`**

Use the Edit tool:
- Old: `| Stage defs | [`build/stages/default.nix`](../build/stages/default.nix) | All | Enumerate all 11 stages |`
- New: `| Stage defs | [`build/stages.nix`](../build/stages.nix) | All | Enumerate all 11 stages |`

- [ ] **Step 5: Fix `README.md`'s `build/stages/` row**

Use the Edit tool on `README.md`:
- Old: `| `build/stages/` | Post-unpack filesystem stages (ssh, sudoers/pam, audit, rsyslog, sysctl, systemd services, users, agent, OpenStack agent settings, blobstore CLIs) mirroring the upstream shell stage names. |`
- New: `| `build/stages.nix` + `build/stages/` | Single-file Nix boilerplate (`stages.nix`) plus one directory per stage (`stages/<name>/apply.sh` + extracted asset files) — ssh, sudoers/pam, audit, rsyslog, sysctl, systemd services, users, agent, OpenStack agent settings, blobstore CLIs. |`

- [ ] **Step 6: Confirm no stale references remain**

Run: `grep -rn "stages/default.nix\|lib/mkStage.nix\|debug-ssh" docs/ARCHITECTURE.md README.md`
Expected: no matches (empty output).

- [ ] **Step 7: Commit**

```bash
git add docs/ARCHITECTURE.md README.md
git commit -m "Update ARCHITECTURE.md and README.md for the stages.nix + per-stage directory layout"
```

---

### Task 17: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Full os-image byte-identical re-check against the Task 1 baseline**

Run:
```bash
out="$(nix build .#os-image --print-out-paths --no-link)"
diff <(sha256sum "$out/rootfs.tar.gz" | cut -d' ' -f1) <(cut -d' ' -f1 /tmp/opencode/baseline-os-image.sha256)
echo "os-image byte-identical: OK"
```
Expected: no diff output, "OK" printed.

- [ ] **Step 2: Double-build determinism gate**

Run: `scripts/byte-check-osimage.sh`
Expected: `REPRODUCIBLE: os-image (rootfs.tar.gz) is byte-identical`

- [ ] **Step 3: `nix flake check`**

Run: `nix flake check`
Expected: succeeds.

- [ ] **Step 4: Hermeticity spot-check — confirm no network verbs were introduced in any new apply.sh**

Run:
```bash
grep -rniE "curl|wget|apt-get|apt |dpkg |http://|https://" build/stages/*/apply.sh || echo "clean: no network verbs found"
```
Expected: `clean: no network verbs found`. (The `openstack-agent-settings/agent.json` asset file legitimately contains `"URI": "http://169.254.169.254"` as *config content*, not a stage invoking network access — that's expected and fine; this grep only scans `apply.sh` files, not asset files, so it won't false-positive on that.)

- [ ] **Step 5: Full stemcell byte-identical check (optional but recommended — matches the design doc's stated bar; this rebuilds through the VM-based disk step and will take noticeably longer)**

Run:
```bash
nix build .#noble-stemcell --print-out-paths --no-link
scripts/byte-check-stemcell.sh
```
Expected: both succeed; `byte-check-stemcell.sh` reports `REPRODUCIBLE: noble-stemcell (bosh-stemcell-*.tgz) is byte-identical`.

- [ ] **Step 6: Confirm working tree is clean**

Run: `git status --porcelain`
Expected: empty output (everything already committed in prior tasks).

- [ ] **Step 7: Review full commit history for this refactor**

Run: `git log --oneline -20`
Expected: shows the sequence of per-stage commits, the stages.nix wiring commit, the deletion commit, the flake.nix commit, and the docs commit — all with clear, individually-revertable messages.

No further commit needed for this task (verification only).
