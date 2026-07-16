# Thin wrapper over vmTools: build `buildCommand` inside a Linux VM with an
# attached empty raw disk of `size` MiB. Used by stemcells/bootable-disk.nix.
{ vmTools, stdenv }:
{
  name,
  size ? 2560,
  buildCommand,
  nativeBuildInputs ? [ ],
  memSize ? 512,
  postVM ? "",
}:
vmTools.runInLinuxVM (
  stdenv.mkDerivation {
    inherit
      name
      buildCommand
      nativeBuildInputs
      memSize
      postVM
      ;
    preVM = vmTools.createEmptyImage {
      inherit size;
      fullName = name;
    };
  }
)
