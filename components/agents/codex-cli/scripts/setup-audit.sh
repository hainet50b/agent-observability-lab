#!/usr/bin/env bash

set -euo pipefail

[ "$#" -eq 2 ] || {
  echo "usage: setup-audit.sh <agent_home> <es_url>" >&2
  exit 1
}
agent_home=$1
es_url=$2

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

"$SCRIPT_DIR/render-agent-audit.sh" "$es_url" "$agent_home"
"$SCRIPT_DIR/render-hooks.sh" "$agent_home"
"$SCRIPT_DIR/render-mcp.sh" "$agent_home"
