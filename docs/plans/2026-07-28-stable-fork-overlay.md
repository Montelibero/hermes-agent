# Stable Fork Overlay Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Convert the Montelibero fork into a stable-release base plus independent Docker, CI, and metadata overlays assembled into `deploy`.

**Architecture:** Pin `main` to the latest stable upstream tag, keep fork-only changes on three independent `local/*` branches, and regenerate `deploy` through explicit merge commits. Disable upstream workflows in the fork while retaining a deploy-only GHCR workflow.

**Tech Stack:** Git, GitHub Actions, Docker Buildx, GHCR, Markdown

---

### Task 1: Establish safety and prove the old topology is invalid

**Files:** None

**Step 1: Protect the old fork tip**

Create annotated tag `pre-overlay-2026-07-28` at the old `main`.

**Step 2: Enable recorded conflict resolution**

Run:

```bash
git config rerere.enabled true
```

**Step 3: Run the pre-migration topology assertions**

Run:

```bash
test "$(git rev-parse main)" = "$(git rev-parse v2026.7.20^{commit})"
git show-ref --verify --quiet refs/heads/local/docker
git show-ref --verify --quiet refs/heads/local/ci-deploy
git show-ref --verify --quiet refs/heads/local/meta
git show-ref --verify --quiet refs/heads/deploy
```

Expected: the first, second, third, and fifth assertions fail because the old
fork stores personal commits on `main` and has no overlay topology.

### Task 2: Create the metadata overlay

**Files:**
- Create: `BRANCHES.md`
- Create: `docs/fork-workflow.md`
- Create: `docs/plans/2026-07-28-stable-fork-overlay-design.md`
- Create: `docs/plans/2026-07-28-stable-fork-overlay.md`

**Step 1: Create `local/meta` from `v2026.7.20`**

The branch must contain documentation only.

**Step 2: Add the active branch registry**

Document the base tag, the purpose of every `local/*` branch, and the fixed
merge order used to rebuild `deploy`.

**Step 3: Add the project-specific update recipe**

Document exact fetch, tag verification, stable-base update, overlay rebase,
deploy rebuild, validation, and push commands. Explicitly state that
`upstream/main` is not a deployable base.

**Step 4: Verify metadata scope**

Run:

```bash
git diff --check v2026.7.20..local/meta
git diff --name-only v2026.7.20..local/meta |
  awk '$0 != "BRANCHES.md" && $0 !~ /^docs\\// { bad=1 } END { exit bad }'
```

Expected: both commands exit 0.

**Step 5: Commit**

```bash
git add BRANCHES.md docs/fork-workflow.md docs/plans
git commit -m "docs: define stable fork overlay workflow"
```

### Task 3: Rebuild the Docker overlay

**Files:**
- Create: `README_RU.md`
- Create: `build.sh`

**Step 1: Create `local/docker` from `v2026.7.20`**

Do not preserve the obsolete commit structure. Restore the two fork-owned
files from `pre-overlay-2026-07-28` as one logical overlay.

**Step 2: Run stale-interface checks before editing**

Run:

```bash
rg -n 'MESSAGING_CWD|/home/hermes|docker/entrypoint\\.sh|cli-config\\.yaml\\.example' README_RU.md
```

Expected: matches are found, proving that the restored April guide targets
removed or deprecated interfaces.

**Step 3: Update the Docker guide**

Describe the stable release's `/opt/data` volume, current `config.yaml`
settings, supported image entrypoint, profiles, gateway use, and safe
multi-instance layout. Do not recommend sidecar `.env` files for server
compose snippets or `${VARIABLE}` substitutions.

**Step 4: Update the image rebuild helper**

Keep `build.sh` non-destructive and explicit:

```bash
#!/usr/bin/env bash
set -euo pipefail

git pull --ff-only
docker build --platform linux/amd64 -t hermes-agent:local .
```

**Step 5: Verify the overlay**

Run:

```bash
bash -n build.sh
test -x build.sh
! rg -n 'MESSAGING_CWD|docker/entrypoint\\.sh|cli-config\\.yaml\\.example' README_RU.md
git diff --check v2026.7.20..HEAD
```

Expected: all commands exit 0.

**Step 6: Commit**

```bash
git add README_RU.md build.sh
git commit -m "docs: add fork Docker operations guide"
```

### Task 4: Rebuild the deploy-only CI overlay

**Files:**
- Create: `.github/workflows/docker-publish-fork.yml`

**Step 1: Create `local/ci-deploy` from `v2026.7.20`**

Restore the fork workflow from `pre-overlay-2026-07-28`, then revise it for
the stable container interface.

**Step 2: Run the behavior checks before editing**

Run:

```bash
rg -n 'branches: \\[main\\]|docker/entrypoint\\.sh' \
  .github/workflows/docker-publish-fork.yml
```

Expected: both obsolete behaviors are present.

**Step 3: Restrict workflow activation**

Configure only:

```yaml
on:
  push:
    branches: [deploy]
```

Retain relevant path filters. Do not add pull request, schedule, or
upstream-branch triggers.

**Step 4: Update build and smoke-test behavior**

Build and publish `linux/amd64`. Smoke-test the supported container
entrypoint without directly invoking the deprecated
`docker/entrypoint.sh`. Publish `latest` and `sha-${GITHUB_SHA}` tags.

**Step 5: Validate the workflow**

Run:

```bash
! rg -n 'branches: \\[main\\]|docker/entrypoint\\.sh|linux/arm64' \
  .github/workflows/docker-publish-fork.yml
rg -n 'branches: \\[deploy\\]|linux/amd64' \
  .github/workflows/docker-publish-fork.yml
git diff --check v2026.7.20..HEAD
```

If `actionlint` is available, also run:

```bash
actionlint .github/workflows/docker-publish-fork.yml
```

Expected: all applicable checks exit 0.

**Step 6: Commit**

```bash
git add .github/workflows/docker-publish-fork.yml
git commit -m "ci: publish fork image from deploy"
```

### Task 5: Reset the stable base and assemble deploy

**Files:** None

**Step 1: Move the primary worktree off `main`**

Check out a temporary detached commit or `deploy` before updating the branch
reference.

**Step 2: Point `main` at the stable release**

Run:

```bash
git branch -f main v2026.7.20
```

**Step 3: Create `deploy` from `main`**

Run:

```bash
git switch -C deploy main
git merge --no-ff local/docker -m "deploy: include local/docker"
git merge --no-ff local/ci-deploy -m "deploy: include local/ci-deploy"
git merge --no-ff local/meta -m "deploy: include local/meta"
```

**Step 4: Verify topology**

Run:

```bash
test "$(git rev-parse main)" = "$(git rev-parse v2026.7.20^{commit})"
for branch in local/docker local/ci-deploy local/meta; do
  test "$(git merge-base main "$branch")" = "$(git rev-parse main)"
  git merge-base --is-ancestor "$branch" deploy
done
test "$(git rev-list --count main..local/docker)" -eq 1
test "$(git rev-list --count main..local/ci-deploy)" -eq 1
git diff --quiet local/docker -- README_RU.md build.sh
git diff --quiet local/ci-deploy -- .github/workflows/docker-publish-fork.yml
git diff --quiet local/meta -- BRANCHES.md docs/fork-workflow.md
```

Expected: all commands exit 0.

### Task 6: Verify the assembled release

**Files:** None

**Step 1: Run repository integrity checks**

Run:

```bash
git status --short
git diff --check main..deploy
bash -n build.sh
```

Expected: clean status and exit 0.

**Step 2: Build the image**

Run:

```bash
docker build --platform linux/amd64 -t hermes-agent:overlay-test .
```

Expected: exit 0.

**Step 3: Smoke-test the supported image entrypoint**

Run the image with an isolated temporary `/opt/data` volume and a harmless
help/version command using the image's default entrypoint.

Expected: exit 0 and Hermes help or version output.

### Task 7: Publish branches and configure GitHub Actions

**Files:** None

**Step 1: Inspect outgoing refs**

Run:

```bash
git log --graph --oneline --decorate --all --simplify-by-decoration
git status --short --branch
```

Confirm the backup tag and exact branch tips before pushing.

**Step 2: Push overlays and backup tag**

```bash
git push origin local/docker local/ci-deploy local/meta
git push origin pre-overlay-2026-07-28
```

**Step 3: Rewrite the initial stable base and deploy**

Use explicit expected remote tips with `--force-with-lease`; never use
unqualified `--force`.

**Step 4: Disable upstream workflows individually**

Keep repository Actions enabled. Disable every upstream workflow path in the
Montelibero fork. Do not disable the fork workflow.

**Step 5: Verify remote state**

Run:

```bash
git fetch origin --prune
test "$(git rev-parse origin/main)" = "$(git rev-parse main)"
test "$(git rev-parse origin/deploy)" = "$(git rev-parse deploy)"
gh api repos/Montelibero/hermes-agent/actions/permissions
gh api repos/Montelibero/hermes-agent/actions/workflows --paginate
```

Expected: remote refs match local refs, Actions is enabled, upstream workflows
are disabled, and the deploy-only workflow is active or has been discovered
from `deploy`.
