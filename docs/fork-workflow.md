# Stable fork workflow

This fork deploys stable upstream releases with a small set of independent
local overlays. The generic fork workflow is intentionally narrowed for
Hermes Agent.

## Invariants

- `main` points exactly at the latest approved stable tag from
  `NousResearch/hermes-agent`.
- `upstream/main` is fetched for visibility but is not a deployable base.
- Each `local/*` branch starts from `main` and remains independent.
- `deploy` is generated from `main` plus the overlays in `BRANCHES.md`.
- Development never happens directly on `main` or `deploy`.
- Git rerere remains enabled.
- Upstream GitHub workflows are disabled in the Montelibero fork.
- The fork image workflow runs only for pushes to `deploy`.

## Confirm the next stable release

Fetch upstream without merging anything:

```bash
git fetch upstream --tags --prune
gh release view --repo NousResearch/hermes-agent \
  --json tagName,name,publishedAt,isDraft,isPrerelease
```

Inspect the release notes and record the selected tag:

```bash
release_tag=v2026.8.16
git merge-base --is-ancestor main "$release_tag"

tag_object="$(git rev-parse "$release_tag^{tag}")"
verification="$(
  gh api "repos/NousResearch/hermes-agent/git/tags/$tag_object" \
    --jq '[.verification.verified, .verification.reason] | @tsv'
)"
test "$verification" = $'true\tvalid'
```

Both ancestry and GitHub signature checks must exit successfully. Stop if the
tag signature is not valid or the release is not a descendant of the current
stable base.

## Update the stable base and overlays

Temporarily pause repository Actions before changing `main`. This prevents a
new upstream workflow from running before it can be disabled:

```bash
gh api --method PUT \
  repos/Montelibero/hermes-agent/actions/permissions \
  -F enabled=false
```

Fast-forward `main` to the selected release:

```bash
git switch main
git merge --ff-only "$release_tag"
```

Rebase every overlay independently:

```bash
for branch in local/docker local/ci-deploy local/meta; do
  git switch "$branch"
  git rebase main
done
```

If a rebase conflicts, resolve only that overlay. Do not merge one local
branch into another.

## Rebuild deploy

The reset below discards commits made directly on `deploy`. Confirm that all
intended work is present on `main` or an active `local/*` branch first.

```bash
git switch deploy
git reset --hard main
git merge --no-ff local/docker -m "deploy: include local/docker"
git merge --no-ff local/ci-deploy -m "deploy: include local/ci-deploy"
git merge --no-ff local/meta -m "deploy: include local/meta"
```

## Verify locally

```bash
test "$(git rev-parse main)" = "$(git rev-parse "$release_tag^{commit}")"

for branch in local/docker local/ci-deploy local/meta; do
  test "$(git merge-base main "$branch")" = "$(git rev-parse main)"
  git merge-base --is-ancestor "$branch" deploy
done

git diff --check main..deploy
bash -n build.sh
python3 -c 'import yaml; yaml.compose(open(".github/workflows/docker-publish-fork.yml", encoding="utf-8"))'

test -z "$(git status --short)"
```

Build and smoke-test the assembled image:

```bash
deploy_sha="$(git rev-parse deploy)"
docker build --platform linux/amd64 \
  --target deploy-rootless \
  --build-arg "HERMES_GIT_SHA=$deploy_sha" \
  -t hermes-agent:overlay-test .
scripts/verify_rootless_image.sh hermes-agent:overlay-test
```

## Publish safely

Push the stable base and rebased overlays while Actions remains paused:

```bash
git push origin main
git push --force-with-lease origin local/docker local/ci-deploy local/meta
```

List workflows known to the fork, then disable every workflow except the
fork-owned deploy workflow:

```bash
gh api repos/Montelibero/hermes-agent/actions/workflows --paginate \
  --jq '.workflows[] | [.path, .state] | @tsv'

gh api repos/Montelibero/hermes-agent/actions/workflows --paginate \
  --jq '.workflows[] |
        select(.path != ".github/workflows/docker-publish-fork.yml") |
        .id' |
while read -r workflow_id; do
  gh api --method PUT \
    "repos/Montelibero/hermes-agent/actions/workflows/$workflow_id/disable"
done
```

The list changes between releases. Disable any newly introduced upstream
workflow before re-enabling repository Actions.

```bash
gh api --method PUT \
  repos/Montelibero/hermes-agent/actions/permissions \
  -F enabled=true \
  -f allowed_actions=all

git push --force-with-lease origin deploy
```

Pushing `deploy` last triggers the fork image workflow after all upstream
workflows have been disabled.

## Verify the remote

```bash
git fetch origin --prune
test "$(git rev-parse origin/main)" = "$(git rev-parse main)"
test "$(git rev-parse origin/deploy)" = "$(git rev-parse deploy)"

gh api repos/Montelibero/hermes-agent/actions/permissions
gh api repos/Montelibero/hermes-agent/actions/workflows --paginate \
  --jq '.workflows[] | [.path, .state] | @tsv'
```

The repository-level result must report Actions enabled. Upstream workflows
must report a disabled state. The only automatic fork build is
`.github/workflows/docker-publish-fork.yml` on `deploy`.
