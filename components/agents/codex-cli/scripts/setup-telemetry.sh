#!/usr/bin/env bash

set -euo pipefail

[ "$#" -eq 2 ] || {
  echo "usage: setup-telemetry.sh <agent_home> <otlp_endpoint>" >&2
  exit 1
}
agent_home=$1
otlp_endpoint=$2

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

"$SCRIPT_DIR/render-otel.sh" "$agent_home" \
  "$otlp_endpoint/v1/logs" "$otlp_endpoint/v1/traces" "$otlp_endpoint/v1/metrics"
"$SCRIPT_DIR/render-mcp.sh" "$agent_home"
