#!/usr/bin/env bash
# Imports the Kibana saved objects for each SOURCE arg (a dir under this component)
# via the _import?overwrite=true API. Within each dir, files load in dependency
# order: data-views → saved-searches → dashboard. Needs curl, jq.

set -euo pipefail

KIBANA_URL=${KIBANA_URL:-http://localhost:5601}

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

# data-views → saved-searches → dashboard; missing categories are skipped.
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

for src in "$@"; do
  import_dir "$src"
done

echo
echo "PASS: Kibana saved objects imported into $KIBANA_URL (sources: $*)."
echo "Open Discover (Open menu) for the saved searches, or the data-view selector"
echo "for the Metrics / Events / Traces views."
