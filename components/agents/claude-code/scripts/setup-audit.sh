#!/usr/bin/env bash
#
# setup-audit.sh — configure Claude Code for the audit concern.
#
# Concern-level façade (see setup-telemetry.sh): the stack passes its agent home
# and the Elasticsearch URL the hook writes to; this script owns which render
# steps realize the audit concern and their order. Renders the UserPromptSubmit
# audit hook registration, the agent-audit.conf delivery config, and the
# Elasticsearch MCP config into the agent home.
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

"$SCRIPT_DIR/render-hook.sh" "$agent_home"
"$SCRIPT_DIR/render-agent-audit.sh" "$es_url" "$agent_home"
"$SCRIPT_DIR/render-mcp.sh" "$agent_home"
