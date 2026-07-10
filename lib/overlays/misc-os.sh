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
    cat > "$root/etc/apt/apt.conf.d/02periodic" <<'EOF'
APT::Periodic {
  Enable "0";
}
EOF
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
    cat > "$root/etc/apt/sources.list" <<'SOURCES'
deb http://archive.ubuntu.com/ubuntu noble main universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main universe multiverse
SOURCES
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
