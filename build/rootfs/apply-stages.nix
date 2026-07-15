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
{
  stdenv,
  fakeroot,
  gnutar,
  pigz,
  coreutils,
  gnused,
  gawk,
  gnugrep,
  findutils,
  dpkg,
  file,
}:
{ base, stages }:
let
  devToolsPackages = import ./dev-tools-packages.nix;
  devToolsBashArray = builtins.concatStringsSep " " (
    map (p: "\"${p}\"") devToolsPackages
  );
  runStages = builtins.concatStringsSep "\n" (
    map (st: ''
      echo "=== stage: ${st.name} ==="
      ( set -euxo pipefail
        ${st.script}
      )
    '') stages
  );
in
stdenv.mkDerivation {
  name = "os-image";
  nativeBuildInputs = [
    fakeroot
    gnutar
    pigz
    coreutils
    gnused
    gawk
    gnugrep
    findutils
    dpkg
    file
  ];
  buildCommand = ''
    fakeroot bash -euxo pipefail <<'IN_FAKEROOT'
    ${builtins.readFile ../lib/hermetic-guard.sh}

    # Reproducibility: normalize every archive mtime to a fixed epoch and sort
    # entries by name so the repack is byte-identical across rebuilds. Without
    # this the stage-modified files carry wall-clock mtimes and readdir order is
    # not guaranteed, making the tarball non-deterministic. See the final tar.
    export SOURCE_DATE_EPOCH=1700000000

    export root="$PWD/root"
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
    # --numeric-owner preserves the real uid/gid state fakeroot recorded (root
    # for system files, 1000/1000 for vcap); --sort=name + --mtime give a
    # deterministic entry order and fixed timestamps; pigz -n omits the gzip
    # name/mtime header. Together these make rootfs.tar.gz bit-for-bit
    # reproducible across rebuilds.
    tar --numeric-owner --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
      --one-file-system -C "$root" -cf - . | pigz -1n > "$out/rootfs.tar.gz"

    # --- stemcell metadata: packages.txt + dev_tools_file_list.txt ---------
    # Generated from the real dpkg admindir baked into $root by the deb-closure
    # base rootfs. Pure (no VM); dpkg-query only reads the text db.
    mkdir -p "$out/metadata"
    admindir="$root/var/lib/dpkg"

    # packages.txt: exact `dpkg -l` column format (upstream bosh_package_list).
    dpkg-query --admindir="$admindir" -l > "$out/metadata/packages.txt"

    # dev_tools_file_list.txt: for each dev-tool package that is actually
    # installed, list its regular files (excluding directories and symlinks),
    # sorted + unique. Mirrors upstream generate_dev_tools_file_list.sh.
    dev_tools_pkgs=( ${devToolsBashArray} )
    dev_tools_tmp="$(mktemp)"
    for pkg in "''${dev_tools_pkgs[@]}"; do
      if dpkg-query --admindir="$admindir" -W "$pkg" >/dev/null 2>&1; then
        dpkg-query --admindir="$admindir" -L "$pkg" 2>/dev/null || true
      fi
    done > "$dev_tools_tmp" || true

    : > "$out/metadata/dev_tools_file_list.txt"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      target="$root$p"
      # keep only regular files that are not symlinks (upstream filters dirs +
      # symlinks via `file`)
      if [ -f "$target" ] && [ ! -L "$target" ]; then
        printf '%s\n' "$p"
      fi
    done < "$dev_tools_tmp" | sort -u > "$out/metadata/dev_tools_file_list.txt"
    IN_FAKEROOT
  '';
}
