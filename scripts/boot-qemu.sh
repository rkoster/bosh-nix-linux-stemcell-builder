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
qemu-system-x86_64 \
  -enable-kvm -m 2048 -smp 2 -machine q35 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_FD" \
  -drive file="$WORK/disk.qcow2",if=virtio,format=qcow2 \
  -nographic -serial mon:stdio -display none -net none \
  > "$LOG" 2>&1 &
QEMU_PID=$!

# Poll for the login prompt so we can stop as soon as boot succeeds instead of
# waiting out the whole timeout. Kill QEMU on success, failure, or timeout.
deadline=$(( $(date +%s) + 240 ))
result=1
while kill -0 "$QEMU_PID" 2>/dev/null; do
  if grep -Eq 'login:' "$LOG"; then result=0; break; fi
  if [ "$(date +%s)" -ge "$deadline" ]; then break; fi
  sleep 2
done
kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true

echo "--- checking serial log for a login prompt ---"
if [ "$result" -eq 0 ] && grep -Eq 'login:' "$LOG"; then
  echo "BOOT OK: reached login prompt"
  cp "$LOG" "$(dirname "$IMG")/../boot-qemu.log" 2>/dev/null || cp "$LOG" ./boot-qemu.log
  exit 0
else
  echo "BOOT FAIL: no login prompt within timeout"
  cp "$LOG" ./boot-qemu.log
  exit 1
fi
