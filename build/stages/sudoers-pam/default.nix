# sudoers-pam stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session.
# PAM_LASTLOG2 selects how the pam_lastlog2 line is emitted:
#   "hack"    -> Noble: a commented placeholder (util-linux < 2.40 lacks the module)
#   "package" -> Resolute: an active line + multiarch securedir symlink bridge
{
  pamLastlog2 ? "hack",
}:
{
  name = "sudoers-pam";
  script = ''
    export STAGE_DIR="${./assets}"
    export PAM_LASTLOG2="${pamLastlog2}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
