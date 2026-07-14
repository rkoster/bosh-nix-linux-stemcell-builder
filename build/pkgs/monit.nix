# monit 5.2.5 — the exact version the BOSH agent speaks to over its 127.0.0.1:2822
# HTTP interface. Built STATICALLY via pkgsStatic (musl) so the binary carries no
# /nix/store closure and runs inside the FHS stemcell, mirroring how the Go
# agent/blobstore CLIs embed (CGO_ENABLED=0 -> static). pkgsStatic links fully
# static by default, so no explicit -static flag is required.
#
# Reproduces upstream stemcell_builder/stages/bosh_monit/apply.sh:
#   ./configure --prefix=$bosh_dir --without-ssl CFLAGS="-fcommon"
# using the vendored source tarball (no network fetch).
{ lib, pkgsStatic, flex, bison }:
pkgsStatic.stdenv.mkDerivation rec {
  pname = "monit";
  version = "5.2.5";

  # Vendored from the upstream stemcell_builder bosh_monit assets
  # (sha256: 3c2496e9f653ff8a46b75b61126a86cb3861ad35e4eeb7379d64a0fc55c1fd8d).
  src = ./monit-5.2.5.tar.gz;

  # monit's configure generates its lexer/parser at build time.
  nativeBuildInputs = [ flex bison ];

  buildInputs = [ pkgsStatic.zlib ];

  # The 2011-era Makefile hardcodes absolute tool paths (/bin/mv, /bin/rm) that
  # do not exist in the Nix build sandbox. Rewrite them to bare command names so
  # they resolve via $PATH.
  postPatch = ''
    substituteInPlace Makefile.in \
      --replace-quiet /bin/mv mv \
      --replace-quiet /bin/rm rm \
      --replace-quiet /bin/cp cp

    # musl `getopt()` is strict POSIX: it stops scanning at the first non-option,
    # so the agent's ACTION-FIRST invocation `monit stop -g vcap` never parses
    # `-g vcap` (Run.mygroup stays NULL) and monit tries to control a service
    # literally named `-g` -> daemon 404 -> "There is no service by that name"
    # -> exit 1, failing every deploy's "stopping jobs" phase. glibc's getopt
    # permutes argv, which is why the dynamically-linked upstream stemcell works.
    # musl's `getopt_long` DOES implement GNU-style permutation, so switch to it
    # (empty long-options table). getopt.h is already included at monitor.c:51.
    # See docs/superpowers/specs/2026-07-08-m5-monit-getopt-ssh-findings.md.
    # --replace-fail: if the vendored source ever changes this line, fail the
    # build loudly rather than silently reintroducing the musl getopt bug.
    substituteInPlace monitor.c \
      --replace-fail 'getopt(argc,argv,"c:d:g:l:p:s:iItvVhH")' \
                     'getopt_long(argc,argv,"c:d:g:l:p:s:iItvVhH",(const struct option[]){{0,0,0,0}},NULL)'
  '';

  # monit 5.2.5 predates modern GCC/toolchain defaults:
  #   -fcommon            : old code relies on common (tentative) definitions
  #   -D_GNU_SOURCE       : expose GNU extensions
  #   -DGLOB_ONLYDIR=0    : musl lacks this glibc glob flag; /proc/[0-9]* entries
  #                         are all directories, so a no-op filter is equivalent
  #   -Wno-*              : 2011-era C compiled by a >=GCC14 toolchain
  env.NIX_CFLAGS_COMPILE = toString [
    "-fcommon"
    "-D_GNU_SOURCE"
    "-DGLOB_ONLYDIR=0"
    "-Wno-implicit-int"
    "-Wno-implicit-function-declaration"
    "-Wno-int-conversion"
    "-Wno-old-style-definition"
  ];

  configureFlags = [
    "--without-ssl"
    "--without-pam"
    # Bake the stemcell control-file location into the binary (-DSYSCONFDIR).
    # The BOSH agent invokes `monit stop -g vcap` etc. WITHOUT `-c`, so monit
    # must find its control file at the default SYSCONFDIR/monitrc. Upstream gets
    # this via `--prefix=/var/vcap/bosh`; we install the binary into the nix
    # store, so set sysconfdir explicitly to match /var/vcap/bosh/etc/monitrc.
    "--sysconfdir=/var/vcap/bosh/etc"
  ];

  enableParallelBuilding = true;
  doCheck = false;

  meta = {
    description = "Monit 5.2.5 (static) for BOSH stemcell process supervision";
    homepage = "https://mmonit.com/monit/";
    license = lib.licenses.gpl3Plus;
  };
}
