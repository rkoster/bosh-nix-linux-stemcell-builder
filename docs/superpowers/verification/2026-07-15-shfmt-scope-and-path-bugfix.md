# shfmt Scope Expansion + Stage Path Bugfix Verification Notes

## Summary

Two changes were made in this session:

1. **shfmt scope expansion**: Removed the `settings.formatter.shfmt.excludes`
   entry from `flake.nix` so `build/stages/*/apply.sh` and
   `build/stages/*/assets/**` are no longer exempt from shfmt formatting.
   Reformatted the 2 of 13 previously-excluded files that needed changes
   (`audit/assets/auditctl.sh`, `blobstore-clis/apply.sh`) — both purely
   cosmetic (redirect spacing, alignment whitespace), no semantic change.

2. **Critical bugfix (found while investigating build verification)**:
   5 of 11 stage `default.nix` files (`users`, `ssh`, `sudoers-pam`,
   `sysctl-limits-env`, `rsyslog`) — all migrated in the first subagent
   batch of the stage directory co-location refactor — still referenced
   the pre-migration sibling paths (e.g. `${./users}`,
   `${./users/apply.sh}`) instead of the corrected self-referencing paths
   (`${./assets}`, `${./apply.sh}`). This broke evaluation with:
   `error: path '.../build/stages/users/users' does not exist`.

   This went undetected during the original refactor because Task 12/15's
   "byte-identical verification" could never actually run a full
   `nix build` in this environment (see below) — it only completed dry-run
   / `nix eval` checks, which don't catch broken store-path interpolations
   inside a stage's `script` string until the derivation actually builds.

## Environment Limitations Discovered

This interactive sandbox cannot complete a full `nix build .#os-image`:

1. **Self-referential git fetch fails**: `nix build .#os-image` (or
   `nix fmt`) needs to fetch the flake's own working directory as a
   `git+file://` input. This fails with:
   `error: resolving HEAD: failed to mmap ... (libgit2 error code = 2)` or
   `error: getting working directory status: object not found ...
   (libgit2 error code = 9)`, inconsistently, across attempts. `git fsck`
   reports no repository corruption. Root cause is presumed to be a
   libgit2/filesystem interaction specific to this sandbox.

   **Workaround used**: `nix build "path:$(pwd)#os-image"` bypasses the
   git fetcher entirely and uses the plain path fetcher instead. This is
   what surfaced the real path bug above.

2. **fakeroot cannot assume root-owned file permissions during the
   build**: Once the git-fetch issue is bypassed, the build fails partway
   through the `users` stage with `cp: cannot create regular file
   '/etc/group': Permission denied`. `nix show-config` reveals
   `build-users-group = ` (empty) — this is a single-user Nix install
   without a dedicated build-users group / user-namespace UID mapping.
   Attempting `--option sandbox false` is rejected
   (`ignoring the client-specified setting 'sandbox', because it is a
   restricted setting and you are not a trusted user`). This is an
   infrastructure-level constraint of this sandbox, not something fixable
   from within the repository.

## What Was and Wasn't Verified

✅ **Verified in this session:**
- `shellcheck` passes with default settings on all 22 shell scripts
  (including the 2 reformatted ones).
- `shfmt -w -i 2 -s` (treefmt-nix's default args) produces zero diffs
  across all 22 shell scripts after the fix — full repo is shfmt-clean
  with no exclusions.
- `nix eval --file flake.nix` succeeds (no syntax errors).
- The `users` stage now evaluates and its build step starts correctly
  (`STAGE_DIR` resolves to a valid store path, `apply.sh` is found and
  begins executing) — confirming the path bugfix is correct, up to the
  point where the fakeroot/permissions environment limitation halts
  further progress.

❌ **Not verified in this session (blocked by environment, not code):**
- A complete `nix build .#os-image` run.
- Byte-identical hash comparison against
  `docs/superpowers/baselines/2026-07-15-os-image-baseline.sha256`
  (`4eee73a9711ab0a5cf4412cef4731df938322de57c4d9bc8509da4c5dbaec456`).
  This baseline is now **known-stale**: both the path bugfix and the
  shfmt reformatting change file contents that feed into the `os-image`
  derivation, so a new hash is expected and was accepted by the user as
  fine ("this will result in a new shasum for the final artifact, but
  this is okay").

## Recommended Follow-up

Run a full `nix build .#os-image` in a properly configured multi-user
Nix environment (e.g. CI, or a dev machine with `build-users-group` set)
to:
1. Confirm the build completes end-to-end for all 11 stages.
2. Record a new baseline hash reflecting the path bugfix + shfmt changes.
