# Rootless Deploy Image Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Publish a Hermes deploy image that runs under any numeric non-root UID/GID with a read-only root filesystem and no privilege escalation.

**Architecture:** Preserve the upstream Docker build and add a fork-owned `deploy-rootless` target. The target replaces s6-overlay with non-setuid `tini`, strips privilege-bearing runtime files, and invokes a UID-agnostic bootstrap that writes only to mounted state paths.

**Tech Stack:** Docker/BuildKit, POSIX shell, pytest contract tests, GitHub Actions, Docker Swarm Compose.

---

### Task 1: Define rootless runtime contracts

**Files:**
- Create: `tests/docker/test_rootless_deploy_contract.py`
- Create: `scripts/verify_rootless_image.sh`

**Step 1: Write failing static contract tests**

Assert that `Dockerfile` exposes `deploy-rootless`, the target uses non-setuid
`tini`, defaults to a non-root user, removes s6 runtime paths, and invokes
`docker/rootless-entrypoint.sh`. Assert that the entrypoint contains no
privilege-changing commands and validates state-directory writability.

**Step 2: Run the tests and verify RED**

Run:

```bash
scripts/run_tests.sh tests/docker/test_rootless_deploy_contract.py
```

Expected: failures because the target and entrypoint do not exist.

**Step 3: Add the image-level verification script**

The script accepts an image reference and runs it with:

```text
--user 12345:23456
--read-only
--cap-drop ALL
--security-opt no-new-privileges:true
--tmpfs /tmp:rw,noexec,nosuid
```

It mounts temporary writable data and workspace directories and verifies the
numeric identity, immutable `/opt/hermes`, writable mounts, absence of `/init`,
and successful `hermes --version`.

### Task 2: Implement the rootless image target

**Files:**
- Modify: `Dockerfile`
- Create: `docker/rootless-entrypoint.sh`

**Step 1: Preserve a real tini binary**

Install Debian's `tini` package and copy it to `/usr/local/bin/tini` before the
upstream compatibility shim replaces `/usr/bin/tini`.

**Step 2: Implement the non-root bootstrap**

Create state directories, safely seed missing `.env`, `config.yaml`, and
`SOUL.md`, run configuration migration and bundled-skill synchronization as
the current user, preserve the configured working directory, and route
arguments to the Hermes CLI.

**Step 3: Add `deploy-rootless`**

Name the upstream runtime stage, inherit it in the final target, remove s6
runtime paths and obsolete shims, strip setuid/setgid bits, set the non-root
default user, and override `ENTRYPOINT`.

**Step 4: Run contract tests and verify GREEN**

Run:

```bash
scripts/run_tests.sh tests/docker/test_rootless_deploy_contract.py
bash -n docker/rootless-entrypoint.sh scripts/verify_rootless_image.sh
```

Expected: all checks pass.

### Task 3: Update operations documentation

**Files:**
- Modify: `README_RU.md`

Document the arbitrary numeric-user contract, required bind-mount ownership,
read-only rootfs, dropped capabilities, `no-new-privileges`, writable `/tmp`,
and removal of `/run`, `HERMES_UID`, and `HERMES_GID` from fork deployment
examples.

### Task 4: Harden fork publishing

**Files:**
- Modify: `.github/workflows/docker-publish-fork.yml`

Build and publish `target: deploy-rootless`. Replace the existing smoke test
with `scripts/verify_rootless_image.sh`, so publishing cannot proceed unless
the exact hardened runtime contract succeeds.

Run:

```bash
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 .github/workflows/docker-publish-fork.yml
```

Expected: no output and exit code 0.

### Task 5: Build and verify locally

Run:

```bash
docker build --platform linux/amd64 --target deploy-rootless -t hermes-agent:rootless-test .
scripts/verify_rootless_image.sh hermes-agent:rootless-test
```

Expected: image build exits 0 and all runtime assertions pass.

Inspect the image configuration and confirm the declared user is non-root,
the entrypoint is `tini` plus the rootless bootstrap, and the architecture is
`linux/amd64`.

### Task 6: Reassemble and publish overlays

Commit Docker/runtime changes on `local/docker`, workflow changes on
`local/ci-deploy`, and these plan documents on `local/meta`. Rebuild `deploy`
from stable `main` by merging all three overlay branches with `--no-ff`.

Push overlay branches normally. Update `deploy` with an explicit
`--force-with-lease`, wait for the fork Docker workflow to finish, and verify
that GHCR `latest` and the immutable `sha-<deploy SHA>` tag point to the new
rootless image.
