#!/usr/bin/env bash
# Headless QEMU/OVMF boot of the Noble image; asserts a getty "login:" prompt on
# the serial console. Requires OVMF_FD (exported by `nix develop ./poc`).
set -euo pipefail

IMG="${1:-result/disk-image.qcow2}"
: "${OVMF_FD:?set OVMF_FD — run inside 'nix develop ./poc'}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp --no-preserve=mode "$IMG" "$WORK/disk.qcow2"
LOG="$WORK/boot.log"

echo "Booting $IMG (timeout 240s, log: $LOG) ..."
timeout 240 qemu-system-x86_64 \
  -enable-kvm -m 2048 -smp 2 -machine q35 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_FD" \
  -drive file="$WORK/disk.qcow2",if=virtio,format=qcow2 \
  -nographic -serial mon:stdio -display none -net none \
  2>&1 | tee "$LOG" || true

echo "--- checking serial log for a login prompt ---"
if grep -Eq 'login:' "$LOG"; then
  echo "BOOT OK: reached login prompt"
  cp "$LOG" "$(dirname "$IMG")/../boot-qemu.log" 2>/dev/null || cp "$LOG" ./boot-qemu.log
  exit 0
else
  echo "BOOT FAIL: no login prompt within timeout"
  cp "$LOG" ./boot-qemu.log
  exit 1
fi
