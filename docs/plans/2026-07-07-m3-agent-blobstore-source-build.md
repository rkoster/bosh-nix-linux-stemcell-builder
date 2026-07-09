# Source-Built BOSH Agent & Blobstore CLIs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the BOSH agent and all four blobstore CLIs from source as inline Nix `buildGoModule` packages, install them into the OS image with full scaffolding, and wire the OpenStack agent settings.

**Architecture:** Five concrete Go packages live in `poc/pkgs/` (exposed as flake outputs for independent `nix build`). A shared builder function `poc/lib/mk-blobstore-cli.nix` keeps the four CLIs DRY. Three new overlays in `poc/lib/overlays/` consume the package derivations and `cp` their outputs into the rootfs tarball via the existing `mk-overlay.nix` contract. `os-image.nix` appends the three overlays; `flake.nix` merges `pkgs/` into its `packages` output.

**Tech Stack:** Nix flakes, `buildGoModule`, `fetchFromGitHub`, flake-parts, existing POC overlay machinery.

**Design reference:** `docs/superpowers/specs/2026-07-07-m3-agent-blobstore-source-build-design.md`

---

## Design Refinement (vs. spec)

The spec placed the shared builder at `poc/pkgs/blobstore-cli.nix`. This plan
moves it to **`poc/lib/mk-blobstore-cli.nix`** instead, because:

1. It matches the existing `mk-overlay.nix` / `mk-rootfs-tarball.nix` naming
   convention already in `poc/lib/`.
2. It keeps the flake's `pkgs/` auto-map clean — every file in `poc/pkgs/` is a
   concrete, buildable package. A bare builder *function* in `pkgs/` would break
   `callPackage`.

All other design decisions are unchanged.

---

## File Structure

**Created:**
- `poc/lib/mk-blobstore-cli.nix` — shared `buildGoModule` wrapper for the 4 CLIs
- `poc/pkgs/bosh-s3cli.nix` — s3cli package
- `poc/pkgs/bosh-davcli.nix` — davcli package
- `poc/pkgs/bosh-gcscli.nix` — gcscli package
- `poc/pkgs/bosh-azure-storage-cli.nix` — azure-storage-cli package
- `poc/pkgs/bosh-agent.nix` — bosh-agent package (version embedded via ldflags)
- `poc/lib/overlays/blobstore-clis.nix` — install 4 CLIs to `/var/vcap/bosh/bin`
- `poc/lib/overlays/agent.nix` — install agent + full scaffolding
- `poc/lib/overlays/openstack-agent-settings.nix` — write OpenStack `agent.json`

**Modified:**
- `poc/flake.nix` — merge `pkgs/*.nix` into `packages` output
- `poc/examples/os-image.nix` — append 3 overlays, pass package derivations

---

## Conventions for Go packages (read once)

**vendorHash discovery loop** (used in every package task): Nix cannot know the
Go module vendor hash ahead of time. Procedure:

1. First check whether the upstream repo vendors its deps. After the
   `fetchFromGitHub` src is written, you can inspect it, but the fastest path is:
   set `vendorHash = lib.fakeHash;` and build.
2. If the build error says the module has a `vendor/` directory, set
   `vendorHash = null;` instead.
3. Otherwise the error prints `got: sha256-XXXX…`. Copy that exact value into
   `vendorHash`.

**CGO:** All packages set `env.CGO_ENABLED = "0"` for static binaries.

**Tests:** All packages set `doCheck = false` (upstream suites need network /
cloud fixtures).

---

### Task 1: Flake wiring + shared CLI builder + first CLI (s3cli)

**Files:**
- Create: `poc/lib/mk-blobstore-cli.nix`
- Create: `poc/pkgs/bosh-s3cli.nix`
- Modify: `poc/flake.nix`

- [ ] **Step 1: Create the shared builder function**

Create `poc/lib/mk-blobstore-cli.nix`:

```nix
# Shared buildGoModule wrapper for the four BOSH blobstore CLIs.
# Each concrete package in ../pkgs supplies the repo coordinates + hashes.
{ lib, buildGoModule, fetchFromGitHub }:
{ pname
, version
, owner ? "cloudfoundry"
, repo
, rev ? "v${version}"
, hash            # fetchFromGitHub source hash
, vendorHash      # null if the repo vendors deps, else sha256-...
, subPackages ? [ "." ]
, ldflagsVersionVar ? null   # e.g. "main.version"; null = no version embed
}:
buildGoModule {
  inherit pname version vendorHash subPackages;
  src = fetchFromGitHub { inherit owner repo rev hash; };
  env.CGO_ENABLED = "0";
  doCheck = false;
  ldflags =
    lib.optionals (ldflagsVersionVar != null)
      [ "-s" "-w" "-X" "${ldflagsVersionVar}=${version}" ];
  meta = {
    description = "BOSH blobstore CLI: ${pname}";
    homepage = "https://github.com/${owner}/${repo}";
  };
}
```

- [ ] **Step 2: Create the s3cli package with fakeHash placeholders**

Create `poc/pkgs/bosh-s3cli.nix`:

```nix
{ lib, callPackage }:
callPackage ../lib/mk-blobstore-cli.nix { } {
  pname = "bosh-s3cli";
  version = "0.0.413";
  repo = "bosh-s3cli";
  hash = lib.fakeHash;
  vendorHash = lib.fakeHash;
  ldflagsVersionVar = null;   # confirmed/adjusted in Step 4
}
```

- [ ] **Step 3: Wire pkgs/ into the flake**

In `poc/flake.nix`, replace the `packages = lib.mapAttrs' …` block with a merged
map over both `./examples` and `./pkgs`:

```nix
      packages =
        let
          mapDir = dir: lib.mapAttrs' (name: _type: {
            name = lib.replaceStrings [ ".nix" ] [ "" ] name;
            value = pkgs.callPackage (dir + "/${name}") { };
          }) (builtins.readDir dir);
        in
        (mapDir ./examples) // (mapDir ./pkgs);
```

- [ ] **Step 4: Resolve the source hash**

Run: `nix build ./poc#bosh-s3cli 2>&1 | tee /tmp/s3.log`
Expected: FAIL with a `hash mismatch` for the `fetchFromGitHub` src, printing
`got: sha256-…`. Copy that value into `hash` in `poc/pkgs/bosh-s3cli.nix`
(replacing `lib.fakeHash`).

- [ ] **Step 5: Resolve the vendor hash**

Run: `nix build ./poc#bosh-s3cli 2>&1 | tee /tmp/s3.log`
Expected: either
- an error mentioning a `vendor` directory → set `vendorHash = null;`, or
- a `got: sha256-…` for the vendor derivation → copy it into `vendorHash`.

Re-run until the build succeeds.

- [ ] **Step 6: Confirm the binary and version-embed option**

Run: `ls ./result/bin` → expect a binary named `s3cli`.
Run: `./result/bin/s3cli --version` (or `-v`).
If the version string is empty/`0.0.0`, find the version symbol:
Run: `grep -rn "version" $(nix eval --raw ./poc#bosh-s3cli.src)/*.go $(nix eval --raw ./poc#bosh-s3cli.src)/cmd 2>/dev/null | grep -i "var\|Version ="`
If a `main.version` (or similar) var exists, set `ldflagsVersionVar` accordingly
and rebuild so `--version` reports `0.0.413`. If none exists, leave it `null`
and note it (acceptable — install name/behaviour is what matters).

- [ ] **Step 7: Commit**

```bash
git add poc/lib/mk-blobstore-cli.nix poc/pkgs/bosh-s3cli.nix poc/flake.nix
git commit -m "feat(m3): source-built bosh-s3cli + flake pkgs wiring"
```

---

### Task 2: davcli package

**Files:**
- Create: `poc/pkgs/bosh-davcli.nix`

- [ ] **Step 1: Create the package**

Create `poc/pkgs/bosh-davcli.nix`:

```nix
{ lib, callPackage }:
callPackage ../lib/mk-blobstore-cli.nix { } {
  pname = "bosh-davcli";
  version = "0.0.486";
  repo = "bosh-davcli";
  hash = lib.fakeHash;
  vendorHash = lib.fakeHash;
  ldflagsVersionVar = null;
}
```

- [ ] **Step 2: Resolve source hash**

Run: `nix build ./poc#bosh-davcli 2>&1 | tail -20`
Expected: FAIL with `got: sha256-…` for src. Copy into `hash`.

- [ ] **Step 3: Resolve vendor hash**

Run: `nix build ./poc#bosh-davcli 2>&1 | tail -20`
Expected: `vendor` dir → `vendorHash = null;`, else copy `got: sha256-…`.
Re-run until success.

- [ ] **Step 4: Confirm binary**

Run: `ls ./result/bin` → expect `davcli`.
Run: `./result/bin/davcli --version` (informational). If a version var exists,
set `ldflagsVersionVar` as in Task 1 Step 6.

- [ ] **Step 5: Commit**

```bash
git add poc/pkgs/bosh-davcli.nix
git commit -m "feat(m3): source-built bosh-davcli"
```

---

### Task 3: gcscli package

**Files:**
- Create: `poc/pkgs/bosh-gcscli.nix`

- [ ] **Step 1: Create the package**

Create `poc/pkgs/bosh-gcscli.nix`:

```nix
{ lib, callPackage }:
callPackage ../lib/mk-blobstore-cli.nix { } {
  pname = "bosh-gcscli";
  version = "0.0.393";
  repo = "bosh-gcscli";
  hash = lib.fakeHash;
  vendorHash = lib.fakeHash;
  ldflagsVersionVar = null;
}
```

- [ ] **Step 2: Resolve source hash**

Run: `nix build ./poc#bosh-gcscli 2>&1 | tail -20`
Expected: FAIL with `got: sha256-…` for src. Copy into `hash`.

- [ ] **Step 3: Resolve vendor hash**

Run: `nix build ./poc#bosh-gcscli 2>&1 | tail -20`
Expected: `vendor` dir → `vendorHash = null;`, else copy `got: sha256-…`.
Re-run until success.

- [ ] **Step 4: Confirm binary**

Run: `ls ./result/bin` → expect `bosh-gcscli`.
Run: `./result/bin/bosh-gcscli --version` (informational).

Note: if the produced binary name differs (e.g. `gcscli`), record the actual
name — Task 6 maps it to `bosh-blobstore-gcs` regardless.

- [ ] **Step 5: Commit**

```bash
git add poc/pkgs/bosh-gcscli.nix
git commit -m "feat(m3): source-built bosh-gcscli"
```

---

### Task 4: azure-storage-cli package

**Files:**
- Create: `poc/pkgs/bosh-azure-storage-cli.nix`

- [ ] **Step 1: Create the package**

Create `poc/pkgs/bosh-azure-storage-cli.nix`:

```nix
{ lib, callPackage }:
callPackage ../lib/mk-blobstore-cli.nix { } {
  pname = "bosh-azure-storage-cli";
  version = "0.0.242";
  repo = "bosh-azure-storage-cli";
  hash = lib.fakeHash;
  vendorHash = lib.fakeHash;
  ldflagsVersionVar = null;
}
```

- [ ] **Step 2: Resolve source hash**

Run: `nix build ./poc#bosh-azure-storage-cli 2>&1 | tail -20`
Expected: FAIL with `got: sha256-…` for src. Copy into `hash`.

- [ ] **Step 3: Resolve vendor hash**

Run: `nix build ./poc#bosh-azure-storage-cli 2>&1 | tail -20`
Expected: `vendor` dir → `vendorHash = null;`, else copy `got: sha256-…`.
Re-run until success.

- [ ] **Step 4: Confirm binary**

Run: `ls ./result/bin` → expect `azure-storage-cli`.
Run: `./result/bin/azure-storage-cli --version` (informational).

- [ ] **Step 5: Commit**

```bash
git add poc/pkgs/bosh-azure-storage-cli.nix
git commit -m "feat(m3): source-built bosh-azure-storage-cli"
```

---

### Task 5: bosh-agent package (version embedded)

**Files:**
- Create: `poc/pkgs/bosh-agent.nix`

The agent is not a blobstore CLI, so it does **not** use `mk-blobstore-cli.nix`.
It is a direct `buildGoModule`. Upstream builds with a version embedded; we
replicate it so `bosh-agent --version` reports `2.861.0`.

- [ ] **Step 1: Create the package with placeholders**

Create `poc/pkgs/bosh-agent.nix`:

```nix
{ lib, buildGoModule, fetchFromGitHub }:
buildGoModule rec {
  pname = "bosh-agent";
  version = "2.861.0";

  src = fetchFromGitHub {
    owner = "cloudfoundry";
    repo = "bosh-agent";
    rev = "v${version}";
    hash = lib.fakeHash;
  };

  vendorHash = lib.fakeHash;   # null if repo vendors deps

  env.CGO_ENABLED = "0";
  doCheck = false;

  # Upstream embeds the version via ldflags in bin/build. Confirmed/adjusted in
  # Step 4 by reading bin/build from the fetched source.
  ldflags = [ "-s" "-w" "-X" "main.version=${version}" ];

  # bosh-agent's main package. Adjust in Step 4 if the module path is /v2 or the
  # main package lives in a subdir (e.g. "main").
  subPackages = [ "." ];

  meta = {
    description = "BOSH agent (built from source)";
    homepage = "https://github.com/cloudfoundry/bosh-agent";
  };
}
```

- [ ] **Step 2: Resolve source hash**

Run: `nix build ./poc#bosh-agent 2>&1 | tail -20`
Expected: FAIL with `got: sha256-…` for src. Copy into `src.hash`.

- [ ] **Step 3: Resolve vendor hash**

Run: `nix build ./poc#bosh-agent 2>&1 | tail -20`
Expected: `vendor` dir → `vendorHash = null;`, else copy `got: sha256-…`.

- [ ] **Step 4: Confirm main package, module path, and version ldflags**

Read the fetched source's build script to replicate the exact ldflags and
target package:

Run: `src=$(nix eval --raw ./poc#bosh-agent.src); sed -n '1,80p' "$src/bin/build" 2>/dev/null; echo '--- go.mod ---'; head -1 "$src/go.mod"`

Adjust the package as needed:
- If `go.mod` declares `…/bosh-agent/v2`, and the version var is in `main`, the
  `-X main.version=` form still applies (it targets the `main` package of the
  built binary, not the module path). Only change it if `bin/build` shows a
  different symbol (e.g. `-X main.gitSHA=` or `-X github.com/.../vcap.Version=`).
- If `bin/build` builds a subdir (e.g. `go build ./main` producing `out/bosh-agent`),
  set `subPackages = [ "main" ];`.
- Match whatever `-ldflags` string `bin/build` uses.

- [ ] **Step 5: Build and verify version**

Run: `nix build ./poc#bosh-agent`
Run: `ls ./result/bin` → expect `bosh-agent`.
Run: `./result/bin/bosh-agent --version`
Expected: reports `2.861.0` (or the commit/version format upstream uses). If the
version cannot be embedded after reasonable effort, record it as a quarantine
note in Task 9 and proceed — the binary functioning is the primary requirement.

- [ ] **Step 6: Commit**

```bash
git add poc/pkgs/bosh-agent.nix
git commit -m "feat(m3): source-built bosh-agent with embedded version"
```

---

### Task 6: blobstore-clis install overlay

**Files:**
- Create: `poc/lib/overlays/blobstore-clis.nix`
- Modify: `poc/examples/os-image.nix`

- [ ] **Step 1: Create the overlay**

Create `poc/lib/overlays/blobstore-clis.nix`. Adjust the four source binary
names on the right of each `cp` to the actual names confirmed in Tasks 1–4:

```nix
# Reproduces the upstream `blobstore_clis` stage: install the four source-built
# CLIs into /var/vcap/bosh/bin as bosh-blobstore-<type>.
{ davcli, s3cli, gcscli, azureStorageCli }:
{
  name = "blobstore-clis";
  script = ''
    mkdir -p "$root/var/vcap/bosh/bin"

    install -m 0755 ${davcli}/bin/davcli                     "$root/var/vcap/bosh/bin/bosh-blobstore-dav"
    install -m 0755 ${s3cli}/bin/s3cli                       "$root/var/vcap/bosh/bin/bosh-blobstore-s3"
    install -m 0755 ${gcscli}/bin/bosh-gcscli                "$root/var/vcap/bosh/bin/bosh-blobstore-gcs"
    install -m 0755 ${azureStorageCli}/bin/azure-storage-cli "$root/var/vcap/bosh/bin/bosh-blobstore-azure-storage"
  '';
}
```

- [ ] **Step 2: Wire the overlay into os-image.nix**

In `poc/examples/os-image.nix`, inside the `let` block (after `base = …`), add
package derivations:

```nix
  davcli          = callPackage ../pkgs/bosh-davcli.nix { };
  s3cli           = callPackage ../pkgs/bosh-s3cli.nix { };
  gcscli          = callPackage ../pkgs/bosh-gcscli.nix { };
  azureStorageCli = callPackage ../pkgs/bosh-azure-storage-cli.nix { };
```

Then append to the `overlays` list (after the `systemd-services` line):

```nix
    (import ../lib/overlays/blobstore-clis.nix {
      inherit davcli s3cli gcscli azureStorageCli;
    })
```

- [ ] **Step 3: Evaluate the overlay wiring**

Run: `nix eval ./poc#os-image.drvPath`
Expected: prints a `.drv` path with no evaluation error (confirms the overlay
and package args resolve).

- [ ] **Step 4: Verify the CLIs land in the overlay output (isolated build)**

Build just this overlay's layer by temporarily confirming via the overlay
derivation. Run:

```bash
nix build ./poc#os-image 2>&1 | tail -20 || echo "full image build may be disk-limited; see Task 9 fallback"
```

If the full build succeeds, extract and assert:

```bash
mkdir -p /tmp/m3check && tar tzf ./result/rootfs.tar.gz \
  | grep -E 'var/vcap/bosh/bin/bosh-blobstore-(dav|s3|gcs|azure-storage)$'
```
Expected: all four paths listed. If the full image build is disk-blocked, defer
this assertion to Task 9 and rely on Step 3 eval + package builds from Tasks 1–4.

- [ ] **Step 5: Commit**

```bash
git add poc/lib/overlays/blobstore-clis.nix poc/examples/os-image.nix
git commit -m "feat(m3): blobstore CLIs install overlay"
```

---

### Task 7: agent install overlay (full scaffolding)

**Files:**
- Create: `poc/lib/overlays/agent.nix`
- Modify: `poc/examples/os-image.nix`

- [ ] **Step 1: Create the overlay**

Create `poc/lib/overlays/agent.nix` (assets inlined byte-faithfully from the
`bosh_go_agent` stage; the metalink/`meta4` download path is intentionally
omitted):

```nix
# Reproduces the upstream `bosh_go_agent` stage using the source-built agent:
# binary + systemd unit + rc + monit alerts + agent.json placeholder +
# log symlink + cron/at hardening.
{ bosh-agent }:
{
  name = "agent";
  script = ''
    mkdir -p "$root/var/vcap/bosh/bin" "$root/var/vcap/bosh/etc" \
             "$root/var/vcap/bosh/log" "$root/var/vcap/monit" \
             "$root/lib/systemd/system"

    # agent binary + monit-access hardlink
    install -m 0755 ${bosh-agent}/bin/bosh-agent "$root/var/vcap/bosh/bin/bosh-agent"
    ln -f "$root/var/vcap/bosh/bin/bosh-agent" \
          "$root/var/vcap/bosh/etc/bosh-enable-monit-access"

    # bosh-agent-rc
    cat > "$root/var/vcap/bosh/bin/bosh-agent-rc" <<'EOF'
#!/bin/sh

set -e

if [ -e /dev/sr0 ]; then
  chmod 0660 /dev/sr0
  chown root:root /dev/sr0
fi

if [ -e /dev/shm ]; then
  chmod 0770 /dev/shm
  chown root:vcap /dev/shm
fi
EOF
    chmod 0755 "$root/var/vcap/bosh/bin/bosh-agent-rc"

    # restart_networking helper
    cat > "$root/var/vcap/bosh/bin/restart_networking" <<'EOF'
#!/bin/bash
systemctl restart systemd-networkd
EOF
    chmod 0755 "$root/var/vcap/bosh/bin/restart_networking"

    # monit alerts
    cat > "$root/var/vcap/monit/alerts.monitrc" <<'EOF'
set alert agent@local

set mailserver localhost port 2825
     with timeout 15 seconds

set eventqueue
    basedir /var/vcap/monit/events
    slots 5000

set mail-format {
  from: monit@localhost
  subject: Monit Alert
  message: Service: $SERVICE
  Event: $EVENT
  Action: $ACTION
  Date: $DATE
  Description: $DESCRIPTION
}
EOF
    chmod 0600 "$root/var/vcap/monit/alerts.monitrc"
    chown root:root "$root/var/vcap/monit/alerts.monitrc"

    # empty agent conf (overwritten by openstack-agent-settings overlay)
    echo '{}' > "$root/var/vcap/bosh/agent.json"

    # cache dir used by agent/init/create-env
    mkdir -p "$root/var/vcap/micro_bosh/data/cache"

    # bosh-agent.service (byte-faithful copy of stage asset)
    cat > "$root/lib/systemd/system/bosh-agent.service" <<'EOF'
[Unit]
Description=Bosh agent service
After=network.target


[Service]
WorkingDirectory=/var/vcap/bosh
ExecStart=/bin/bash -c 'PATH=/var/vcap/bosh/bin:$PATH \
    exec nice -n -15 /var/vcap/bosh/bin/bosh-agent \
    -P $(cat /var/vcap/bosh/etc/operating_system) \
    -C /var/vcap/bosh/agent.json'
Restart=always
KillMode=process
StandardOutput=journal
StandardError=inherit
SyslogIdentifier=bosh-agent

[Install]
WantedBy=multi-user.target
Alias=agent.service
EOF

    # enable bosh-agent.service (declarative wants + Alias symlinks)
    mkdir -p "$root/lib/systemd/system/multi-user.target.wants"
    ln -sf /lib/systemd/system/bosh-agent.service \
      "$root/lib/systemd/system/multi-user.target.wants/bosh-agent.service"
    ln -sf /lib/systemd/system/bosh-agent.service \
      "$root/lib/systemd/system/agent.service"

    # agent log symlink target (log file created at runtime)
    ln -sf /var/log/bosh-agent.log "$root/var/vcap/bosh/log/current"

    # cron/at hardening (bosh_go_agent chroot block)
    rm -f "$root/etc/cron.deny" "$root/etc/at.deny"
    echo 'vcap' > "$root/etc/cron.allow"
    echo 'vcap' > "$root/etc/at.allow"
    chmod -f og-rwx "$root/etc/at.allow" "$root/etc/cron.allow" \
      "$root/etc/crontab" "$root/etc/cron.hourly" "$root/etc/cron.daily" \
      "$root/etc/cron.weekly" "$root/etc/cron.monthly" "$root/etc/cron.d" \
      2>/dev/null || true
    chown -f root:root "$root/etc/at.allow" "$root/etc/cron.allow" \
      "$root/etc/crontab" "$root/etc/cron.hourly" "$root/etc/cron.daily" \
      "$root/etc/cron.weekly" "$root/etc/cron.monthly" "$root/etc/cron.d" \
      2>/dev/null || true
  '';
}
```

Note: `/var/lock` ownership from the upstream stage is omitted — it is a
tmpfs-mounted runtime path, not meaningful in the static tarball. Record this in
Task 9.

- [ ] **Step 2: Wire the overlay into os-image.nix**

In `poc/examples/os-image.nix` `let` block, add:

```nix
  bosh-agent = callPackage ../pkgs/bosh-agent.nix { };
```

Append to the `overlays` list, **before** the `blobstore-clis` entry (agent
first, then CLIs, then settings):

```nix
    (import ../lib/overlays/agent.nix { inherit bosh-agent; })
```

- [ ] **Step 3: Evaluate the wiring**

Run: `nix eval ./poc#os-image.drvPath`
Expected: prints a `.drv` path with no evaluation error.

- [ ] **Step 4: Verify agent scaffolding (if full build succeeds)**

```bash
nix build ./poc#os-image 2>&1 | tail -20 || echo "disk-limited; defer to Task 9"
```
If it succeeds:
```bash
tar tzf ./result/rootfs.tar.gz | grep -E \
  'var/vcap/bosh/bin/bosh-agent$|lib/systemd/system/bosh-agent.service$|var/vcap/monit/alerts.monitrc$|var/vcap/bosh/bin/bosh-agent-rc$'
```
Expected: all four present. Otherwise defer to Task 9.

- [ ] **Step 5: Commit**

```bash
git add poc/lib/overlays/agent.nix poc/examples/os-image.nix
git commit -m "feat(m3): bosh-agent install overlay with full scaffolding"
```

---

### Task 8: OpenStack agent-settings overlay

**Files:**
- Create: `poc/lib/overlays/openstack-agent-settings.nix`
- Modify: `poc/examples/os-image.nix`

- [ ] **Step 1: Create the overlay**

Create `poc/lib/overlays/openstack-agent-settings.nix` (agent.json inlined
byte-faithfully from `bosh_openstack_agent_settings/assets/agent.json`):

```nix
# Reproduces `bosh_openstack_agent_settings`: overwrite /var/vcap/bosh/agent.json
# with the OpenStack platform + settings sources config.
{ }:
{
  name = "openstack-agent-settings";
  script = ''
    mkdir -p "$root/var/vcap/bosh"
    cat > "$root/var/vcap/bosh/agent.json" <<'EOF'
{
  "Platform": {
    "Linux": {
      "PartitionerType": "parted",
      "CreatePartitionIfNoEphemeralDisk": true,
      "DevicePathResolutionType": "virtio",
      "ServiceManager": "systemd",
      "DiskIDTransformPattern": "^([0-9a-f]{8})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{12})$",
      "DiskIDTransformReplacement": "scsi-${1}${2}${3}${4}${5}"
    }
  },
  "Infrastructure": {
    "Settings": {
      "Sources": [
        {
          "Type": "File",
          "SettingsPath": "/var/vcap/bosh/agent-bootstrap-env.json"
        },
        {
          "Type": "ConfigDrive",
          "DiskPaths": [
            "/dev/disk/by-label/CONFIG-2",
            "/dev/disk/by-label/config-2"
          ],
          "MetaDataPath": "ec2/latest/meta-data.json",
          "UserDataPath": "ec2/latest/user-data"
        },
        {
          "Type": "HTTP",
          "URI": "http://169.254.169.254",
          "UserDataPath": "/latest/user-data",
          "InstanceIDPath": "/latest/meta-data/instance-id",
          "SSHKeysPath": "/latest/meta-data/public-keys/0/openssh-key"
        }
      ],

      "UseServerName": true,
      "UseRegistry": true
    }
  }
}
EOF
  '';
}
```

**IMPORTANT:** The `${1}`…`${5}` sequences in `DiskIDTransformReplacement` are
literal JSON content, but Nix would try to interpolate them inside a `''…''`
string. Because they sit inside a heredoc that bash writes verbatim, they must
survive Nix string interpolation first. Escape each as `''${1}` … `''${5}` in
the `.nix` file so Nix emits a literal `${1}`. Verify in Step 3.

- [ ] **Step 2: Wire the overlay into os-image.nix**

Append to the `overlays` list as the **last** entry (after `blobstore-clis`):

```nix
    (import ../lib/overlays/openstack-agent-settings.nix { })
```

- [ ] **Step 3: Verify the literal-JSON escaping**

Run: `nix eval --raw ./poc#os-image.drvPath`
Expected: no evaluation error. Then confirm the emitted script keeps the literal
`${1}` (not an empty string) — build the overlay layer or, if the full image
builds, assert after extraction:

```bash
tar xzf ./result/rootfs.tar.gz -O ./var/vcap/bosh/agent.json | grep 'scsi-'
```
Expected: `"DiskIDTransformReplacement": "scsi-${1}${2}${3}${4}${5}"` appears
verbatim. If disk-limited, at minimum confirm `nix eval` succeeds and the
`''${1}` escaping is present in the source file.

- [ ] **Step 4: Commit**

```bash
git add poc/lib/overlays/openstack-agent-settings.nix poc/examples/os-image.nix
git commit -m "feat(m3): openstack agent settings overlay"
```

---

### Task 9: Full verification + findings doc

**Files:**
- Create: `docs/superpowers/specs/2026-07-07-m3-agent-blobstore-findings.md`

- [ ] **Step 1: Build every package independently and record versions**

Run:
```bash
for p in bosh-agent bosh-s3cli bosh-davcli bosh-gcscli bosh-azure-storage-cli; do
  nix build ./poc#$p && echo "$p: $(ls ./result/bin)"
done
```
Expected: all five build; binaries listed. Record the output.

- [ ] **Step 2: Attempt the full image + overlay assertions**

Run:
```bash
rm -rf /tmp/opencode/* 2>/dev/null || true   # free scratch space
nix build ./poc#os-image 2>&1 | tail -30
```
If it succeeds, assert all install paths:
```bash
tar tzf ./result/rootfs.tar.gz | grep -E \
  'var/vcap/bosh/bin/(bosh-agent|bosh-blobstore-dav|bosh-blobstore-s3|bosh-blobstore-gcs|bosh-blobstore-azure-storage)$'
tar tzf ./result/rootfs.tar.gz | grep -E \
  'lib/systemd/system/(bosh-agent.service|multi-user.target.wants/bosh-agent.service)$'
tar xzf ./result/rootfs.tar.gz -O ./var/vcap/bosh/agent.json | grep -q '"UseRegistry": true' && echo "openstack agent.json OK"
```
Expected: agent + 4 CLIs + service + enable symlink + openstack agent.json all
present. If the build is disk-blocked, record that the per-package builds
(Step 1) plus `nix eval ./poc#os-image.drvPath` success are the verification of
record, and the tarball assertion is deferred.

- [ ] **Step 3: Write the findings doc**

Create `docs/superpowers/specs/2026-07-07-m3-agent-blobstore-findings.md` with:
- **Versions built** (from Step 1 output): agent + 4 CLIs, with resolved
  `hash`/`vendorHash` values and whether each repo vendored deps.
- **Version-embed results:** did `bosh-agent --version` report `2.861.0`? Did any
  CLI support version embedding? Note the `ldflagsVersionVar` chosen per package.
- **Install verification:** paths asserted (or deferred with reason).
- **Deviations from upstream:** metalink/`meta4` download path dropped;
  `/var/lock` runtime ownership omitted (tmpfs path).
- **FIPS finding:** FIPS is entirely conditional on the `fips` variant
  (`prelude_fips.bash` `exit 0` for non-fips; `stage_collection.rb` gates
  `system_fips_kernel` + `base_fips_apt` on the fips variant). The non-FIPS
  noble stemcell gets zero FIPS hardening; nothing to implement.
- **Oracle caveat:** agent/blobstore are not covered by the OS_IMAGE Serverspec
  suite (stemcell-phase specs), so verification is package smoke-tests + tarball
  assertions.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-07-07-m3-agent-blobstore-findings.md
git commit -m "docs(m3): agent + blobstore source-build findings"
```

---

## Self-Review

**Spec coverage:**
- All 4 blobstore CLIs from source → Tasks 1–4 ✓
- bosh-agent from source with version embed → Task 5 ✓
- Pin to upstream versions → versions hard-coded in every package task ✓
- Agent full scaffolding → Task 7 (unit, rc, monit, restart_networking, agent.json, hardlink, log symlink, cron/at) ✓
- OpenStack agent settings → Task 8 ✓
- `poc/pkgs/` location + flake exposure → Task 1 Step 3 ✓
- FIPS finding (no code) → Task 9 Step 3 ✓
- Validation strategy (per-package + tarball + oracle caveat) → Task 9 ✓

**Placeholder scan:** `vendorHash`/`hash` use `lib.fakeHash` as an explicit,
resolved-by-command value (not a vague TODO) — each has a concrete discovery
step with exact commands. No "TBD"/"handle appropriately" left.

**Type consistency:** `mk-blobstore-cli.nix` parameter names (`pname`, `version`,
`repo`, `hash`, `vendorHash`, `subPackages`, `ldflagsVersionVar`) are used
identically in Tasks 1–4. Overlay arg names (`davcli`, `s3cli`, `gcscli`,
`azureStorageCli`, `bosh-agent`) match between the overlay files and the
`os-image.nix` wiring. Overlay order (agent → blobstore-clis →
openstack-agent-settings) is consistent between Tasks 6/7/8 and honors the
"settings overwrites placeholder" requirement.
