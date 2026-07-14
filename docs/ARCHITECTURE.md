# Architecture: Nix-Based BOSH Linux Stemcell Builder

## Overview

This repository implements a **reproducible, content-addressed BOSH Linux stemcell builder** using Nix, replacing the upstream Docker + Ruby/Rake + debootstrap/apt approach.

**Key Goals:**
- ✅ **Reproducibility:** Bit-for-bit identical builds across independent runs
- ✅ **Determinism:** All inputs content-addressed (no mutable network state)
- ✅ **Transparency:** Pure Nix expressions for auditability
- ✅ **Efficiency:** Lazy evaluation and caching via Nix store

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        BOSH STEMCELL                            │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ bosh-stemcell-X.X.X-nix-openstack-kvm-ubuntu-noble.tgz│    │
│  │  ├── stemcell.MF (metadata, sha256 hashes)             │    │
│  │  ├── image (gzipped disk image with UUIDs pinned)      │    │
│  │  ├── packages.txt (all installed packages)             │    │
│  │  ├── dev_tools_file_list.txt                           │    │
│  │  ├── sbom.spdx.json                                    │    │
│  │  └── sbom.cdx.json                                     │    │
│  └────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
         ↑
         │ stemcells/package.nix
         │ (tar --sort=name, gzip -n, drop pigz)
         │
┌─────────────────────────────────────────────────────────────────┐
│                    BOOTABLE DISK IMAGE                          │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ root.qcow2 (UUID: 44444444-4444-4444-4444-444444444444)│    │
│  │  ├── EFI System Partition (vfat, vol-id: 4444-4444)    │    │
│  │  ├── ext4 root (deterministic hash_seed)              │    │
│  │  └── GRUB + initramfs with fixed timestamps           │    │
│  └────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
         ↑
         │ stemcells/bootable-disk.sh
         │ (mkfs.ext4/vfat, SOURCE_DATE_EPOCH, initramfs repacking)
         │
┌─────────────────────────────────────────────────────────────────┐
│                    OS-IMAGE ROOTFS TARBALL                      │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ rootfs.tar.gz (~2.5 GiB)                               │    │
│  │  ├── Extracted and configured .deb packages           │    │
│  │  ├── BOSH agent + monitoring tools                    │    │
│  │  ├── Hardening + audit configuration                 │    │
│  │  └── SSH, sudoers, system utilities                   │    │
│  └────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
         ↑
         │ rootfs/os-image.nix
         │ (apply-stages, tarball with deterministic flags)
         │
┌─────────────────────────────────────────────────────────────────┐
│              FILESYSTEM ASSEMBLY (IN-VM dpkg)                   │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ /mnt/root (ext4, mounted in Linux VM)                 │    │
│  │  ├── dpkg -i package1.deb ... packageN.deb            │    │
│  │  ├── Run postinst scripts in chroot                   │    │
│  │  ├── Apply 11 configuration stages (fakeroot)       │    │
│  │  └── Output: ext4 filesystem image                    │    │
│  └────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
         ↑
         │ rootfs/fill-disk-usrmerge.nix
         │ (usrmerge-safe dpkg extraction, stage application)
         │
┌─────────────────────────────────────────────────────────────────┐
│         DEPENDENCY RESOLUTION & PACKAGE FETCHING                │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ vmTools.debClosureGenerator                            │    │
│  │  ├── Parse Packages.xz indices (from snapshot)         │    │
│  │  ├── Recursively resolve Depends: fields               │    │
│  │  ├── Generate .nix with fetchurl per .deb              │    │
│  │  └── Result: 429 resolved packages (98.8% coverage)    │    │
│  │                                                         │    │
│  │ ubuntu/essential.nix (seed Priority:required)          │    │
│  │  └── Pure-Nix parsing ensures no critical gaps         │    │
│  │                                                         │    │
│  │ Fixed-output derivations (one per .deb)                │    │
│  │  ├── URL from Packages index                           │    │
│  │  ├── SHA256 from Packages index                        │    │
│  │  └── Cached in /nix/store by content hash              │    │
│  └────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
         ↑
         │ ubuntu/apt-pins.nix + ubuntu/deb-sets.nix
         │
┌─────────────────────────────────────────────────────────────────┐
│            IMMUTABLE APT INDEX COORDINATES                      │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ snapshot.ubuntu.com/ubuntu/20260101T000000Z            │    │
│  │  ├── main/binary-amd64/Packages.xz (sha256)            │    │
│  │  ├── universe/binary-amd64/Packages.xz (sha256)        │    │
│  │  └── multiverse/binary-amd64/Packages.xz (sha256)      │    │
│  │                                                         │    │
│  │ Package list (ubuntu/deb-sets.nix)                     │    │
│  │  ├── bootEssentials (systemd, linux, grub, apt...)    │    │
│  │  ├── bosh (ssl, monitoring, debugging tools...)        │    │
│  │  └── stages (ssh, audit, sudoers, hardening...)      │    │
│  └────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Layer-by-Layer Design

### Layer 1: APT Pinning — Reproducible Package Coordinates

**File:** [`build/ubuntu/apt-pins.nix`](../build/ubuntu/apt-pins.nix)

```nix
{ fetchurl }:
let
  urlPrefix = "https://snapshot.ubuntu.com/ubuntu/20260101T000000Z";
  codename = "noble";
in
{
  packagesLists = [
    (fetchurl { url = "${urlPrefix}/dists/${codename}/main/binary-amd64/Packages.xz"; 
                sha256 = "0l94v..."; })
    (fetchurl { url = "${urlPrefix}/dists/${codename}/universe/binary-amd64/Packages.xz"; 
                sha256 = "16jr..."; })
    (fetchurl { url = "${urlPrefix}/dists/${codename}/multiverse/binary-amd64/Packages.xz"; 
                sha256 = "1sjh..."; })
  ];
}
```

**Key Decisions:**
- **snapshot.ubuntu.com** instead of live mirrors:
  - Immutable (obsolete packages remain fetchable forever)
  - Deterministic (package resolution identical across rebuilds)
  - Pinned to specific date (2026-01-01 for this POC)
  
- **Fixed-output derivations for indices:**
  - Each `.xz` file verified by sha256 before use
  - Prevents man-in-the-middle attacks
  - Enables content-addressed caching

**Package List:** [`build/ubuntu/deb-sets.nix`](../build/ubuntu/deb-sets.nix)

Declares all packages to install, organized by category:
- **bootEssentials:** systemd, linux-image-generic, grub-efi, e2fsprogs, apt
- **bosh:** BOSH-specific tools (ssl-dev, lsof, strace, tcpdump, build-essential, etc.)
- **image:** union of both sets

---

### Layer 2: Dependency Resolution — vmTools.debClosureGenerator

**Mechanism:** Nix-native resolver that parses Ubuntu Packages indices and recursively resolves `Depends:` fields.

**Entry Point:** [`build/rootfs/rootfs.nix`](../build/rootfs/rootfs.nix)

```nix
mkRootfsTarball {
  inherit aptPins;
  packages = (callPackage ../ubuntu/deb-sets.nix { }).image;
  size = 16384;
}
```

**Resolver Flow:**

1. **Parse Packages.xz indices:**
   ```
   debClosureGenerator {
     packagesLists = [ main universe multiverse ]
     packages = [ systemd linux-image-generic ... ]
     urlPrefix = "https://snapshot.ubuntu.com/ubuntu/20260101T000000Z"
   }
   ```

2. **Recursively resolve Depends:**
   ```
   systemd Depends: libsystemd0, util-linux, ...
   libsystemd0 Depends: libc6 >= 2.31, ...
   libc6 Depends: (base package, no further deps)
   ```

3. **Generate fetchurl list:**
   ```nix
   [
     (fetchurl { url = ".../systemd_254.5-1ubuntu...deb"; sha256 = "..."; })
     (fetchurl { url = ".../libsystemd0_254.5-1ubuntu...deb"; sha256 = "..."; })
     ...
   ]
   ```

**Coverage & Limitations:**

| Metric | Result |
|--------|--------|
| Packages Resolved | 429 / 434 (98.8%) |
| Boot-Critical Packages | ✅ All present |
| Gaps | 5 non-critical (debug symbols, versioned headers) |

**Why it works despite being "primitive":**
- Ignores version bounds (e.g., `zlib1g (>= 1.2)`) — works because Noble's packages have compatible versions
- Ignores alternatives (e.g., `virtual-package \| real-package`) — most packages have clear real packages
- Ignores Recommends/Suggests — only processes `Depends:`, which is correct for minimalism
- No circular-dependency detection — the package set has no cycles

**Mitigation for Missing Packages:** [`build/ubuntu/essential.nix`](../build/ubuntu/essential.nix)

Pure-Nix parsing of the main Packages index to seed all `Priority: required` or `Essential: yes` packages:

```nix
isSeed = stanza:
  hasInfix "\nPriority: required" stanza ||
  hasInfix "\nEssential: yes" stanza;

seedPackages = lib.unique (map nameOf (filter isSeed stanzas))
```

This ensures critical packages like `base-files` (which has no reverse-dependencies) are always included.

---

### Layer 3: Package Fetching — Fixed-Output Derivations

**Mechanism:** Nix's `fetchurl` with sha256 verification from APT metadata.

**For each resolved package:**

```nix
fetchurl {
  url = "https://snapshot.ubuntu.com/ubuntu/20260101T000000Z/pool/main/b/bash/bash_5.2.26-1ubuntu1_amd64.deb";
  sha256 = "1a2b3c4d5e6f...";  # extracted from Packages.xz
}
```

**Guarantees:**
- **Security:** sha256 mismatch causes build failure (detects tampering)
- **Availability:** snapshot.ubuntu.com keeps all historical packages
- **Caching:** Nix stores by content hash; rebuilds only fetch missing `.deb` files
- **Reproducibility:** Same snapshot date always resolves to same package URLs and hashes

---

### Layer 4: Filesystem Assembly — In-VM dpkg Extraction

**File:** [`build/rootfs/fill-disk-usrmerge.nix`](../build/rootfs/fill-disk-usrmerge.nix) (fork of upstream `vmTools.fillDiskWithDebs`)

**Why a fork?** Upstream doesn't use `--keep-directory-symlink` flag in dpkg extraction, causing symlink clobbering on usr-merged systems (Ubuntu Noble).

**Filesystem Assembly Flow:**

1. **Create ext4 filesystem in VM:**
   ```bash
   mkfs.ext4 /dev/vda -L root -F \
     -U 44444444-4444-4444-4444-444444444444 \
     -E hash_seed=44444444-4444-4444-4444-444444444444
   ```
   (UUIDs pinned for reproducibility and BOSH templating)

2. **Mount and prepare rootfs:**
   ```bash
   mount /dev/vda /mnt
   mkdir /mnt/{proc,dev,sys}
   # Seed fake start-stop-daemon (no-op) to prevent service startup during build
   printf '#!/bin/true\n' > /mnt/usr/sbin/start-stop-daemon
   ```

3. **Extract and install packages (in dependency order):**
   ```bash
   for deb in package1.deb package2.deb ... packageN.deb; do
     dpkg-deb --fsys-tarfile "$deb" | tar -xf - --keep-directory-symlink -C /mnt
     # --keep-directory-symlink: preserves symlink targets, prevents clobbering
   done
   ```

4. **Run postinst scripts in chroot:**
   ```bash
   chroot /mnt dpkg --configure -a
   ```
   (Installs fail gracefully with `|| true`, like debootstrap)

5. **Apply configuration stages (single fakeroot session):**
   ```bash
   fakeroot -i state-in -s state-out << 'EOF'
     # Apply SSH, sudoers, audit, systemd, hardening stages...
   EOF
   ```

**Key Design Decisions:**
- **Single fakeroot session:** Avoids expensive re-extractions
- **Dependency-order installation:** Respects `Depends:` graph
- **Error tolerance:** Continues on postinst failures (e.g., `dbus` activation)
- **Usrmerge-safe dpkg:** `--keep-directory-symlink` ensures symlinks aren't clobbered

---

### Layer 5: OS-Image Tarball — Deterministic Compression

**File:** [`build/rootfs/tarball.nix`](../build/rootfs/tarball.nix)

Creates the base `rootfs.tar.gz` with deterministic tar and gzip flags:

```bash
export SOURCE_DATE_EPOCH=1700000000

# Deterministic tar + gzip flags:
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@$SOURCE_DATE_EPOCH" --format=gnu \
    --use-compress-program="gzip -n -1" \
    -cf rootfs.tar.gz /mnt/
```

**Flags Explained:**
- `--sort=name` — Ensure consistent tar entry ordering
- `--owner=0 --group=0 --numeric-owner` — Normalize ownership to UID/GID 0
- `--mtime="@$SOURCE_DATE_EPOCH"` — Set all files to same timestamp
- `--format=gnu` — Use GNU tar format (ensures reproducible header layout)
- `gzip -n` — No filename/timestamp in gzip header (single-threaded, reproducible)

**Result:** Byte-for-byte identical `rootfs.tar.gz` across independent rebuilds.

---

### Layer 6: Bootable Disk Image — Fixed UUIDs & Deterministic Build

**File:** [`build/stemcells/bootable-disk.sh`](../build/stemcells/bootable-disk.sh)

Builds a QEMU-compatible qcow2 disk image with:

1. **Fixed ext4 UUID:**
   ```bash
   mkfs.ext4 "$disk"2 -L root -F \
     -U 44444444-4444-4444-4444-444444444444 \
     -E hash_seed=44444444-4444-4444-4444-444444444444,root_owner=0:0 \
     -O ^dir_index -q
   ```

2. **Fixed vfat ESP volume id:**
   ```bash
   mkfs.vfat -F32 -n ESP -i 44444444 "$disk"1
   ```

3. **Deterministic initramfs:**
   ```bash
   # Re-pack initramfs cpio with sorted entries and gzip -n
   for img in /boot/initrd.img-*; do
     tmpd=$(mktemp -d)
     ( cd "$tmpd" && zcat "$img" | cpio -idm --quiet )
     ( cd "$tmpd" && find . -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z \
         | cpio -o -H newc --quiet -0 --owner=0:0 \
         | gzip -n -9 > "$img" )
   done
   ```

4. **Fixed grub timestamps:**
   ```bash
   find /boot/grub -name '*.mod' -o -name 'grub.cfg' | while read -r f; do
     touch -d "@$SOURCE_DATE_EPOCH" "$f"
   done
   ```

**Key Decisions:**
- **Fixed UUIDs:** Simplifies diffoscope comparison, proven safe for BOSH (CPI regenerates VMs each time)
- **Single-threaded gzip:** Reproducible compression (vs. multithreaded pigz)
- **SOURCE_DATE_EPOCH=1700000000:** Consistent timestamps across all layers

**Result:** Byte-for-byte identical `root.qcow2` across independent rebuilds.

---

### Layer 7: Stemcell Packaging — Final Tarball with SBOM

**File:** [`build/stemcells/package.nix`](../build/stemcells/package.nix)

Packages the disk image into BOSH stemcell format:

```bash
export SOURCE_DATE_EPOCH=1700000000

# Inner image tarball (gzipped disk):
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@$SOURCE_DATE_EPOCH" --format=gnu \
    -cf - root.img | gzip -n -1 > image

# Outer stemcell tarball:
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@$SOURCE_DATE_EPOCH" --format=gnu \
    --use-compress-program="gzip -n" \
    -cf stemcell.tgz \
    stemcell.MF packages.txt dev_tools_file_list.txt \
    image sbom.spdx.json sbom.cdx.json
```

**Key Changes from Upstream:**
- **Removed pigz:** Single-threaded `gzip -n` for reproducibility
- **Deterministic tar flags:** `--sort=name`, `--owner=0`, `--numeric-owner`, `--mtime=@SOURCE_DATE_EPOCH`

**Result:** Byte-for-byte identical `bosh-stemcell-*.tgz` across independent rebuilds.

---

## Reproducibility Gates

### Generic Gate: [`scripts/byte-check.sh`](../scripts/byte-check.sh)

Two-build reproducibility verification:

```bash
#!/usr/bin/env bash
# 1. Build target, compute hash
hash1=$(nix build .#<target> --out-link result1 && sha256sum result1/<artifact> | cut -d' ' -f1)

# 2. Remove result, rebuild
rm -rf result1
hash2=$(nix build .#<target> --out-link result2 && sha256sum result2/<artifact> | cut -d' ' -f1)

# 3. Compare
if [ "$hash1" = "$hash2" ]; then
  echo "REPRODUCIBLE: <target> (<artifact>) is byte-identical"
  exit 0
else
  echo "NOT REPRODUCIBLE: hashes differ"
  diffoscope result1 result2
  exit 1
fi
```

### Layer-Specific Gates:

| Layer | Gate | Artifact | Expected |
|-------|------|----------|----------|
| L1 | [`scripts/byte-check-osimage.sh`](../scripts/byte-check-osimage.sh) | `rootfs.tar.gz` | Byte-identical ✅ |
| L2 | [`scripts/byte-check-disk.sh`](../scripts/byte-check-disk.sh) | `root.qcow2` | Byte-identical ✅ |
| L3 | [`scripts/byte-check-stemcell.sh`](../scripts/byte-check-stemcell.sh) | `bosh-stemcell-*.tgz` | Byte-identical ✅ |

---

## Configuration Stages

After the base filesystem is assembled, 11 configuration stages are applied in a **single fakeroot session** (avoiding expensive re-extractions):

1. **SSH Configuration** — [`build/stages/ssh.nix`](../build/stages/ssh.nix) — server keys, sshd_config
2. **Sudoers Setup** — [`build/stages/sudoers-pam.sh`](../build/stages/sudoers-pam.sh) — vcap user with passwordless sudo
3. **Audit Daemon** — [`build/stages/audit.sh`](../build/stages/audit.sh) — auditd rules and logging
4. **Systemd Units** — [`build/stages/systemd-services.nix`](../build/stages/systemd-services.nix) — BOSH agent service, monitoring
5. **Hardening** — [`build/stages/sysctl-limits-env.nix`](../build/stages/sysctl-limits-env.nix) — sysctl, kernel parameters
6. **Package Lists** — [`build/stages/misc-os.sh`](../build/stages/misc-os.sh) — packages.txt, dev_tools_file_list.txt, SBOM
7. **Locale & Timezone** — [`build/stages/misc-os.sh`](../build/stages/misc-os.sh) — en_US.UTF-8, UTC
8. **Hostname & Network** — [`build/stages/misc-os.sh`](../build/stages/misc-os.sh) — dhclient, hostname resolution
9. **OpenStack Agent Settings** — [`build/stages/openstack-agent-settings.nix`](../build/stages/openstack-agent-settings.nix) — OpenStack-specific cloud-init
10. **User Accounts** — [`build/stages/users.nix`](../build/stages/users.nix) — root, vcap, bosh_ssh_* users
11. **Debug SSH** — [`build/stages/debug-ssh-root-login.nix`](../build/stages/debug-ssh-root-login.nix) — diagnostic SSH access

Orchestrated by: [`build/stages/default.nix`](../build/stages/default.nix) and [`build/rootfs/apply-stages.nix`](../build/rootfs/apply-stages.nix)

---

## Determinism Properties

### Input Determinism

**All inputs are content-addressed:**

| Component | Source | Tracking | Verification |
|-----------|--------|----------|--------------|
| APT indices | snapshot.ubuntu.com | sha256 from `.xz` files | Fixed-output derivations |
| .deb packages | snapshot.ubuntu.com | sha256 from Packages index | Fixed-output derivations |
| Nix code | Git repo | git commit hash | Flake lock (reproducible) |
| Stages | Git repo | git commit hash | Part of derivation |

### Output Determinism

**Build outputs are deterministic:**

| Layer | Determinism Measure | Status |
|-------|---------------------|--------|
| L1: os-image | Tar entry order, ownership, mtime | ✅ Byte-identical across rebuilds |
| L2: disk | ext4 UUID, initramfs cpio order, grub timestamps | ✅ Byte-identical across rebuilds |
| L3: stemcell | Tar entry order, gzip compression | ✅ Byte-identical across rebuilds |

### Known Limitations

1. **Snapshot pinning freezes packages:**
   - Security patches are fixed at `20260101T000000Z`
   - Requires periodic refresh cycle (manual or CI/CD automation)

2. **Single-threaded gzip slower than pigz:**
   - Acceptable trade-off for reproducibility
   - Build time: ~15-20 minutes on modern hardware

3. **Image size (~2.5 GiB):**
   - No delta qcow2 or incremental builds implemented
   - Consider for future optimization if storage becomes bottleneck

4. **Fixed UUIDs are cosmetic:**
   - UUIDs are not security-sensitive for templated stemcells
   - BOSH CPI regenerates VMs each time (new UUIDs assigned by hypervisor)
   - Chosen for simpler reproducibility verification (no UUID normalization needed)

---

## Integration with BOSH

### Stemcell Format

The final `bosh-stemcell-*.tgz` follows BOSH stemcell conventions:

```
bosh-stemcell-0.0.5-nix-openstack-kvm-ubuntu-noble.tgz
├── stemcell.MF           # Metadata (name, version, sha256 hashes)
├── image                 # Gzipped disk image (contains rootfs.tar.gz)
├── packages.txt          # All installed packages (for tracking)
├── dev_tools_file_list.txt  # Development tools included
├── sbom.spdx.json        # Software Bill of Materials (SPDX format)
└── sbom.cdx.json         # Software Bill of Materials (CycloneDX format)
```

### Real-World Validation

End-to-end deployment on Incus BOSH director:
- ✅ Stemcell uploads successfully
- ✅ Deployment reaches `running` state
- ✅ Fixed UUIDs boot without errors
- ✅ BOSH agent starts and is operational
- ✅ SSH connectivity confirmed

---

## Development Workflow

### Building Locally

```bash
# Enter reproducible dev environment
nix develop .#repro

# Build os-image
nix build .#os-image --no-link -L

# Build bootable disk
nix build .#noble-stemcell-disk --no-link -L

# Build full stemcell
nix build .#noble-stemcell --no-link -L
```

### Reproducibility Testing

```bash
# Run all three gates
bash scripts/byte-check-osimage.sh    # L1
bash scripts/byte-check-disk.sh       # L2
bash scripts/byte-check-stemcell.sh   # L3

# Expected: all exit 0, all report "REPRODUCIBLE"
```

### Updating APT Snapshot

Edit `build/ubuntu/apt-pins.nix`:

```nix
urlPrefix = "https://snapshot.ubuntu.com/ubuntu/20260101T000000Z";
# → change to new date (must recompute Packages.xz hashes)
```

Then:
```bash
nix flake update
# (Re-downloads indices, recomputes sha256 hashes)
```

---

## Files & Organization

```
├── flake.nix                          # Nix flake entry point (packages, devShells)
│                                       # L1: os-image → build/rootfs/os-image.nix
│                                       # L2: noble-stemcell-disk → build/stemcells/openstack-kvm-disk.nix
│                                       # L3: noble-stemcell → build/stemcells/openstack-kvm.nix
├── flake.lock                         # Reproducible dependency lock (git-tracked)
├── build/
│   ├── ubuntu/
│   │   ├── apt-pins.nix               # APT coordinates (snapshot URL + index hashes)
│   │   ├── deb-sets.nix               # Package lists (bootEssentials, bosh, image)
│   │   └── essential.nix              # Essential package seed (pure-Nix parsing)
│   ├── rootfs/
│   │   ├── os-image.nix               # Entry point (base + stages) → L1 output
│   │   ├── rootfs.nix                 # Tarball builder (calls tarball.nix)
│   │   ├── tarball.nix                # Deterministic tar + gzip → rootfs.tar.gz
│   │   ├── fill-disk-usrmerge.nix     # In-VM dpkg extraction (usrmerge-safe fork)
│   │   ├── apply-stages.nix         # Stage application (single fakeroot session)
│   │   └── stages/
│   │       ├── default.nix            # Stage orchestration
│   │       ├── ssh.nix                 # SSH key generation and config
│   │       ├── sudoers-pam.sh          # Sudoers and PAM setup
│   │       ├── audit.sh                # Audit daemon configuration
│   │       ├── systemd-services.nix    # Systemd unit definitions
│   │       ├── sysctl-limits-env.nix   # Kernel parameters and limits
│   │       ├── misc-os.sh              # Packages.txt, SBOM, locale, network
│   │       ├── openstack-agent-settings.nix  # OpenStack cloud-init
│   │       ├── users.nix               # User account creation
│   │       ├── debug-ssh-root-login.nix # Debug SSH access
│   │       └── blobstore-clis.nix      # Blobstore tools (S3, Azure, etc.)
│   ├── stemcells/
│   │   ├── bootable-disk.sh           # Disk builder (L2) → root.qcow2
│   │   ├── bootable-disk.nix          # Wrapper calling bootable-disk.sh
│   │   ├── openstack-kvm-disk.nix     # Disk packaging for OpenStack/KVM
│   │   ├── openstack-kvm.nix          # L3 stemcell packaging → bosh-stemcell-*.tgz
│   │   └── package.nix                # Stemcell archive creation (tar/gzip determinism)
│   ├── pkgs/
│   │   ├── bosh-agent.nix             # BOSH agent build
│   │   ├── monit.nix                  # Monit process monitor
│   │   └── blobstore-clis.nix         # Blobstore CLI tools
│   └── lib/
│       ├── mkVmImage.nix              # VM image creation utilities
│       └── mkStage.nix              # Stage composition utilities
├── scripts/
│   ├── byte-check.sh                  # Generic 2-build reproducibility gate
│   ├── byte-check-osimage.sh          # L1 gate wrapper
│   ├── byte-check-disk.sh             # L2 gate wrapper
│   └── byte-check-stemcell.sh         # L3 gate wrapper
├── docs/
│   ├── ARCHITECTURE.md                # This file
│   └── superpowers/specs/
│       └── 2026-07-14-binary-reproducibility-findings.md
└── .gitignore                         # Ignores bosh.env (secrets), results/, ...
```

**Key Entry Point:** [`flake.nix`](../flake.nix) (lines 37-44)
- `os-image` package → [`build/rootfs/os-image.nix`](../build/rootfs/os-image.nix)
- `noble-stemcell-disk` package → [`build/stemcells/openstack-kvm-disk.nix`](../build/stemcells/openstack-kvm-disk.nix)
- `noble-stemcell` package → [`build/stemcells/openstack-kvm.nix`](../build/stemcells/openstack-kvm.nix)

**Reproducibility devShell:** [`flake.nix`](../flake.nix) (lines 69-74) — provides `diffoscope`, `xxd`, `coreutils`

---

## Source Code Navigation by Build Stage

### Stage 1: Dependency Resolution & Package Fetching

| Component | File | Key Lines | Purpose |
|-----------|------|-----------|---------|
| APT coordinates | [`build/ubuntu/apt-pins.nix`](../build/ubuntu/apt-pins.nix) | All | Snapshot URL, component indices, sha256 hashes |
| Package lists | [`build/ubuntu/deb-sets.nix`](../build/ubuntu/deb-sets.nix) | All | bootEssentials, bosh packages, image union |
| Essential seed | [`build/ubuntu/essential.nix`](../build/ubuntu/essential.nix) | All | Parse Packages.xz, seed Priority:required packages |
| Resolver entry | [`build/rootfs/rootfs.nix`](../build/rootfs/rootfs.nix) | All | Call tarball.nix with aptPins + packages |

### Stage 2: Filesystem Assembly

| Component | File | Key Lines | Purpose |
|-----------|------|-----------|---------|
| Disk creation | [`build/rootfs/fill-disk-usrmerge.nix`](../build/rootfs/fill-disk-usrmerge.nix) | All | Usrmerge-safe dpkg extraction, postinst scripts |
| Stage app | [`build/rootfs/apply-stages.nix`](../build/rootfs/apply-stages.nix) | All | Single fakeroot session, compose stages |
| Stage defs | [`build/stages/default.nix`](../build/stages/default.nix) | All | Enumerate all 11 stages |

### Stage 3: Tarball Creation (L1 Output)

| Component | File | Key Lines | Purpose |
|-----------|------|-----------|---------|
| Tarball builder | [`build/rootfs/tarball.nix`](../build/rootfs/tarball.nix) | All | SOURCE_DATE_EPOCH, tar determinism flags, gzip -n |
| Entry point | [`build/rootfs/os-image.nix`](../build/rootfs/os-image.nix) | All | Compose base + stages, call tarball builder |

### Stage 4: Bootable Disk Build (L2 Output)

| Component | File | Key Lines | Purpose |
|-----------|------|-----------|---------|
| Disk builder | [`build/stemcells/bootable-disk.sh`](../build/stemcells/bootable-disk.sh) | All | mkfs.ext4/vfat (fixed UUID), initramfs repack, grub timestamps |
| Disk wrapper | [`build/stemcells/bootable-disk.nix`](../build/stemcells/bootable-disk.nix) | All | Call bootable-disk.sh, mount disk, populate |
| Disk packaging | [`build/stemcells/openstack-kvm-disk.nix`](../build/stemcells/openstack-kvm-disk.nix) | All | Format disk for OpenStack/KVM, qcow2 conversion |

### Stage 5: Stemcell Packaging (L3 Output)

| Component | File | Key Lines | Purpose |
|-----------|------|-----------|---------|
| Stemcell archiver | [`build/stemcells/package.nix`](../build/stemcells/package.nix) | All | Drop pigz, use gzip -n, tar determinism flags |
| Stemcell composer | [`build/stemcells/openstack-kvm.nix`](../build/stemcells/openstack-kvm.nix) | All | Package disk + metadata + SBOMs into final .tgz |

### Reproducibility Gates

| Layer | File | Target | Purpose |
|-------|------|--------|---------|
| Generic | [`scripts/byte-check.sh`](../scripts/byte-check.sh) | Any | 2-build double-check, sha256 diff, diffoscope on mismatch |
| L1 | [`scripts/byte-check-osimage.sh`](../scripts/byte-check-osimage.sh) | `os-image` | Gate rootfs.tar.gz reproducibility |
| L2 | [`scripts/byte-check-disk.sh`](../scripts/byte-check-disk.sh) | `noble-stemcell-disk` | Gate root.qcow2 reproducibility |
| L3 | [`scripts/byte-check-stemcell.sh`](../scripts/byte-check-stemcell.sh) | `noble-stemcell` | Gate final stemcell .tgz reproducibility |

---

## Future Improvements

1. **CI/CD Integration:**
   - Gate stemcell releases on reproducibility (all 3 gates pass)
   - Nightly determinism monitoring

2. **Snapshot Refresh Automation:**
   - Monthly script to update `apt-pins.nix` with latest security patches
   - Automated testing and release workflow

3. **Incremental Builds:**
   - Delta qcow2 between versions (reduce image size)
   - Lazy evaluation of non-changing stages

4. **Architecture Support:**
   - Port to `arm64` (currently `x86_64` only)
   - Test on vSphere, AWS, Azure, GCP hypervisors

5. **FIPS Certification:**
   - FIPS kernel modules + userspace libraries
   - Cryptography module certification

---

## References

- **Nix Manual:** https://nixos.org/manual/nix/stable/
- **NixOS vmTools:** https://github.com/nixos/nixpkgs/tree/master/nixos/lib/build-vms.nix
- **Ubuntu Snapshots:** https://snapshot.ubuntu.com/
- **BOSH Stemcell Format:** https://bosh.io/docs/stemcell-v1/
- **Original Article:** https://linus.schreibt.jetzt/posts/ubuntu-images.html

---

## Contact & Feedback

For questions or issues:
- Open an issue on this repo
- Contact the BOSH team
