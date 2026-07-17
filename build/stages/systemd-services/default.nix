# systemd-services stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session.
# maskTmpMount masks systemd's static tmp.mount (systemd 259 / Resolute) by
# symlinking /etc/systemd/system/tmp.mount -> /dev/null. BOSH manages /tmp
# itself. Noble (systemd 255) has no such unit and passes maskTmpMount = false.
{
  maskTmpMount ? false,
}:
{
  name = "systemd-services";
  script = ''
    export STAGE_DIR="${./assets}"
    export MASK_TMP_MOUNT="${if maskTmpMount then "1" else "0"}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
