#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: setup-telemetry.sh <agent_home> <otlp_endpoint> [otlp_api_key]" >&2
  exit 1
fi
agent_home=$1
otlp_endpoint=$2
otlp_api_key=${3:-}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

"$SCRIPT_DIR/render-otel.sh" "$agent_home" \
  "$otlp_endpoint/v1/logs" "$otlp_endpoint/v1/traces" "$otlp_endpoint/v1/metrics" \
  "$otlp_api_key"
"$SCRIPT_DIR/render-mcp.sh" "$agent_home"
