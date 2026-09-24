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


def test_rootless_entrypoint_preserves_upstream_first_boot_contracts() -> None:
    script = ENTRYPOINT.read_text(encoding="utf-8")
    assert "HERMES_SKIP_CONFIG_MIGRATION" in script
    assert "API_SERVER_KEY" in script
    assert "HERMES_AUTH_JSON_BOOTSTRAP" in script
    assert "docker_rebootstrap_nous_session.py" in script
    assert "refusing auth bootstrap through symlink" in script


def test_rootless_entrypoint_respects_operator_api_server_key() -> None:
    """A container-env API_SERVER_KEY must win over key generation.

    $HERMES_HOME/.env is loaded with override=True at runtime, so a key
    generated while the operator supplied one through the environment
    would shadow their credential and 401 every client using it.
    """
    script = ENTRYPOINT.read_text(encoding="utf-8")
    guard = '[ -n "${API_SERVER_KEY:-}" ]'
    generation = "generated_key=$(head -c 32 /dev/urandom"
    assert guard in script
    assert generation in script
    assert script.index(guard) < script.index(generation)


def test_rootless_entrypoint_seeds_xdg_runtime_dir() -> None:
    script = ENTRYPOINT.read_text(encoding="utf-8")
    assert 'XDG_RUNTIME_DIR' in script
    assert 'chmod 0700 "$XDG_RUNTIME_DIR"' in script


def test_rootless_entrypoint_supports_gateway_state_bootstrap() -> None:
    script = ENTRYPOINT.read_text(encoding="utf-8")
    assert "HERMES_GATEWAY_BOOTSTRAP_STATE" in script
    assert "gateway_state.json" in script
    assert '"gateway_state":"running"' in script


def test_rootless_entrypoint_syncs_nous_routing_overrides() -> None:
    script = ENTRYPOINT.read_text(encoding="utf-8")
    assert "HERMES_PORTAL_BASE_URL" in script
    assert "NOUS_PORTAL_BASE_URL" in script
    assert "NOUS_INFERENCE_BASE_URL" in script
    assert "sync_routing_overrides" in script


def test_rootless_entrypoint_prefers_headless_browser_shell() -> None:
    script = ENTRYPOINT.read_text(encoding="utf-8")
    headless = script.index("-name 'chrome-headless-shell'")
    full = script.index("-name chromium-browser")
    assert headless < full


def test_rootless_target_bakes_billion_context() -> None:
    """The compression proxy ships in the fork target, exactly pinned.

    The runtime tree is immutable, so the package's self-updater is disabled
    in the stage and a new version only arrives with a rebuilt image.
    """
    stage = _rootless_stage()
    assert "billion-context@0.1.147" in stage
    assert "test -x /usr/local/bin/bili" in stage
    assert "ACP_AUTO_UPDATE=0" in stage


def test_rootless_entrypoint_enables_billion_context_plugin() -> None:
    """The entrypoint installs+enables the native hermes plugin each boot,
    gated by an opt-out env; the gate must precede the install."""
    script = ENTRYPOINT.read_text(encoding="utf-8")
    gate = '[ "${HERMES_BILLION_CONTEXT:-1}" = "1" ]'
    install = "bili plugin install hermes"
    assert gate in script
    assert install in script
    assert script.index(gate) < script.index(install)
