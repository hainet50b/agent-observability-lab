#!/usr/bin/env bash
#
# render-mcp.sh — materialize the Claude Code agent's project-scoped MCP config
# at <target>/.mcp.json from the agent-owned template ../templates/mcp.template.json.
#
# The MCP server definitions are the agent's property and live once in the
# template. This writes them verbatim — dropping only the _comment — to the
# target's .mcp.json, so a `claude` launched from <target> discovers the
# project-scoped Elasticsearch MCP server. No placeholder substitution: the
# template is self-contained.
#
# No auto-approve key is written: the project-scoped server stays
# interactive-approval (claude prompts to trust it on first launch — a user
# decision, deliberately not pre-approved here).
#
# create-if-absent: an existing .mcp.json is left untouched (your edits survive;
# delete it to regenerate).
#
# Usage: render-mcp.sh <target-dir>

set -euo pipefail

target=${1:-}
if [ -z "$target" ]; then
  echo "usage: render-mcp.sh <target-dir>" >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE="$COMPONENT_DIR/templates/mcp.template.json"
out="$target/.mcp.json"

[ -f "$TEMPLATE" ] || {
  echo "FAIL: template not found: $TEMPLATE" >&2
  exit 1
}

if [ -e "$out" ]; then
  echo "kept existing $out (delete to regenerate)"
  exit 0
fi

mkdir -p "$target"
jq 'del(._comment)' "$TEMPLATE" >"$out"
echo "wrote $out"
