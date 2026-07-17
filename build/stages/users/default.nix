# users stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session.
# ACCOUNTS_DIR selects the per-release passwd/shadow/group/gshadow asset set;
# Noble uses the top-level assets dir (byte-identical to before), Resolute uses
# assets/resolute. Shared assets (ps1) always come from STAGE_DIR.
{
  release ? "noble",
}:
let
  accountsDir = if release == "resolute" then "${./assets/resolute}" else "${./assets}";
in
{
  name = "users";
  script = ''
    export STAGE_DIR="${./assets}"
    export ACCOUNTS_DIR="${accountsDir}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
