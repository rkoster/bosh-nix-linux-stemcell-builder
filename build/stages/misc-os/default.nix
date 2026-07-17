# misc-os stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{
  codename ? "noble",
}:
{
  name = "misc-os";
  script = ''
    export STAGE_DIR="${./assets}"
    export CODENAME="${codename}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
