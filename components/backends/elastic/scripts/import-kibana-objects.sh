#!/usr/bin/env bash
#
# import-kibana-objects.sh — import the Elastic backend's cross-agent Kibana
# saved objects.
#
# Scope: **cross-agent telemetry backend assets only** — agent-specific assets
# (per-agent data views, saved searches, dashboards) are imported by each agent's
# own import script (e.g. components/agents/claude-code/scripts/import-kibana-objects.sh);
# the cross-agent Agent Audit assets are imported by the elastic-audit backend. A
# stack composes the two by running this script first, then the agent's.
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

command -v curl >/dev/null 2>&1 || skip "curl not found"
command -v jq >/dev/null 2>&1 || skip "jq not found"

# The cross-agent assets this backend owns: the AI Agents — Traces data view
# (traces-apm-agents_*). Agent-specific data views / saved searches / dashboards
# are imported by the agent's own import script; the cross-agent Agent Audit
# assets live in the elastic-audit backend (composed by *-elastic-audit stacks),
# not here. Each NDJSON is self-contained (its saved search's data-view reference
# resolves within the same file).
FILES="
kibana/agents-data-views.ndjson
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

echo "[import] importing Kibana saved objects into $KIBANA_URL…"
for f in $FILES; do
  import_file "$f"
done

echo
echo "PASS: backend cross-agent Kibana objects imported into $KIBANA_URL."
