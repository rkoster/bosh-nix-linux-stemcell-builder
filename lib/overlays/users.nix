# bosh_users stage: declarative passwd/group/gshadow + vcap home + bashrc + ps1 sourcing.
# Reproduces stemcell_builder/stages/bosh_users/apply.sh by writing exact /etc/group,
# /etc/gshadow from the os_image spec, appending vcap+root to passwd/shadow, creating
# /home/vcap (700), and sourcing the ps1 asset + PATH export in bashrc/profile.
# Assets are inlined for reproducibility (nested git repo access not available in Nix sandbox).
{}:
{
  name = "users";
  script = ''
    # /etc/group — exact bytes asserted by os_image/ubuntu_spec.rb (lines 413–477)
    cat > "$root/etc/group" <<'GROUP'
root:x:0:
daemon:x:1:
bin:x:2:
sys:x:3:
adm:x:4:vcap
tty:x:5:syslog
disk:x:6:
lp:x:7:
mail:x:8:
news:x:9:
uucp:x:10:
man:x:12:
proxy:x:13:
kmem:x:15:
dialout:x:20:vcap
fax:x:21:
voice:x:22:
cdrom:x:24:vcap
floppy:x:25:vcap
tape:x:26:
sudo:x:27:vcap
audio:x:29:vcap
dip:x:30:vcap
www-data:x:33:
backup:x:34:
operator:x:37:
list:x:38:
irc:x:39:
src:x:40:
shadow:x:42:
utmp:x:43:
video:x:44:vcap
sasl:x:45:
plugdev:x:46:vcap
staff:x:50:
games:x:60:
users:x:100:
nogroup:x:65534:
systemd-journal:x:999:
systemd-network:x:998:
crontab:x:997:
systemd-timesync:x:996:
input:x:995:
sgx:x:994:
kvm:x:993:
render:x:992:
messagebus:x:101:
syslog:x:102:
systemd-resolve:x:991:
netdev:x:103:
uuidd:x:104:
_ssh:x:105:
_chrony:x:106:
_runit-log:x:990:
rdma:x:107:
tcpdump:x:108:
polkitd:x:989:
admin:x:988:vcap
vcap:x:1000:syslog
bosh_sshers:x:1001:vcap
bosh_sudoers:x:1002:
GROUP

    # /etc/gshadow — exact bytes asserted by os_image/ubuntu_spec.rb (lines 479–543)
    cat > "$root/etc/gshadow" <<'GSHADOW'
root:*::
daemon:*::
bin:*::
sys:*::
adm:*::vcap
tty:*::syslog
disk:*::
lp:*::
mail:*::
news:*::
uucp:*::
man:*::
proxy:*::
kmem:*::
dialout:*::vcap
fax:*::
voice:*::
cdrom:*::vcap
floppy:*::vcap
tape:*::
sudo:*::vcap
audio:*::vcap
dip:*::vcap
www-data:*::
backup:*::
operator:*::
list:*::
irc:*::
src:*::
shadow:*::
utmp:*::
video:*::vcap
sasl:*::
plugdev:*::vcap
staff:*::
games:*::
users:*::
nogroup:*::
systemd-journal:!*::
systemd-network:!*::
crontab:!*::
systemd-timesync:!*::
input:!*::
sgx:!*::
kvm:!*::
render:!*::
messagebus:!::
syslog:!::
systemd-resolve:!*::
netdev:!::
uuidd:!::
_ssh:!::
_chrony:!::
_runit-log:!::
rdma:!::
tcpdump:!::
polkitd:!*::
admin:!::vcap
vcap:!::syslog
bosh_sshers:!::vcap
bosh_sudoers:!::
GSHADOW

    # vcap user (uid/gid 1000), home 700
    grep -q '^vcap:' "$root/etc/passwd" || \
      echo 'vcap:x:1000:1000:BOSH System User:/home/vcap:/bin/bash' >> "$root/etc/passwd"
    grep -q '^vcap:' "$root/etc/shadow" || \
      echo 'vcap:!:19000:0:99999:7:::' >> "$root/etc/shadow"
    mkdir -p "$root/home/vcap"
    chmod 700 "$root/home/vcap"

    # Inline ps1 asset (from bosh_users/assets/ps1.sh; inlined for reproducibility)
    mkdir -p "$root/etc/profile.d"
    cat > "$root/etc/profile.d/00-bosh-ps1" << 'PS1'
#!/bin/sh

# only if interactive
[ ! -z "$PS1" ] || return

bosh_instance="$( cat /var/vcap/instance/name )/$( cat /var/vcap/instance/id )"

PS1="$bosh_instance:\\w\\\$ "

unset bosh_instance
PS1

    # Update bashrc + profile for root, vcap, and skel
    for home in "$root/root" "$root/home/vcap" "$root/etc/skel"; do
      mkdir -p "$home"
      printf 'export PATH=/var/vcap/bosh/bin:$PATH\nsource /etc/profile.d/00-bosh-ps1\n' >> "$home/.bashrc"
    done
    grep -q '.bashrc' "$root/root/.profile" 2>/dev/null || \
      printf '\n. ~/.bashrc\n' >> "$root/root/.profile"
  '';
}
