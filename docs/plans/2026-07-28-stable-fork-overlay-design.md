# Stable Fork Overlay Design

## Goal

Keep the Montelibero Hermes Agent fork on the latest stable upstream release
while isolating fork-only Docker, CI, and metadata changes from the stable
base.

## Branch model

`main` is the stable base branch. It must point exactly at the latest signed
stable tag published by `NousResearch/hermes-agent`; at the time of the
migration that tag is `v2026.7.20` (`v0.19.0`). Unlike the generic overlay
workflow, this repository intentionally does not track unreleased
`upstream/main` commits.

Three independent overlay branches start from `main`:

- `local/docker` contains the Russian Docker operations guide and the local
  image rebuild helper.
- `local/ci-deploy` contains the fork-only GHCR build workflow.
- `local/meta` contains only fork documentation and the active branch
  registry.

`deploy` is a generated integration branch. It is rebuilt from `main` by
merging the three overlays with explicit merge commits in this order:
`local/docker`, `local/ci-deploy`, and `local/meta`. No development happens
directly on `deploy`.

Before the initial history rewrite, the old fork tip is retained as the
annotated tag `pre-overlay-2026-07-28`.

## CI behavior

GitHub Actions remains enabled because the fork publishes its own image.
Upstream workflows are disabled individually in the Montelibero fork. The
fork workflow exists only in `local/ci-deploy` and the assembled `deploy`
branch. It runs automatically only for pushes to `deploy`, builds
`linux/amd64`, performs a smoke test through the image's supported entrypoint,
and publishes `latest` plus an immutable `sha-*` tag to GHCR.

## Stable update flow

When upstream publishes a new stable release:

1. Fetch and verify the release tag.
2. Fast-forward `main` to that tag.
3. Rebase each `local/*` branch independently onto `main`.
4. Rebuild `deploy` from scratch and merge the overlays in the fixed order.
5. Run structural, workflow, and container checks.
6. Push rewritten overlay branches and `deploy` with `--force-with-lease`;
   push `main` as a fast-forward whenever possible.

The project-specific workflow is documented on `local/meta`; the generic
cross-project document is not copied into this repository.
