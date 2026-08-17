"""Static contracts for the fork's hardened rootless Docker target."""

from pathlib import Path
import re


REPO_ROOT = Path(__file__).resolve().parents[2]
DOCKERFILE = REPO_ROOT / "Dockerfile"
ENTRYPOINT = REPO_ROOT / "docker" / "rootless-entrypoint.sh"


def _dockerfile() -> str:
    dockerfile = DOCKERFILE.read_text(encoding="utf-8")
    assert "<<<<<<<" not in dockerfile
    assert "=======" not in dockerfile
    assert ">>>>>>>" not in dockerfile
    return dockerfile


def _rootless_stage() -> str:
    dockerfile = _dockerfile()
    marker = " AS deploy-rootless"
    assert marker in dockerfile, "Dockerfile must define a deploy-rootless target"
    return dockerfile.split(marker, maxsplit=1)[1]


def test_rootless_target_inherits_built_runtime_and_uses_non_root_default() -> None:
    dockerfile = _dockerfile()
    assert "FROM debian:13.4 AS sqlite_build" in dockerfile
    assert "FROM node:26-bookworm-slim@" in dockerfile
    assert re.search(
        r"^FROM debian:13\.4 AS upstream-runtime$", dockerfile, re.MULTILINE
    )

    stage = _rootless_stage()
    assert re.search(r"^USER hermes$", stage, re.MULTILINE)
    assert (
        'ENTRYPOINT [ "/usr/local/bin/tini", "--", '
        '"/opt/hermes/docker/rootless-entrypoint.sh" ]'
    ) in stage


def test_default_build_keeps_the_upstream_runtime() -> None:
    dockerfile = _dockerfile().rstrip()
    assert dockerfile.endswith("FROM upstream-runtime AS upstream-default")


def test_rootless_target_removes_privileged_s6_runtime() -> None:
    stage = _rootless_stage()
    for path in ("/init", "/package", "/command", "/etc/s6-overlay"):
        assert path in stage, f"rootless target must remove {path}"
    assert "chmod a-s" in stage
    assert "mkdir -p /workspace" in stage


def test_rootless_target_preserves_real_tini_before_compatibility_shim() -> None:
    dockerfile = _dockerfile()
    install = dockerfile.index("apt-get -o Acquire::Retries=3 install")
    preserve = dockerfile.index("cp /usr/bin/tini /usr/local/bin/tini")
    shim = dockerfile.index("COPY --chmod=0755 docker/tini-shim.sh /usr/bin/tini")
    assert install < preserve < shim


def test_rootless_entrypoint_never_changes_identity_or_ownership() -> None:
    assert ENTRYPOINT.exists(), "rootless entrypoint must exist"
    script = ENTRYPOINT.read_text(encoding="utf-8")
    executable_lines = "\n".join(
        line for line in script.splitlines() if not line.lstrip().startswith("#")
    )
    forbidden = ("chown", "usermod", "groupmod", "setuid", "sudo", "su ")
    for token in forbidden:
        assert token not in executable_lines


def test_rootless_entrypoint_validates_and_bootstraps_writable_state() -> None:
    script = ENTRYPOINT.read_text(encoding="utf-8")
    assert "HERMES_HOME=${HERMES_HOME:-/opt/data}" in script
    assert 'test -w "$HERMES_HOME"' in script
    assert "docker_config_migrate.py" in script
    assert "tools/skills_sync.py" in script
    assert 'exec "$@"' in script


def test_rootless_entrypoint_preserves_v0202_first_boot_contracts() -> None:
    script = ENTRYPOINT.read_text(encoding="utf-8")
    assert "HERMES_SKIP_CONFIG_MIGRATION" in script
    assert "API_SERVER_KEY" in script
    assert "HERMES_AUTH_JSON_BOOTSTRAP" in script
    assert "docker_rebootstrap_nous_session.py" in script
    assert "refusing auth bootstrap through symlink" in script
