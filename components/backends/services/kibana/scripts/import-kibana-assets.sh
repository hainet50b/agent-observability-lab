#!/usr/bin/env bash
#
# import-kibana-assets.sh — the Kibana service's single saved-objects importer
# for every source (agent / path / cross-agent audit).
#
# Kibana objects are consumed by Kibana, so every per-source NDJSON bundle lives
# under this service component, namespaced by source: <source>/ (e.g.
# claude-code/, codex-cli/, otelcol-sidecar/, agent-audit/). Backends select
# which sources to import; the importer itself carries no per-backend selection.
#
# Usage: pass the source namespace(s) to import as positional arguments:
#
#   scripts/import-kibana-assets.sh claude-code
#   scripts/import-kibana-assets.sh claude-code otelcol-sidecar
#   scripts/import-kibana-assets.sh codex-cli
#   scripts/import-kibana-assets.sh agent-audit
#
# Within every source directory files import in category
# order: data-views → saved-searches → dashboard, so data views exist before the
# saved searches and dashboards that reference them.
#
# Imports each NDJSON through the Kibana Saved Objects `_import?overwrite=true`
# API and prints the per-file import result.
#
# Prerequisites: curl, jq. Override the Kibana base URL with KIBANA_URL if you
# publish a different port than the default below.
#
#   KIBANA_URL=http://localhost:5601  scripts/import-kibana-assets.sh claude-code
#
# Run from anywhere — it locates its own component directory like the others.

set -euo pipefail

KIBANA_URL=${KIBANA_URL:-http://localhost:5601}

# Resolve and enter the component root (parent of this scripts/ directory) so the
# per-source NDJSON paths resolve regardless of the caller's cwd.
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

# Import every NDJSON in a directory in dependency category order: data views
# before the saved searches and dashboards that reference them. Missing
# categories are skipped silently (not every source ships all three).
import_dir() {
  dir=$1
  [ -d "$dir" ] || fail "$dir not found"
  for category in data-views saved-searches dashboard; do
    for f in "$dir"/*"$category".ndjson; do
      [ -f "$f" ] || continue
      import_file "$f"
    done
  done
}

[ "$#" -ge 1 ] || fail "usage: import-kibana-assets.sh <source>... (e.g. claude-code)"

echo "[import] importing Kibana saved objects into $KIBANA_URL…"

# Each requested source namespace.
for src in "$@"; do
  import_dir "$src"
done

echo
echo "PASS: Kibana saved objects imported into $KIBANA_URL (sources: $*)."
echo "Open Discover (Open menu) for the saved searches, or the data-view selector"
echo "for the Metrics / Events / Traces views."
