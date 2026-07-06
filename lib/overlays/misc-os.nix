{ stageAssets }:
{
  name = "misc-os";
  script = ''
    # system_grub: menu.lst placeholder (grub2 pkg already installed in M1 closure).
    mkdir -p "$root/boot/grub"
    touch "$root/boot/grub/menu.lst"

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
    echo "" > "$root/etc/machine-id"
    rm -f "$root/var/lib/dbus/machine-id"
  '';
}
