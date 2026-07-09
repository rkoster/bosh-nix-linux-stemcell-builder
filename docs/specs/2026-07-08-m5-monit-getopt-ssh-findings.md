# M5 Findings — monit `getopt` (musl) Fix, `bosh ssh` Enablement, and `sudo`

Date: 2026-07-08
Status: **RESOLVED** — monit, `bosh ssh`, and `sudo` all fixed; green end-to-end
jobless deploy with working `bosh ssh` + passwordless `sudo` on the Nix stemcell

## Executive Summary

Two defects that blocked a clean end-to-end deploy of the Nix-built stemcell on the
Incus/LXD director were root-caused and fixed:

1. **monit `stop -g vcap` returned exit 1** during the agent's "stopping jobs"
   phase, failing every deploy. Root cause: our **static (musl) monit build** —
   musl's `getopt()` does **not** permute `argv`, so the agent's action-first
   invocation `monit stop -g vcap` silently dropped the `-g vcap` option. Fixed
   by patching monit to use `getopt_long` (which musl *does* permute).
2. **`bosh ssh` was rejected** (`Permission denied (publickey)`). Root cause: a
   **debug overlay** rewrote `sshd_config` with `AllowUsers root vcap`, which
   blocks the agent's ephemeral `bosh_*` login users. Fixed by removing the debug
   overlays from the build (files retained on disk).

Both fixes are verified against the live director:
`bosh -d nix-stemcell-poc deploy` now completes the full update lifecycle, and
`bosh ssh` logs in as an agent-created ephemeral user.

A follow-on gap surfaced via the now-working `bosh ssh`: **`sudo` is not present**
in the image (`sudo: command not found`), so privilege escalation for the
`bosh_sudoers`/`admin` users does not work. Addressed in the `sudo` section below.

---

## Finding 1 — monit `stop -g vcap` exit 1 (musl `getopt` non-permutation)

### Symptom
Every deploy failed at:
```
L stopping jobs: ...
Stopping Monitored Services: ... 'monit stop -g vcap' ...
  monit: action failed -- There is no service by that name': exit status 1
```

### Diagnostic path (systematic)
- **Ruled out the manifest.** Hypothesis: the jobless manifest (`jobs: []`)
  produces an empty `vcap` group, so `monit stop -g vcap` legitimately errors.
  Controlled experiment disproved this: deploying the **identical jobless
  manifest** against the **upstream `1.425` stemcell** succeeded (stopping jobs
  passed). So the empty group is *not* the cause.
- **Isolated to our binary.** `bosh ssh` (upstream) + debug root SSH (nix) showed
  the two VMs had **byte-identical** monit config, version (5.2.5), `monitrc`, and
  `/var/vcap/monit` contents, and neither declared a `group vcap`. Yet:

  | command | upstream (glibc, dynamic) | nix (musl, static) |
  |---|---|---|
  | `monit stop -g vcap` | **exit 0** | **exit 1** |
  | `monit stop -g nosuchgroup12345` | **exit 0** | **exit 1** |
  | `monit stop -g system` | **exit 0** | **exit 1** |

  Exit 1 for a *nonexistent* group is impossible per the CLI source
  (`monitor.c:401 do_action`): a group with no match is a no-op → exit 0.
- **Ruled out the agent's monit-access firewall.** That feature would produce
  `"Cannot connect to the monit daemon"` (a connection error); instead we saw an
  HTTP 404 from the daemon (`"There is no service by that name"`), proving the CLI
  connected fine. `monit summary` also worked.
- **Root cause found — `getopt` permutation.** The agent calls monit
  **action-first**: `monit stop -g vcap`
  (`bosh-agent jobsupervisor/monit_job_supervisor.go` `StopAndWait`, ~line 210).
  monit parses options with plain `getopt(argc,argv,"c:d:g:l:p:s:iItvVhH")`
  (`monitor.c:599`).
  - **glibc `getopt` permutes `argv`** → `-g vcap` is parsed even though it
    follows the `stop` positional. Upstream works.
  - **musl `getopt` is strict POSIX** → it stops scanning at the first
    non-option (`stop`), so `-g vcap` is never parsed. `Run.mygroup` stays `NULL`,
    monit falls into the "single service" branch and tries to control a service
    literally named `-g` → daemon returns 404 → CLI prints
    `"action failed -- There is no service by that name"` → `exit(1)`. This
    matches *every* group name, exactly as observed.

  Confirmed on the live nix VM:
  ```
  monit stop -g vcap   -> exit 1   (agent's form)
  monit -g vcap stop   -> exit 0   (options-first)
  ```

### Fix
`poc/pkgs/monit.nix` — `postPatch` now substitutes monit's `getopt` call with
`getopt_long` (empty long-options table). musl's `getopt_long` **does** implement
GNU-style permutation, restoring glibc-equivalent behavior while keeping the small,
closure-free static binary.

```
substituteInPlace monitor.c \
  --replace 'getopt(argc,argv,"c:d:g:l:p:s:iItvVhH")' \
            'getopt_long(argc,argv,"c:d:g:l:p:s:iItvVhH",(const struct option[]){{0,0,0,0}},NULL)'
```

Verified before shipping with a standalone static-musl probe (both arg orders
parse identically), then locally against the rebuilt monit with a synthetic
`group vcap` control file, then end-to-end on the director.

### Why this matters for feasibility
- Building BOSH's vendored C components **statically via musl (`pkgsStatic`)** is
  attractive (no `/nix` closure in the image, mirroring the `CGO_ENABLED=0` agent),
  but musl is **not** a drop-in for glibc. Behavioral differences (here, `getopt`
  argument permutation) can silently break BOSH's exact CLI invocation patterns.
- Mitigations available: (a) prefer `getopt_long` / glibc-compatible calls,
  (b) build against glibc where faithful behavior matters, (c) test the *exact*
  command forms the agent uses, not just `--version`.
- Suppressing compiler diagnostics (`-Wno-implicit-function-declaration`,
  `-Wno-int-conversion`) on 2011-era C is risky; those flags masked no bug here,
  but they could hide real pointer-truncation miscompilations. Worth revisiting.

---

## Finding 2 — `bosh ssh` rejected (`Permission denied (publickey)`)

### Symptom
```
bosh ssh vm-instance/0
  bosh_c5bf...@10.246.0.108: Permission denied (publickey).
```
The director *did* create the ephemeral user and attempt the login, so agent-side
setup (`CreateUser` + `AddUserToGroups` + `SetupSSH`) succeeded — the rejection was
purely at sshd auth time.

### Root cause
The agent's SSH setup adds the ephemeral user to
`[vcap, admin, bosh_sudoers, bosh_sshers]`
(`bosh-agent agent/action/ssh.go` `setupSSH`), and the base `ssh.nix` config
allows `AllowGroups bosh_sshers` — which would permit it. But the **debug overlay**
`poc/lib/overlays/debug-ssh-root-login.nix` rewrote `sshd_config` to add:
```
AllowUsers root vcap
```
Once `AllowUsers` is present, sshd permits **only** the listed users, so the
ephemeral `bosh_*` user is denied regardless of group membership.

### Fix
`poc/examples/os-image.nix` — removed the two debug overlays
(`debug-ssh-root-login.nix`, `debug-ssh-keys.nix`) from the `overlays` list and
commented out the `debugSshPubKey = builtins.readFile ...` binding they consumed.
The **files remain on disk**, guarded by comments explaining how to re-enable them
for emergency debugging.

The base `ssh.nix` (`AllowGroups bosh_sshers`, `DenyUsers root`,
`PasswordAuthentication no`) now governs access; all four groups the agent needs
already exist in `users.nix` (`admin:988`, `vcap:1000`, `bosh_sshers:1001`,
`bosh_sudoers:1002`).

### Bonus: pure build
Because the only `--impure` input was the debug key's `readFile`, and that thunk is
no longer referenced, the stemcell now builds **without `--impure`**
(`nix build ./poc#noble-stemcell`), improving reproducibility.

### Verification
```
bosh -d nix-stemcell-poc ssh vm-instance/0 -c 'echo SSH_OK; id'
  SSH_OK
  uid=1001(bosh_3f7a78074d90425) ... groups=...,988(admin),1000(vcap),1001(bosh_sshers),1002(bosh_sudoers)
```

---

## Deploy status after Findings 1 & 2

`bosh -d nix-stemcell-poc deploy nix-stemcell-poc.yml` completes the entire update
lifecycle on the Nix-built stemcell:
`pre-stop → drain → stopping jobs → post-stop → installing packages →
configuring jobs → pre-start → starting jobs → post-start`. `bosh vms` reports the
instance `started` / responsive. This is the first **green end-to-end deploy** of
the Nix stemcell on the real Incus/LXD director (jobless manifest).

---

## Finding 3 — `sudo: command not found` (RESOLVED)

### Symptom
Surfaced immediately via the now-working `bosh ssh`:
```
sudo -n id   ->  bash: sudo: command not found
```
Escalation for the `bosh_sudoers` / `admin` users failed because the `sudo`
**binary** is absent from the image. The `sudoers-pam` overlay writes
`/etc/sudoers.d/bosh_sudoers` (`%bosh_sudoers ALL=(ALL) NOPASSWD: ALL`) and the
`restrict_su_command` policy adds `vcap` to the sudo group, but neither installs
the `sudo` program itself.

### Root cause
Identical in nature to the earlier `hostname` gap. `sudo` is Debian
**`Priority: important`**, which `debootstrap` installs by default in the classic
builder — but the article's **primitive deb resolver only pulls
`Priority: required`**, so `sudo` never enters the closure. It was present in no
package list (`base-packages.nix`, `boot-packages.nix`, `noble-packages.nix`).

This is a concrete, repeatable instance of the assessment's
**dependency-resolution-fidelity** risk: the naive resolver silently omits
packages that the real Ubuntu bootstrap includes by priority, and the omission
only shows up at runtime.

### Fix
`poc/lib/noble-packages.nix` — added `"sudo"` to the explicit BOSH package set,
with a comment mirroring the `hostname` rationale. This pulls the real Ubuntu
`sudo` `.deb` (binary + `sudoers.so` PAM module + `/etc/pam.d/sudo`) into the
closure via the fixed-output deb fetch.

### Verification
- Image level (cheap, pre-deploy): `tar tzf rootfs.tar.gz` now lists
  `./usr/bin/sudo`, `./usr/libexec/sudo/sudoers.so`, `./etc/pam.d/sudo`,
  `./etc/sudoers`.
- End-to-end on the director (stemcell `img-fd69d622`, green deploy):
  ```
  bosh ssh vm-instance/0 -c 'command -v sudo; sudo -n true && echo OK; sudo -n id'
    BINARY=/usr/bin/sudo
    PASSWORDLESS_SUDO_OK
    uid=0(root) gid=0(root) groups=0(root)
  ```
  The agent's ephemeral `bosh_sudoers` user escalates to root passwordlessly, as
  BOSH expects.

### Operational note — host disk exhaustion (not a code defect)
The first rebuild after adding `sudo` failed with `No space left on device` during
overlay tar extraction (root fs 100% full, 264 MiB free) — a byproduct of many
iterative image builds and leftover `result-*` gcroots, **not** the `sudo` change.
`rm` of temp result links + `nix store gc` freed **95.9 GiB** (49% used after);
the rebuild then succeeded. Takeaway for the assessment: the monolithic
image-in-a-VM approach is disk-hungry (multi-GiB qcow2 + rootfs per iteration);
routine GC / incremental (delta qcow2) building matters for a real build pipeline.

---

## Files touched this session

- `poc/pkgs/monit.nix` — `getopt_long` patch (Finding 1).
- `poc/examples/os-image.nix` — debug SSH overlays removed from build; pure build
  restored (Finding 2).
- `poc/lib/noble-packages.nix` — added `"sudo"` to the package set (Finding 3).
- (retained, unbuilt) `poc/lib/overlays/debug-ssh-root-login.nix`,
  `poc/lib/overlays/debug-ssh-keys.nix`.

## Reference: agent invocation forms that must be exercised

- `monit stop -g vcap`, `monit unmonitor -g vcap`, `monit start -g vcap`,
  `monit summary`, `monit reload` — all **action-first**; require `getopt`
  permutation.
- SSH ephemeral user must satisfy `AllowGroups bosh_sshers`; no `AllowUsers`
  narrowing.
- Ephemeral users are placed in `vcap, admin, bosh_sudoers, bosh_sshers` and
  expect working passwordless `sudo`.
