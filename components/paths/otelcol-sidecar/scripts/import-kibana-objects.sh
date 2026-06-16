#!/usr/bin/env bash
#
# import-kibana-objects.sh — import the otelcol-sidecar path's Kibana saved objects.
#
# Scope: the **path** component assets — the sidecar self-telemetry data view
# (OTel Collector Sidecar — Metrics, on metrics-apm.app.otelcol_sidecar*). The
# sidecar emits only metrics, so there are no saved searches; the visualization
# surface is the Health dashboard. A stack that includes this path composes the
# imports by running the backend's import, then the agent's, then this one.
#
# Imports the NDJSON files in ../kibana/ through the Kibana Saved Objects
# `_import?overwrite=true` API: the self-telemetry data view first, then the
# Health dashboard that references it (a by-value Lens dashboard, id
# otelcol-sidecar-health). Prints the per-file import result.
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

# Data view first — the Health dashboard references the otelcol-sidecar-metrics
# data view, so it must be imported before the dashboard.
FILES="
kibana/data-views.ndjson
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

echo "[import] importing otelcol-sidecar Kibana saved objects into $KIBANA_URL…"
for f in $FILES; do
  import_file "$f"
done

echo
echo "PASS: otelcol-sidecar Kibana saved objects imported. Open the OTel Collector"
echo "Sidecar — Health dashboard, or pick the OTel Collector Sidecar — Metrics data"
echo "view in Discover to inspect the otelcol_* self-metrics."
