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
  $0

  # Deploy, verify, and cleanup
  $0 --cleanup
EOF
}

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

log_step() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "$*"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

log_error() {
  echo "[ERROR] $*" >&2
}

run_cmd() {
  local cmd=("$@")

  if [[ $DRY_RUN == true ]]; then
    log "[DRY RUN] ${cmd[*]}"
    return 0
  else
    log "Running: ${cmd[*]}"
    "${cmd[@]}"
  fi
}

# Parse options
while [[ $# -gt 0 ]]; do
  case $1 in
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
    log_error "Unknown option: $1"
    print_help
    exit 1
    ;;
  esac
done

# Change to workspace root
cd "$WORKSPACE_ROOT"

log_step "Deploying zookeeper e2e validation manifest"

# Step 1: Environment check
log_step "Step 1: Checking BOSH environment"

if [[ ! -f "./bosh.env" ]]; then
  log_error "bosh.env not found. Please create it with BOSH credentials."
  exit 1
fi

# shellcheck source=/dev/null
source ./bosh.env

if [[ -z $BOSH_ENVIRONMENT ]] || [[ -z $BOSH_CLIENT ]] || [[ -z $BOSH_CLIENT_SECRET ]]; then
  log_error "BOSH_ENVIRONMENT, BOSH_CLIENT, or BOSH_CLIENT_SECRET not set in ./bosh.env"
  exit 1
fi

log "BOSH environment: $BOSH_ENVIRONMENT"
log "BOSH client: $BOSH_CLIENT"

# Verify director is reachable
if ! run_cmd bosh env >/dev/null 2>&1; then
  log_error "Cannot reach BOSH director at $BOSH_ENVIRONMENT"
  exit 1
fi

log "✓ BOSH director is reachable"

# Step 2: Deploy manifest (fetched live from upstream + inline ops-file)
log_step "Step 2: Deploying zookeeper manifest"

if ! run_cmd bosh -d zookeeper deploy \
  <(curl -fsSL "$ZOOKEEPER_MANIFEST_URL") \
  -o <(
    cat <<'EOF'
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

# Success
log_step "✅ All verifications passed!"

# Optional cleanup
if [[ $CLEANUP == true ]]; then
  log_step "Cleaning up deployment"

  log "Deleting deployment..."
  if ! run_cmd bosh -d zookeeper delete-deployment --force; then
    log_error "Failed to delete deployment"
    exit 1
  fi

  log "✓ Cleanup complete"
fi

log_step "Done!"
exit 0
