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

# Match upstream's first-boot control-plane contract. The key is generated
# only when the mounted .env has no operator-provided value.
if [ -f "$HERMES_HOME/.env" ] && [ ! -L "$HERMES_HOME/.env" ] && \
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

if [ -d "$INSTALL_DIR/skills" ]; then
    "$INSTALL_DIR/.venv/bin/python" "$INSTALL_DIR/tools/skills_sync.py" \
        || printf '%s\n' "[rootless] WARNING: bundled skill sync failed; continuing" >&2
fi

if [ -z "${AGENT_BROWSER_EXECUTABLE_PATH:-}" ] && \
        [ -d "${PLAYWRIGHT_BROWSERS_PATH:-}" ]; then
    browser_bin=$(
        find "$PLAYWRIGHT_BROWSERS_PATH" -type f -executable \
            \( -name chrome -o -name chromium -o -name chrome-headless-shell \
               -o -name headless_shell -o -name chromium-browser \) \
            2>/dev/null | head -n 1
    )
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
