#!/usr/bin/env bash
#
# import-kibana-objects.sh — import the elastic-audit backend's Agent Audit
# Kibana saved objects.
#
# Scope: the cross-agent **Agent Audit** assets this backend owns — the Agent
# Audit data views (logs-agent_audit.user_prompt-* / logs-agent_audit.tool_call-*)
# and their saved searches. These are agent-cross-cutting (the AI agent is a
# document field, not a stream-name segment), so they belong to the backend, not
# to any single agent's import script.
#
# Imports the NDJSON files in ../kibana/ through the Kibana Saved Objects
# `_import?overwrite=true` API. Prints the per-file import result.
#
# Prerequisites: curl, jq. Override the Kibana base URL with KIBANA_URL if you
# publish a different port than the default below.
#
#   KIBANA_URL=http://localhost:5601  scripts/import-kibana-objects.sh
#
# Run from anywhere — it locates its own component directory like the others.

set -euo pipefail

KIBANA_URL=${KIBANA_URL:-http://localhost:5601}

# Resolve and enter the component root (parent of this scripts/ directory) so the
# kibana/ NDJSON paths resolve regardless of the caller's cwd.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$COMPONENT_DIR"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || skip "curl not found"
command -v jq   >/dev/null 2>&1 || skip "jq not found"

# The Agent Audit assets this backend owns: the Agent Audit — User Prompts and
# Agent Audit — Tool Calls data views + saved searches (the cross-agent hook->ES
# audit streams logs-agent_audit.*-*). Each NDJSON is self-contained (its saved
# search's data-view reference resolves within the same file).
FILES="
kibana/agent-audit.ndjson
"

import_file() {
  f=$1
  [ -f "$f" ] || fail "$f not found"
  echo "[import] $f"
  result=$(curl -s -X POST "$KIBANA_URL/api/saved_objects/_import?overwrite=true" \
    -H "kbn-xsrf: true" --form file=@"$f") || fail "request to Kibana failed for $f"

  echo "$result" | jq .

  success=$(echo "$result" | jq -r '.success // false')
  [ "$success" = true ] || fail "$f did not import cleanly (success=$success)"
  count=$(echo "$result" | jq -r '.successCount // 0')
  echo "[import] $f -> $count object(s) imported ✓"
}

echo "[import] importing Agent Audit Kibana saved objects into $KIBANA_URL…"
for f in $FILES; do
  import_file "$f"
done

echo
echo "PASS: Agent Audit Kibana objects imported into $KIBANA_URL."
