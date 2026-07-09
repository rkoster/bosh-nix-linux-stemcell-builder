# Zookeeper End-to-End Validation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the canonical BOSH acceptance test (zookeeper-release, 3-node quorum) against the M6 Nix-built stemcell and run the smoke-tests errand to confirm the stemcell is fully functional end-to-end.

**Architecture:** Rebuild the stemcell from the M6 os-image (oracle-green), bump to version `0.0.2-nix`, upload to the Incus BOSH director, upload zookeeper-release, deploy with an adapted manifest (ubuntu-noble, 3 instances), and run the smoke-tests errand.

**Tech Stack:** Nix flake (`poc/`), BOSH CLI, zookeeper-release v0.0.10, existing Incus director (`instant-bosh`, LXD CPI), cloud-config with azs z1/z2/z3, vm_type `default`, network `default`.

---

## Context

| Item | Value |
|------|-------|
| Director | `instant-bosh` (Incus/LXD CPI, source from `bosh.env`) |
| Current nix stemcell on director | `bosh-openstack-kvm-ubuntu-noble/0.0.1-nix` (pre-M6) |
| Target new version | `0.0.2-nix` |
| Existing deployment to clean up | `nix-stemcell-poc` (bare, no releases, using `0.0.1-nix`) |
| Zookeeper release version | `0.0.10` |
| Oracle result | 366/366 pass (M6, commit `cfc0991`) |
| Re-upload sequence | delete-deployment → delete-stemcell → upload-stemcell → deploy |

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `poc/examples/noble-stemcell.nix` | Modify | Bump stemcell version `0.0.1-nix` → `0.0.2-nix` |
| `manifests/zookeeper.yml` | Create | Adapted zookeeper manifest (ubuntu-noble, 3 instances, nix stemcell) |

---

## Task 1: Bump stemcell version and rebuild

**Files:**
- Modify: `poc/examples/noble-stemcell.nix` (line with `version = "0.0.1-nix"`)

- [ ] **Step 1.1: Bump version in noble-stemcell.nix**

Edit `poc/examples/noble-stemcell.nix`, changing:
```nix
  version = "0.0.1-nix";
```
to:
```nix
  version = "0.0.2-nix";
```

- [ ] **Step 1.2: Build the M6 stemcell**

```bash
cd poc
nix build .#noble-stemcell --log-format bar-with-logs -L
```

This runs in a Linux VM (`runInLinuxVM`): partitions a qcow2 disk, extracts
`rootfs.tar.gz`, installs grub (BIOS + EFI), then packages the 6-member
stemcell tarball. Expect **15–25 minutes**.

Expected output file: `result/bosh-stemcell-0.0.2-nix-openstack-kvm-ubuntu-noble.tgz`

Verify it exists and is sane:
```bash
ls -lh poc/result/bosh-stemcell-0.0.2-nix-openstack-kvm-ubuntu-noble.tgz
# Expected: ~300–500 MB file

tar -tzf poc/result/bosh-stemcell-0.0.2-nix-openstack-kvm-ubuntu-noble.tgz
# Expected members: stemcell.MF  packages.txt  dev_tools_file_list.txt
#                   image  sbom.spdx.json  sbom.cdx.json
```

- [ ] **Step 1.3: Commit version bump**

```bash
git add poc/examples/noble-stemcell.nix
git commit -m "chore: bump nix stemcell version to 0.0.2-nix (M6 oracle-green build)"
```

---

## Task 2: Clean up old stemcell deployment

**Goal:** Free the director's reference to the pre-M6 `0.0.1-nix` stemcell so it can be deleted.

- [ ] **Step 2.1: Source BOSH credentials**

```bash
source ./bosh.env
```

- [ ] **Step 2.2: Delete the bare nix-stemcell-poc deployment**

```bash
bosh delete-deployment -d nix-stemcell-poc --force -n
```

Expected: `Deleted deployment 'nix-stemcell-poc'`

- [ ] **Step 2.3: Delete old nix stemcell**

```bash
bosh delete-stemcell bosh-openstack-kvm-ubuntu-noble/0.0.1-nix -n
```

Expected: `Deleted stemcell 'bosh-openstack-kvm-ubuntu-noble/0.0.1-nix'`

- [ ] **Step 2.4: Confirm stemcell list**

```bash
bosh stemcells
```

`0.0.1-nix` should be gone. `1.425` and `1.333` (upstream stemcells) remain.

---

## Task 3: Upload M6 stemcell

- [ ] **Step 3.1: Upload stemcell**

```bash
bosh upload-stemcell \
  poc/result/bosh-stemcell-0.0.2-nix-openstack-kvm-ubuntu-noble.tgz
```

Expected: `Succeeded` and the stemcell appears in:
```bash
bosh stemcells
# bosh-openstack-kvm-ubuntu-noble   0.0.2-nix   ubuntu-noble   ...
```

---

## Task 4: Upload zookeeper release

- [ ] **Step 4.1: Upload zookeeper-release v0.0.10**

```bash
bosh upload-release \
  https://github.com/cppforlife/zookeeper-release/releases/download/v0.0.10/zookeeper-release-0.0.10.tgz
```

If the URL 404s (GitHub release assets sometimes move), use the git+https form:
```bash
bosh upload-release --sha1 skip \
  git+https://github.com/cppforlife/zookeeper-release
```

Expected:
```bash
bosh releases | grep zookeeper
# zookeeper   0.0.10*   ...
```

---

## Task 5: Write the adapted zookeeper manifest

**Files:**
- Create: `manifests/zookeeper.yml`

The upstream manifest targets `ubuntu-xenial` with 5 instances across 3 AZs.
We change:
- Stemcell `ubuntu-xenial` → `ubuntu-noble`, version `0.0.2-nix`
- `instances: 5` → `instances: 3` (minimum viable quorum; saves resources)

- [ ] **Step 5.1: Create manifests/ directory**

```bash
mkdir -p manifests
```

- [ ] **Step 5.2: Write manifests/zookeeper.yml**

```yaml
name: zookeeper

releases:
- name: zookeeper
  version: "0.0.10"

stemcells:
- alias: default
  os: ubuntu-noble
  version: "0.0.2-nix"

update:
  canaries: 1
  max_in_flight: 1
  canary_watch_time: 5000-60000
  update_watch_time: 5000-60000

instance_groups:
- name: zookeeper
  azs: [z1, z2, z3]
  instances: 3
  jobs:
  - name: zookeeper
    release: zookeeper
    provides:
      conn: {shared: true}
    properties: {}
  - name: status
    release: zookeeper
    properties: {}
  vm_type: default
  stemcell: default
  persistent_disk: 10240
  networks:
  - name: default

- name: smoke-tests
  azs: [z1]
  lifecycle: errand
  instances: 1
  jobs:
  - name: smoke-tests
    release: zookeeper
    properties: {}
  vm_type: default
  stemcell: default
  networks:
  - name: default
```

- [ ] **Step 5.3: Commit manifest**

```bash
git add manifests/zookeeper.yml
git commit -m "feat: add adapted zookeeper manifest for nix stemcell e2e validation"
```

---

## Task 6: Deploy zookeeper

- [ ] **Step 6.1: Deploy**

```bash
bosh deploy -d zookeeper manifests/zookeeper.yml -n
```

This compiles zookeeper packages (first deploy takes longer; compilation VMs use
`vm_type: compilation` per cloud-config). Expect **10–20 minutes** for first deploy.

Watch for:
- `Creating missing vms` — 3 zookeeper VMs + compilation VMs
- `Updating instance zookeeper` — agent running, packages installed
- `Succeeded` at the end

If deploy fails, check the task output:
```bash
bosh task --recent 5
bosh task <TASK_ID> --debug | tail -100
```

- [ ] **Step 6.2: Confirm instances are running**

```bash
bosh -d zookeeper instances --ps
```

Expected: 3 `zookeeper` instances in `running` state, each with `zookeeper` and
`status` processes listed as `running`.

```bash
bosh -d zookeeper vms
```

---

## Task 7: Run smoke-tests errand

- [ ] **Step 7.1: Run the smoke-tests errand**

```bash
bosh -d zookeeper run-errand smoke-tests --keep-alive
```

`--keep-alive` keeps the errand VM around on failure so you can `bosh ssh` into it.

Expected output: the errand connects to each zookeeper node, writes a value, reads
it back, and reports success. Final line: `Errand 'smoke-tests' completed successfully`.

- [ ] **Step 7.2: Confirm errand result**

```bash
bosh tasks --recent 3
```

Task type `run_errand` should show `done`.

---

## Task 8: Record findings and commit

- [ ] **Step 8.1: Capture key evidence**

```bash
bosh -d zookeeper instances --ps 2>&1 | tee /tmp/zookeeper-instances.txt
bosh tasks --recent 5 2>&1 | tee /tmp/bosh-tasks.txt
```

- [ ] **Step 8.2: Write findings doc**

Create `docs/superpowers/specs/2026-07-08-m7-zookeeper-e2e-findings.md` documenting:
- Stemcell version used (`0.0.2-nix`)
- Whether deploy succeeded
- Whether smoke-tests errand passed
- Any issues encountered and how they were resolved
- Overall feasibility signal: "Nix-built stemcell successfully hosts a real BOSH workload"

- [ ] **Step 8.3: Commit all findings**

```bash
git add docs/superpowers/specs/2026-07-08-m7-zookeeper-e2e-findings.md
git commit -m "docs: M7 zookeeper e2e findings — nix stemcell hosts real BOSH workload"
```

---

## Troubleshooting Reference

### Deploy fails at VM creation
```bash
bosh -d zookeeper cloud-check  # detect/fix VM issues
bosh task <ID> --debug | grep -E "Error|error|fail"
```

### Agent doesn't come up (timeout waiting for agent)
- SSH into VM via `bosh -d zookeeper ssh zookeeper/0`
- Check: `sudo systemctl status bosh-agent`
- Check: `sudo journalctl -u bosh-agent -n 50`
- Look for monit issues: `sudo /var/vcap/bosh/bin/monit summary`

### Package compilation fails
- BOSH compiles ruby/java packages — check compilation VM has internet or
  use pre-compiled releases from `releases.yml` if available
- Check: `bosh task <compilation-task-id> --debug`

### smoke-tests errand fails
- `bosh -d zookeeper ssh smoke-tests/0` (with `--keep-alive`)
- Check `/var/vcap/sys/log/smoke-tests/smoke-tests.stderr.log`
