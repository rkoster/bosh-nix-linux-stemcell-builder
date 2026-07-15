# Design: One directory per stage, single `stages.nix`, heredocs extracted to files

## Problem

`build/stages/` currently holds two parallel, inconsistent representations of
the same 11 stages:

1. **Externalized stages** (`audit`, `misc-os`, `openstack-agent-settings`,
   `rsyslog`, `ssh`, `sudoers-pam`, `sysctl-limits-env`, `systemd-services`,
   `users`): a tiny `<name>.nix` wrapper (`{ }: import ../lib/mkStage.nix { name
   = "<name>"; src = ./<name>.sh; }`) plus a flat `<name>.sh` file. Each `.sh`
   still embeds its rootfs config content as inline `cat > ... <<'EOF'`
   heredocs (38 of them across the 9 files).
2. **Inline stages** (`agent`, `blobstore-clis`): a `<name>.nix` file whose
   `script` is a Nix `''…''` string, mixing Nix store-path interpolation
   (`${bosh-agent}/bin/main`) with more inline heredocs (6 more, in `agent.nix`
   alone). These can't be shellchecked or shfmt'd at all today.

On top of that, `build/stages/default.nix` (the ordered list) and
`build/lib/mkStage.nix` (the script-assembly helper) are separate small files
whose only job is Nix plumbing — one file's worth of boilerplate spread across
12 files.

Two additional stages, `debug-ssh-keys.nix` and
`debug-ssh-root-login.nix`/`.sh`, exist but are already excluded from the
active stage list (emergency-debug tooling, per `default.nix`'s comment). The
stemcell build is stable now; these are no longer needed.

This mirrors the structural problem the upstream
[bosh-linux-stemcell-builder `stages/`](https://github.com/cloudfoundry/bosh-linux-stemcell-builder/tree/ubuntu-jammy/stemcell_builder/stages)
directory solved differently: one directory per stage
(`stages/<name>/apply.sh` + `stages/<name>/assets/*`), with static content
copied into place rather than heredoc'd inline.

## Goal

1. **Single `build/stages.nix`**: absorbs `build/stages/default.nix` (ordered
   list) and `build/lib/mkStage.nix` (script-assembly helper) into one file —
   all Nix boilerplate for every stage lives here, nowhere else.
2. **One directory per stage**, `build/stages/<name>/`, containing a plain
   `apply.sh` (no Nix syntax, fully shellcheck/shfmt-able) and any extracted
   asset files it copies into place.
3. **No inline heredocs.** Every `cat > dest <<'EOF' ... EOF` block becomes a
   static file alongside `apply.sh`, copied into place with `cp`/`install`.
4. **No Nix store-path interpolation inside shell scripts.** The 2 stages that
   need Nix-built binaries (`agent`, `blobstore-clis`) receive them as
   environment variables exported by `stages.nix` before `apply.sh` runs —
   never as text substituted into the script.
5. **Delete** `debug-ssh-keys.nix` and `debug-ssh-root-login.nix`/`.sh`
   entirely (no longer needed).
6. **Byte-identical output.** This is a pure structural refactor — same
   discipline as the prior overlays→stages rename
   (`docs/superpowers/specs/2026-07-14-stages-rename-hermetic-guard-design.md`).
   `scripts/byte-check-osimage.sh` / `byte-check-stemcell.sh` must report
   identical output before and after.
7. **Stages remain pure file operations.** No stage may fetch anything from
   the network — this refactor doesn't change that constraint, it just makes
   every stage script plain enough to audit at a glance (and shellcheck-able,
   closing the gap the two inline stages had today).

## Non-goals

- No change to stage *ordering* or *content/behavior* (users before
  group-membership asserts, ssh after base packages, agent + blobstore late,
  openstack-agent-settings last — unchanged).
- No change to `build/rootfs/apply-stages.nix`'s consumed interface: it still
  takes a list of `{ name; script; }` records and assembles them into one
  fakeroot session exactly as today.
- No new hermetic-guard mechanism — the existing runtime network-probe
  (`build/lib/hermetic-guard.sh`) is untouched and keeps doing its job.
- Historical dated docs (`docs/specs/*`, `docs/plans/*`, existing
  `docs/superpowers/{specs,plans}/*`) are left untouched, per established
  precedent. `docs/ARCHITECTURE.md` and `README.md` (living docs) are updated.

## Design

### Directory layout

```
build/
  stages.nix                          # ordered list + mkStage helper (NEW; replaces
                                       # stages/default.nix + lib/mkStage.nix)
  stages/
    users/apply.sh
    users/group
    users/gshadow
    users/passwd
    users/shadow
    users/00-bosh-ps1
    ssh/apply.sh
    ssh/10-ssh-firstboot-done.conf
    ssh/securetty
    sysctl-limits-env/apply.sh
    sysctl-limits-env/60-bosh-sysctl.conf
    sysctl-limits-env/60-bosh-sysctl-neigh-fix.conf
    sudoers-pam/apply.sh
    sudoers-pam/bosh_sudoers
    rsyslog/apply.sh
    rsyslog/rsyslog.conf
    rsyslog/50-default.conf
    rsyslog/90-bosh-agent.conf
    rsyslog/rsyslog                    # logrotate.d/rsyslog content
    rsyslog/wait_for_var_log_to_be_mounted
    rsyslog/rsyslog-service-override.conf
    rsyslog/journald-override.conf
    audit/apply.sh
    audit/audit.rules
    audit/00-override.conf
    audit/bosh-start-logging-and-auditing
    audit/auditctl.sh
    misc-os/apply.sh
    misc-os/02periodic
    misc-os/sources.list
    systemd-services/apply.sh
    systemd-services/monit.service
    systemd-services/prevent_mount_locking.conf
    systemd-services/add-container-listener-address.conf
    systemd-services/create-systemd-resolved-listener-address.service
    systemd-services/sysstat
    systemd-services/firstboot.service
    systemd-services/firstboot.sh
    agent/apply.sh
    agent/monitrc
    agent/bosh-agent-rc
    agent/restart_networking
    agent/alerts.monitrc
    agent/bosh-agent.service
    agent/sync-time
    blobstore-clis/apply.sh            # no assets: pure `install` from env-var paths
    openstack-agent-settings/apply.sh
    openstack-agent-settings/agent.json
```

Asset files sit flat inside each stage directory (no `assets/` subdirectory)
and are named after their destination basename, except where two files in the
same stage share a destination basename (`rsyslog`'s two `00-override.conf`
targets), which get disambiguated as `rsyslog-service-override.conf` and
`journald-override.conf`.

### `stages.nix`

```nix
# build/stages.nix
# Ordered stage list + the generic stage-builder helper. Every stage is a
# directory under ./stages/<name>/ containing a plain apply.sh (and any
# extracted asset files it copies into place). Stages are pure file
# operations only -- no network access (enforced at runtime by
# lib/hermetic-guard.sh in apply-stages.nix).
{ callPackage, lib }:
let
  # env: attrset of SHELL_VAR_NAME -> nix value (store path, string, etc.),
  # exported before apply.sh runs. STAGE_DIR is always exported so apply.sh
  # can reference its own sibling asset files.
  mkStage =
    { name, env ? { } }:
    {
      inherit name;
      script = ''
        export STAGE_DIR=${lib.escapeShellArg (toString (./stages + "/${name}"))}
        ${lib.concatStrings (
          lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg (toString v)}\n") env
        )}
        ${builtins.readFile (./stages + "/${name}/apply.sh")}
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

`build/rootfs/os-image.nix` changes its one reference from
`callPackage ../stages/default.nix { }` to `callPackage ../stages.nix { }`.

### Stage script transform pattern

Every heredoc:

```bash
cat > "$root/dest/path" <<'EOF'
...static content...
EOF
some-mode-or-owner-lines
```

becomes:

```bash
cp "$STAGE_DIR/<asset-file>" "$root/dest/path"
some-mode-or-owner-lines
```

(mode/owner lines are unchanged — they already exist as separate
`chmod`/`chown` calls following each heredoc in every current stage script).

Every Nix store-path interpolation:

```nix
install -m 0755 ${bosh-agent}/bin/main "$root/var/vcap/bosh/bin/bosh-agent"
```

becomes, in `apply.sh` (plain shell, referencing the env var `stages.nix`
exported):

```bash
install -m 0755 "$BOSH_AGENT_BIN" "$root/var/vcap/bosh/bin/bosh-agent"
```

This is verified to be safe because every heredoc in the current codebase
uses a *quoted* delimiter (`<<'EOF'`, `<<'AUDITRULES'`, etc.) — meaning no
shell-side variable expansion happens inside any of them today. All content
is static text after Nix evaluation, so a byte-for-byte file copy is
equivalent. The only stage where Nix `${...}` interpolation and heredocs
coexist is `agent.nix`, and in every case the `${...}` interpolations occur
*outside* the heredoc bodies (in `install` lines), never inside them — so the
heredoc bodies extract cleanly as static files with zero ambiguity.

### Tooling updates

- `flake.nix`: `treefmt.settings.formatter.shfmt.excludes` changes from
  `[ "build/stages/*.sh" ]` to `[ "build/stages/*/apply.sh" ]`. (This exclude
  exists because `.sh` files under this path are actually shell *fragments*
  concatenated into a larger `fakeroot bash` heredoc, not standalone scripts —
  shfmt's heredoc-body reformatting isn't appropriate for a file that's
  `builtins.readFile`'d into another script's body. Same reasoning continues
  to apply, now scoped to `apply.sh` under each stage directory.) Shellcheck
  remains enabled and now covers `agent/apply.sh` and `blobstore-clis/apply.sh`
  for the first time (previously inline Nix strings, unreachable by any
  linter).

## Files touched

**New:**
- `build/stages.nix`
- `build/stages/<name>/apply.sh` × 11
- `build/stages/<name>/<asset-file>` × 37 (extracted heredoc bodies)

**Deleted:**
- `build/stages/default.nix`
- `build/lib/mkStage.nix`
- `build/stages/{users,ssh,sysctl-limits-env,sudoers-pam,rsyslog,audit,misc-os,systemd-services}.nix` (8 wrapper files)
- `build/stages/{users,ssh,sysctl-limits-env,sudoers-pam,rsyslog,audit,misc-os,systemd-services}.sh` (8 flat scripts, content moved into `<name>/apply.sh` + assets)
- `build/stages/agent.nix`, `build/stages/blobstore-clis.nix` (content moved into `agent/apply.sh` + assets, `blobstore-clis/apply.sh`)
- `build/stages/debug-ssh-keys.nix`
- `build/stages/debug-ssh-root-login.nix`, `build/stages/debug-ssh-root-login.sh`

**Modified:**
- `build/rootfs/os-image.nix` (one-line path update)
- `flake.nix` (shfmt excludes pattern)
- `docs/ARCHITECTURE.md`, `README.md` (path/terminology updates)

## Verification

1. **Baseline byte-check:** run `scripts/byte-check-osimage.sh` and
   `scripts/byte-check-stemcell.sh` on `main` before making changes, capture
   output hashes.
2. **Post-refactor byte-check:** re-run both scripts; confirm identical
   output to the baseline.
3. **`nix flake check`**: confirms the flake still evaluates (treefmt config,
   import chains, `stages.nix` wiring).
4. **Shellcheck/shfmt clean:** `nix fmt` / treefmt checks pass on every new
   `apply.sh`, including `agent/apply.sh` and `blobstore-clis/apply.sh` (newly
   lintable).
5. **Manual hermeticity spot-check:** grep every new `apply.sh` for
   `curl|wget|apt-get|apt |dpkg |http://|https://` to confirm no network
   verbs were introduced during extraction (the runtime `hermetic-guard.sh`
   check in `apply-stages.nix` remains the authoritative enforcement
   mechanism; this is a fast pre-build sanity check).
6. **Doc consistency:** no stale `build/stages/default.nix`,
   `build/lib/mkStage.nix`, or debug-stage references remain in
   `ARCHITECTURE.md`/`README.md`.
