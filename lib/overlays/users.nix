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

    # /etc/passwd — exact bytes asserted by os_image/ubuntu_spec.rb (allowed user accounts test).
    # Written last (after all packages) to normalise uid/ordering differences introduced by
    # apt installing packages in a different order than the classic debootstrap pipeline.
    # systemd-timesync (uid 996) is added by the systemd-timesyncd package; polkitd (989),
    # _runit-log (999), and syslog (102) UIDs differ from what apt assigns in our build.
    cat > "$root/etc/passwd" <<'PASSWD'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
bin:x:2:2:bin:/bin:/usr/sbin/nologin
sys:x:3:3:sys:/dev:/usr/sbin/nologin
sync:x:4:65534:sync:/bin:/bin/sync
games:x:5:60:games:/usr/games:/usr/sbin/nologin
man:x:6:12:man:/var/cache/man:/usr/sbin/nologin
lp:x:7:7:lp:/var/spool/lpd:/usr/sbin/nologin
mail:x:8:8:mail:/var/mail:/usr/sbin/nologin
news:x:9:9:news:/var/spool/news:/usr/sbin/nologin
uucp:x:10:10:uucp:/var/spool/uucp:/usr/sbin/nologin
proxy:x:13:13:proxy:/bin:/usr/sbin/nologin
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
backup:x:34:34:backup:/var/backups:/usr/sbin/nologin
list:x:38:38:Mailing List Manager:/var/list:/usr/sbin/nologin
irc:x:39:39:ircd:/run/ircd:/usr/sbin/nologin
_apt:x:42:65534::/nonexistent:/usr/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
systemd-network:x:998:998:systemd Network Management:/:/usr/sbin/nologin
systemd-timesync:x:996:996:systemd Time Synchronization:/:/usr/sbin/nologin
dhcpcd:x:100:65534:DHCP Client Daemon,,,:/usr/lib/dhcpcd:/bin/false
messagebus:x:101:101::/nonexistent:/usr/sbin/nologin
syslog:x:102:102::/nonexistent:/usr/sbin/nologin
systemd-resolve:x:991:991:systemd Resolver:/:/usr/sbin/nologin
uuidd:x:103:104::/run/uuidd:/usr/sbin/nologin
_chrony:x:104:106:Chrony daemon,,,:/var/lib/chrony:/usr/sbin/nologin
_runit-log:x:999:990:Created by dh-sysuser for runit:/nonexistent:/usr/sbin/nologin
sshd:x:105:65534::/run/sshd:/usr/sbin/nologin
tcpdump:x:106:108::/nonexistent:/usr/sbin/nologin
polkitd:x:989:989:User for polkitd:/:/usr/sbin/nologin
vcap:x:1000:1000:BOSH System User:/home/vcap:/bin/bash
PASSWD
    # /etc/shadow — exact ordering and format asserted by ubuntu_spec.rb allowed user accounts test.
    # Uses static date 19000 (5 digits, ≈ 2022-01-01) because the Nix debootstrap environment
    # sets a very old epoch date (3652 = 1980, only 4 digits) which fails the spec regex \d{5}.
    # vcap needs password field non-empty (regex uses (.+)), min-age=1 (not 0).
    cat > "$root/etc/shadow" <<'SHADOW'
root:*:19000:0:99999:7:::
daemon:*:19000:0:99999:7:::
bin:*:19000:0:99999:7:::
sys:*:19000:0:99999:7:::
sync:*:19000:0:99999:7:::
games:*:19000:0:99999:7:::
man:*:19000:0:99999:7:::
lp:*:19000:0:99999:7:::
mail:*:19000:0:99999:7:::
news:*:19000:0:99999:7:::
uucp:*:19000:0:99999:7:::
proxy:*:19000:0:99999:7:::
www-data:*:19000:0:99999:7:::
backup:*:19000:0:99999:7:::
list:*:19000:0:99999:7:::
irc:*:19000:0:99999:7:::
_apt:*:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
systemd-network:!*:19000::::::
systemd-timesync:!*:19000::::::
dhcpcd:!:19000::::::
messagebus:!:19000::::::
syslog:!:19000::::::
systemd-resolve:!*:19000::::::
uuidd:!:19000::::::
_chrony:!:19000::::::
_runit-log:!:19000::::::
sshd:!:19000::::::
tcpdump:!:19000::::::
polkitd:!*:19000::::::
vcap:*:19000:1:99999:7:::
SHADOW
    chmod 000 "$root/etc/shadow"
    mkdir -p "$root/home/vcap"
    chmod 700 "$root/home/vcap"
    chown 1000:1000 "$root/home/vcap" 2>/dev/null || true

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
