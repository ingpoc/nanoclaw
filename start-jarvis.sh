#!/usr/bin/env bash
# Start NanoClaw. Notion MCP HTTP (7802) and Linear MCP HTTP (7803) start
# automatically as part of the NanoClaw process — no separate servers needed.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
exec node --env-file=.env --import ./node_modules/tsx/dist/loader.mjs src/index.ts
