# DEBUG ONLY: Enable root login for emergency debugging of agent connectivity issues.
# This overlay is temporary and should be removed from production stemcells.
# Placed after ssh.nix to modify its configuration.

{ stageAssets }:
{
  name = "debug-ssh-root-login";
  script = ''
    # DEBUG ONLY: Enable root login for emergency debugging
    # This should be removed from production stemcells

    # Try to uncomment or add PermitRootLogin yes
    if grep -q "^#PermitRootLogin" "$root/etc/ssh/sshd_config"; then
      # Line exists but is commented; uncomment it
      sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' "$root/etc/ssh/sshd_config"
    elif grep -q "^PermitRootLogin" "$root/etc/ssh/sshd_config"; then
      # Line already exists; make sure it's set to yes
      sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' "$root/etc/ssh/sshd_config"
    else
      # Line doesn't exist; add it
      echo "PermitRootLogin yes" >> "$root/etc/ssh/sshd_config"
    fi
  '';
}
