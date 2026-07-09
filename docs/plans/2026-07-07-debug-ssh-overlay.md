# Debug SSH Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add pre-baked SSH keys and enable root login in the stemcell to allow direct debugging when BOSH agent fails to connect.

**Architecture:** Create two new Nix overlays that modify SSH configuration and install a public key into `/root/.ssh/authorized_keys`. These overlays are inserted into `os-image.nix` after SSH setup but before agent installation. The result is a stemcell where you can SSH directly as root, even if the BOSH agent times out.

**Tech Stack:** Nix, bash overlays, sshd configuration

---

## File Structure

- **Create**: `poc/lib/overlays/debug-ssh-root-login.nix` — Enable root login in sshd_config
- **Create**: `poc/lib/overlays/debug-ssh-keys.nix` — Install public SSH key to authorized_keys
- **Modify**: `poc/examples/os-image.nix` — Add both overlays to the fold
- **Build**: `poc#os-image` and `poc#noble-stemcell` (existing targets, no new entry points needed)

---

## Task 1: Create debug-ssh-root-login.nix overlay

**Files:**
- Create: `poc/lib/overlays/debug-ssh-root-login.nix`

- [ ] **Step 1: Write the debug-ssh-root-login.nix overlay**

Create the file with content that modifies sshd_config to enable root login:

```nix
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
```

- [ ] **Step 2: Verify file exists**

Run: `test -f poc/lib/overlays/debug-ssh-root-login.nix && echo "File created"`

Expected output: `File created`

---

## Task 2: Create debug-ssh-keys.nix overlay

**Files:**
- Create: `poc/lib/overlays/debug-ssh-keys.nix`

- [ ] **Step 1: Write the debug-ssh-keys.nix overlay**

Create the file with content that installs the SSH public key:

```nix
# DEBUG ONLY: Pre-bake SSH public key for emergency debugging of agent connectivity issues.
# This overlay is temporary and should be removed from production stemcells.
# Allows direct SSH access when BOSH agent fails to connect to the director.

{ stageAssets }:
{
  name = "debug-ssh-keys";
  script = ''
    # DEBUG ONLY: Pre-bake SSH public key for emergency debugging
    # This allows direct SSH access when BOSH agent fails to connect
    # This should be removed from production stemcells

    mkdir -p "$root/root/.ssh"

    # Read public key from host (try common key names)
    PUB_KEY=""
    if [ -f "$HOME/.ssh/id_rsa.pub" ]; then
      PUB_KEY=$(cat "$HOME/.ssh/id_rsa.pub")
    elif [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
      PUB_KEY=$(cat "$HOME/.ssh/id_ed25519.pub")
    fi

    if [ -z "$PUB_KEY" ]; then
      echo "ERROR: No SSH public key found in ~/.ssh/" >&2
      exit 1
    fi

    # Install the public key
    echo "$PUB_KEY" >> "$root/root/.ssh/authorized_keys"

    # Set correct permissions
    chmod 600 "$root/root/.ssh/authorized_keys"
    chmod 700 "$root/root/.ssh"
  '';
}
```

- [ ] **Step 2: Verify file exists**

Run: `test -f poc/lib/overlays/debug-ssh-keys.nix && echo "File created"`

Expected output: `File created`

---

## Task 3: Integrate overlays into os-image.nix

**Files:**
- Modify: `poc/examples/os-image.nix` (add two imports and integrate into overlays fold)

- [ ] **Step 1: Read current os-image.nix to understand structure**

Run: `head -35 poc/examples/os-image.nix`

Expected: See the import statements and overlays list starting around line 16.

- [ ] **Step 2: Modify os-image.nix to add debug overlay imports**

Edit `poc/examples/os-image.nix` to add imports after the existing package definitions (around line 14). After the existing package definitions (`bosh-agent`, `davcli`, etc.), add:

```nix
  stageAssets = callPackage ../lib/stage-assets.nix { };
```

(This should already be there, verify it exists.)

Now modify the `overlays` list to include the two new overlays. Change from:

```nix
   overlays = [
      (import ../lib/overlays/users.nix { })
      (import ../lib/overlays/ssh.nix { inherit stageAssets; })
      (import ../lib/overlays/sysctl-limits-env.nix { inherit stageAssets; })
```

To:

```nix
   overlays = [
      (import ../lib/overlays/users.nix { })
      (import ../lib/overlays/ssh.nix { inherit stageAssets; })
      (import ../lib/overlays/debug-ssh-root-login.nix { inherit stageAssets; })
      (import ../lib/overlays/debug-ssh-keys.nix { inherit stageAssets; })
      (import ../lib/overlays/sysctl-limits-env.nix { inherit stageAssets; })
```

- [ ] **Step 3: Verify the modification**

Run: `grep -A 2 "debug-ssh" poc/examples/os-image.nix`

Expected: Should see both debug overlay imports in the list.

---

## Task 4: Build os-image with debug overlays

**Files:**
- Build: `poc#os-image` (existing target, no file changes)

- [ ] **Step 1: Build the os-image**

Run: `cd /home/ruben/workspace/rfc-nix-based-linuxstemcell-builder && nix build ./poc#os-image -L`

Expected: Build succeeds, produces `./result/rootfs.tar.gz`

- [ ] **Step 2: Verify SSH config in tarball**

Run: `tar -tzf ./result/rootfs.tar.gz | grep "etc/ssh/sshd_config"`

Expected: Should see the file listed.

- [ ] **Step 3: Extract and inspect sshd_config**

Run: `tar -xzf ./result/rootfs.tar.gz ./etc/ssh/sshd_config -O | grep -i "permitrootlogin"`

Expected: Should see `PermitRootLogin yes` (or similar)

- [ ] **Step 4: Verify SSH key in tarball**

Run: `tar -tzf ./result/rootfs.tar.gz | grep "root/.ssh/authorized_keys"`

Expected: Should see the file listed.

- [ ] **Step 5: Extract and inspect authorized_keys**

Run: `tar -xzf ./result/rootfs.tar.gz ./root/.ssh/authorized_keys -O`

Expected: Should see your SSH public key (starting with ssh-rsa or ssh-ed25519)

---

## Task 5: Build stemcell with debug overlays

**Files:**
- Build: `poc#noble-stemcell` (existing target, no file changes)

- [ ] **Step 1: Build the stemcell**

Run: `nix build ./poc#noble-stemcell -L`

Expected: Build succeeds, produces `./result/bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz`

- [ ] **Step 2: Verify stemcell contains debug SSH config**

Run: `tar -tzf ./result/bosh-stemcell-*.tgz | head -20`

Expected: Should see member files listed (stemcell.MF, image, packages.txt, etc.)

- [ ] **Step 3: Inspect inner image tarball for SSH config**

Run: `tar -xzf ./result/bosh-stemcell-*.tgz image && tar -tzf image | grep "etc/ssh/sshd_config"`

Expected: Should see the sshd_config file in the inner image.

- [ ] **Step 4: Verify SSH key in inner image**

Run: `tar -tzf image | grep "root/.ssh/authorized_keys"`

Expected: Should see the authorized_keys file in the inner image.

---

## Task 6: Commit the changes

**Files:**
- Modified: `poc/examples/os-image.nix`
- Created: `poc/lib/overlays/debug-ssh-root-login.nix`
- Created: `poc/lib/overlays/debug-ssh-keys.nix`

- [ ] **Step 1: Stage all changes**

Run: `git add poc/lib/overlays/debug-ssh-*.nix poc/examples/os-image.nix`

- [ ] **Step 2: Create commit with warning**

Run: 
```bash
git commit -m "feat(debug): add SSH debug overlays for agent connectivity troubleshooting

- Add debug-ssh-root-login.nix: enables root SSH login in sshd_config
- Add debug-ssh-keys.nix: pre-bakes public SSH key for direct access
- Integrate into os-image.nix after SSH setup, before agent installation
- DEBUG ONLY: These overlays must be removed before production builds
- Allows direct SSH access when BOSH agent fails to connect to director

Debugging workflow after deployment with agent timeout:
  ssh -i ~/.ssh/id_rsa root@<vm-ip>
  systemctl status bosh-agent
  journalctl -u bosh-agent
  cat /var/vcap/bosh/agent.json
"
```

- [ ] **Step 3: Verify commit**

Run: `git log --oneline -3`

Expected: Latest commit should show the debug SSH overlay message.

---

## Summary

This plan creates two debug overlays (SSH root login + pre-baked keys) and integrates them into the os-image build. The stemcell will now include:
- `PermitRootLogin yes` in `/etc/ssh/sshd_config`
- Your public SSH key in `/root/.ssh/authorized_keys`

After deployment (even with agent timeout), you can SSH directly as root to diagnose agent issues:
```bash
ssh -i ~/.ssh/id_rsa root@<vm-ip>
systemctl status bosh-agent
journalctl -u bosh-agent -n 100
```

This enables debugging without waiting for `bosh ssh` or director connectivity.
