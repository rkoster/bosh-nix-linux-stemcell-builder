#!/usr/bin/env bash
# Smoke test: boot qcow2 disk locally with QEMU to verify MBR/UEFI bootability.
# Tests both UEFI (with OVMF) and BIOS (legacy) boot paths.
# At least one must succeed (reach boot prompt, kernel messages, or login).
#
# Usage:
#   ./boot-smoke-test.sh [path/to/disk.qcow2]
#
# Environment:
#   OVMF_FD (optional) — path to OVMF firmware. If not set, will resolve from nixpkgs.
#
# Exit codes:
#   0 — boot smoke test passed (at least one boot path succeeded)
#   1 — both boot paths timed out or panicked

set -euo pipefail

IMG="${1:-result/root.qcow2}"

# Resolve OVMF firmware if not already set
if [ -z "${OVMF_FD:-}" ]; then
  echo "ℹ️  OVMF_FD not set; resolving from nixpkgs..."
  OVMF_FD=$(nix eval --raw '<nixpkgs>' -A OVMF.fd 2>/dev/null)
  if [ -z "$OVMF_FD" ]; then
    echo "❌ Failed to resolve OVMF.fd from nixpkgs"
    exit 1
  fi
fi

# Verify input file exists
if [ ! -f "$IMG" ]; then
  echo "❌ Input qcow2 not found: $IMG"
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "QEMU Boot Smoke Test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Image:    $IMG"
echo "OVMF_FD:  $OVMF_FD"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Verify qcow2 format is valid
echo "Validating qcow2 format..."
if ! qemu-img info "$IMG" >/dev/null 2>&1; then
  echo "❌ qcow2 validation failed"
  exit 1
fi
echo "✅ qcow2 format is valid"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Copy disk to temp location (avoids R/O issues)
cp --no-preserve=mode "$IMG" "$WORK/disk.qcow2"

UEFI_LOG="$WORK/boot-uefi.log"
BIOS_LOG="$WORK/boot-bios.log"

# Boot success indicators (match any of these patterns)
BOOT_SUCCESS_PATTERNS=(
  "login:"
  "Linux version"
  "Welcome to Ubuntu"
  "init-bottom"
  "Starting.*network"
  "Cloud-init"
  "Reached target.*Boot"
  "grub>"
)

# Function to check if log contains boot success indicators
check_boot_success() {
  local log="$1"
  for pattern in "${BOOT_SUCCESS_PATTERNS[@]}"; do
    if grep -qi "$pattern" "$log" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Attempt 1: UEFI Boot (OVMF firmware)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Timeout: 60s"
echo ""

if timeout 60 qemu-system-x86_64 \
  -enable-kvm \
  -m 1024 \
  -machine q35 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_FD" \
  -drive file="$WORK/disk.qcow2",if=virtio,format=qcow2 \
  -nographic -serial mon:stdio -display none -net none \
  2>&1 | tee "$UEFI_LOG"; then
  :
else
  # timeout exit code 124 is expected; capture whatever output we got
  :
fi

if check_boot_success "$UEFI_LOG"; then
  echo ""
  echo "✅ UEFI Boot SUCCESS"
  echo "Boot output (first 20 lines):"
  head -20 "$UEFI_LOG"
  exit 0
else
  echo "❌ UEFI boot did not reach expected milestone (timed out or failed early)"
  echo "Boot output (last 20 lines):"
  tail -20 "$UEFI_LOG"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Attempt 2: BIOS Boot (legacy MBR)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Timeout: 60s"
echo ""

if timeout 60 qemu-system-x86_64 \
  -enable-kvm \
  -m 1024 \
  -machine pc \
  -drive file="$WORK/disk.qcow2",if=virtio,format=qcow2 \
  -nographic -serial mon:stdio -display none -net none \
  2>&1 | tee "$BIOS_LOG"; then
  :
else
  # timeout exit code 124 is expected
  :
fi

if check_boot_success "$BIOS_LOG"; then
  echo ""
  echo "✅ BIOS Boot SUCCESS"
  echo "Boot output (first 20 lines):"
  head -20 "$BIOS_LOG"
  exit 0
else
  echo "❌ BIOS boot did not reach expected milestone (timed out or failed early)"
  echo "Boot output (last 20 lines):"
  tail -20 "$BIOS_LOG"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "❌ BOOT SMOKE TEST FAILED"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Neither UEFI nor BIOS boot reached a boot milestone within 60 seconds."
echo ""
echo "Debugging hints:"
echo "  - Check that root.qcow2 was built successfully (Task 2)"
echo "  - Verify the disk has a valid partition table: fdisk -l result/root.qcow2"
echo "  - Run manually for verbose output: qemu-system-x86_64 ... -serial stdio"
echo "  - Check logs: $UEFI_LOG and $BIOS_LOG"
echo ""

exit 1
