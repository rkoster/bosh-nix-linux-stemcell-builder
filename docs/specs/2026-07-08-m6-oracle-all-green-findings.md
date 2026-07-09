# M6 Findings: All 366 Oracle Specs Pass

**Date:** 2026-07-08  
**Milestone:** M6 — Full oracle green  
**Result:** 366/366 os_image Serverspec specs pass against the Nix-built stemcell

---

## Summary

All 366 tests from the upstream `bosh-stemcell/spec/os_image/ubuntu_spec.rb` oracle suite
now pass against the Nix-built `poc/result/rootfs.tar.gz` os-image. This is the primary
oracle acceptance criterion for the Nix-based stemcell builder POC.

---

## Starting Point (M5 handoff)

After M5 (chroot PATH fix): **366 examples, 28 failures**.

The 28 failures were categorized and root-caused at the end of M5. All fixes were
written during M6. This doc records the final fixes that closed the last 27.

---

## Fixes Applied This Milestone

### 1. Audit Rules — Field Order Conflict (`audit.nix`)

**Problem:** Two separate spec contexts check the same audit rules file with
*different* field orderings:

- `os_image_shared_examples.rb:679-703` ("record use of binaries"): expects  
  `-a always,exit -F perm=x -F auid>=500 -F auid!=4294967295 -F path=<X> -k privileged`
- `os_image_shared_examples.rb:737-751` ("record use of privileged programs", CIS-8.1.12):  
  dynamically finds SUID/SGID binaries and expects  
  `-a always,exit -F path=<X> -F perm=x -F auid>=500 -F auid!=4294967295 -k privileged$`

These are *incompatible* — same binaries, opposite field orders, different regex anchors.

**Fix:** Write *both* formats for each binary:
1. 24 hardcoded rules changed to `perm=x` first (satisfies lines 680-703).
2. Added a separate CIS-8.1.12 section with `path=` first for every SUID/SGID binary
   in the image: `/usr/bin/{sudo,umount,newgrp,chsh,mount,su,passwd,chfn,gpasswd,`
   `ssh-agent,expiry,chage,crontab}` and `/usr/sbin/{unix_chkpwd,pam_extrausers_chkpwd}`.

**Key insight — `/usr/bin/expiry` was the first CIS-8.1.12 failure because:**
- `find` inside the chroot resolves `/bin` → `/usr/bin` and reports canonical paths,
  so no duplicate `/bin/...` paths.
- `expiry` (SGID shadow) was not in the original hardcoded list; it was simply missing.
- CIS-8.1.12 uses `its(:content) { each }` which stops at the first failure —
  expiry was the first binary in filesystem order without a `path=` first rule.
- Adding `/usr/bin/sudo` and `/usr/sbin/pam_extrausers_chkpwd` pre-emptively avoids
  the next failure after expiry.

### 2. rsyslog Log File Ownership (`rsyslog.nix`)

**Problem:** `os_image_shared_examples.rb:103-126` greps all `/var/log/` references in
`/etc/rsyslog*` and checks each file is owned by `syslog:syslog` with **mode 0600**.
Two issues:
- Files were pre-created with `chmod 0640` (spec requires 0600).
- `/var/log/bosh-agent.log` referenced in `rsyslog.d/90-bosh-agent.conf` was not
  pre-created.

**Fix:** Changed `chmod 0640` → `chmod 0600` and added `bosh-agent.log` to the
pre-creation loop.

### 3. `/etc/shadow` Content (`users.nix`)

**Problem:** The shadow file left by `makeImageFromDebDist` had two defects:
1. **4-digit date** (`3652` ≈ 1980-01-01 days from epoch) — spec regex requires `\d{5}`
   (exactly 5 digits, i.e. ≥ 10000 days ≈ post-1997).
2. **Wrong service-account ordering** and **missing `vcap` entry** — spec uses a
   multi-line anchored regex that requires exact left-to-right order plus vcap at tail.

**Fix:** Write a static normalized `/etc/shadow` in `users.nix` (the last overlay,
after all packages) with:
- Date `19000` (≈ 2022-01-01, 5 digits).
- All entries in the exact spec-mandated order:
  `root, daemon, bin, sys, sync, games, man, lp, mail, news, uucp, proxy, www-data,`
  `backup, list, irc, _apt, nobody, systemd-network, systemd-timesync, dhcpcd,`
  `messagebus, syslog, systemd-resolve, uuidd, _chrony, _runit-log, sshd, tcpdump,`
  `polkitd, vcap`.
- `vcap:*:19000:1:99999:7:::` — password `*` satisfies `(.+)`, min-age `1` required.
- `chmod 000 "$root/etc/shadow"` after write to preserve mode 0000.

### 4. Previously Fixed (M5 → M6, committed in M6 batch)

These were written during the previous session and applied via the M6 build:

| Overlay | Fix |
|---------|-----|
| `mk-apply-overlays.nix` | Remove `find -perm /000 -exec chmod u+r` — GNU find `-perm /000` with mask 000 matches EVERY file, corrupting shadow/gshadow mode 0000 |
| `systemd-services.nix` | Move monit enable symlink to `/etc/systemd/system/` (not `/lib/systemd/system/`) so `systemctl is-enabled` reports "enabled" |
| `ssh.nix` | Add `/etc/issue`, `/etc/issue.net` (BOSH unauthorized-use banner), empty `/etc/motd`, `/etc/default/motd-news` with `ENABLED=0` |
| `sudoers-pam.nix` | Add `%bosh_sudoers ALL=(ALL) NOPASSWD: ALL` directly to `/etc/sudoers` |
| `rsyslog.nix` | Pre-create `/var/log/{auth,syslog,cron,daemon,kern}.log` with correct ownership |
| `agent.nix` | Add `/var/vcap/bosh/bin/sync-time` script (`chronyc reload sources && chronyc waitsync 10`) |
| `misc-os.nix` | `/etc/apt/sources.list` (noble deb lines), `PASS_MIN_DAYS 1` in login.defs, ZFS kernel module dir removal, `/boot/grub/gfxblacklist.txt` stub |
| `audit.nix` | `/var/log/audit` group root:root; initial audit rules pass (before field-order fix) |
| `noble-packages.nix` | Add `cron`, `systemd-timesyncd`, `grub2` |
| `users.nix` | Normalized `/etc/passwd` (correct UID ordering, includes systemd-timesync) |

---

## Technical Notes

### GNU `find` and SUID/SGID binary discovery (CIS-8.1.12)

The spec uses `find /bin /sbin /usr/bin /usr/sbin /boot -xdev \( -perm -4000 -o -perm -2000 \) -type f`. In Ubuntu 24.04 Noble, `/bin → usr/bin` and `/sbin → usr/sbin` are relative symlinks. GNU `find` follows top-level symlink arguments and reports paths using the *canonical* resolved form, so `/bin/` paths are not duplicated as `/usr/bin/`. The effective SUID/SGID binary set is the `/usr/bin/...` and `/usr/sbin/...` paths only.

### Shadow date field

The `makeImageFromDebDist` Nix build runs in a sandbox where the system clock is frozen at a very early epoch. Shadow entries are written by `chpasswd`/`useradd` at this fake time, producing a 4-digit days-since-epoch value. Normalizing to a static 5-digit value (`19000`) in the last overlay is the clean solution — it never goes stale since the spec only checks `\d{5}` (any 5-digit value), not the specific date.

### `find -perm /000` GNU find behaviour

GNU find's man page: "If no permission bits in mode are set, this test matches any file." The expression `-perm /000` has mask `000` (zero bits), so it trivially matches every file in the tree. This caused `chmod u+r` to run on every file including `shadow` and `gshadow`, setting them to `0400` instead of `0000`. Removing this line entirely was the correct fix.

### Dual-format audit rules

The spec has historically accumulated two separately-implemented audit rule checkers with incompatible conventions. Having *both* rule formats in `audit.rules` is not a security problem — `auditd` accepts (and deduplicates at load time) rules with the same semantics expressed in different field orders.

---

## Oracle Run Evidence

```
Finished in 24.32 seconds (files took 1.4 seconds to load)
366 examples, 0 failures
```

Command used:
```bash
nix develop ./poc#oracle --command bash \
  poc/oracle/run-os-image-specs.sh poc/result/rootfs.tar.gz --format progress
```

Store path: `/nix/store/sm6d3xs13fxp16xly87m8jskjjsn4inz-os-image`  
Commit: `cfc0991` (feat(oracle): all 366 os_image specs pass (M6))

---

## Next Steps

1. **End-to-end BOSH validation** — re-upload the Nix-built stemcell to the Incus
   BOSH director and verify the previous green deployment still holds.
2. **Reproducibility check** — rebuild twice from identical inputs, diff the tarballs.
3. **Stemcell packaging** — complete the stemcell (IaaS metadata + BOSH agent + qcow2
   image) and upload to the director as a full `bosh-openstack-kvm-ubuntu-noble` stemcell.
4. **Write final feasibility assessment** in `docs/superpowers/specs/`.
