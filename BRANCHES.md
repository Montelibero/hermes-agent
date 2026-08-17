# Active fork branches

Stable base: `main` = upstream release `v2026.8.16` (`v0.20.2`).

| Branch | Type | Purpose | Upstream PR |
|---|---|---|---|
| `local/docker` | local | Russian Docker operations guide and local build helper | n/a |
| `local/ci-deploy` | local | Build and publish the fork image from `deploy` | n/a |
| `local/meta` | local | Branch registry, fork workflow, and migration plans | n/a |
| `deploy` | generated | Stable base with all active overlays merged | n/a |

## Assembly order

`deploy` is rebuilt from `main`; it is not developed manually.

```bash
git switch deploy
git reset --hard main
git merge --no-ff local/docker -m "deploy: include local/docker"
git merge --no-ff local/ci-deploy -m "deploy: include local/ci-deploy"
git merge --no-ff local/meta -m "deploy: include local/meta"
```

The full stable update and verification procedure is in
[`docs/fork-workflow.md`](docs/fork-workflow.md).
