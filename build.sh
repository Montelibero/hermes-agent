#!/usr/bin/env bash
set -euo pipefail

git pull --ff-only
docker build --platform linux/amd64 --target deploy-rootless -t hermes-agent:local .
