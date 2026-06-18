#!/usr/bin/env bash
#
# render-agent-audit.sh — render the Claude Code agent's Agent Audit delivery
# config at <target>/.claude/agent-audit.conf from ../agent-audit.template.conf.
#
# The capture-prompt hook reads its delivery config (Elasticsearch endpoint,
# per-stream destination, capture posture) from a flat key=value agent-audit.conf
# — zero external deps, no jq/TOML parser (SPEC/agent-audit.md "Delivery and
# authorization"). This fills the one value that is the stack's to supply,
# @@ES_URL@@ (the backend's Elasticsearch base URL), into that file.
#
# create-if-absent: an existing agent-audit.conf is left untouched (your edits —
# e.g. an api_key, or content=redacted — survive; delete it to regenerate).
#
# Usage: render-agent-audit.sh <es-url> <target-dir>

set -euo pipefail

es_url=${1:-}
target_dir=${2:-}

if [ -z "$es_url" ] || [ -z "$target_dir" ]; then
  echo "usage: render-agent-audit.sh <es-url> <target-dir>" >&2
  exit 2
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE="$COMPONENT_DIR/agent-audit.template.conf"
config="$target_dir/.claude/agent-audit.conf"

[ -f "$TEMPLATE" ] || {
  echo "FAIL: template not found: $TEMPLATE" >&2
  exit 1
}

if [ -e "$config" ]; then
  echo "kept existing $config (delete to regenerate)"
  exit 0
fi

mkdir -p "$target_dir/.claude"
sed -e "s#@@ES_URL@@#$es_url#" "$TEMPLATE" >"$config"
echo "wrote $config"
