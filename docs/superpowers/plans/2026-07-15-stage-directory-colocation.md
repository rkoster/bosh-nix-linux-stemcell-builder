# Stage Directory Co-location Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move each stage's Nix wrapper from a sibling file (`build/stages/<name>.nix`) into its own directory as `default.nix`, and nest each stage's asset files under a new `assets/` subdirectory, so every stage directory is fully self-contained (`default.nix` + `apply.sh` + `assets/`).

**Architecture:** Pure file-layout/wiring change. `git mv` each stage's `.nix` wrapper into its directory as `default.nix`, rewrite its two path interpolations (`STAGE_DIR` and the `apply.sh` reference) to be relative to itself instead of a sibling, and nest existing asset files under `assets/`. Then update the top-level orchestrator (`build/stages.nix` → `build/stages/default.nix`), `build/rootfs/os-image.nix`, `flake.nix`, and docs. No stage script logic changes — verified via byte-identical rootfs hash against the existing baseline.

**Tech Stack:** Nix, Bash, git

---

## Important Context

- **Existing baseline hash** (must match exactly at the end):
  `4eee73a9711ab0a5cf4412cef4731df938322de57c4d9bc8509da4c5dbaec456`
  recorded in `docs/superpowers/baselines/2026-07-15-os-image-baseline.sha256`.
- **Intermediate non-buildable state is expected and OK.** Tasks 1–11 rename
  each stage's `.nix` wrapper into its own directory. Until Task 12 updates
  `build/stages/default.nix` (formerly `build/stages.nix`) to import from the
  new directory paths, `nix build .#os-image` **will fail** because the old
  import paths (`./stages/users.nix`, etc.) no longer exist. **This is
  expected — do not attempt to fix the build in Tasks 1–11.** Full build
  verification happens in Task 12 and is re-confirmed in Task 15.
- Design doc: `docs/superpowers/specs/2026-07-15-stage-directory-colocation-design.md`

---

### Task 1: Migrate `users` stage

**Files:**
- Move: `build/stages/users.nix` → `build/stages/users/default.nix`
- Move: `build/stages/users/{00-bosh-ps1,group,gshadow,passwd,shadow}` → `build/stages/users/assets/`

- [ ] **Step 1: Create the assets directory and move the 5 existing asset files into it**

```bash
mkdir -p build/stages/users/assets
git mv build/stages/users/00-bosh-ps1 build/stages/users/assets/00-bosh-ps1
git mv build/stages/users/group        build/stages/users/assets/group
git mv build/stages/users/gshadow      build/stages/users/assets/gshadow
git mv build/stages/users/passwd       build/stages/users/assets/passwd
git mv build/stages/users/shadow       build/stages/users/assets/shadow
```

- [ ] **Step 2: Move the wrapper file into the stage directory as `default.nix`**

```bash
git mv build/stages/users.nix build/stages/users/default.nix
```

- [ ] **Step 3: Rewrite `default.nix` to reference itself instead of a sibling directory**

```bash
cat > build/stages/users/default.nix <<'NIXEOF'
# users stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "users";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
NIXEOF
```

- [ ] **Step 4: Verify structure**

```bash
find build/stages/users -type f | sort
```
Expected output:
```
build/stages/users/apply.sh
build/stages/users/assets/00-bosh-ps1
build/stages/users/assets/group
build/stages/users/assets/gshadow
build/stages/users/assets/passwd
build/stages/users/assets/shadow
build/stages/users/default.nix
```

- [ ] **Step 5: Commit**

```bash
git add build/stages/users/
git commit -m "Task 1: Migrate users stage to default.nix + assets/ co-location"
```

---

### Task 2: Migrate `ssh` stage

**Files:**
- Move: `build/stages/ssh.nix` → `build/stages/ssh/default.nix`
- Move: `build/stages/ssh/{10-ssh-firstboot-done.conf,securetty}` → `build/stages/ssh/assets/`

- [ ] **Step 1: Create the assets directory and move the 2 existing asset files into it**

```bash
mkdir -p build/stages/ssh/assets
git mv build/stages/ssh/10-ssh-firstboot-done.conf build/stages/ssh/assets/10-ssh-firstboot-done.conf
git mv build/stages/ssh/securetty                   build/stages/ssh/assets/securetty
```

- [ ] **Step 2: Move the wrapper file into the stage directory as `default.nix`**

```bash
git mv build/stages/ssh.nix build/stages/ssh/default.nix
```

- [ ] **Step 3: Rewrite `default.nix`**

```bash
cat > build/stages/ssh/default.nix <<'NIXEOF'
# ssh stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "ssh";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
NIXEOF
```

- [ ] **Step 4: Verify structure**

```bash
find build/stages/ssh -type f | sort
```
Expected output:
```
build/stages/ssh/apply.sh
build/stages/ssh/assets/10-ssh-firstboot-done.conf
build/stages/ssh/assets/securetty
build/stages/ssh/default.nix
```

- [ ] **Step 5: Commit**

```bash
git add build/stages/ssh/
git commit -m "Task 2: Migrate ssh stage to default.nix + assets/ co-location"
```

---

### Task 3: Migrate `sysctl-limits-env` stage

**Files:**
- Move: `build/stages/sysctl-limits-env.nix` → `build/stages/sysctl-limits-env/default.nix`
- Move: `build/stages/sysctl-limits-env/{60-bosh-sysctl.conf,60-bosh-sysctl-neigh-fix.conf}` → `build/stages/sysctl-limits-env/assets/`

- [ ] **Step 1: Create the assets directory and move the 2 existing asset files into it**

```bash
mkdir -p build/stages/sysctl-limits-env/assets
git mv build/stages/sysctl-limits-env/60-bosh-sysctl.conf           build/stages/sysctl-limits-env/assets/60-bosh-sysctl.conf
git mv build/stages/sysctl-limits-env/60-bosh-sysctl-neigh-fix.conf build/stages/sysctl-limits-env/assets/60-bosh-sysctl-neigh-fix.conf
```

- [ ] **Step 2: Move the wrapper file into the stage directory as `default.nix`**

```bash
git mv build/stages/sysctl-limits-env.nix build/stages/sysctl-limits-env/default.nix
```

- [ ] **Step 3: Rewrite `default.nix`**

```bash
cat > build/stages/sysctl-limits-env/default.nix <<'NIXEOF'
# sysctl-limits-env stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "sysctl-limits-env";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
NIXEOF
```

- [ ] **Step 4: Verify structure**

```bash
find build/stages/sysctl-limits-env -type f | sort
```
Expected output:
```
build/stages/sysctl-limits-env/apply.sh
build/stages/sysctl-limits-env/assets/60-bosh-sysctl-neigh-fix.conf
build/stages/sysctl-limits-env/assets/60-bosh-sysctl.conf
build/stages/sysctl-limits-env/default.nix
```

- [ ] **Step 5: Commit**

```bash
git add build/stages/sysctl-limits-env/
git commit -m "Task 3: Migrate sysctl-limits-env stage to default.nix + assets/ co-location"
```

---

### Task 4: Migrate `sudoers-pam` stage

**Files:**
- Move: `build/stages/sudoers-pam.nix` → `build/stages/sudoers-pam/default.nix`
- Move: `build/stages/sudoers-pam/bosh_sudoers` → `build/stages/sudoers-pam/assets/`

- [ ] **Step 1: Create the assets directory and move the 1 existing asset file into it**

```bash
mkdir -p build/stages/sudoers-pam/assets
git mv build/stages/sudoers-pam/bosh_sudoers build/stages/sudoers-pam/assets/bosh_sudoers
```

- [ ] **Step 2: Move the wrapper file into the stage directory as `default.nix`**

```bash
git mv build/stages/sudoers-pam.nix build/stages/sudoers-pam/default.nix
```

- [ ] **Step 3: Rewrite `default.nix`**

```bash
cat > build/stages/sudoers-pam/default.nix <<'NIXEOF'
# sudoers-pam stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "sudoers-pam";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
NIXEOF
```

- [ ] **Step 4: Verify structure**

```bash
find build/stages/sudoers-pam -type f | sort
```
Expected output:
```
build/stages/sudoers-pam/apply.sh
build/stages/sudoers-pam/assets/bosh_sudoers
build/stages/sudoers-pam/default.nix
```

- [ ] **Step 5: Commit**

```bash
git add build/stages/sudoers-pam/
git commit -m "Task 4: Migrate sudoers-pam stage to default.nix + assets/ co-location"
```

---

### Task 5: Migrate `rsyslog` stage

**Files:**
- Move: `build/stages/rsyslog.nix` → `build/stages/rsyslog/default.nix`
- Move: `build/stages/rsyslog/{50-default.conf,90-bosh-agent.conf,journald-override.conf,rsyslog,rsyslog.conf,rsyslog-service-override.conf,wait_for_var_log_to_be_mounted}` → `build/stages/rsyslog/assets/`

- [ ] **Step 1: Create the assets directory and move the 7 existing asset files into it**

```bash
mkdir -p build/stages/rsyslog/assets
git mv build/stages/rsyslog/50-default.conf                    build/stages/rsyslog/assets/50-default.conf
git mv build/stages/rsyslog/90-bosh-agent.conf                  build/stages/rsyslog/assets/90-bosh-agent.conf
git mv build/stages/rsyslog/journald-override.conf              build/stages/rsyslog/assets/journald-override.conf
git mv build/stages/rsyslog/rsyslog                             build/stages/rsyslog/assets/rsyslog
git mv build/stages/rsyslog/rsyslog.conf                        build/stages/rsyslog/assets/rsyslog.conf
git mv build/stages/rsyslog/rsyslog-service-override.conf       build/stages/rsyslog/assets/rsyslog-service-override.conf
git mv build/stages/rsyslog/wait_for_var_log_to_be_mounted      build/stages/rsyslog/assets/wait_for_var_log_to_be_mounted
```

- [ ] **Step 2: Move the wrapper file into the stage directory as `default.nix`**

```bash
git mv build/stages/rsyslog.nix build/stages/rsyslog/default.nix
```

- [ ] **Step 3: Rewrite `default.nix`**

```bash
cat > build/stages/rsyslog/default.nix <<'NIXEOF'
# rsyslog stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "rsyslog";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
NIXEOF
```

- [ ] **Step 4: Verify structure**

```bash
find build/stages/rsyslog -type f | sort
```
Expected output:
```
build/stages/rsyslog/apply.sh
build/stages/rsyslog/assets/50-default.conf
build/stages/rsyslog/assets/90-bosh-agent.conf
build/stages/rsyslog/assets/journald-override.conf
build/stages/rsyslog/assets/rsyslog
build/stages/rsyslog/assets/rsyslog-service-override.conf
build/stages/rsyslog/assets/rsyslog.conf
build/stages/rsyslog/assets/wait_for_var_log_to_be_mounted
build/stages/rsyslog/default.nix
```

- [ ] **Step 5: Commit**

```bash
git add build/stages/rsyslog/
git commit -m "Task 5: Migrate rsyslog stage to default.nix + assets/ co-location"
```

---

### Task 6: Migrate `audit` stage

**Files:**
- Move: `build/stages/audit.nix` → `build/stages/audit/default.nix`
- Move: `build/stages/audit/{00-override.conf,auditctl.sh,audit.rules,bosh-start-logging-and-auditing}` → `build/stages/audit/assets/`

- [ ] **Step 1: Create the assets directory and move the 4 existing asset files into it**

```bash
mkdir -p build/stages/audit/assets
git mv build/stages/audit/00-override.conf                   build/stages/audit/assets/00-override.conf
git mv build/stages/audit/auditctl.sh                         build/stages/audit/assets/auditctl.sh
git mv build/stages/audit/audit.rules                         build/stages/audit/assets/audit.rules
git mv build/stages/audit/bosh-start-logging-and-auditing     build/stages/audit/assets/bosh-start-logging-and-auditing
```

- [ ] **Step 2: Move the wrapper file into the stage directory as `default.nix`**

```bash
git mv build/stages/audit.nix build/stages/audit/default.nix
```

- [ ] **Step 3: Rewrite `default.nix`**

```bash
cat > build/stages/audit/default.nix <<'NIXEOF'
# audit stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "audit";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
NIXEOF
```

- [ ] **Step 4: Verify structure**

```bash
find build/stages/audit -type f | sort
```
Expected output:
```
build/stages/audit/apply.sh
build/stages/audit/assets/00-override.conf
build/stages/audit/assets/audit.rules
build/stages/audit/assets/auditctl.sh
build/stages/audit/assets/bosh-start-logging-and-auditing
build/stages/audit/default.nix
```

- [ ] **Step 5: Commit**

```bash
git add build/stages/audit/
git commit -m "Task 6: Migrate audit stage to default.nix + assets/ co-location"
```

---

### Task 7: Migrate `misc-os` stage

**Files:**
- Move: `build/stages/misc-os.nix` → `build/stages/misc-os/default.nix`
- Move: `build/stages/misc-os/{02periodic,sources.list}` → `build/stages/misc-os/assets/`

- [ ] **Step 1: Create the assets directory and move the 2 existing asset files into it**

```bash
mkdir -p build/stages/misc-os/assets
git mv build/stages/misc-os/02periodic    build/stages/misc-os/assets/02periodic
git mv build/stages/misc-os/sources.list  build/stages/misc-os/assets/sources.list
```

- [ ] **Step 2: Move the wrapper file into the stage directory as `default.nix`**

```bash
git mv build/stages/misc-os.nix build/stages/misc-os/default.nix
```

- [ ] **Step 3: Rewrite `default.nix`**

```bash
cat > build/stages/misc-os/default.nix <<'NIXEOF'
# misc-os stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "misc-os";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
NIXEOF
```

- [ ] **Step 4: Verify structure**

```bash
find build/stages/misc-os -type f | sort
```
Expected output:
```
build/stages/misc-os/apply.sh
build/stages/misc-os/assets/02periodic
build/stages/misc-os/assets/sources.list
build/stages/misc-os/default.nix
```

- [ ] **Step 5: Commit**

```bash
git add build/stages/misc-os/
git commit -m "Task 7: Migrate misc-os stage to default.nix + assets/ co-location"
```

---

### Task 8: Migrate `systemd-services` stage

**Files:**
- Move: `build/stages/systemd-services.nix` → `build/stages/systemd-services/default.nix`
- Move: `build/stages/systemd-services/{add-container-listener-address.conf,create-systemd-resolved-listener-address.service,firstboot.service,firstboot.sh,monit.service,prevent_mount_locking.conf,sysstat}` → `build/stages/systemd-services/assets/`

- [ ] **Step 1: Create the assets directory and move the 7 existing asset files into it**

```bash
mkdir -p build/stages/systemd-services/assets
git mv build/stages/systemd-services/add-container-listener-address.conf              build/stages/systemd-services/assets/add-container-listener-address.conf
git mv build/stages/systemd-services/create-systemd-resolved-listener-address.service build/stages/systemd-services/assets/create-systemd-resolved-listener-address.service
git mv build/stages/systemd-services/firstboot.service                                build/stages/systemd-services/assets/firstboot.service
git mv build/stages/systemd-services/firstboot.sh                                     build/stages/systemd-services/assets/firstboot.sh
git mv build/stages/systemd-services/monit.service                                    build/stages/systemd-services/assets/monit.service
git mv build/stages/systemd-services/prevent_mount_locking.conf                       build/stages/systemd-services/assets/prevent_mount_locking.conf
git mv build/stages/systemd-services/sysstat                                          build/stages/systemd-services/assets/sysstat
```

- [ ] **Step 2: Move the wrapper file into the stage directory as `default.nix`**

```bash
git mv build/stages/systemd-services.nix build/stages/systemd-services/default.nix
```

- [ ] **Step 3: Rewrite `default.nix`**

```bash
cat > build/stages/systemd-services/default.nix <<'NIXEOF'
# systemd-services stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "systemd-services";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
NIXEOF
```

- [ ] **Step 4: Verify structure**

```bash
find build/stages/systemd-services -type f | sort
```
Expected output:
```
build/stages/systemd-services/apply.sh
build/stages/systemd-services/assets/add-container-listener-address.conf
build/stages/systemd-services/assets/create-systemd-resolved-listener-address.service
build/stages/systemd-services/assets/firstboot.service
build/stages/systemd-services/assets/firstboot.sh
build/stages/systemd-services/assets/monit.service
build/stages/systemd-services/assets/prevent_mount_locking.conf
build/stages/systemd-services/assets/sysstat
build/stages/systemd-services/default.nix
```

- [ ] **Step 5: Commit**

```bash
git add build/stages/systemd-services/
git commit -m "Task 8: Migrate systemd-services stage to default.nix + assets/ co-location"
```

---

### Task 9: Migrate `agent` stage

**Files:**
- Move: `build/stages/agent.nix` → `build/stages/agent/default.nix`
- Move: `build/stages/agent/{alerts.monitrc,bosh-agent-rc,bosh-agent.service,monitrc,restart_networking,sync-time}` → `build/stages/agent/assets/`

- [ ] **Step 1: Create the assets directory and move the 6 existing asset files into it**

```bash
mkdir -p build/stages/agent/assets
git mv build/stages/agent/alerts.monitrc      build/stages/agent/assets/alerts.monitrc
git mv build/stages/agent/bosh-agent-rc       build/stages/agent/assets/bosh-agent-rc
git mv build/stages/agent/bosh-agent.service  build/stages/agent/assets/bosh-agent.service
git mv build/stages/agent/monitrc             build/stages/agent/assets/monitrc
git mv build/stages/agent/restart_networking  build/stages/agent/assets/restart_networking
git mv build/stages/agent/sync-time           build/stages/agent/assets/sync-time
```

- [ ] **Step 2: Move the wrapper file into the stage directory as `default.nix`**

```bash
git mv build/stages/agent.nix build/stages/agent/default.nix
```

- [ ] **Step 3: Rewrite `default.nix`** (store-path env vars for `bosh-agent` and `monit` stay identical — only `STAGE_DIR` and the `apply.sh` reference change)

```bash
cat > build/stages/agent/default.nix <<'NIXEOF'
# agent stage: install bosh-agent, monit, and related configuration
# Receives store-built bosh-agent and monit binaries as arguments
{ bosh-agent, monit }:
{
  name = "agent";
  script = ''
    export STAGE_DIR="${./assets}"
    export BOSH_AGENT_BIN="${bosh-agent}/bin/main"
    export MONIT_BIN="${monit}/bin/monit"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
NIXEOF
```

- [ ] **Step 4: Verify structure**

```bash
find build/stages/agent -type f | sort
```
Expected output:
```
build/stages/agent/apply.sh
build/stages/agent/assets/alerts.monitrc
build/stages/agent/assets/bosh-agent-rc
build/stages/agent/assets/bosh-agent.service
build/stages/agent/assets/monitrc
build/stages/agent/assets/restart_networking
build/stages/agent/assets/sync-time
build/stages/agent/default.nix
```

- [ ] **Step 5: Commit**

```bash
git add build/stages/agent/
git commit -m "Task 9: Migrate agent stage to default.nix + assets/ co-location"
```

---

### Task 10: Migrate `blobstore-clis` stage (no assets — drop dead `STAGE_DIR` export)

**Files:**
- Move: `build/stages/blobstore-clis.nix` → `build/stages/blobstore-clis/default.nix`
- No asset files exist for this stage; no `assets/` directory is created.

**Context:** The current wrapper exports `STAGE_DIR="${./blobstore-clis}"`, but `build/stages/blobstore-clis/apply.sh` never reads `$STAGE_DIR` (verified: `grep -n STAGE_DIR build/stages/blobstore-clis/apply.sh` returns nothing). Since there are no asset files and no `assets/` subdirectory for this stage, this dead export is dropped rather than pointed at `${./.}` (which would otherwise pull `default.nix` into the store for no reason).

- [ ] **Step 1: Confirm there is no `$STAGE_DIR` usage in `apply.sh` before proceeding**

```bash
grep -n 'STAGE_DIR' build/stages/blobstore-clis/apply.sh || echo "confirmed: no STAGE_DIR usage"
```
Expected output: `confirmed: no STAGE_DIR usage`

- [ ] **Step 2: Move the wrapper file into the stage directory as `default.nix`**

```bash
git mv build/stages/blobstore-clis.nix build/stages/blobstore-clis/default.nix
```

- [ ] **Step 3: Rewrite `default.nix`, dropping the unused `STAGE_DIR` export**

```bash
cat > build/stages/blobstore-clis/default.nix <<'NIXEOF'
# blobstore-clis stage: install the four source-built CLIs into /var/vcap/bosh/bin
# Receives store-built CLI packages as arguments
{
  davcli,
  s3cli,
  gcscli,
  azureStorageCli,
}:
{
  name = "blobstore-clis";
  script = ''
    export DAVCLI_BIN="${davcli}/bin/davcli"
    export S3CLI_BIN="${s3cli}/bin/bosh-s3cli"
    export GCSCLI_BIN="${gcscli}/bin/bosh-gcscli"
    export AZURE_STORAGE_CLI_BIN="${azureStorageCli}/bin/bosh-azure-storage-cli"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
NIXEOF
```

- [ ] **Step 4: Verify structure**

```bash
find build/stages/blobstore-clis -type f | sort
```
Expected output:
```
build/stages/blobstore-clis/apply.sh
build/stages/blobstore-clis/default.nix
```

- [ ] **Step 5: Commit**

```bash
git add build/stages/blobstore-clis/
git commit -m "Task 10: Migrate blobstore-clis stage to default.nix co-location, drop dead STAGE_DIR export"
```

---

### Task 11: Migrate `openstack-agent-settings` stage

**Files:**
- Move: `build/stages/openstack-agent-settings.nix` → `build/stages/openstack-agent-settings/default.nix`
- Move: `build/stages/openstack-agent-settings/agent.json` → `build/stages/openstack-agent-settings/assets/`

- [ ] **Step 1: Create the assets directory and move the 1 existing asset file into it**

```bash
mkdir -p build/stages/openstack-agent-settings/assets
git mv build/stages/openstack-agent-settings/agent.json build/stages/openstack-agent-settings/assets/agent.json
```

- [ ] **Step 2: Move the wrapper file into the stage directory as `default.nix`**

```bash
git mv build/stages/openstack-agent-settings.nix build/stages/openstack-agent-settings/default.nix
```

- [ ] **Step 3: Rewrite `default.nix`**

```bash
cat > build/stages/openstack-agent-settings/default.nix <<'NIXEOF'
# openstack-agent-settings stage
# Applied by rootfs/apply-stages.nix inside the shared fakeroot session
{ }:
{
  name = "openstack-agent-settings";
  script = ''
    export STAGE_DIR="${./assets}"
    bash -euxo pipefail "${./apply.sh}"
  '';
}
NIXEOF
```

- [ ] **Step 4: Verify structure**

```bash
find build/stages/openstack-agent-settings -type f | sort
```
Expected output:
```
build/stages/openstack-agent-settings/apply.sh
build/stages/openstack-agent-settings/assets/agent.json
build/stages/openstack-agent-settings/default.nix
```

- [ ] **Step 5: Commit**

```bash
git add build/stages/openstack-agent-settings/
git commit -m "Task 11: Migrate openstack-agent-settings stage to default.nix + assets/ co-location"
```

---

### Task 12: Move top-level orchestrator, wire up `os-image.nix`, verify byte-identical build

**Files:**
- Move: `build/stages.nix` → `build/stages/default.nix`
- Modify: `build/rootfs/os-image.nix`

**Context:** This is the task that restores buildability. All 11 stage directories now contain `default.nix` (Task 1–11); this task moves the top-level orchestrator into `build/stages/` itself and updates its imports to reference sibling directories directly (`./users`, `./agent`, etc.) instead of the old flat `.nix` files, and fixes the now-one-level-deeper relative path to `build/pkgs/`.

- [ ] **Step 1: Move `build/stages.nix` into `build/stages/default.nix`**

```bash
git mv build/stages.nix build/stages/default.nix
```

- [ ] **Step 2: Rewrite `build/stages/default.nix`** — fix the `../pkgs` relative path (one level deeper now) and simplify stage imports to directory imports

```bash
cat > build/stages/default.nix <<'NIXEOF'
{ callPackage }:
let
  # Source-built components that need store-path interpolation
  bosh-agent = callPackage ../pkgs/bosh-agent.nix { };
  monit = callPackage ../pkgs/monit.nix { };
  blob = callPackage ../pkgs/blobstore-clis.nix { };
in
[
  # Pure stages: import individual stage directories (each resolves to its own default.nix)
  (import ./users { })
  (import ./ssh { })
  (import ./sysctl-limits-env { })
  (import ./sudoers-pam { })
  (import ./rsyslog { })
  (import ./audit { })
  (import ./misc-os { })
  (import ./systemd-services { })

  # Interpolated stages (embed store paths)
  (import ./agent { inherit bosh-agent monit; })
  (import ./blobstore-clis {
    inherit (blob)
      davcli
      s3cli
      gcscli
      azureStorageCli
      ;
  })
  (import ./openstack-agent-settings { })
]
NIXEOF
```

- [ ] **Step 3: Update `build/rootfs/os-image.nix`** to import the stages directory instead of the old flat file

Read the file first, then apply this change:
- Old line: `  stages = callPackage ../stages.nix { };`
- New line: `  stages = callPackage ../stages { };`

```bash
sed -i 's|stages = callPackage ../stages.nix { };|stages = callPackage ../stages { };|' build/rootfs/os-image.nix
grep -n 'stages = callPackage' build/rootfs/os-image.nix
```
Expected output: `  stages = callPackage ../stages { };`

- [ ] **Step 4: Build os-image and verify byte-identical output against the established baseline**

```bash
nix build .#os-image
NEW_HASH=$(sha256sum result/rootfs.tar.gz | awk '{print $1}')
BASELINE_HASH=$(awk '{print $1}' docs/superpowers/baselines/2026-07-15-os-image-baseline.sha256)
echo "Baseline: $BASELINE_HASH"
echo "Current:  $NEW_HASH"
if [ "$NEW_HASH" = "$BASELINE_HASH" ]; then
  echo "MATCH: byte-identical output confirmed"
else
  echo "MISMATCH: investigate before proceeding"
  exit 1
fi
```
Expected output: `MATCH: byte-identical output confirmed`

**If this fails:** do not proceed to Task 13. Investigate which stage's
`default.nix` has an incorrect path (most likely a typo in a `STAGE_DIR` or
`apply.sh` interpolation from Tasks 1–11) and fix it before continuing.

- [ ] **Step 5: Commit**

```bash
git add build/stages/default.nix build/rootfs/os-image.nix
git commit -m "Task 12: Move build/stages.nix to build/stages/default.nix, wire up os-image.nix, verify byte-identical hash"
```

---

### Task 13: Update `flake.nix` shfmt excludes

**Files:**
- Modify: `flake.nix`

**Context:** Closes a pre-existing gap: the current excludes list only covers
`apply.sh` files, not asset shell scripts extracted verbatim from upstream
heredocs (`audit/assets/auditctl.sh`, `systemd-services/assets/firstboot.sh`).
Running `nix fmt` today could silently reformat these files and break the
byte-identical extraction guarantee.

- [ ] **Step 1: Update the excludes list**

Read the file first, then apply this change:
- Old line: `            settings.formatter.shfmt.excludes = [ "build/stages/*/apply.sh" ];`
- New line: `            settings.formatter.shfmt.excludes = [ "build/stages/*/apply.sh" "build/stages/*/assets/**" ];`

```bash
sed -i 's|settings.formatter.shfmt.excludes = \[ "build/stages/\*/apply.sh" \];|settings.formatter.shfmt.excludes = [ "build/stages/*/apply.sh" "build/stages/*/assets/**" ];|' flake.nix
grep -n 'shfmt.excludes' flake.nix
```
Expected output: `            settings.formatter.shfmt.excludes = [ "build/stages/*/apply.sh" "build/stages/*/assets/**" ];`

- [ ] **Step 2: Verify flake.nix still evaluates**

```bash
nix flake check --no-build 2>&1 | tail -20
```
Expected: no syntax errors reported for `flake.nix`.

- [ ] **Step 3: Commit**

```bash
git add flake.nix
git commit -m "Task 13: Exclude build/stages/*/assets/** from shfmt formatting"
```

---

### Task 14: Update living docs (ARCHITECTURE.md, README.md)

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `README.md`

- [ ] **Step 1: Update the "Configuration Stages" prose section in `docs/ARCHITECTURE.md`**

Find this text (around line 448):
```
Each stage lives in its own directory under `build/stages/<stage-name>/` with an `apply.sh` script and any necessary asset files. Stages use the `$STAGE_DIR` environment variable to access extracted assets, and store paths are mapped as environment variables (e.g., `BOSH_AGENT_BIN`, `MONIT_BIN`, etc.).
```

Replace with:
```
Each stage lives in its own directory under `build/stages/<stage-name>/`, fully self-contained: `default.nix` (Nix wiring), `apply.sh` (shell implementation), and `assets/` (static content, for stages that have any). Stages use the `$STAGE_DIR` environment variable — pointing at the stage's own `assets/` subdirectory — to access extracted assets, and store paths are mapped as environment variables (e.g., `BOSH_AGENT_BIN`, `MONIT_BIN`, etc.).
```

- [ ] **Step 2: Update the "Orchestrated by" link in `docs/ARCHITECTURE.md`**

Find this text (around line 463):
```
Orchestrated by: [`build/stages.nix`](../build/stages.nix) (main coordinator) and [`build/rootfs/apply-stages.nix`](../build/rootfs/apply-stages.nix) (integration)
```

Replace with:
```
Orchestrated by: [`build/stages/default.nix`](../build/stages/default.nix) (main coordinator) and [`build/rootfs/apply-stages.nix`](../build/rootfs/apply-stages.nix) (integration)
```

- [ ] **Step 3: Update the file-tree diagram in `docs/ARCHITECTURE.md`**

Find this block (around lines 603–642):
```
│   ├── stages.nix                      # Stage orchestration (main coordinator)
│   ├── stages/
│   │   ├── ssh/
│   │   │   └── apply.sh               # SSH key generation and config
│   │   ├── sudoers-pam/
│   │   │   └── apply.sh               # Sudoers and PAM setup
│   │   ├── audit/
│   │   │   ├── apply.sh               # Audit daemon configuration
│   │   │   └── auditctl.sh            # Audit rule templates
│   │   ├── systemd-services/
│   │   │   ├── apply.sh               # Systemd unit definitions
│   │   │   └── firstboot.sh           # First-boot initialization
│   │   ├── sysctl-limits-env/
│   │   │   └── apply.sh               # Kernel parameters and limits
│   │   ├── misc-os/
│   │   │   └── apply.sh               # Packages.txt, SBOM, locale, network
│   │   ├── openstack-agent-settings/
│   │   │   └── apply.sh               # OpenStack cloud-init
│   │   ├── users/
│   │   │   └── apply.sh               # User account creation
│   │   ├── rsyslog/
│   │   │   └── apply.sh               # Remote syslog configuration
│   │   ├── agent/
│   │   │   └── apply.sh               # BOSH agent setup
│   │   └── blobstore-clis/
│   │       └── apply.sh               # Blobstore tools (S3, Azure, GCS, WebDAV)
```

Replace with:
```
│   ├── stages/
│   │   ├── default.nix                # Stage orchestration (main coordinator)
│   │   ├── ssh/
│   │   │   ├── default.nix            # Nix wiring (STAGE_DIR, apply.sh invocation)
│   │   │   ├── apply.sh               # SSH key generation and config
│   │   │   └── assets/                # sshd config, securetty, etc.
│   │   ├── sudoers-pam/
│   │   │   ├── default.nix
│   │   │   ├── apply.sh               # Sudoers and PAM setup
│   │   │   └── assets/
│   │   ├── audit/
│   │   │   ├── default.nix
│   │   │   ├── apply.sh               # Audit daemon configuration
│   │   │   └── assets/                # audit.rules, auditctl.sh, etc.
│   │   ├── systemd-services/
│   │   │   ├── default.nix
│   │   │   ├── apply.sh               # Systemd unit definitions
│   │   │   └── assets/                # unit files, firstboot.sh, etc.
│   │   ├── sysctl-limits-env/
│   │   │   ├── default.nix
│   │   │   ├── apply.sh               # Kernel parameters and limits
│   │   │   └── assets/
│   │   ├── misc-os/
│   │   │   ├── default.nix
│   │   │   ├── apply.sh               # Packages.txt, SBOM, locale, network
│   │   │   └── assets/
│   │   ├── openstack-agent-settings/
│   │   │   ├── default.nix
│   │   │   ├── apply.sh               # OpenStack cloud-init
│   │   │   └── assets/
│   │   ├── users/
│   │   │   ├── default.nix
│   │   │   ├── apply.sh               # User account creation
│   │   │   └── assets/                # group, passwd, shadow, etc.
│   │   ├── rsyslog/
│   │   │   ├── default.nix
│   │   │   ├── apply.sh               # Remote syslog configuration
│   │   │   └── assets/
│   │   ├── agent/
│   │   │   ├── default.nix            # Receives bosh-agent, monit store paths
│   │   │   ├── apply.sh               # BOSH agent setup
│   │   │   └── assets/
│   │   └── blobstore-clis/
│   │       ├── default.nix            # Receives davcli/s3cli/gcscli/azureStorageCli store paths
│   │       └── apply.sh               # Blobstore tools (S3, Azure, GCS, WebDAV) — no assets
```

- [ ] **Step 4: Remove the stale `mkStage.nix` reference in the same file-tree diagram**

Find this block (around lines 639–642):
```
│   └── lib/
│       ├── mkVmImage.nix              # VM image creation utilities
│       ├── mkStage.nix                # Stage composition utilities
│       └── hermetic-guard.sh          # Network-namespace probe: fails the build if network is reachable
```

Replace with (removes the reference to `build/lib/mkStage.nix`, which was deleted in the prior directory-per-stage refactor and no longer exists):
```
│   └── lib/
│       ├── mkVmImage.nix              # VM image creation utilities
│       └── hermetic-guard.sh          # Network-namespace probe: fails the build if network is reachable
```

- [ ] **Step 5: Update the "Stage orchestrator" row in the Source Code Navigation table**

Find this text (around line 681):
```
| Stage orchestrator | [`build/stages.nix`](../build/stages.nix) | All | Coordinate all 12 stages |
```

Replace with:
```
| Stage orchestrator | [`build/stages/default.nix`](../build/stages/default.nix) | All | Coordinate all 12 stages |
```

- [ ] **Step 6: Update `README.md`'s `build/stages/` row**

Find this text (around line 60):
```
| `build/stages/` | Post-unpack filesystem stages (each stage is a directory with `apply.sh` + asset files: ssh, sudoers/pam, audit, rsyslog, sysctl, systemd services, users, agent, blobstore CLIs, OpenStack agent settings) mirroring the upstream shell stage names. Orchestrated by `build/stages.nix`. |
```

Replace with:
```
| `build/stages/` | Post-unpack filesystem stages (each stage is a self-contained directory with `default.nix` + `apply.sh` + `assets/`: ssh, sudoers/pam, audit, rsyslog, sysctl, systemd services, users, agent, blobstore CLIs, OpenStack agent settings) mirroring the upstream shell stage names. Orchestrated by `build/stages/default.nix`. |
```

- [ ] **Step 7: Verify no stale references remain**

```bash
grep -rn "build/stages\.nix\b" docs/ARCHITECTURE.md README.md || echo "clean: no stale build/stages.nix references"
grep -n "mkStage\.nix" docs/ARCHITECTURE.md || echo "clean: no stale mkStage.nix references"
```
Expected: both print their "clean" message.

- [ ] **Step 8: Commit**

```bash
git add docs/ARCHITECTURE.md README.md
git commit -m "Task 14: Update ARCHITECTURE.md and README.md for stage directory co-location"
```

---

### Task 15: Final byte-identical verification

**Files:** none (verification only)

- [ ] **Step 1: Clean rebuild**

```bash
rm -rf result
nix build .#os-image
```

- [ ] **Step 2: Compare hash against the established baseline**

```bash
NEW_HASH=$(sha256sum result/rootfs.tar.gz | awk '{print $1}')
BASELINE_HASH=$(awk '{print $1}' docs/superpowers/baselines/2026-07-15-os-image-baseline.sha256)
echo "Baseline: $BASELINE_HASH"
echo "Current:  $NEW_HASH"
if [ "$NEW_HASH" = "$BASELINE_HASH" ]; then
  echo "MATCH: byte-identical output confirmed"
else
  echo "MISMATCH: investigate before proceeding"
  exit 1
fi
```
Expected output: `MATCH: byte-identical output confirmed`

- [ ] **Step 3: Confirm no old flat `.nix` files remain (only `default.nix` inside `build/stages/` itself)**

```bash
ls build/stages/*.nix 2>/dev/null
```
Expected output: `build/stages/default.nix` (and nothing else — no `build/stages/users.nix`, `build/stages/agent.nix`, etc.)

- [ ] **Step 4: Confirm every stage directory has the expected co-located structure**

```bash
for d in build/stages/*/; do
  name=$(basename "$d")
  if [ ! -f "$d/default.nix" ]; then
    echo "FAIL: $name missing default.nix"
  fi
  if [ ! -f "$d/apply.sh" ]; then
    echo "FAIL: $name missing apply.sh"
  fi
done
echo "done checking all stage directories"
```
Expected output: `done checking all stage directories` with no `FAIL` lines above it.

- [ ] **Step 5: Review final commit history**

```bash
git log --oneline -15
```
Expected: 14 commits from this plan (Tasks 1–14, one commit each) at the top
of the log. This verification task (Task 15) makes no file changes and is not
itself committed.

- [ ] **Step 6: Report final status**

Refactor complete when:
- Byte-identical hash confirmed (Step 2)
- No stale flat `.nix` files remain (Step 3)
- Every stage directory has `default.nix` + `apply.sh` (Step 4)
- All 14 commits present in git log (Step 5)

---

## Self-Review Notes

**Spec coverage:** Every stage listed in the design doc's target directory
structure (Task 1–11) has a corresponding migration task. Top-level
orchestrator move + `os-image.nix` wiring is Task 12. `flake.nix` shfmt fix is
Task 13. Docs updates (including the incidental `mkStage.nix` staleness fix
noted in the design doc's context) are Task 14. Final verification is Task 15.

**Type/path consistency:** Verified every `STAGE_DIR` and `apply.sh`
interpolation path in Tasks 1–11 against the actual current file content
of each `build/stages/<name>.nix` (read directly from the repository before
writing this plan) — no drift between "before" and "after" beyond the two
intended path changes per stage. The `blobstore-clis` exception (dropped dead
`STAGE_DIR` export) is called out explicitly in both the design doc and Task
10, avoiding an inconsistency between the two documents.

**No placeholders:** Every task has complete, copy-pasteable shell commands
and full file contents — no "same as Task N" shortcuts, per the file-move
commands and heredoc contents being fully spelled out for each of the 11
stages individually.
