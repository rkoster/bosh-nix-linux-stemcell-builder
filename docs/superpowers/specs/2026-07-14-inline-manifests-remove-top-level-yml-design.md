# Design: Inline manifests, remove `manifests/` and top-level `.yml` files

## Problem

The repo has two top-level `.yml` files (`nix-stemcell-poc.yml`, `upstream-jobless-poc.yml`) and a `manifests/` directory (containing `zookeeper.yml`) cluttering the top level. Investigation found:

- `nix-stemcell-poc.yml` is actively used — hardcoded and read from disk by `scripts/deploy-stemcell.sh` (the main e2e stemcell validation script).
- `upstream-jobless-poc.yml` is **unused** — not referenced by any script, `.nix` file, or living doc. It pins the official upstream BOSH stemcell (version `1.425`) for one-off manual comparison, unrelated to what `deploy-stemcell.sh` validates (the Nix-built stemcell).
- `manifests/zookeeper.yml` is **not wired into any script** — it's only ever deployed manually via a hand-typed `bosh deploy -d zookeeper manifests/zookeeper.yml -n` command, documented in dated historical docs (`docs/plans/2026-07-08-zookeeper-e2e-validation.md`, `docs/specs/2026-07-13-nix-native-refactor-e2e-findings.md`). It's an adapted copy of the upstream `cppforlife/zookeeper-release` manifest with exactly 3 deltas: `stemcells[0]` (`ubuntu-xenial`/`latest` → `ubuntu-noble`/`0.0.5-nix`), `update.canaries` (2→1), `instance_groups[0].instances` (5→3).

## Goal

Remove the top-level `.yml` files and `manifests/` directory. Inline what's actually used; don't carry forward what isn't; automate what was previously manual-only.

## Changes

### 1. `nix-stemcell-poc.yml` → inlined into `scripts/deploy-stemcell.sh`

Delete the file. Replace the current file-based deploy step:

```bash
if [[ ! -f "./nix-stemcell-poc.yml" ]]; then
  log_error "Manifest not found: ./nix-stemcell-poc.yml"
  exit 1
fi

if ! run_cmd bosh -d nix-stemcell-poc deploy ./nix-stemcell-poc.yml -n; then
  log_error "Deployment failed"
  exit 1
fi
```

with an inlined heredoc (identical manifest content) deployed via process substitution:

```bash
if ! run_cmd bosh -d nix-stemcell-poc deploy <(cat <<'YAML'
name: nix-stemcell-poc

releases: []

stemcells:
  - alias: ubuntu
    os: ubuntu-noble
    version: "0.0.5-nix"

instance_groups:
  - name: vm-instance
    instances: 1
    vm_type: default
    azs:
      - z1
    networks:
      - name: default
    stemcell: ubuntu
    jobs: []

variables: []

update:
  canaries: 0
  max_in_flight: 1
  canary_watch_time: 1000-1000
  update_watch_time: 1000-1000
YAML
) -n; then
  log_error "Deployment failed"
  exit 1
fi
```

Deployment name (`nix-stemcell-poc`) and behavior are unchanged — only the manifest source moves from a file read to an inline heredoc.

### 2. `deploy-stemcell.sh` cleanup version fix

While touching this file: the cleanup step deletes `ubuntu/0.0.1-nix`, but the manifest pins stemcell version `0.0.5-nix`. Fix the mismatch:

```bash
if ! run_cmd bosh delete-stemcell ubuntu/0.0.1-nix --force; then
```
→
```bash
if ! run_cmd bosh delete-stemcell ubuntu/0.0.5-nix --force; then
```

### 3. `upstream-jobless-poc.yml` → deleted, not carried forward

Confirmed unused (no script/doc/nix reference beyond the README table row being removed in this change). Dropped entirely.

### 4. `manifests/zookeeper.yml` + `manifests/` → deleted, replaced by new `scripts/deploy-zookeeper.sh`

New script, mirroring `deploy-stemcell.sh`'s structure and style (same `log`/`log_step`/`log_error`/`run_cmd` helpers, `--dry-run`, `--help`, bosh.env sourcing + director-reachability check):

```bash
#!/run/current-system/sw/bin/bash

# deploy-zookeeper.sh
# Deploys the upstream cppforlife/zookeeper-release e2e validation manifest,
# fetched live from GitHub and adapted for this repo's Nix stemcell via an
# inline ops-file (ubuntu-noble/0.0.5-nix stemcell, single canary, 3-node
# quorum instead of upstream's 5).
# 1. Verify BOSH environment
# 2. Deploy manifest (fetched + ops-file applied inline)
# 3. Run smoke-tests errand
# 4. Optional cleanup

set -e

ZOOKEEPER_MANIFEST_URL="https://raw.githubusercontent.com/cppforlife/zookeeper-release/master/manifests/zookeeper.yml"

CLEANUP=false
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

print_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

Deploys the zookeeper e2e validation manifest (fetched live from
cppforlife/zookeeper-release) against the Nix-built stemcell, via an inline
ops-file overriding stemcell/update/instance-count for this repo.

Options:
  --cleanup            Delete deployment after successful validation
  --dry-run            Show what would be done, don't actually deploy
  --help               Print this help message

Environment:
  Requires ./bosh.env to be sourced with BOSH_ENVIRONMENT, BOSH_CLIENT, BOSH_CLIENT_SECRET set.
  Requires the Nix stemcell (bosh-openstack-kvm-ubuntu-noble, 0.0.5-nix) already uploaded
  to the director (see scripts/deploy-stemcell.sh).

Examples:
  # Deploy and verify
  \$0

  # Deploy, verify, and cleanup
  \$0 --cleanup
EOF
}

log() { echo "[\$(date +'%Y-%m-%d %H:%M:%S')] \$*"; }
log_step() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "\$*"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
log_error() { echo "[ERROR] \$*" >&2; }

run_cmd() {
  local cmd=("\$@")
  if [[ "\$DRY_RUN" == true ]]; then
    log "[DRY RUN] \${cmd[*]}"
    return 0
  else
    log "Running: \${cmd[*]}"
    "\${cmd[@]}"
  fi
}

# Parse options
while [[ \$# -gt 0 ]]; do
  case \$1 in
    --cleanup)
      CLEANUP=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help)
      print_help
      exit 0
      ;;
    *)
      log_error "Unknown option: \$1"
      print_help
      exit 1
      ;;
  esac
done

cd "\$WORKSPACE_ROOT"

log_step "Deploying zookeeper e2e validation manifest"

# Step 1: Environment check
log_step "Step 1: Checking BOSH environment"

if [[ ! -f "./bosh.env" ]]; then
  log_error "bosh.env not found. Please create it with BOSH credentials."
  exit 1
fi

# shellcheck source=/dev/null
source ./bosh.env

if [[ -z "\$BOSH_ENVIRONMENT" ]] || [[ -z "\$BOSH_CLIENT" ]] || [[ -z "\$BOSH_CLIENT_SECRET" ]]; then
  log_error "BOSH_ENVIRONMENT, BOSH_CLIENT, or BOSH_CLIENT_SECRET not set in ./bosh.env"
  exit 1
fi

log "BOSH environment: \$BOSH_ENVIRONMENT"

if ! run_cmd bosh env > /dev/null 2>&1; then
  log_error "Cannot reach BOSH director at \$BOSH_ENVIRONMENT"
  exit 1
fi

log "✓ BOSH director is reachable"

# Step 2: Deploy manifest (fetched live from upstream + inline ops-file)
log_step "Step 2: Deploying zookeeper manifest"

if ! run_cmd bosh -d zookeeper deploy \
  <(curl -fsSL "\$ZOOKEEPER_MANIFEST_URL") \
  -o <(cat <<'EOF'
- type: replace
  path: /stemcells/0
  value:
    alias: default
    os: ubuntu-noble
    version: 0.0.5-nix
- type: replace
  path: /update/canaries
  value: 1
- type: replace
  path: /instance_groups/0/instances
  value: 3
EOF
) -n; then
  log_error "Deployment failed"
  exit 1
fi

log "✓ Deployment completed"

# Step 3: Run smoke-tests errand
log_step "Step 3: Running smoke-tests errand"

if ! run_cmd bosh -d zookeeper run-errand smoke-tests; then
  log_error "smoke-tests errand failed"
  exit 1
fi

log "✓ smoke-tests passed"

# Optional cleanup
if [[ "\$CLEANUP" == true ]]; then
  log_step "Cleaning up deployment"
  if ! run_cmd bosh -d zookeeper delete-deployment --force; then
    log_error "Failed to delete deployment"
    exit 1
  fi
  log "✓ Cleanup complete"
fi

log_step "Done!"
exit 0
```

Made executable (`chmod +x`), matching `deploy-stemcell.sh`'s permissions.

### 5. `README.md`

Remove the now-stale row:

```markdown
| `manifests/`, `*.yml` | Validation manifests: `zookeeper.yml` (e2e deployment), `nix-stemcell-poc.yml` (jobless boot), `upstream-jobless-poc.yml` (upstream baseline). |
```

Update the `scripts/` row to mention both deploy scripts:

```markdown
| `scripts/` | `deploy-stemcell.sh` (end-to-end director validation; manifest inlined), `deploy-zookeeper.sh` (zookeeper e2e validation; fetches upstream manifest + inline ops-file), `apt-resolve-noble.sh`, QEMU/OVMF boot smoke tests. |
```

### 6. Historical docs — untouched

`docs/plans/2026-07-08-zookeeper-e2e-validation.md`, `docs/specs/2026-07-13-nix-native-refactor-e2e-findings.md`, and other dated specs/plans referencing the old `manifests/zookeeper.yml` path stay as-is — they're historical records of what was true at the time, consistent with this repo's existing documentation policy (established in the `2026-07-14-move-nix-sources-into-build-dir-design.md` spec).

## Verification

1. `bash -n scripts/deploy-stemcell.sh` and `bash -n scripts/deploy-zookeeper.sh` — syntax check (heredocs + process substitution parse correctly).
2. `scripts/deploy-stemcell.sh --dry-run` and `scripts/deploy-zookeeper.sh --dry-run` — confirm the scripts run through their logic without a real director (no `bosh.env` needed for a dry look at the flow up to the environment check, or with a dummy `bosh.env` to get past that gate).
3. Manual diff: confirm the inlined `nix-stemcell-poc.yml` heredoc in `deploy-stemcell.sh` is byte-identical to the deleted file's content.
4. `git status` — confirm `manifests/`, `nix-stemcell-poc.yml`, `upstream-jobless-poc.yml` are gone and nothing else references them (`grep -rn` sweep).

No functional change to `deploy-stemcell.sh`'s deployment behavior (same manifest content, same deployment name) other than the cleanup version fix. `deploy-zookeeper.sh` is new functionality (previously manual-only) and requires a real BOSH director + already-uploaded Nix stemcell to actually exercise end-to-end — that live-director verification is out of scope for this change (matches this repo's existing pattern of not requiring a live director for other script changes).
