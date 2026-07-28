#!/usr/bin/env bash

set -euo pipefail

image=${1:?usage: verify_rootless_image.sh IMAGE}
runtime_uid=${HERMES_TEST_UID:-12345}
runtime_gid=${HERMES_TEST_GID:-23456}

docker run --rm \
  --user "${runtime_uid}:${runtime_gid}" \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --tmpfs "/opt/data:rw,noexec,nosuid,nodev,size=67108864,uid=${runtime_uid},gid=${runtime_gid},mode=0700" \
  --tmpfs "/workspace:rw,noexec,nosuid,nodev,size=16777216,uid=${runtime_uid},gid=${runtime_gid},mode=0700" \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=134217728,mode=1777 \
  --workdir /workspace \
  "$image" \
  sh -ec '
    test "$(id -u)" = "'"$runtime_uid"'"
    test "$(id -g)" = "'"$runtime_gid"'"
    test ! -e /init
    test ! -w /opt/hermes
    test -w /opt/data
    test -w /workspace
    test -w /tmp
    grep -Eq "^API_SERVER_KEY=.{16,}$" /opt/data/.env
    grep -Eq "^CapEff:[[:space:]]+0000000000000000$" /proc/self/status
    grep -Eq "^NoNewPrivs:[[:space:]]+1$" /proc/self/status
    test -z "$(find / -xdev -type f \( -perm /4000 -o -perm /2000 \) -print -quit 2>/dev/null)"
    test "$(node --version | cut -d. -f1)" = "v26"
    python -c "import sqlite3, sys; sys.exit(0 if sqlite3.sqlite_version_info >= (3, 51, 3) else 1)"
    hermes --version
  '
