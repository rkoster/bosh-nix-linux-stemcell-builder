# Pure-Nix (no VM, no chroot) rootfs transform that applies MANY overlays in a
# SINGLE fakeroot session: extract the base rootfs.tar.gz once, run every overlay
# script in order (each in an isolated subshell), then repack once.
#
# This replaces the previous per-overlay mk-overlay.nix folded 11x, which
# extracted + gzip-recompressed the full ~3 GB rootfs on every overlay. Here the
# expensive extract/repack happens exactly once.
#
# Ownership: the Nix store normalizes file ownership, but the BOSH rootfs needs
# real uid/gid 0 (and package-created users). A single continuous `fakeroot`
# session holds that ownership state end-to-end; the final `tar --numeric-owner`
# serializes it so it survives the store boundary (same guarantee mk-overlay.nix
# gave, without re-deriving it 11 times). See the auditd/sshd/sudo "not owned by
# root" failure mode this prevents.
#
# Compression: intermediate gzip is not load-bearing (tar -xf auto-detects), so
# the single final repack uses parallel `pigz -1`.
{ stdenv, fakeroot, gnutar, pigz, coreutils, gnused, gawk, gnugrep, findutils }:
{ base, overlays }:
let
  runOverlays = builtins.concatStringsSep "\n" (map (ov: ''
    echo "=== overlay: ${ov.name} ==="
    ( set -euxo pipefail
      ${ov.script}
    )
  '') overlays);
in
stdenv.mkDerivation {
  name = "os-image";
  nativeBuildInputs = [ fakeroot gnutar pigz coreutils gnused gawk gnugrep findutils ];
  buildCommand = ''
    fakeroot bash -euxo pipefail <<'IN_FAKEROOT'
    root="$PWD/root"
    mkdir -p "$root"
    tar -xzf ${base}/rootfs.tar.gz -C "$root"

    # --- overlay scripts run here in order; $root is the rootfs tree ---
    ${runOverlays}
    # ------------------------------------------------------------------

    # Ensure all files are readable for tar packing (fix any 0000 permissions)
    find "$root" -perm /000 -exec chmod u+r {} \; 2>/dev/null || true

    mkdir -p "$out"
    tar --numeric-owner --one-file-system -C "$root" -cf - . | pigz -1 > "$out/rootfs.tar.gz"
    IN_FAKEROOT
  '';
}
