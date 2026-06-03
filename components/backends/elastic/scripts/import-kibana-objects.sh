#!/usr/bin/env bash
#
# import-kibana-objects.sh — import the claude-code-elastic Kibana saved objects.
#
# Imports the NDJSON files in ../kibana/ through the Kibana Saved Objects
# `_import?overwrite=true` API, in dependency order: the **data views** first, so
# the `cce-claude-code-events` / `cce-claude-code-metrics` references resolve,
# then the **saved searches**, then the **dashboard** (which references the data
# views by id). Prints the per-file import result.
#
# This absorbs the shell-specific curl loop that the README used to spell out
# twice (bash `for…do…done` vs fish `for…end`): run this instead.
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

# Data views BEFORE saved searches BEFORE the dashboard — the saved searches and
# the dashboard reference the data views (cce-claude-code-events /
# cce-claude-code-metrics), and those references must already exist.
FILES="
kibana/claude-code-data-views.ndjson
kibana/claude-code-saved-searches.ndjson
kibana/claude-code-dashboard.ndjson
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
echo "PASS: all Kibana saved objects imported. Open Discover (Open menu) to use the"
echo "saved searches, or the data-view selector for the Metrics / Events data views."
