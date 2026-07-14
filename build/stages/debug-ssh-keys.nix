# DEBUG ONLY: Pre-bake SSH public key for emergency debugging of agent connectivity issues.
# This stage is temporary and should be removed from production stemcells.
# Allows direct SSH access when BOSH agent fails to connect to the director.

{ sshPubKey }:
{
  name = "debug-ssh-keys";
  script = ''
    # DEBUG ONLY: Pre-bake SSH public key for emergency debugging
    # This allows direct SSH access when BOSH agent fails to connect
    # This should be removed from production stemcells

    mkdir -p "$root/root/.ssh"

    # Install the public key
    cat > "$root/root/.ssh/authorized_keys" << 'PUBKEY'
${sshPubKey}
PUBKEY

    # Set correct permissions
    chmod 600 "$root/root/.ssh/authorized_keys"
    chmod 700 "$root/root/.ssh"
  '';
}
