#!/bin/sh
# Rootless deploy entrypoint. All initialization runs as the container's
# configured numeric UID:GID and writes only to mounted state directories.

set -eu
umask 077

HERMES_HOME=${HERMES_HOME:-/opt/data}
INSTALL_DIR=/opt/hermes
export HERMES_HOME
export HOME=${HOME:-$HERMES_HOME}

mkdir -p "$HERMES_HOME"

if ! test -w "$HERMES_HOME"; then
    printf '%s\n' \
        "[rootless] ERROR: $HERMES_HOME is not writable by UID $(id -u):$(id -g)." \
        "[rootless] Prepare the bind mount for the configured container user." >&2
    exit 1
fi

write_probe="$HERMES_HOME/.rootless-write-probe.$$"
cleanup_probe() {
    rm -f "$write_probe"
}
trap cleanup_probe 0 1 2 15
if ! : > "$write_probe"; then
    printf '%s\n' \
        "[rootless] ERROR: cannot create files in $HERMES_HOME as UID $(id -u):$(id -g)." >&2
    exit 1
fi
cleanup_probe
trap - 0 1 2 15

mkdir -p \
    "$HERMES_HOME/backups" \
    "$HERMES_HOME/cron" \
    "$HERMES_HOME/sessions" \
    "$HERMES_HOME/logs/gateways" \
    "$HERMES_HOME/hooks" \
    "$HERMES_HOME/memories" \
    "$HERMES_HOME/skills" \
    "$HERMES_HOME/skins" \
    "$HERMES_HOME/plans" \
    "$HERMES_HOME/workspace" \
    "$HERMES_HOME/home" \
    "$HERMES_HOME/pairing" \
    "$HERMES_HOME/platforms/pairing" \
    "$HERMES_HOME/lazy-packages"

# Seed XDG_RUNTIME_DIR the way the upstream stage2 hook does, minus the
# root-only ownership repair (everything this script creates is already
# owned by the runtime identity). The baked directory is hidden by the
# writable /tmp tmpfs in production, and dbus plus the display-allocation
# lock require 0700. A symlink at the path is refused, not adopted.
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    if [ -L "$XDG_RUNTIME_DIR" ]; then
        printf '%s\n' \
            "[rootless] ERROR: refusing symlink at XDG_RUNTIME_DIR $XDG_RUNTIME_DIR" >&2
        exit 1
    fi
    mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || \
        printf '%s\n' "[rootless] WARNING: could not create XDG_RUNTIME_DIR $XDG_RUNTIME_DIR" >&2
    chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
fi

seed_one() {
    destination=$1
    source=$2
    if [ -L "$HERMES_HOME/$destination" ]; then
        printf '%s\n' \
            "[rootless] ERROR: refusing to seed symlink $HERMES_HOME/$destination" >&2
        exit 1
    fi
    if [ ! -e "$HERMES_HOME/$destination" ] && [ -f "$INSTALL_DIR/$source" ]; then
        cp -- "$INSTALL_DIR/$source" "$HERMES_HOME/$destination"
    fi
}

seed_one ".env" ".env.example"
seed_one "config.yaml" "cli-config.yaml.example"
seed_one "SOUL.md" "docker/SOUL.md"

# Upstream excludes .env.example from the Docker build context.  A fresh data
# volume still needs a secrets file so first-boot credentials can be persisted.
# seed_one() already rejected a symlink at this path.
if [ ! -e "$HERMES_HOME/.env" ]; then
    : > "$HERMES_HOME/.env"
fi

# The install-method marker belongs to the immutable code tree. Remove the
# stale data-volume copy left by older container releases.
if [ -f "$HERMES_HOME/.install_method" ] && [ ! -L "$HERMES_HOME/.install_method" ]; then
    install_method=$(tr -d '[:space:]' < "$HERMES_HOME/.install_method" 2>/dev/null || true)
    if [ "$install_method" = "docker" ]; then
        rm -f "$HERMES_HOME/.install_method"
    fi
fi

# Match upstream's first-boot control-plane contract. An operator-provided
# API_SERVER_KEY in the container environment wins: $HERMES_HOME/.env is
# loaded with override=True at runtime, so a key generated here would shadow
# the operator's credential and 401 every client still using it. Generate
# only when neither the environment nor the mounted .env carries a value.
if [ -n "${API_SERVER_KEY:-}" ]; then
    if [ -f "$HERMES_HOME/.env" ] && [ ! -L "$HERMES_HOME/.env" ]; then
        # Drop a stale empty assignment so the operator key wins at runtime.
        sed -i '/^API_SERVER_KEY=$/d' "$HERMES_HOME/.env" 2>/dev/null || true
    fi
elif [ -f "$HERMES_HOME/.env" ] && [ ! -L "$HERMES_HOME/.env" ] && \
        ! grep -q '^API_SERVER_KEY=..*' "$HERMES_HOME/.env" 2>/dev/null; then
    generated_key=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    if [ -n "$generated_key" ]; then
        sed -i '/^API_SERVER_KEY=$/d' "$HERMES_HOME/.env" 2>/dev/null || true
        printf 'API_SERVER_KEY=%s\n' "$generated_key" >> "$HERMES_HOME/.env"
    fi
    unset generated_key
fi

if [ -f "$HERMES_HOME/.env" ] && [ ! -L "$HERMES_HOME/.env" ]; then
    chmod 600 "$HERMES_HOME/.env"
fi

# Sync deploy-injected Nous routing overrides into $HERMES_HOME/.env and
# every profile .env, mirroring the upstream stage2 hook: the profile
# secret scope reads these names with no os.environ fallback, so a value
# that lives only in the container environment is invisible on every
# routed turn. The container wins over a stale line, an already-correct
# line is left alone, and lines written here carry a marker so a boot
# WITHOUT the variable removes them again (a hand-set line is never
# touched).
_ROUTING_MARK='# rootless-managed'
# rewrite_env_var FILE NAME DROP_PATTERN [LINE]: drop the lines matching DROP_PATTERN (a BRE),
# append LINE when given. Rewritten through the existing inode (owner and mode kept — sed -i would
# re-create the file). `grep -v` exits 1 when nothing remains (fine) and 2 when the file could not
# be read (then a rewrite would wipe every other secret — refuse). A read-only volume degrades to a
# warning, never a boot abort.
rewrite_env_var() {
    _rc=0
    _rest=$(grep -v -- "$3" "$1" 2>/dev/null) || _rc=$?
    if [ "$_rc" -gt 1 ]; then
        printf '%s\n' "[rootless] WARNING: could not read $1 — leaving $2 untouched" >&2
        return 1
    fi
    if [ $# -ge 4 ]; then
        _rest="${_rest:+$_rest
}$4"
    fi
    if printf '%s' "${_rest:+$_rest
}" 2>/dev/null > "$1"; then
        return 0
    fi
    printf '%s\n' "[rootless] WARNING: could not write $2 to $1 (read-only volume?) — routed turns will fall back to the production Portal" >&2
    return 1
}
sync_routing_overrides() {
    _file="$1"
    if [ -L "$_file" ]; then
        return 0
    fi
    for _name in HERMES_PORTAL_BASE_URL NOUS_PORTAL_BASE_URL NOUS_INFERENCE_BASE_URL; do
        eval "_value=\${$_name:-}"
        _managed="^$_name=.* $_ROUTING_MARK\$"
        if [ -z "$_value" ]; then
            if grep -q -- "$_managed" "$_file" 2>/dev/null && rewrite_env_var "$_file" "$_name" "$_managed"; then
                printf '%s\n' "[rootless] Removed $_name from $_file (no longer set in the container environment)"
            fi
            continue
        fi
        _line="$_name=$_value $_ROUTING_MARK"
        if grep -qxF -- "$_line" "$_file" 2>/dev/null; then
            continue
        fi
        if [ ! -f "$_file" ] && ! (umask 077 && : >> "$_file"); then
            printf '%s\n' "[rootless] WARNING: could not create $_file — the Nous routing overrides will not reach this profile's secret scope" >&2
            return 0
        fi
        if rewrite_env_var "$_file" "$_name" "^$_name=" "$_line"; then
            printf '%s\n' "[rootless] Synced $_name from the container environment into $_file"
        fi
    done
}
sync_routing_overrides "$HERMES_HOME/.env"
for _profile_dir in "$HERMES_HOME"/profiles/*/; do
    [ -d "$_profile_dir" ] || continue
    sync_routing_overrides "${_profile_dir}.env"
done
unset _profile_dir _file _name _value _managed _line _rest _rc

if [ -f "$HERMES_HOME/config.yaml" ] && \
        [ "${HERMES_SKIP_CONFIG_MIGRATION:-0}" != "1" ]; then
    "$INSTALL_DIR/.venv/bin/python" "$INSTALL_DIR/scripts/docker_config_migrate.py" \
        || printf '%s\n' "[rootless] WARNING: config migration failed; continuing" >&2
fi

# Bootstrap auth once without ever replacing a persisted, rotating session.
if [ -L "$HERMES_HOME/auth.json" ] && \
        { [ -n "${HERMES_AUTH_JSON_BOOTSTRAP:-}" ] || \
          [ -n "${HERMES_AUTH_JSON_REBOOTSTRAP:-}" ]; }; then
    printf '%s\n' \
        "[rootless] ERROR: refusing auth bootstrap through symlink $HERMES_HOME/auth.json" >&2
    exit 1
fi

if [ ! -e "$HERMES_HOME/auth.json" ] && [ -n "${HERMES_AUTH_JSON_BOOTSTRAP:-}" ]; then
    printf '%s' "$HERMES_AUTH_JSON_BOOTSTRAP" > "$HERMES_HOME/auth.json"
    chmod 600 "$HERMES_HOME/auth.json"
fi

# A managed deployment may supply a newer Nous session for a terminally dead
# persisted credential. The upstream helper performs the guarded replacement.
if [ -f "$HERMES_HOME/auth.json" ] && [ ! -L "$HERMES_HOME/auth.json" ] && \
        [ -n "${HERMES_AUTH_JSON_REBOOTSTRAP:-}" ]; then
    "$INSTALL_DIR/.venv/bin/python" \
        "$INSTALL_DIR/scripts/docker_rebootstrap_nous_session.py" \
        "$HERMES_HOME/auth.json" \
        || printf '%s\n' "[rootless] WARNING: Nous auth rebootstrap failed; continuing" >&2
fi

# First-boot gateway state seed, mirroring the upstream container contract:
# HERMES_GATEWAY_BOOTSTRAP_STATE=running records the initial supervised
# state on a fresh volume. Only a literal "running" is honoured; a
# persisted file always wins, and the seed never goes through a symlink.
if [ -n "${HERMES_GATEWAY_BOOTSTRAP_STATE:-}" ]; then
    if [ -L "$HERMES_HOME/gateway_state.json" ]; then
        printf '%s\n' \
            "[rootless] ERROR: refusing gateway state seed through symlink $HERMES_HOME/gateway_state.json" >&2
        exit 1
    fi
    if [ ! -e "$HERMES_HOME/gateway_state.json" ] && \
            [ "$HERMES_GATEWAY_BOOTSTRAP_STATE" = "running" ]; then
        printf '{"gateway_state":"running"}\n' > "$HERMES_HOME/gateway_state.json"
        chmod 644 "$HERMES_HOME/gateway_state.json"
    fi
fi

if [ -d "$INSTALL_DIR/skills" ]; then
    "$INSTALL_DIR/.venv/bin/python" "$INSTALL_DIR/tools/skills_sync.py" \
        || printf '%s\n' "[rootless] WARNING: bundled skill sync failed; continuing" >&2
fi

if [ -z "${AGENT_BROWSER_EXECUTABLE_PATH:-}" ] && \
        [ -d "${PLAYWRIGHT_BROWSERS_PATH:-}" ]; then
    # Two ordered finds, matching the upstream stage2 hook: the headless
    # shell first (what agent-browser launches for ordinary headless
    # browsing and the lighter build), the full chromium second.
    browser_bin=$(
        find "$PLAYWRIGHT_BROWSERS_PATH" -type f -executable \
            \( -name 'chrome-headless-shell' -o -name 'headless_shell' \) \
            2>/dev/null | head -n 1
    )
    if [ -z "$browser_bin" ]; then
        browser_bin=$(
            find "$PLAYWRIGHT_BROWSERS_PATH" -type f -executable \
                \( -name chrome -o -name chromium -o -name chromium-browser \) \
                2>/dev/null | head -n 1
        )
    fi
    if [ -n "$browser_bin" ]; then
        AGENT_BROWSER_EXECUTABLE_PATH=$browser_bin
        export AGENT_BROWSER_EXECUTABLE_PATH
    fi
fi

if [ "$#" -eq 0 ]; then
    set -- hermes
elif ! command -v "$1" >/dev/null 2>&1; then
    set -- hermes "$@"
fi

exec "$@"
