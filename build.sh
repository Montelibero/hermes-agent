#!/usr/bin/env bash
set -euo pipefail

git pull --ff-only
docker build --platform linux/amd64 -t hermes-agent:local .
