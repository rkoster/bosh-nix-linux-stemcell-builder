# Stage Directory Co-location Refactor — Design

## Context

The previous refactor (`docs/superpowers/specs/2026-07-15-stages-directory-per-stage-refactor-design.md`)
converted `build/stages/` from flat `.nix` + `.sh` files into a directory per
stage (`build/stages/<name>/apply.sh` + flat asset files), orchestrated by a
single `build/stages.nix`. That refactor deliberately kept each stage's Nix
wrapper (`build/stages/<name>.nix`) as a *sibling file* next to its directory
(`build/stages/<name>/`), and kept assets flat (no `assets/` subdirectory).

In practice this leaves the Nix wiring for a stage physically separated from
its shell implementation and assets — e.g. `build/stages/agent.nix` sits next
to, but outside of, `build/stages/agent/`. This design closes that gap by
moving each stage's Nix wrapper *into* its own directory as `default.nix`,
following the idiomatic Nix/nixpkgs convention where a directory with a
`default.nix` is importable as a self-contained unit (`import ./agent` reads
`build/stages/agent/default.nix` automatically). The top-level
`build/stages.nix` similarly becomes `build/stages/default.nix`.

Since the stage directory's Nix file will now live physically inside the
directory it also needs to reference as `STAGE_DIR`, this design also
reintroduces a nested `assets/` subdirectory per stage (reversing a decision
made in the prior design) so that the directory copied into the Nix store as
`STAGE_DIR` contains only the static asset files the stage's `apply.sh` reads —
not the `default.nix` wiring file, and not `apply.sh` itself.

While touching the `flake.nix` `shfmt.excludes` pattern for this move, this
design also closes a related, pre-existing gap: the current excludes list
(`"build/stages/*/apply.sh"`) does not exclude asset shell scripts extracted
verbatim from upstream heredocs (`audit/auditctl.sh`,
`systemd-services/firstboot.sh`). Running `nix fmt` today could silently
reformat these files, breaking the byte-identical extraction guarantee. This
design fixes the excludes pattern to also cover `build/stages/*/assets/**`.

## Goals

- Each stage directory is fully self-contained: `default.nix` (Nix wiring),
  `apply.sh` (shell implementation), `assets/` (static content, only if the
  stage has any).
- `build/stages.nix` becomes `build/stages/default.nix`; each
  `build/stages/<name>.nix` becomes `build/stages/<name>/default.nix`.
- No functional change: identical files are copied to identical destinations
  in the final rootfs. Only the *source paths* Nix uses to build `STAGE_DIR`
  and locate `apply.sh` change.
- Byte-identical `rootfs.tar.gz` output, verified against the existing
  baseline hash captured in the prior refactor
  (`docs/superpowers/baselines/2026-07-15-os-image-baseline.sha256`,
  `4eee73a9711ab0a5cf4412cef4731df938322de57c4d9bc8509da4c5dbaec456`).
- Close the `shfmt.excludes` gap for extracted asset shell scripts.

## Non-Goals

- No changes to stage script logic, stage ordering, or which files get
  installed where in the rootfs.
- No changes to `build/rootfs/apply-stages.nix` (the single-fakeroot-session
  stage runner) beyond what's needed to keep it working — its interface
  (`{ base, stages }:` where `stages` is a list of `{ name; script; }`) is
  unaffected.
- No changes to `build/pkgs/*.nix` (bosh-agent, monit, blobstore-clis source
  builds) beyond fixing the one relative-path reference from the moved
  orchestrator file.

## Target Directory Structure

```
build/stages/
├── default.nix                          # was build/stages.nix (orchestrator)
├── agent/
│   ├── default.nix                      # was build/stages/agent.nix
│   ├── apply.sh
│   └── assets/
│       ├── monitrc
│       ├── bosh-agent-rc
│       ├── restart_networking
│       ├── alerts.monitrc
│       ├── bosh-agent.service
│       └── sync-time
├── audit/
│   ├── default.nix
│   ├── apply.sh
│   └── assets/
│       ├── audit.rules
│       ├── 00-override.conf
│       ├── bosh-start-logging-and-auditing
│       └── auditctl.sh
├── blobstore-clis/
│   ├── default.nix                      # no assets/ — stage has none
│   └── apply.sh
├── misc-os/
│   ├── default.nix
│   ├── apply.sh
│   └── assets/
│       ├── 02periodic
│       └── sources.list
├── openstack-agent-settings/
│   ├── default.nix
│   ├── apply.sh
│   └── assets/
│       └── agent.json
├── rsyslog/
│   ├── default.nix
│   ├── apply.sh
│   └── assets/
│       ├── rsyslog.conf
│       ├── 50-default.conf
│       ├── 90-bosh-agent.conf
│       ├── rsyslog
│       ├── wait_for_var_log_to_be_mounted
│       ├── rsyslog-service-override.conf
│       └── journald-override.conf
├── ssh/
│   ├── default.nix
│   ├── apply.sh
│   └── assets/
│       ├── 10-ssh-firstboot-done.conf
│       └── securetty
├── sudoers-pam/
│   ├── default.nix
│   ├── apply.sh
│   └── assets/
│       └── bosh_sudoers
├── sysctl-limits-env/
│   ├── default.nix
│   ├── apply.sh
│   └── assets/
│       ├── 60-bosh-sysctl.conf
│       └── 60-bosh-sysctl-neigh-fix.conf
├── systemd-services/
│   ├── default.nix
│   ├── apply.sh
│   └── assets/
│       ├── monit.service
│       ├── prevent_mount_locking.conf
│       ├── add-container-listener-address.conf
│       ├── create-systemd-resolved-listener-address.service
│       ├── sysstat
│       ├── firstboot.service
│       └── firstboot.sh
└── users/
    ├── default.nix
    ├── apply.sh
    └── assets/
        ├── group
        ├── gshadow
        ├── passwd
        ├── shadow
        └── 00-bosh-ps1
```

## Migration Mechanics

### Per-stage moves (all 11 stages)

For each stage `<name>` (users, ssh, sysctl-limits-env, sudoers-pam, rsyslog,
audit, misc-os, systemd-services, agent, blobstore-clis,
openstack-agent-settings):

1. `git mv build/stages/<name>.nix build/stages/<name>/default.nix`
2. For stages with asset files (all except `blobstore-clis`):
   `mkdir -p build/stages/<name>/assets` then
   `git mv build/stages/<name>/<asset-file> build/stages/<name>/assets/<asset-file>`
   for every existing asset file.
3. Inside the moved `default.nix`:
   - `STAGE_DIR` interpolation changes from `${./<name>}` (referencing the
     sibling directory) to `${./assets}` (referencing the now-local `assets/`
     subdirectory). For `blobstore-clis`, there is no `STAGE_DIR` export today
     — leave it absent.
   - The `apply.sh` interpolation changes from `${./<name>/apply.sh}` to
     `${./apply.sh}` (now a direct sibling of `default.nix`).
   - All other content (env var exports for store paths like
     `BOSH_AGENT_BIN`, function signature/args) stays identical.

**Example — `build/stages/agent/default.nix` before/after:**

Before (`build/stages/agent.nix`):
```nix
{ bosh-agent, monit }:
{
  name = "agent";
  script = ''
    export STAGE_DIR="${./agent}"
    export BOSH_AGENT_BIN="${bosh-agent}/bin/main"
    export MONIT_BIN="${monit}/bin/monit"
    bash -euxo pipefail "${./agent/apply.sh}"
  '';
}
```

After (`build/stages/agent/default.nix`):
```nix
{ bosh-agent, monit }:
{
  name = "agent";
  script = ''
    export STAGE_DIR="${./assets}"
    export BOSH_AGENT_BIN="${bosh-agent}/bin/main"
    export MONIT_BIN="${monit}/bin/monit"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
```

**Example — `build/stages/blobstore-clis/default.nix` (no assets, unchanged
apart from the `apply.sh` path):**
```nix
{ davcli, s3cli, gcscli, azureStorageCli }:
{
  name = "blobstore-clis";
  script = ''
    export DAVCLI_BIN="${davcli}/bin/davcli"
    export S3CLI_BIN="${s3cli}/bin/bosh-s3cli"
    export GCSCLI_BIN="${gcscli}/bin/bosh-gcscli"
    export AZURE_STORAGE_CLI_BIN="${azureStorageCli}/bin/bosh-azure-storage-cli"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
```

`apply.sh` files themselves are **not modified** — they already reference
assets purely via `$STAGE_DIR/<filename>`, which is unaffected by where the
directory physically lives in the Nix store.

### Top-level orchestrator move

1. `git mv build/stages.nix build/stages/default.nix`
2. Fix the now-one-level-deeper relative path to the package definitions:
   `./pkgs/bosh-agent.nix` → `../pkgs/bosh-agent.nix` (and the same for
   `monit.nix`, `blobstore-clis.nix`).
3. Simplify stage imports — since the orchestrator now lives inside
   `build/stages/` itself, sibling stage directories are one level up in the
   reference, not nested under `./stages/`:
   - `import ./stages/users.nix { }` → `import ./users { }`
   - `import ./stages/agent.nix { inherit bosh-agent monit; }` →
     `import ./agent { inherit bosh-agent monit; }`
   - ...and so on for all 11 stages. (`import ./users { }` automatically
     resolves to `build/stages/users/default.nix` — standard Nix directory
     import behavior.)

### Other wiring updates

- **`build/rootfs/os-image.nix`**: `stages = callPackage ../stages.nix { };`
  → `stages = callPackage ../stages { };` (directory import; `callPackage`
  resolves `../stages` to `../stages/default.nix` the same way plain `import`
  does).
- **`flake.nix`**: `settings.formatter.shfmt.excludes` changes from
  `[ "build/stages/*/apply.sh" ]` to
  `[ "build/stages/*/apply.sh" "build/stages/*/assets/**" ]`, closing the gap
  where extracted asset shell scripts (`audit/assets/auditctl.sh`,
  `systemd-services/assets/firstboot.sh`) were not excluded from `shfmt`
  reformatting.
- **`docs/ARCHITECTURE.md`**: update the "Configuration Stages" section and
  file-tree diagram to describe each stage directory as containing
  `default.nix` (Nix wiring) + `apply.sh` (shell implementation) + `assets/`
  (static content, when present). Update the `build/stages.nix` link to
  `build/stages/default.nix`.
- **`README.md`**: update the `build/stages/` row in the repository layout
  table to mention the `default.nix` + `apply.sh` + `assets/` co-location and
  the new orchestrator path.

## Verification

This is purely a file-layout and Nix-wiring change — every stage still copies
the exact same files to the exact same rootfs destinations; only the *source
paths* Nix uses to build `STAGE_DIR` and locate `apply.sh` change (from
sibling-directory references to same-directory references).

1. `nix build .#os-image`
2. `sha256sum result/rootfs.tar.gz`
3. Compare against the existing baseline recorded in
   `docs/superpowers/baselines/2026-07-15-os-image-baseline.sha256`
   (`4eee73a9711ab0a5cf4412cef4731df938322de57c4d9bc8509da4c5dbaec456`).
   Hashes must match exactly — no new baseline capture is needed since no
   functional change is introduced.
4. Confirm `nix flake check` (or equivalent) evaluates cleanly with the new
   `import ./stages { ... }` / `import ./<name> { ... }` directory-import
   forms.

## Rollback / Risk

Low risk: mechanical file moves plus small, well-scoped path-string edits in
already-passing Nix expressions. If the hash comparison in step 3 fails, the
prior commit history (from the first refactor) provides a clean revert point.
