#!/bin/bash
set -eu

# $root is exported by build/rootfs/apply-stages.nix (the rootfs tree target).
# shellcheck disable=SC2154

# Configure sudoers and PAM hardening inside the rootfs tree ("$root").

# bosh_sudoers: Append includedir to sudoers and create bosh_sudoers sudoers.d file
# Also add the rule directly to /etc/sudoers so that spec tests checking
# /etc/sudoers content (not just the included directory) find the rule.
echo '%bosh_sudoers ALL=(ALL) NOPASSWD: ALL' >>"$root/etc/sudoers"
echo '#includedir /etc/sudoers.d' >>"$root/etc/sudoers"
mkdir -p "$root/etc/sudoers.d"
cp "$STAGE_DIR"/bosh_sudoers "$root/etc/sudoers.d/bosh_sudoers"
chmod 0440 "$root/etc/sudoers.d/bosh_sudoers"

# restrict_su_command: Add pam_wheel.so use_uid to /etc/pam.d/su
echo 'auth required pam_wheel.so use_uid' >>"$root/etc/pam.d/su"

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
