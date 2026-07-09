# M2 OS Image Baseline Spec Report

**Date:** 2026-07-06  
**Test Suite:** `bosh-linux-stemcell-builder/bosh-stemcell/spec/os_image/ubuntu_spec.rb`  
**Image:** Ubuntu 24.04 Noble (Nix-built, bare rootfs, no overlays)

## Summary

| Metric | Count |
|--------|-------|
| **Total Examples** | 366 |
| **Passed** | 20 |
| **Failed** | 346 |
| **Skipped** | 0 |
| **Pass Rate** | 5.5% |

## Test Execution

- **Suite ran:** YES ✓
- **Harness loaded:** YES ✓  
  - Bosh stemcell modules loaded via `poc/oracle/lib-slice/`
  - Spec loaded with wrapper to preload `bosh/stemcell` module
  - Serverspec + Specinfra gems pinned and installed
  - Host `sudo` used for chroot/tar operations
- **Duration:** ~6.47 seconds

## Key Findings

### Expected Failures (Fixable by Overlays)

The majority of the 346 failures are due to **missing stages and packages** in the bare rootfs. These are expected and **fixable by adding the corresponding BOSH builder stages as Nix overlays:**

1. **Missing BOSH agent and tools** (~50+ failures)
   - Files like `/var/vcap/bosh/bin/*`, `/var/vcap/sys/*` do not exist
   - **Overlay:** `base_bosh_go_agent` stage

2. **SSH hardening** (~20+ failures)
   - SSH ciphers/HMACs not configured in `/etc/ssh/sshd_config`
   - Missing SSH keys and configuration
   - **Overlay:** `base_ssh` stage

3. **Missing sysctl hardening** (~30+ failures)
   - `/etc/sysctl.d/60-bosh-sysctl.conf` missing
   - Kernel parameters not set (IP forwarding, ASLR, syncookies, etc.)
   - **Overlay:** `bosh_sysctl` stage

4. **Missing auditd configuration** (~50+ failures)
   - Audit rules, plugins, log configuration missing
   - Auditd service not configured for startup
   - **Overlay:** `bosh_audit_hardening` stage (or similar)

5. **Missing user/group management** (~20+ failures)
   - `vcap` user not created
   - User/group file ownership and permissions not set
   - **Overlay:** `bosh_users` stage

6. **Missing PAM/password policy** (~15+ failures)
   - PAM modules not loaded
   - Password quality not configured
   - **Overlay:** `system_pam` or `base_pam` stage

7. **Missing timesync (chrony)** (~10+ failures)
   - `/var/vcap/bosh/bin/sync-time` missing
   - Chrony configuration missing
   - **Overlay:** `base_chrony` stage

8. **Missing system services and permissions** (~80+ failures)
   - Monit service not configured
   - Rsyslog service not configured
   - File ownership/permissions across etc and lib not set
   - **Overlay:** Multiple stages (bosh_monit, bosh_rsyslog, etc.)

### Non-Fixable / Out-of-Scope Findings

None identified at this baseline level. All failing tests appear to be fixable by adding overlays that replicate the builder's stages.

### Sample Failures

```
  1) Ubuntu 24.04 OS image behaves like every OS image 
     etc_environment should have /var/vcap/bosh/bin on the PATH
     RuntimeError: ... (missing /etc/environment content)

  2) Ubuntu 24.04 OS image behaves like every OS image 
     /etc/ssh/sshd_config should have Ciphers configured
     RuntimeError: ... (file does not exist)

  3) Ubuntu 24.04 OS image behaves like every OS image 
     /etc/sysctl.d/60-bosh-sysctl.conf should exist
     Errno::ENOENT: No such file or directory

  4) Ubuntu 24.04 OS image behaves like every OS image 
     auditd should be installed
     RuntimeError: ... (package not found)
```

## Quarantine List (Initial)

**Current status:** Empty. No failures identified that should be quarantined (marked as known-failing / out-of-scope).

All 346 failures are addressable by adding overlay stages. As overlays are implemented, failures will be re-tested and moved from "fixable" to either:
- **Fixed** (passes after overlay)
- **Quarantine** (can't be fixed, must be excluded from tests)

## Next Steps

1. **Task 4:** Implement `base_ssh` overlay to harden SSH config
2. **Task 5+:** Add remaining overlays (sysctl, users, auditd, chrony, etc.)
3. **Re-baseline:** After each overlay, re-run suite to confirm fixes
4. **Quarantine updates:** Any test that remains failing after attempted fixes will be moved to quarantine

## Tech Notes

- **lib-slice location:** `poc/oracle/lib-slice/`
  - Contains: `bosh/stemcell.rb`, `bosh/stemcell/arch.rb`, `bosh/core/shell.rb`, `shellout_types/*`
  - Minimal set to avoid pulling builder build-time dependencies
  - Wrapped spec loading avoids issues with module namespace
- **Gem versions:** Pinned to match builder compatibility (rspec 3.13.2, serverspec 2.42.2, specinfra 2.87.2)
- **Harness:** Uses `STEMCELL_INFRASTRUCTURE=openstack` to select grub paths
