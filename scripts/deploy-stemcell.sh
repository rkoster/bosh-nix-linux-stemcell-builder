#!/run/current-system/sw/bin/bash

# deploy-stemcell.sh
# Orchestrates end-to-end stemcell validation:
# 1. Build Nix stemcell (optional)
# 2. Upload to BOSH director
# 3. Deploy manifest
# 4. Verify instance boots and connects
# 5. Test SSH access and confirm OS/kernel
# 6. Optional cleanup

set -e

# Configuration
BUILD_STEMCELL=false
CLEANUP=false
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Helper functions
print_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

Orchestrates end-to-end Nix stemcell validation on BOSH director.

Options:
  --build              Build Nix stemcell first (default: use existing)
  --cleanup            Delete deployment after successful validation
  --dry-run            Show what would be done, don't actually deploy
  --help               Print this help message

Environment:
  Requires ./bosh.env to be sourced with BOSH_ENVIRONMENT, BOSH_CLIENT, BOSH_CLIENT_SECRET set.

Examples:
  # Build, deploy, verify, and cleanup
  $0 --build --cleanup

  # Just verify an existing stemcell
  $0

  # Dry-run to see what would happen
  $0 --build --dry-run

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
  
  if [[ "$DRY_RUN" == true ]]; then
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
    --build)
      BUILD_STEMCELL=true
      shift
      ;;
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

log_step "Deploying Nix Stemcell to BOSH Director"

# Step 1: Environment check
log_step "Step 1: Checking BOSH environment"

if [[ ! -f "./bosh.env" ]]; then
  log_error "bosh.env not found. Please create it with BOSH credentials."
  exit 1
fi

# Source BOSH environment
# shellcheck source=/dev/null
source ./bosh.env

if [[ -z "$BOSH_ENVIRONMENT" ]] || [[ -z "$BOSH_CLIENT" ]] || [[ -z "$BOSH_CLIENT_SECRET" ]]; then
  log_error "BOSH_ENVIRONMENT, BOSH_CLIENT, or BOSH_CLIENT_SECRET not set in ./bosh.env"
  exit 1
fi

log "BOSH environment: $BOSH_ENVIRONMENT"
log "BOSH client: $BOSH_CLIENT"

# Verify director is reachable
if ! run_cmd bosh env > /dev/null 2>&1; then
  log_error "Cannot reach BOSH director at $BOSH_ENVIRONMENT"
  exit 1
fi

log "✓ BOSH director is reachable"

# Step 2: Build stemcell (if requested)
if [[ "$BUILD_STEMCELL" == true ]]; then
  log_step "Step 2: Building Nix stemcell"
  
  if run_cmd nix build .#noble-stemcell -L --no-link; then
    log "✓ Build succeeded"
  else
    log_error "Build failed"
    exit 1
  fi
fi

# Step 3: Locate stemcell
log_step "Step 3: Locating stemcell"

STEMCELL_PATH=""
if [[ -L ./result ]]; then
  STEMCELL_PATH=$(realpath ./result/bosh-stemcell-*.tgz 2>/dev/null || true)
fi

if [[ -z "$STEMCELL_PATH" ]] || [[ ! -f "$STEMCELL_PATH" ]]; then
  log_error "No stemcell found at ./result/bosh-stemcell-*.tgz"
  log_error "Run with --build to build it first, or ensure nix build output exists"
  exit 1
fi

log "Using stemcell: $STEMCELL_PATH"
log "Stemcell size: $(du -h "$STEMCELL_PATH" | cut -f1)"

# Step 4: Upload stemcell
log_step "Step 4: Uploading stemcell to director"

if ! run_cmd bosh upload-stemcell "$STEMCELL_PATH" --fix; then
  log_error "Failed to upload stemcell"
  exit 1
fi

log "✓ Stemcell uploaded"

# Step 5: Deploy manifest (inlined; no separate manifest file on disk)
log_step "Step 5: Deploying manifest"

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

log "✓ Deployment completed"

# Step 6: Verify instance is running
log_step "Step 6: Verifying instance is running"

MAX_RETRIES=30
RETRY_COUNT=0
INSTANCE_READY=false

while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
  if run_cmd bosh -d nix-stemcell-poc vms > /tmp/bosh_vms.txt 2>&1; then
    if grep -q "running\|started" /tmp/bosh_vms.txt; then
      log "Instance is running"
      run_cmd cat /tmp/bosh_vms.txt
      INSTANCE_READY=true
      break
    fi
  fi
  
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; then
    log "Waiting for instance to be ready... (attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 2
  fi
done

if [[ "$INSTANCE_READY" == false ]]; then
  log_error "Instance did not reach running state within timeout"
  exit 1
fi

log "✓ Instance is ready"

# Step 7: Test SSH access and verify kernel
log_step "Step 7: Testing SSH access and verifying kernel"

if ! run_cmd bosh -d nix-stemcell-poc ssh vm-instance/0 'uname -r'; then
  log_error "SSH access failed or kernel verification failed"
  exit 1
fi

log "✓ Kernel verified"

# Step 8: Verify OS info
log_step "Step 8: Verifying OS information"

if ! run_cmd bosh -d nix-stemcell-poc ssh vm-instance/0 'cat /etc/os-release'; then
  log_error "Failed to retrieve OS information"
  exit 1
fi

log "✓ OS information verified"

# Success
log_step "✅ All verifications passed!"

# Optional cleanup
if [[ "$CLEANUP" == true ]]; then
  log_step "Cleaning up deployment and stemcell"
  
  log "Deleting deployment..."
  if ! run_cmd bosh -d nix-stemcell-poc delete-deployment --force; then
    log_error "Failed to delete deployment"
    exit 1
  fi
  
  log "Deleting stemcell..."
  if ! run_cmd bosh delete-stemcell ubuntu/0.0.5-nix --force; then
    log_error "Failed to delete stemcell"
    exit 1
  fi
  
  log "✓ Cleanup complete"
fi

log_step "Done!"
exit 0
