"""Contracts for the fork-only deploy image workflow."""

from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "docker-publish-fork.yml"


def test_publish_builds_embed_the_exact_deploy_commit() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    assert workflow.count("HERMES_GIT_SHA=${{ github.sha }}") == 2
