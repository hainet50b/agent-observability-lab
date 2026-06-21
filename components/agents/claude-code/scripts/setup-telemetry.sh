#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: setup-telemetry.sh <agent_home> <otlp_base> [otlp_api_key]" >&2
  exit 1
fi
agent_home=$1
otlp_base=$2
otlp_api_key=${3:-}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Optional OTLP auth. Empty key -> empty headers (rendered byte-identically);
# present -> OTEL_EXPORTER_OTLP_HEADERS = "Authorization=ApiKey <key>".
otlp_headers=""
if [ -n "$otlp_api_key" ]; then
  otlp_headers="Authorization=ApiKey $otlp_api_key"
fi

"$SCRIPT_DIR/render-otel.sh" "$agent_home" \
  "$otlp_base/v1/logs" "$otlp_base/v1/traces" "$otlp_base/v1/metrics" \
  "$otlp_headers" "$otlp_base"
