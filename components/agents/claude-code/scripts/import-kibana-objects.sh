#!/usr/bin/env bash
#
# import-kibana-objects.sh — import the Claude Code agent's Kibana saved objects.
#
# Scope: the Claude Code **agent** assets — its per-agent data views (Metrics /
# Events / Traces), saved searches, and the Overview dashboard. The cross-agent
# backend data view (AI Agents — Traces) is imported separately by the Elastic
# backend's own import script; a stack composes the two by running the backend's
# import first, then this one.
#
# Imports the NDJSON files in ../kibana/ through the Kibana Saved Objects
# `_import?overwrite=true` API, in dependency order: **data views first**, so the
# `claude-code-events` / `claude-code-metrics` / `claude-code-traces`
# references in the saved searches and the dashboard resolve, then the **saved
# searches**, then the **dashboard**. Prints the per-file import result.
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
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
COMPONENT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$COMPONENT_DIR"

skip() {
  echo "SKIP: $*"
  exit 0
}
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v curl > /dev/null 2>&1 || skip "curl not found"
command -v jq > /dev/null 2>&1 || skip "jq not found"

# Data views BEFORE saved searches BEFORE the dashboard — the saved searches and
# the dashboard reference the data views (claude-code-events /
# claude-code-metrics / claude-code-traces), and those references must
# already exist.
FILES="
kibana/data-views.ndjson
kibana/saved-searches.ndjson
kibana/dashboard.ndjson
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

echo "[import] importing Claude Code Kibana saved objects into $KIBANA_URL…"
for f in $FILES; do
  import_file "$f"
done

echo
echo "PASS: Claude Code Kibana saved objects imported. Open Discover (Open menu) to"
echo "use the saved searches, or the data-view selector for the Metrics / Events views."
