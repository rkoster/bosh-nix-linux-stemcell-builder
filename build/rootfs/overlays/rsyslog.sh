# shellcheck shell=bash
# shellcheck disable=SC2148,SC2154,SC2016
    # Create /etc/rsyslog.conf with the main rsyslog configuration
    cat > "$root/etc/rsyslog.conf" <<'RSYSLOGCONF'
#  /etc/rsyslog.conf	Configuration file for rsyslog.
#
#			For more information see
#			/usr/share/doc/rsyslog-doc/html/rsyslog_conf.html
#
#  Default logging rules can be found in /etc/rsyslog.d/50-default.conf


#################
#### MODULES ####
#################

$ModLoad imuxsock # provides support for local system logging
# # The default path to the syslog socket provided by journald:
$SystemLogSocketName /run/systemd/journal/syslog

$ModLoad imklog   # provides kernel logging support (previously done by rklogd)
module( load="omrelp" tls.tlslib="openssl" )
#$ModLoad immark  # provides --MARK-- message capability

# provides UDP syslog reception
#$ModLoad imudp
#$UDPServerRun 514

# provides TCP syslog reception
#$ModLoad imtcp
#$InputTCPServerRun 514


###########################
#### GLOBAL DIRECTIVES ####
###########################

#
# Use traditional timestamp format.
# To enable high precision timestamps, comment out the following line.
#
$ActionFileDefaultTemplate RSYSLOG_FileFormat

# Filter duplicated messages
$RepeatedMsgReduction on

$MaxMessageSize 4k
#
# Set the default permissions for all log files.
#
$FileOwner syslog
$FileGroup syslog
$FileCreateMode 0600
$DirCreateMode 0755
$Umask 0022
$PrivDropToUser syslog
$PrivDropToGroup syslog

#
# Include all config files in /etc/rsyslog.d/
#
$IncludeConfig /etc/rsyslog.d/*.conf
RSYSLOGCONF

    # Clear any default rsyslog.d contents and create the directory
    if [ -d "$root/etc/rsyslog.d" ]; then
      rm -rf "$root/etc/rsyslog.d"/*
    else
      mkdir -p "$root/etc/rsyslog.d"
    fi

    # Create /etc/rsyslog.d/50-default.conf
    cat > "$root/etc/rsyslog.d/50-default.conf" <<'RSYSLOGDEFAULT'
#  Default rules for rsyslog.
#
#			For more information see rsyslog.conf(5) and /etc/rsyslog.conf

#
# First some standard log files.  Log by facility.
#
auth,authpriv.*			/var/log/auth.log
*.*;auth,authpriv.none		/var/log/syslog
#syslog.*                        /var/log/rsyslog.log #rsyslog error messages
cron.*				/var/log/cron.log
daemon.*			/var/log/daemon.log
kern.*				/var/log/kern.log
#lpr.*				/var/log/lpr.log
#mail.*				/var/log/mail.log
#user.*				/var/log/user.log

#
# Logging for the mail system.  Split it up so that
# it is easy to write scripts to parse these files.
#
#mail.info			/var/log/mail.info
#mail.warn			/var/log/mail.warn
#mail.err			/var/log/mail.err

#
# Logging for INN news system.
#
#news.crit			/var/log/news/news.crit
#news.err			/var/log/news/news.err
#news.notice			/var/log/news/news.notice

#
# Some "catch-all" log files.
#
#*.=debug;\
#	auth,authpriv.none;\
#	news.none;mail.none	/var/log/debug
#*.=info;*.=notice;*.=warn;\
#	auth,authpriv.none;\
#	cron,daemon.none;\
#	mail,news.none		/var/log/messages

#
# Emergencies are sent to everybody logged in.
#
*.emerg                                :omusrmsg:*

#
# I like to have messages displayed on the console, but only on a virtual
# console I usually leave idle.
#
#daemon,mail.*;\
#	news.=crit;news.=err;news.=notice;\
#	*.=debug;*.=info;\
#	*.=notice;*.=warn	/dev/tty8

# The named pipe /dev/xconsole is for the `xconsole' utility.  To use it,
# you must invoke `xconsole' with the `-file' option:
#
#    $ xconsole -file /dev/xconsole [...]
#
# NOTE: adjust the list below, or you'll go crazy if you have a reasonably
#      busy site..
#
#
# As this functionality is almost never needed, it is commented out. If you
# need it, be sure to remove the comment characters below.
#daemon.*;mail.*;\
#	news.err;\
#	*.=debug;*.=info;\
#	*.=notice;*.=warn	|/dev/xconsole
RSYSLOGDEFAULT

    # Create /etc/rsyslog.d/90-bosh-agent.conf
    cat > "$root/etc/rsyslog.d/90-bosh-agent.conf" <<'RSYSLOGBOSH'
if $programname == 'bosh-agent' then
/var/log/bosh-agent.log
& stop
RSYSLOGBOSH

    # Create /etc/logrotate.d/rsyslog
    mkdir -p "$root/etc/logrotate.d"
    cat > "$root/etc/logrotate.d/rsyslog" <<'LOGROTATE'
/var/log/syslog
{
	su syslog syslog
	rotate 7
	nodateext
	size 5M
	missingok
	notifempty
	delaycompress
	compress
	postrotate
		sudo systemctl kill -s HUP rsyslog.service
	endscript
}

/var/log/daemon.log
/var/log/kern.log
/var/log/auth.log
/var/log/cron.log
{
	su syslog syslog
	rotate 4
	nodateext
	size 5M
	missingok
	notifempty
	compress
	delaycompress
	sharedscripts
	postrotate
		sudo systemctl kill -s HUP rsyslog.service
	endscript
}

/var/log/bosh-agent.log {
	rotate 4
	nodateext
	size 5M
	missingok
	notifempty
	compress
	delaycompress
	sharedscripts
	postrotate
		sudo systemctl kill -s HUP rsyslog.service
	endscript
}
LOGROTATE

    # Create /usr/local/bin/wait_for_var_log_to_be_mounted with 755 permissions
    mkdir -p "$root/usr/local/bin"
    cat > "$root/usr/local/bin/wait_for_var_log_to_be_mounted" <<'WAITSCRIPT'
#!/bin/bash

until mountpoint -q /var/log
do
    sleep .1
done
WAITSCRIPT
    chmod 755 "$root/usr/local/bin/wait_for_var_log_to_be_mounted"

    # Pre-create log files referenced by rsyslog.d/50-default.conf so that
    # the os_image spec "secures rsyslog.conf-referenced files" test can stat
    # them.  rsyslog owns these files (uid/gid of syslog account).
    # In the tarball, fakeroot records the syslog uid/gid (102:102 as per
    # the group/passwd written by the users overlay).
    mkdir -p "$root/var/log"
    for logfile in auth.log syslog cron.log daemon.log kern.log bosh-agent.log; do
      touch "$root/var/log/$logfile"
      chmod 0600 "$root/var/log/$logfile"
      chown 102:102 "$root/var/log/$logfile" 2>/dev/null || true
    done

    # Create rsyslog.service.d override
    mkdir -p "$root/etc/systemd/system/rsyslog.service.d"
    cat > "$root/etc/systemd/system/rsyslog.service.d/00-override.conf" <<'SYSLOGOVERRIDE'
[Service]
ExecStartPre=/usr/local/bin/wait_for_var_log_to_be_mounted
SYSLOGOVERRIDE

    # Create journald.conf.d override
    mkdir -p "$root/etc/systemd/journald.conf.d"
    cat > "$root/etc/systemd/journald.conf.d/00-override.conf" <<'JOURNALOVERRIDE'
[Journal]
Storage=volatile
JOURNALOVERRIDE
