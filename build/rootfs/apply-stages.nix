# Pure-Nix (no VM, no chroot) rootfs transform that applies MANY stages in a
# SINGLE fakeroot session: extract the base rootfs.tar.gz once, run every stage
# script in order (each in an isolated subshell), then repack once.
#
# This replaces the previous per-stage mk-stage.nix folded 11x, which
# extracted + gzip-recompressed the full ~3 GB rootfs on every stage. Here the
# expensive extract/repack happens exactly once.
#
# Ownership: the Nix store normalizes file ownership, but the BOSH rootfs needs
# real uid/gid 0 (and package-created users). A single continuous `fakeroot`
# session holds that ownership state end-to-end; the final `tar --numeric-owner`
# serializes it so it survives the store boundary (same guarantee mk-stage.nix
# gave, without re-deriving it 11 times). See the auditd/sshd/sudo "not owned by
# root" failure mode this prevents.
#
# Compression: intermediate gzip is not load-bearing (tar -xf auto-detects), so
# the single final repack uses parallel `pigz -1`.
{ stdenv, fakeroot, gnutar, pigz, coreutils, gnused, gawk, gnugrep, findutils }:
{ base, stages }:
let
  runStages = builtins.concatStringsSep "\n" (map (st: ''
    echo "=== stage: ${st.name} ==="
    ( set -euxo pipefail
      ${st.script}
    )
  '') stages);
in
stdenv.mkDerivation {
  name = "os-image";
  nativeBuildInputs = [ fakeroot gnutar pigz coreutils gnused gawk gnugrep findutils ];
  buildCommand = ''
    fakeroot bash -euxo pipefail <<'IN_FAKEROOT'
    ${builtins.readFile ../lib/hermetic-guard.sh}

    root="$PWD/root"
    mkdir -p "$root"
    tar -xzf ${base}/rootfs.tar.gz -C "$root"

    # --- stage scripts run here in order; $root is the rootfs tree ---
    ${runStages}
    # ------------------------------------------------------------------

    # Note: do NOT add a blanket "chmod u+r" here.  fakeroot's chmod only
    # updates the fakeroot metadata database; the real file permissions are
    # never changed.  tar reads files via the real permissions (always
    # accessible) and records the fakeroot-reported modes in the archive,
    # so mode-0000 security files (gshadow, shadow) are correctly packed
    # without any workaround.  A previous "-perm /000 -exec chmod u+r"
    # invocation used the wrong find predicate (-perm /000 with mask 000
    # matches ALL files) and silently reset every file to at least mode 0400,
    # breaking the gshadow/shadow security-mode tests.

    mkdir -p "$out"
    tar --numeric-owner --one-file-system -C "$root" -cf - . | pigz -1 > "$out/rootfs.tar.gz"
    IN_FAKEROOT
  '';
}
