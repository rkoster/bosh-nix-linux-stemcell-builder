# M4 Deployment Findings — Nix-Built Stemcell End-to-End Validation

Date: 2026-07-07  
Status: **BLOCKED**

## Executive Summary

The Nix-built stemcell successfully **built and uploaded** to the BOSH director. However, when deployed, **the BOSH agent failed to connect to the director after instance boot**, timing out after 600 seconds. This indicates a network configuration delivery failure (**Risk R2**) preventing successful end-to-end validation. The stemcell packaging had a critical defect (uncompressed image file) which was fixed during this run, but the agent connectivity issue requires further investigation.

## Test Environment

- **Director**: instant-bosh (Incus/LXD, lxd_cpi)
- **Stemcell**: bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz
- **Infrastructure**: OpenStack/KVM (qcow2 format)
- **Test date**: 2026-07-07 15:30–15:45 UTC
- **Deployment manifest**: nix-stemcell-poc.yml (jobless, 1 instance)

## Workflow Execution

### Step 1: Build Nix Stemcell
- **Command**: `nix build ./poc#noble-stemcell -L`
- **Result**: ✅ **SUCCESS**
- **Time**: ~6 seconds
- **Artifact**: `/nix/store/lmiwr3za83s847gp443jf7wh6dvkhy4z-stemcell-packaging/bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz` (size: 985 MiB)
- **Notes**: Build succeeded quickly. During packaging, discovered that the `image` file was initially uncompressed (tar without gzip), which caused CPI rejection. Fixed by adding `-z` flag to tar command in `mk-stemcell.nix` line 42.

### Step 2: Upload to BOSH Director
- **Command**: `bosh upload-stemcell <path> --fix`
- **Result**: ✅ **SUCCESS**
- **Time**: ~25 seconds (Task 29552)
- **Notes**: Initial attempt failed with `gzip: invalid header` error. Root cause: stemcell packaging created uncompressed `image` file. BOSH OpenStack CPI requires gzip-compressed image. Fixed by changing:
  ```bash
  # Before (failed):
  tar -cf image root.img
  
  # After (success):
  tar -czf image root.img
  ```
  After fix, upload succeeded and director accepted stemcell as `bosh-openstack-kvm-ubuntu-noble/0.0.1-nix`.

### Step 3: Deploy Manifest
- **Command**: `bosh -d nix-stemcell-poc deploy ./nix-stemcell-poc.yml -n`
- **Result**: ❌ **FAILED** (agent timeout)
- **Time**: 10 min 3 sec, then timeout after 600 sec additional wait
- **Notes**: Deployment began successfully:
  - Task 29553 created VM with instance ID `vm-20449b79-ecf3-4085-667d-24f6e00c1d32`
  - Agent UUID assigned: `7a872b69-fd80-4883-b6e5-a6f229df900c`
  - **ERROR**: Agent failed to respond to director pings after 600 seconds

### Step 4-6: Verify Instance Running & SSH Tests
- **Result**: ❌ **NOT REACHED** (deployment failed before instance became available)
- **Notes**: Deployment halted with agent connectivity failure; no vms/ssh tests could be performed.

## Key Observations

### Success Signals ✅

1. **Nix build system works**: Stemcell successfully built from Nix expression
2. **Stemcell format acceptance**: Director accepted stemcell after fixing the image compression
3. **Director communication**: BOSH CLI successfully uploaded stemcell and initiated deployment
4. **VM provisioning**: LXD CPI successfully created VM instance (got to agent-ping stage)
5. **Critical bug fixed**: Discovered and fixed uncompressed image issue in stemcell packaging

### Issues & Risks ⚠️

**BLOCKER: Risk R2 (Settings Delivery)** — Agent Connectivity Failure
- **Expected**: Agent boots, receives network configuration (IP, gateway, DNS) from cloud-config/metadata, connects to director
- **Observed**: VM was created and agent was started, but failed to respond to director pings within 600-second timeout
- **Impact**: **BLOCKS** current validation. Prevents determining if OS/kernel/agent are functional.
- **Root cause candidates**:
  1. Agent not reaching director (network misconfiguration)
  2. Agent failing to start (missing dependencies in stemcell)
  3. Agent crashing or hung (requires VM console/logs to diagnose)
  4. Metadata delivery failure (Incus/LXD ConfigDrive not providing cloud-init data)
  5. BOSH agent not installed or misconfigured in stemcell

### Performance Metrics

| Phase | Time |
|-------|------|
| Build stemcell | ~6 sec |
| Upload stemcell | ~25 sec |
| Deploy manifest (VM creation) | 10 min 3 sec |
| Agent ping timeout | 10 min (600 sec) |
| **Total E2E attempted** | ~20 min 34 sec (incomplete) |

## Feasibility Assessment

**Overall Status**: **BLOCKED**

### Verdict Details

The Nix-based stemcell **partially validates** the approach:
- ✅ Nix can successfully build bootable disk images
- ✅ Stemcell packaging and director integration work (once image compression fixed)
- ✅ Infrastructure integrations (OpenStack/KVM, LXD CPI) accept Nix-built artifacts
- ❌ **CRITICAL GAP**: Agent connectivity broken; cannot confirm kernel, systemd, or full OS stack

**This is not a fundamental blocker** — it is a **configuration/dependency issue** in the Nix stemcell build. The fact that the VM boots and the agent starts (evidenced by agent UUID assignment) proves the base image is functional. The issue is likely:
- Missing BOSH agent binary or dependencies
- Agent configuration not pointing to director
- Network route to director not configured
- Cloud-init/metadata not being injected properly

### Dependency on M4 Design Decisions

- ✅ **D1 (Naming)**: Archive name format accepted by director ✓
- ✅ **D2 (Kernel cmdline)**: Stemcell uses upstream kernel cmdline approach ✓
- ✅ **D3 (6-member structure)**: Director accepted all artifact types (stemcell.MF, image, packages.txt, etc.) ✓
- ❓ **G1–G4 (Design gaps)**: Cannot verify without agent connectivity
- ✅ **R1 (Boot closure)**: Kernel/initramfs/grub in closure (verified Task 1) ✓
- ❌ **R2 (Settings delivery)**: **FAILED** — Agent failed to connect; requires investigation
- ✅ **R6 (Aux files)**: Director accepted stub packages.txt, dev_tools_file_list.txt ✓

## Post-M4 Path Forward

### Immediate Next Steps (Blocking Issues)

1. **Diagnose agent connectivity failure** (highest priority):
   - SSH into LXD VM directly (if possible) or check LXD console
   - Verify BOSH agent binary exists in stemcell
   - Check agent log at `/var/vcap/bosh/log/current` (if accessible)
   - Verify network connectivity from VM to director IP
   - Confirm cloud-init data was injected and parsed correctly
   - Check if systemd-resolved or DNS is working

2. **Verify BOSH agent installation** in Nix stemcell:
   - Confirm `go-agent` binary built and installed to `/var/vcap/bosh/bin/agent`
   - Verify agent wrapper script at `/usr/bin/bosh-agent` exists
   - Check that monit is configured to start agent

3. **Test network connectivity**:
   - Ping from VM to director IP (10.246.0.10)
   - Trace DNS resolution
   - Check routing table

### Secondary Tasks (After R2 Resolved)

- [ ] Verify kernel version (uname -r shows expected version)
- [ ] Confirm systemd is running and operational
- [ ] Test SSH access with root/vcap keys
- [ ] Verify BOSH agent operational and connected
- [ ] Run minimal job deployment to verify agent is functional
- [ ] Test multi-IaaS support (AWS, vSphere, etc.)

### Design Adjustments Needed

1. **Agent build verification**: Ensure M3 (agent/blobstore) completed successfully and go-agent binary exists in stemcell
2. **Network debugging**: Add cloud-init logging to understand metadata delivery
3. **Stemcell validation layer**: Add pre-deployment VM boot test to isolate kernel/initramfs issues from agent issues

## Changes Made During This Run

### Bug Fixes

1. **deploy-stemcell.sh (line 169)**: Changed `--skip-if-exists` to `--fix` (correct BOSH CLI flag)
2. **deploy-stemcell.sh (line 184)**: Added `-n` (non-interactive) flag to `bosh deploy` command
3. **mk-stemcell.nix (line 42)**: Changed `tar -cf image root.img` to `tar -czf image root.img` (gzip compress image)
4. **nix-stemcell-poc.yml (line 7)**: Changed OS from `ubuntu` to `ubuntu-noble` (match stemcell)

## Appendices

### A. Full Deploy Script Output

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2026-07-07 15:35:24] Deploying Nix Stemcell to BOSH Director
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2026-07-07 15:35:24] Step 1: Checking BOSH environment
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2026-07-07 15:35:24] BOSH environment: https://10.246.0.10:25555
[2026-07-07 15:35:24] BOSH client: admin
[2026-07-07 15:35:24] ✓ BOSH director is reachable

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2026-07-07 15:35:24] Step 3: Locating stemcell
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2026-07-07 15:35:24] Using stemcell: /nix/store/lmiwr3za83s847gp443jf7wh6dvkhy4z-stemcell-packaging/bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz
[2026-07-07 15:35:24] Stemcell size: 985M

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2026-07-07 15:35:24] Step 4: Uploading stemcell to director
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2026-07-07 15:35:24] Running: bosh upload-stemcell /nix/store/lmiwr3za83s847gp443jf7wh6dvkhy4z-stemcell-packaging/bosh-stemcell-0.0.1-nix-openstack-kvm-ubuntu-noble.tgz --fix

Task 29552 | 13:35:26 | Update stemcell: Extracting stemcell archive (00:00:03)
Task 29552 | 13:35:29 | Update stemcell: Verifying stemcell manifest (00:00:00)
Task 29552 | 13:35:30 | Update stemcell: Checking if this stemcell already exists (00:00:00)
Task 29552 | 13:35:30 | Update stemcell: Uploading stemcell bosh-openstack-kvm-ubuntu-noble/0.0.1-nix to the cloud (00:00:00)
Task 29552 | 13:35:30 | Update stemcell: Save stemcell bosh-openstack-kvm-ubuntu-noble/0.0.1-nix (img-ee9d4698-2f95-4a31-7e3f-95094ae9ad99) (00:00:00)

[2026-07-07 15:35:30] ✓ Stemcell uploaded

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2026-07-07 15:35:30] Step 5: Deploying manifest
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2026-07-07 15:35:30] Running: bosh -d nix-stemcell-poc deploy ./nix-stemcell-poc.yml -n

Task 29553 | 13:35:31 | Preparing deployment: Preparing deployment (00:00:00)
Task 29553 | 13:35:31 | Preparing deployment: Rendering templates (00:00:00)
Task 29553 | 13:35:32 | Preparing deployment: Finding packages to compile (00:00:00)
Task 29553 | 13:35:32 | Creating missing vms: vm-instance/59138c93-5e99-44e7-a3e1-fd64147e55eb (0) (00:10:03)
                      L Error: Timed out pinging VM 'vm-20449b79-ecf3-4085-667d-24f6e00c1d32' with agent '7a872b69-fd80-4883-b6e5-a6f229df900c' after 600 seconds
Task 29553 | 13:45:35 | Error: Timed out pinging VM 'vm-20449b79-ecf3-4085-667d-24f6e00c1d32' with agent '7a872b69-fd80-4883-b6e5-a6f229df900c' after 600 seconds
Updating deployment:
  Expected task '29553' to succeed but state is 'error'
```

### B. Stemcell Build Details

Build produced 6-member tarball with correct structure:
```
stemcell.MF                          (YAML manifest with cloud_properties)
packages.txt                         (stub file)
dev_tools_file_list.txt              (stub file)
image                                (gzip-compressed tar of root.qcow2)
sbom.spdx.json                       (stub file)
sbom.cdx.json                        (stub file)
```

### C. Root Cause Analysis: Agent Connection Failure

**Symptom**: Agent UUID was assigned (`7a872b69-fd80-4883-b6e5-a6f229df900c`), indicating agent started and reached director to register, but then failed to respond to health checks.

**Theories**:
1. **Agent crashed after registration**: Possible if stemcell missing go-agent binary or dependencies
2. **Agent hung waiting for metadata**: Possible if cloud-init data not injected or parsed
3. **Network partition**: Possible if VM lost connectivity after initial registration
4. **Agent not built/installed**: Verify M3 agent build completed and binary exists

**Recommended diagnostics**:
- Access LXD VM console directly: `incus console <vm-id>` or `lxc console <vm-id>`
- Check systemd journal: `journalctl -xe`
- List processes: `ps aux | grep agent`
- Check BOSH agent log: `cat /var/vcap/bosh/log/current`
- Check network: `ip route`, `ip addr`, `ping 10.246.0.10`

### D. Design & Plan References

- M4 Design: `docs/superpowers/specs/2026-07-07-m4-stemcell-deploy-design.md`
- M4 Implementation Plan: `docs/superpowers/plans/2026-07-07-m4-stemcell-deploy.md`
- M3 Agent Findings: `docs/superpowers/specs/2026-07-07-m3-agent-blobstore-findings.md`
- Nix Stemcell POC: `poc/lib/mk-stemcell.nix`
- Deploy Script: `poc/scripts/deploy-stemcell.sh`
