# Pure-Nix (no VM, no chroot) tarball -> tarball transform.
# Unpacks `base` (a derivation producing $out/rootfs.tar.gz) into a tree, runs `script`
# with $root pointing at the tree, then repacks to $out/rootfs.tar.gz.
{ stdenv, gnutar, gzip, coreutils, gnused, gawk, gnugrep, findutils }:
{ base, name, script }:
stdenv.mkDerivation {
  name = "os-overlay-${name}";
  nativeBuildInputs = [ gnutar gzip coreutils gnused gawk gnugrep findutils ];
  buildCommand = ''
    root=$PWD/root
    mkdir -p "$root"
    tar -xzf ${base}/rootfs.tar.gz -C "$root"

    # --- stage script runs here; $root is the rootfs tree ---
    ${script}
    # --------------------------------------------------------

    # Ensure all files are readable for tar packing (fix any 0000 permissions)
    find "$root" -perm /000 -exec chmod u+r {} \; 2>/dev/null || true

    mkdir -p $out
    tar --numeric-owner --one-file-system -C "$root" -czf $out/rootfs.tar.gz .
  '';
}
