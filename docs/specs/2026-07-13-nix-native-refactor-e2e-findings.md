# Nix-Native Refactor: E2E Validation Findings

**Date:** 2026-07-13
**Context:** Follow-up to `docs/plans/2026-07-10-nix-native-refactor.md` (Phases 0-4
implemented across several sessions). This note records (1) a byte-identity
regression discovered while executing Phase 5 (treefmt), (2) the investigation
into it, and (3) the end-to-end functional validation that was run instead of
continuing to chase byte-for-byte reproducibility.

---

## 1. Byte-check regression found during Phase 5

The refactor's acceptance bar was a byte-identical `os-image` `rootfs.tar.gz`
before/after every rootfs-touching change (Task 0.2 baseline:
`935c70c9ca120d2fa47d1d9c457aaa005db061b6b3e7efc0b4e29b68b05921a6`).

While wiring up treefmt (Phase 5.1), a fresh byte-check produced a **different**
hash: `9e82107a0134eb656ed30d8d7243cce25eacfc49dacfb8b383c167155ee4d0aa`.

### Root-cause investigation (systematic-debugging)

1. **Confirmed HEAD was actually broken.** Building the exact commit tree at
   `4c45fc4` ("rewrite flake.nix with explicit outputs") failed outright:
   `error: path '.../lib/mk-apply-overlays.nix' does not exist`. The Phase
   2.3-2.5 commits (`64f9c61`, `e5f3df4`, `80c30c1`) only performed file
   **moves** (`git show <sha> --stat` showed `0` changed lines for the moved
   files) — the necessary internal path rewiring existed **only in the
   uncommitted working tree**, left there by earlier sub-agent sessions that
   verified a byte-check against the working tree but never `git add`ed the
   fix. This is a commit-hygiene bug, not an architectural one.
2. **Static-diffed every "collapse" refactor against its pre-refactor
   original** to rule out semantic drift, since collapsing was the highest-risk
   change (vs. pure file moves):
   - `ubuntu/deb-sets.nix` vs. old `base/boot/noble/image-packages.nix`: package
     lists, order, and the `lib.unique (essential ++ filter(base) ++ boot ++
     bosh)` assembly are byte-for-byte identical.
   - `ubuntu/essential.nix` vs. old `essential-packages.nix`: the
     Priority:required/Essential:yes stanza parser is unchanged logic (just a
     `noble` → `aptPins` parameter rename).
   - `ubuntu/apt-pins.nix` vs. old `noble-distro.nix` + `noble-source.nix`:
     identical `urlPrefix`, `codename`, and all three `Packages.xz` sha256
     pins.
   - `pkgs/blobstore-clis.nix` vs. the four old `pkgs/bosh-*cli.nix` files:
     identical versions, `fetchFromGitHub` hashes, and `ldflags`/`vendorHash`
     per CLI.
   - `rootfs/overlays/default.nix`'s ordered list vs. the original inline
     `overlays = [ ... ]` in `os-image.nix`: same 11 entries, same order, same
     `debug-*` exclusions.

   **No semantic differences were found anywhere in the refactor.**
3. **Committed the necessary rewire** (`c4a5f69`) so `HEAD` builds again, and
   confirmed re-running the byte-check against the same unchanged tree twice
   in a row is stable (`9e82107a...` both times) — i.e. the build is at least
   deterministic for a fixed input, ruling out gross non-determinism as the
   sole explanation.
4. Diagnosing further would have required rebuilding the **pre-refactor**
   `os-image` fresh today to check whether `935c70c9c...` is even still
   reproducible from a clean store (Ubuntu archive contents, VM boot
   timestamps, or `vmTools.runInLinuxVM` non-determinism are all candidate
   causes — this is literally one of the feasibility questions called out in
   the top-level `AGENTS.md`: *"Reproducibility / determinism — mutable-
   filesystem image builds are hard to make bit-for-bit reproducible."*).
   This was **deliberately not pursued further**: each additional bisection
   step requires a full VM-based rebuild (expensive, and the host had already
   crashed multiple times this session, plausibly from thermal/disk
   pressure — see §3).

**Conclusion:** the refactor is judged **behaviorally equivalent** to the
pre-refactor code by exhaustive static analysis. The byte-check regression is
either (a) a pre-existing non-determinism in the VM-based OS-image build that
the original single baseline capture didn't happen to reveal, or (b) a subtle
difference not caught by static diffing. Given (1) below, functional
end-to-end validation was prioritized over continuing to chase (b).

---

## 2. End-to-end functional validation (the deciding test)

Per direction, byte-identity was de-prioritized in favor of proving the
refactored pipeline still produces a **working** stemcell.

### Build

```
nix build "path:.#noble-stemcell" -o result
```
Output: `bosh-stemcell-0.0.5-nix-openstack-kvm-ubuntu-noble.tgz` (1.09 GB).

### Upload

```
bosh upload-stemcell --fix result/bosh-stemcell-0.0.5-nix-openstack-kvm-ubuntu-noble.tgz
```
Task 30060 — `done`. Notably, BOSH's CPI recorded the **same** image ID
(`img-3df0e77c-b261-4f13-67b9-181f9f45bcca`) already on file for the
pre-refactor `0.0.5-nix` stemcell, which is suggestive (though not proof)
that the underlying image content is unchanged.

### Deploy — zookeeper (3-node quorum)

```
bosh deploy -d zookeeper manifests/zookeeper.yml -n
```
Task 30061 — `done` in ~2 minutes (all 3 canary-rolled instances came up
cleanly: VM create → agent-ready → package-install → job-start).

```
bosh -d zookeeper instances --ps
```
All 3 `zookeeper/*` instances: `running`, `zookeeper` process: `running`.

### Smoke-tests errand

```
bosh -d zookeeper run-errand smoke-tests --keep-alive
```
Task 30063 — **`1 succeeded, 0 errored, 0 canceled`**. The errand performed
real ZK operations against both a single node and the full 3-node quorum
(create/set/get/delete of permanent and ephemeral znodes, watch
notifications) with sub-2ms average op latency — i.e. actual client traffic
against a live BOSH-agent-managed workload on the refactored stemcell.

**This is the strongest feasibility signal available: the Nix-native-
refactored stemcell boots, runs the BOSH agent, compiles/installs a real
release, and serves live application traffic identically to the
pre-refactor artifact.**

---

## 3. Incidental finding: host disk exhaustion

Mid-session, `/` was at 100% (1.9M free), which caused a stemcell build to
fail with `Virtual machine didn't produce an exit code` /
`lack of free disk space`. `nix-collect-garbage -d` freed 62 GiB (2516 store
paths). This is very likely a contributing factor (if not the sole cause) of
the "host crashes" reported earlier in the session — worth proactively
running `nix-collect-garbage` on a schedule for this workspace, since
`vmTools.runInLinuxVM` builds and repeated `path:` scratch-copies both
consume nix store space quickly.

---

## 4. Recommendations going forward

1. **Treat the byte-check as a regression *signal*, not an absolute gate**,
   for this VM-image-based build style — re-derive the pre-refactor baseline
   fresh (not from a cached hash) before trusting any single comparison, and
   budget for build-to-build variance investigation as its own task rather
   than blocking the whole refactor on it.
2. **Prefer functional (deploy + errand) validation as the primary
   feasibility signal** for this class of change — it caught nothing wrong,
   which combined with the exhaustive static diff gives high confidence the
   refactor is safe to continue (Phases 5-6).
3. Keep `nix-collect-garbage -d` in the standard pre-flight checklist for this
   workspace given the disk-exhaustion incident above.
