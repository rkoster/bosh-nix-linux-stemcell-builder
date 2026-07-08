# DEBUG ONLY: Enable root login for emergency debugging of agent connectivity issues.
# This overlay is temporary and should be removed from production stemcells.
# Placed after ssh.nix to modify its configuration.

{ stageAssets }:
{
  name = "debug-ssh-root-login";
  script = ''
    # DEBUG ONLY: Enable root login for emergency debugging
    # This should be removed from production stemcells

    # DEBUG ONLY: Enable root login for emergency debugging.
    # Deterministically drop every PermitRootLogin line (commented or not,
    # including the "PermitRootLogin no" that base_ssh appends) and set one
    # authoritative "yes". sshd honours the first match, so leaving stale lines
    # around is fragile — remove them all.
    sed -i '/^[[:space:]]*#\?[[:space:]]*PermitRootLogin/d' "$root/etc/ssh/sshd_config"
    echo "PermitRootLogin yes" >> "$root/etc/ssh/sshd_config"

    # DEBUG ONLY: base_ssh sets "DenyUsers root" and "AllowGroups bosh_sshers",
    # which override PermitRootLogin and block root login entirely. Remove the
    # DenyUsers restriction and ensure root can pass the AllowGroups/AllowUsers
    # gate so the pre-baked /root/.ssh key actually works for emergency debug.
    sed -i '/^ *DenyUsers/d' "$root/etc/ssh/sshd_config"
    sed -i '/^ *AllowUsers/d' "$root/etc/ssh/sshd_config"
    echo "AllowUsers root vcap" >> "$root/etc/ssh/sshd_config"

    # sshd requires the user to satisfy BOTH AllowUsers and AllowGroups. root is
    # not in bosh_sshers, so widen AllowGroups to include root's primary group.
    sed -i '/^ *AllowGroups/d' "$root/etc/ssh/sshd_config"
    echo "AllowGroups bosh_sshers root" >> "$root/etc/ssh/sshd_config"
  '';
}
