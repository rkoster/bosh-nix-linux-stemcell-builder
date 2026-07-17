# Operator Runbook: Deploy & Validate the Ubuntu Resolute Stemcell

**Audience:** BOSH operators validating the `ubuntu-resolute` stemcell end-to-end
against a real director. The build/determinism/boot gates are automated in
`nix flake check`; this runbook covers the parts that require a live BOSH
director and are therefore operator-run.

**Operating system:** `ubuntu-resolute` (Ubuntu 26.04-class snapshot pin).
Coexists with the unchanged `ubuntu-noble` stemcell — see the rollback note.

---

## 1. Build the stemcell tarball

Build reproducibly with Nix. Choose the infrastructure you deploy to:

```bash
# OpenStack (qcow2 / KVM)
nix build .#packages.x86_64-linux.resolute-stemcell -o /tmp/res-openstack

# AWS (raw / Xen, root_device_name /dev/sda1, boot_mode uefi-preferred)
nix build .#packages.x86_64-linux.resolute-stemcell-aws -o /tmp/res-aws
```

The output directory contains the stemcell tarball, e.g.:

- `bosh-stemcell-0.0.5-nix-openstack-kvm-ubuntu-resolute.tgz`
- `bosh-stemcell-0.0.5-nix-aws-xen-ubuntu-resolute.tgz`

Both declare `operating_system: ubuntu-resolute`, `version: 0.0.5-nix`.

Optional integrity check (matches the recorded build):

```bash
sha256sum /tmp/res-openstack/*.tgz
```

---

## 2. Upload the stemcell to the director

```bash
bosh upload-stemcell /tmp/res-openstack/*.tgz
# or, for AWS:
bosh upload-stemcell /tmp/res-aws/*.tgz

# Confirm it registered:
bosh stemcells
# Expect a row: ubuntu-resolute   0.0.5-nix   ...
```

### 2a. LXD / Incus CPI: "Missing creation date" workaround

On the **LXD/Incus CPI**, `bosh upload-stemcell` can fail with:

```
CPI error 'Bosh::Clouds::CloudError' with message 'Missing creation date' in 'create_stemcell'
```

Cause: the CPI derives the image `creation_date` from the ModTime of the first
tar entry larger than 100 MiB — which for the openstack stemcell is `root.img`
*inside* the nested `image` tar.gz. Our build is fully deterministic (every mtime
pinned to epoch 0), so the CPI reads `creation_date = 0` and rejects it.

Repack a **deploy copy** with a real, non-zero mtime on the inner `root.img`.
This does **not** alter the committed, byte-reproducible build artifact:

```bash
work=$(mktemp -d)
tar -xf /tmp/res-openstack/*.tgz -C "$work"          # outer members
mkdir "$work/inner"
tar -xzf "$work/image" -C "$work/inner"              # -> root.img (a qcow2)
touch -d '2026-01-01 12:00:00' "$work/inner/root.img"
tar -C "$work/inner" -czf "$work/image" --owner=0 --group=0 root.img
touch -d '1970-01-01' "$work/image"
tar -C "$work" -czf /tmp/res-openstack-deploy.tgz --owner=0 --group=0 \
  stemcell.MF packages.txt dev_tools_file_list.txt image sbom.spdx.json sbom.cdx.json

bosh upload-stemcell /tmp/res-openstack-deploy.tgz
```

> The mtime the CPI reads is on the **inner** `root.img`, not the outer `image`
> member — bumping the outer member alone is not sufficient.

If a broken/old stemcell is already registered at the same version, delete it
first (delete any deployment using it, then `bosh delete-stemcell
bosh-openstack-kvm-ubuntu-resolute/0.0.5-nix`); the director skips re-upload when
name+version already exist.

---

## 3. Deploy a smoke manifest

Pin the deployment's stemcell to the Resolute OS. Minimal single-instance
manifest (`smoke.yml`):

```yaml
name: smoke

stemcells:
- alias: default
  os: ubuntu-resolute
  version: latest

update:
  canaries: 1
  max_in_flight: 1
  canary_watch_time: 30000-300000
  update_watch_time: 30000-300000
  serial: true

instance_groups:
- name: smoke
  instances: 1
  stemcell: default
  vm_type: default          # adjust to your cloud-config
  network: [{ name: default }]  # adjust to your cloud-config
  azs: [z1]                  # adjust to your cloud-config
  jobs: []                   # no release jobs needed to validate the stemcell
```

Deploy:

```bash
bosh -d smoke deploy smoke.yml
```

A successful deploy already proves the most important things: the stemcell
**boots**, the **bosh-agent comes up**, and the director can **create/converge**
the VM. (This is the live-director analogue of the QEMU boot check that the
build pipeline runs — see `docs/plans/resolute-boot-validation.txt`.)

---

## 4. Post-deploy validation

### 4.1 Agent + monit responsive

```bash
bosh -d smoke instances --ps
```

Expect the instance `running` with its process list reported (empty job list is
fine); a hung agent or missing monit shows up here as `unresponsive agent` or a
missing process table.

### 4.2 System reached a healthy state

```bash
bosh -d smoke ssh -c 'systemctl is-system-running'
```

Expect `running` (or `degraded` only for units unrelated to the stemcell — inspect
with `systemctl --failed` if degraded).

> **Known benign degradation:** `audit-rules.service` shows as failed on a
> validated Resolute deploy. On first boot it finishes successfully; the failure
> is the bosh-agent-triggered reload where `augenrules --load` prints `No change`
> and exits 1 — a quirk of the base Ubuntu audit package, not a stemcell
> regression. The audit rules are loaded. Confirm no *other* unit is failed.

### 4.3 pam_lastlog2 is active (Resolute replaced pam_lastlog)

Resolute ships `libpam-lastlog2` and the stemcell activates the
`pam_lastlog2.so` session line. Verify login accounting works:

```bash
bosh -d smoke ssh -c 'lastlog2 2>/dev/null | head -n 5 || \
  grep -R "pam_lastlog2.so" /etc/pam.d/'
```

Expect either `lastlog2` output or the active `session ... pam_lastlog2.so`
line present in the PAM config (not commented out).

### 4.4 runit is absent (Resolute drops the runit supervision package)

The Resolute descriptor omits the `runit` package and its `_runit-log` account.
Confirm the supervisor tooling is not present:

```bash
bosh -d smoke ssh -c '! command -v chpst && ! command -v runsvdir && \
  ! getent passwd _runit-log && echo "runit-absent OK"'
```

Expect `runit-absent OK`.

### 4.5 (optional) Confirm the OS identity

```bash
bosh -d smoke ssh -c 'cat /var/vcap/bosh/etc/stemcell_version; \
  . /etc/os-release; echo "$ID $VERSION_ID"'
```

---

## 5. Tear down

```bash
bosh -d smoke delete-deployment
bosh delete-stemcell ubuntu-resolute/0.0.5-nix   # optional
```

---

## Rollback

The Resolute work is additive and data-only. The existing `ubuntu-noble`
stemcell is **unchanged** and remains uploadable/deployable at any time:

```bash
nix build .#packages.x86_64-linux.noble-stemcell -o /tmp/noble-openstack
bosh upload-stemcell /tmp/noble-openstack/*.tgz
```

Repin any deployment's `stemcells[].os` back to `ubuntu-noble` and redeploy to
revert. No Noble artifact bytes changed as part of adding Resolute (verified by
the byte-identity gates in `nix flake check`).

---

## Notes

- **Determinism:** every stemcell/rootfs/disk artifact is byte-reproducible;
  `nix flake check` builds each twice and compares.
- **Boot:** validated in QEMU for both releases (openstack disk) —
  `docs/plans/resolute-boot-validation.txt`. Both reach `localhost login:` with
  a full initramfs.
- **Infrastructure axis:** `-aws` variants set `root_device_name: /dev/sda1`
  and `boot_mode: uefi-preferred`; openstack variants use qcow2/KVM.
