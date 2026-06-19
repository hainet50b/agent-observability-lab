#!/usr/bin/env bash
#
# setup-audit.sh — configure Codex CLI for the audit concern.
#
# Concern-level façade: the stack passes its agent home and the Elasticsearch URL
# the hooks write to; this script owns which render steps realize the audit
# concern AND their order — the hooks block must be rendered before the MCP block
# is appended to config.toml. Renders agent-audit.conf, the UserPromptSubmit +
# PostToolUse hooks, then the Elasticsearch MCP config into the agent home.
#
# Usage: setup-audit.sh <agent_home> <es_url>

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
